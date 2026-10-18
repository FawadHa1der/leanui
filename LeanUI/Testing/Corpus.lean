module
public import LeanUI.Testing.Spec
public import LeanUI.Testing.Harness
/-!
# A replay corpus for the browser runtime

The DOM model (`Testing.Dom`) is the reference `runtime/leanui.js` is checked against. This
module writes what a browser needs to replay a native session and compare: every buffer the
engine flushed (`Buf.encode`, base64), and after each one the DOM the model holds (strict canon
with listener slots, properties by pre-order index) and, for every listener, the slots a
dispatched event must reach (bubbling, `stopPropagation`), the payloads it must carry and whether
the default is prevented. `tests/browser/fuzz.mjs` replays it in Chromium and Firefox.
-/
public section
namespace LeanUI.Testing.Corpus

private def b64chars : Array Char := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toList.toArray

def base64 (b : ByteArray) : String := Id.run do
  let mut out := ""
  let mut i := 0
  while i < b.size do
    let x0 := b[i]!.toNat
    let x1 := if i + 1 < b.size then b[i + 1]!.toNat else 0
    let x2 := if i + 2 < b.size then b[i + 2]!.toNat else 0
    let n := (x0 <<< 16) ||| (x1 <<< 8) ||| x2
    out := out.push b64chars[(n >>> 18) &&& 63]! |>.push b64chars[(n >>> 12) &&& 63]!
    out := if i + 1 < b.size then out.push b64chars[(n >>> 6) &&& 63]! else out.push '='
    out := if i + 2 < b.size then out.push b64chars[n &&& 63]! else out.push '='
    i := i + 3
  return out

private def hex4 (n : Nat) : String :=
  let ds := Nat.toDigits 16 n
  String.ofList (List.replicate (4 - ds.length) '0' ++ ds)

/-- A JSON string literal. -/
def json (s : String) : String :=
  "\"" ++ s.foldl (init := "") (fun acc c =>
    if c == '"' then acc ++ "\\\"" else if c == '\\' then acc ++ "\\\\"
    else if c == '\n' then acc ++ "\\n" else if c == '\r' then acc ++ "\\r" else if c == '\t' then acc ++ "\\t"
    else if c.val < 0x20 then acc ++ "\\u" ++ hex4 c.val.toNat
    else acc.push c) ++ "\""

def jsonArr (xs : Array String) : String := "[" ++ ",".intercalate xs.toList ++ "]"

/-- Handles in the browser's pre-order (comments are not nodes of the model). -/
partial def preorder (d : Dom) (h : UInt32) (acc : Array UInt32 := #[]) : Array UInt32 :=
  (d.get h).kids.foldl (fun acc k => preorder d k acc) (acc.push h)

/-- The payload `runtime/leanui.js` extracts for a synthetic event of type `ev` on node `h`.
`formData` reads the element's form (itself, or the form a control belongs to; nothing for other
elements); the generated views name no form fields, so it is always empty. -/
def expectedPayload (d : Dom) (h : UInt32) (ev : String) (code : UInt32) : Option String :=
  let n := d.get h
  let prop (k : String) := (n.props.find? (·.1 == k)).map (·.2)
  if code == Payload.value.code then
    some (if n.tag == "li" then "0" else (prop "value").getD "")
  else if code == Payload.checked.code then some (if prop "checked" == some "true" then "true" else "false")
  else if code == Payload.key.code then some (if ev == "keydown" then "Enter" else "")
  else if code == Payload.formData.code then some ""
  else some ""

/-- The listeners an event of type `ev` dispatched on `h` reaches, in order: the node and its
ancestors with a listener for `ev`, up to the first that stops propagation. An event that does not
bubble reaches the node only. -/
partial def chain (d : Dom) (root : UInt32) (h : UInt32) (ev : String) (acc : Array String := #[]) : Array String :=
  let n := d.get h
  let (acc, stop) := match n.listeners.find? (·.1 == ev) with
    | some (_, sl, pl, fl) =>
      let p := match expectedPayload d h ev pl with | some s => json s | none => "null"
      (acc.push s!"[{sl},{p},{fl}]", fl &&& 2 != 0)
    | none => (acc, false)
  if stop || h == root || LeanUI.Testing.Running.nonBubbling.contains ev then acc
  else match n.parent with
    | some p => chain d root p ev acc
    | none => acc

/-- One step of a replay: the DOM after the buffer, properties, and event expectations. -/
def stepJson (d : Dom) (buf : ByteArray) : String := Id.run do
  let some root := d.rootOf "#app" | return s!"\{\"buf\":{json (base64 buf)},\"canon\":null}"
  let order := preorder d root
  let canon := strictDom d root (slots := true) (props := false)
  let mut props := #[]
  let mut fires := #[]
  for h : i in [0:order.size] do
    let n := d.get order[i]
    for (k, v) in n.props do props := props.push s!"[{i},{json k},{json v}]"
    for (ev, _, _, _) in n.listeners do
      fires := fires.push s!"[{i},{json ev},{jsonArr (chain d root order[i] ev)}]"
  return s!"\{\"buf\":{json (base64 buf)},\"canon\":{json canon},\"props\":{jsonArr props},\"fires\":{jsonArr fires}}"

end LeanUI.Testing.Corpus
