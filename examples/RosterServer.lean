module
public import LeanUI.Server
public import LeanUI.Json
public import Roster.Receipt
public import Roster.Solver
meta import LeanUI.Json.Derive
/-!
# `leanui-roster`: the Roster demo and its notary

    leanui-roster [--port 5370] [--host 127.0.0.1] [--dist dist] [--receipts .lake/roster-receipts] [--quiet]
    leanui-roster --notarize-sample OUT.ndjson

Run from the repository root (it runs `roster/notary/notarize.sh`). It serves:

* `/roster/`: the app, a client-side wasm app (`dist/roster`, from `tools/build-app.sh RosterApp
  roster`), and below it `/roster/verify/`, the verify page (`dist/roster/verify`, from
  `roster/verify/build.sh`);
* `/roster/receipts/<id>.ndjson`: the receipts the notary wrote (in `--receipts`);
* `POST /roster/notarize`: a problem and a roster for it,
  `{"people":[…],"shifts":[…],"need":[…],"avail":[[…]],"roster":[n|null,…]}`, answered with
  `{"url":"/roster/receipts/<id>.ndjson","ms":n}` or `{"error":"…"}`: 400 for a roster that
  `checkRoster` rejects or a malformed or too large problem, 503 when the notary cannot run.

The server trusts the request no more than the app trusts its solver: it checks the roster again,
writes `Roster.receiptSource` to a fresh temporary directory and runs the notary there, which has
Lean 4.35's kernel prove the roster valid and exports the proof (`roster/notary`). A receipt gets
a random name, and the latest 1,000 are kept. The kernel's time grows with the problem, so
problems are limited to 100 people and 30 shifts (about 3 s) and bodies to 64 KiB, and the notary
takes one receipt at a time, on a thread of its own, with a short queue: other requests are not
held up.
-/
public section
open LeanUI LeanUI.Server Std.Async

namespace RosterServer

structure Opts where
  port : UInt16 := 5370
  host : String := "127.0.0.1"
  dist : System.FilePath := "dist"
  receipts : System.FilePath := ".lake/roster-receipts"
  quiet : Bool := false
  /-- Notarize the Feasible preset's roster into this file, and exit. -/
  sample : Option System.FilePath := none

partial def parseArgs : List String → Opts → Except String Opts
  | [], o => .ok o
  | "--port" :: p :: rest, o => match p.toNat? with
    | some n => if n < 65536 then parseArgs rest { o with port := n.toUInt16 } else .error s!"bad port {p}"
    | none => .error s!"bad port {p}"
  | "--host" :: h :: rest, o => parseArgs rest { o with host := h }
  | "--dist" :: d :: rest, o => parseArgs rest { o with dist := d }
  | "--receipts" :: d :: rest, o => parseArgs rest { o with receipts := d }
  | "--notarize-sample" :: f :: rest, o => parseArgs rest { o with sample := some f }
  | "--quiet" :: rest, o => parseArgs rest { o with quiet := true }
  | a :: _, _ => .error s!"unknown argument {a}"

/-! ## The request -/

/-- The body of `POST /roster/notarize`: a `Roster.Problem` and the roster, `null` for nobody's
shift. -/
structure Request where
  people : List String
  shifts : List String
  need : List Nat
  avail : List (List Bool)
  roster : List (Option Nat)
  deriving FromJson

/-- The largest problem the notary takes. -/
def maxPeople := 100
def maxShifts := 30

/-- The problem and roster of a request, if the notary should take them: a rectangular problem
within the limits, and a roster that `checkRoster` accepts. -/
def parse (body : ByteArray) : Except String (Roster.Problem × Roster.Roster) := do
  let some text := String.fromUTF8? body | throw "the body is not UTF-8"
  let q ← Json.decode Request text
  let p : Roster.Problem := { people := q.people, shifts := q.shifts, need := q.need, avail := q.avail }
  if p.people.length > maxPeople || p.shifts.length > maxShifts then
    throw s!"the notary takes at most {maxPeople} people and {maxShifts} shifts"
  unless p.need.length == p.shifts.length && p.avail.length == p.people.length &&
      p.avail.all (·.length == p.shifts.length) do
    throw "expected a need for each shift and a row of availability for each person, with an entry for each shift"
  unless p.checkRoster q.roster do
    -- the verdict is `checkRoster`'s; `diagnose` only puts it in words
    throw s!"not a valid roster: {Roster.diagnose p (.staffed q.roster)}"
  return (p, q.roster)

def error (status : Nat) (why : String) : Res := Res.json (Json.mkObj [("error", .str why)]).compress status

/-! ## The notary -/

def notarizeSh : System.FilePath := "roster/notary/notarize.sh"

/-- The receipts kept, about 2 GB: the oldest go first. -/
def maxReceipts := 1000

/-- Remove the oldest receipts in `dir`, leaving room for one more. -/
def prune (dir : System.FilePath) : IO Unit := do
  let mut kept := #[]
  for e in ← dir.readDir do
    if e.fileName.endsWith ".ndjson" && !e.fileName.startsWith "." then
      kept := kept.push ((← e.path.metadata).modified, e.path)
  let oldest := kept.qsort fun a b => compare a.1 b.1 == .lt
  for (_, f) in oldest.extract 0 (oldest.size + 1 - maxReceipts) do IO.FS.removeFile f

/-- The receipt of a roster `checkRoster` accepted, from the notary, or the status to answer and
why not. -/
def prove (o : Opts) (p : Roster.Problem) (r : Roster.Roster) : IO (Except (Nat × String) ByteArray) := do
  unless ← notarizeSh.pathExists do
    return .error (503, s!"no notary at {notarizeSh} (run leanui-roster from the repository root)")
  IO.FS.withTempDir fun dir => do
    IO.FS.writeFile (dir / "Receipt.lean") (Roster.receiptSource p r)
    let out ← IO.Process.output {
      cmd := notarizeSh.toString, args := #[(dir / "Receipt.lean").toString, (dir / "receipt.ndjson").toString] }
    if out.exitCode != 0 then
      IO.eprint out.stderr
      -- the script's last line says what failed; 3: the toolchain is missing
      let why := (out.stderr.trimAsciiEnd.toString.splitOn "\n").getLast!
      return .error (if out.exitCode == 3 then 503 else 500, why)
    unless o.quiet do IO.print out.stdout
    return .ok (← IO.FS.readBinFile (dir / "receipt.ndjson"))

/-- Notarize a roster `checkRoster` accepted: the receipt's id, or the status to answer and why. -/
def notarize (o : Opts) (p : Roster.Problem) (r : Roster.Roster) : IO (Except (Nat × String) String) := do
  match ← prove o p r with
  | .error e => return .error e
  | .ok receipt =>
    -- a random name: one made from the contents could be aimed at another receipt's, by a request
    -- crafted to collide (the receipt states its own roster, and the verify page shows it)
    let id := String.ofList <| (← IO.getRandomBytes 16).toList.flatMap fun b =>
      (Nat.toDigits 16 (b.toNat + 256)).drop 1
    IO.FS.createDirAll o.receipts
    prune o.receipts
    -- renamed into place once written, so it is never served half written (dotfiles are not served)
    let part := o.receipts / s!".{id}.ndjson.part"
    IO.FS.writeBinFile part receipt
    IO.FS.rename part (o.receipts / s!"{id}.ndjson")
    return .ok id

/-- `--notarize-sample`: the receipt the LeanUI site serves, which has no notary
(`deploy/cloudflare/stage.sh`): the Feasible preset's roster, as the app's solver finds it. -/
def notarizeSample (o : Opts) (out : System.FilePath) : IO UInt32 := do
  let p := Roster.samples[0]!.2
  let .staffed r := Roster.solve p | IO.eprintln "leanui-roster: the Feasible preset cannot be staffed"; return 1
  unless p.checkRoster r do IO.eprintln "leanui-roster: the solver's roster for the Feasible preset is not valid"; return 1
  match ← prove o p r with
  | .ok receipt => IO.FS.writeBinFile out receipt; return 0
  | .error (_, why) => IO.eprintln s!"leanui-roster: {why}"; return 1

/-- Each receipt is a Lean process and they all use one Lake build, so the notary takes them one
at a time (`turn`); `queue` bounds the requests waiting or being served, and turns the rest away. -/
structure Notary where
  turn : Std.Semaphore
  queue : Std.Semaphore

/-- One receipt in the works and three waiting: about 12 s of waiting at the size limit. -/
def Notary.new : BaseIO Notary := return { turn := ← Std.Semaphore.new 1, queue := ← Std.Semaphore.new 4 }

/-- `POST /notarize`. The notary runs on a dedicated thread, and the handler awaits it without
holding one. -/
def notarizeRoute (o : Opts) (n : Notary) : Route := Route.post "/notarize" fun req => do
  let (p, r) ← match parse req.body with
    | .ok pr => pure pr
    | .error why => return error 400 why
  unless ← n.queue.tryAcquire do return error 503 "the notary is busy: try again in a moment"
  try
    await (← n.turn.acquire)
    try
      let t0 ← IO.monoMsNow
      match ← await (← IO.asTask (prio := .dedicated) (notarize o p r)) with
      | .ok (.ok id) =>
        let ms := (← IO.monoMsNow) - t0
        return Res.json (Json.mkObj [("url", .str s!"{req.base}/receipts/{id}.ndjson"), ("ms", toJson ms)]).compress
      | .ok (.error (status, why)) => return error status why
      | .error e => return error 500 s!"the notary failed: {e}"
    finally n.turn.release
  finally n.queue.release

def routes (o : Opts) (n : Notary) : Route :=
  Route.first [
    Route.get "/" fun _ => return Res.redirect "/roster/",
    Route.under "/roster" <| Route.first [
      notarizeRoute o n,
      Route.under "/receipts" (Static.route { root := o.receipts }),
      -- the app, and the verify page in its subdirectory
      Static.route { root := o.dist / "roster" }]]

def main (args : List String) : IO UInt32 := do
  let o ← match parseArgs args {} with
    | .ok o => pure o
    | .error e => IO.eprintln s!"leanui-roster: {e}"; return 2
  if let some out := o.sample then return ← notarizeSample o out
  unless ← (o.dist / "roster" / "app.wasm").pathExists do
    IO.eprintln s!"[roster] no app at {o.dist / "roster"} (run `tools/build-app.sh RosterApp roster`)"
  unless ← (o.dist / "roster" / "verify" / "checker.wasm").pathExists do
    IO.eprintln s!"[roster] no verify page at {o.dist / "roster" / "verify"} (run `roster/verify/build.sh`)"
  unless ← notarizeSh.pathExists do
    IO.eprintln s!"[roster] no notary at {notarizeSh}: run leanui-roster from the repository root"
  serve { port := o.port, host := o.host, log := !o.quiet, maxBody := 1 <<< 16 } (routes o (← Notary.new))
  return 0

end RosterServer

def main (args : List String) : IO UInt32 := RosterServer.main args
