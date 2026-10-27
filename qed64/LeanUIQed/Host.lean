module
public import LeanUI.App
/-!
# The stdin/stdout host

The host for running a LeanUI program in Lean's own interpreter (`lean --run`), natively or in
QED64's `lean.wasm` (qed64/README.md), where nothing of LeanUI is compiled: the program, LeanUI's
diff and the buffer writers are all interpreted IR; only `Init`/`Std` run as the compiled code
inside the `lean` binary. It talks over the process's standard streams, so it needs nothing but a
`lean` that can `--run` a file. Compiled (`bench-host`, `life-host`), it is the reference the
interpreted runs are compared with byte for byte.

Each update is `[u32 opsBytes][ops][strs]` (the bytes the native server sends, docs/PROTOCOL.md
§1, the format `vir/LeanUIVir/Host.lean` also returns), so any LeanUI runtime that applies server
buffers applies these.

## Framing

Input, one message after another (a header line, then exactly `n` payload bytes, UTF-8):

    e <slot> <n>\n<payload>          an event on a listener slot
    c <cb> <0|1> <n>\n<payload>      an effect result or a subscription tick
    p\n                              ping: an empty reply at once (a round trip's floor)
    q\n                              quit (end of input quits too)

Output: the reply to the boot, then one reply per message. A reply is the updates the call made,
in order, then one end line:

    u <base64>\n                     one update (`--out b64`, the default: text-safe)
    u <n>\n<n raw bytes>             one update (`--out raw`: binary, for pipes that carry bytes)
    . <leanNs> <encodeNs>\n          end of reply: nanoseconds in LeanUI (update, view, diff, the
                                     buffer) and in encoding the reply's updates
    ! <message>\n                    a message it could not parse (then the end line); after an
                                     input error (the input ended inside a payload) the host
                                     exits with status 1

Arguments: `--selector <css>` (default `#app`), `--flags <string>` (default empty),
`--out b64|raw`.
-/
public section
namespace LeanUIQed

/-- One update as the server encodes it. -/
def encode (ops strs : ByteArray) : ByteArray :=
  LeanUI.pushU32 (ByteArray.emptyWithCapacity (4 + ops.size + strs.size)) ops.size.toUInt32 ++ ops ++ strs

/-- The base64 alphabet (RFC 4648 §4). -/
def b64Alphabet : ByteArray := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toUTF8

/-- Append `b` in base64, padded. -/
def base64 (b : ByteArray) (out : ByteArray) : ByteArray := Id.run do
  let t := b64Alphabet
  let n := b.size
  let mut out := out
  let mut i := 0
  while i + 3 ≤ n do
    let x := (b[i]!.toUInt32 <<< 16) ||| (b[i + 1]!.toUInt32 <<< 8) ||| b[i + 2]!.toUInt32
    out := out.push t[(x >>> 18 &&& 63).toNat]! |>.push t[(x >>> 12 &&& 63).toNat]!
      |>.push t[(x >>> 6 &&& 63).toNat]! |>.push t[(x &&& 63).toNat]!
    i := i + 3
  if n - i == 1 then
    let x := b[i]!.toUInt32 <<< 16
    out := out.push t[(x >>> 18 &&& 63).toNat]! |>.push t[(x >>> 12 &&& 63).toNat]! |>.push 61 |>.push 61
  else if n - i == 2 then
    let x := (b[i]!.toUInt32 <<< 16) ||| (b[i + 1]!.toUInt32 <<< 8)
    out := out.push t[(x >>> 18 &&& 63).toNat]! |>.push t[(x >>> 12 &&& 63).toNat]!
      |>.push t[(x >>> 6 &&& 63).toNat]! |>.push 61
  return out

inductive Out | b64 | raw
  deriving BEq

structure Config where
  selector : String := "#app"
  flags : String := ""
  out : Out := .b64

def parseArgs : Config → List String → Except String Config
  | c, [] => .ok c
  | c, "--selector" :: s :: rest => parseArgs { c with selector := s } rest
  | c, "--flags" :: s :: rest => parseArgs { c with flags := s } rest
  | c, "--out" :: "b64" :: rest => parseArgs { c with out := .b64 } rest
  | c, "--out" :: "raw" :: rest => parseArgs { c with out := .raw } rest
  | _, a :: _ => .error s!"unknown argument {a.quote} (expected --selector, --flags, --out b64|raw)"

/-- A running app and the updates it made since the host last wrote them. -/
structure Session where
  inst : LeanUI.Instance
  out : IO.Ref (Array ByteArray)

def take (s : Session) : IO (Array ByteArray) := s.out.modifyGet fun a => (a, #[])

/-- Write one reply: the updates, then the end line with the two times. -/
def reply (o : IO.FS.Stream) (cfg : Config) (ups : Array ByteArray) (leanNs : Nat) (err : String := "") : IO Unit := do
  let t0 ← IO.monoNanosNow
  let mut buf := ByteArray.emptyWithCapacity 256
  for u in ups do
    match cfg.out with
    | .b64 => buf := base64 u (buf.push 117 |>.push 32) |>.push 10
    | .raw => buf := (buf ++ s!"u {u.size}\n".toUTF8) ++ u
  if !err.isEmpty then buf := buf ++ s!"! {err.replace "\n" " "}\n".toUTF8
  let t1 ← IO.monoNanosNow
  o.write buf
  o.putStr s!". {leanNs} {t1 - t0}\n"
  o.flush

/-- Read exactly `n` bytes. -/
partial def readExact (i : IO.FS.Stream) (n : Nat) (acc : ByteArray := .empty) : IO ByteArray := do
  if acc.size ≥ n then return acc
  let chunk ← i.read (n - acc.size).toUSize
  if chunk.isEmpty then throw (IO.userError s!"input ended {n - acc.size} bytes short of a payload")
  readExact i n (acc ++ chunk)

def u32? (s : String) : Option UInt32 :=
  match s.toNat? with
  | some n => if n < 4294967296 then some n.toUInt32 else none
  | none => none

/-- One message: what to run, or why it could not be parsed. `none` at the end of input. -/
def readMsg (i : IO.FS.Stream) : IO (Option (Except String (LeanUI.Instance → IO Unit))) := do
  let line ← i.getLine
  if line.isEmpty then return none
  let payload (n : String) : IO (Except String String) := do
    match n.toNat? with
    | none => return .error s!"bad payload length {n.quote}"
    | some k =>
      match String.fromUTF8? (← readExact i k) with
      | some p => return .ok p
      | none => return .error "payload is not UTF-8"
  match (line.trimAsciiEnd.toString.splitOn " ") with
  | ["q"] => return none
  | ["p"] => return some (.ok fun _ => pure ())
  | ["e", slot, n] =>
    let p ← payload n
    return some do
      let p ← p
      let some s := u32? slot | .error s!"bad listener slot {slot.quote}"
      return fun inst => inst.event s p
  | ["c", cb, ok, n] =>
    let p ← payload n
    return some do
      let p ← p
      let some c := u32? cb | .error s!"bad callback id {cb.quote}"
      let ok ← match ok with
        | "1" => pure true
        | "0" => pure false
        | _ => .error s!"bad callback status {ok.quote}"
      return fun inst => inst.callback c ok p
  | _ => return some (.error s!"not a message: {(line.take 40).toString.quote}")

/-- Boot `p`, write the first reply, then serve messages until `q` or the end of input. -/
def serve {Model Msg : Type} (p : LeanUI.Program Model Msg) (args : List String) : IO UInt32 := do
  let cfg ← match parseArgs {} args with
    | .ok c => pure c
    | .error e => IO.eprintln e; return 2
  let i ← IO.getStdin
  let o ← IO.getStdout
  let out ← IO.mkRef #[]
  let t0 ← IO.monoNanosNow
  let inst ← LeanUI.start p { flush := fun ops strs => out.modify (·.push (encode ops strs)) } cfg.flags cfg.selector false
  let s : Session := { inst, out }
  let t1 ← IO.monoNanosNow
  reply o cfg (← take s) (t1 - t0)
  repeat
    -- a read that fails (input ended inside a payload) ends the session with an error reply
    let m ← try readMsg i catch e => do reply o cfg #[] 0 (toString e); return 1
    match m with
    | none => break
    | some (.error e) => reply o cfg #[] 0 e
    | some (.ok run) =>
      let t0 ← IO.monoNanosNow
      run s.inst
      let ups ← take s
      let t1 ← IO.monoNanosNow
      reply o cfg ups (t1 - t0)
  return 0

end LeanUIQed
