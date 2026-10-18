module
public import LeanUI.App
public import LeanUI.Testing.Dom
public section
namespace LeanUI.Testing

/-- A program running against the DOM model. -/
structure Running where
  inst : Instance
  dom : IO.Ref Dom

/-- Start a program in the model, mounted under `"#app"`. -/
def run {Model Msg : Type} (p : Program Model Msg) (flags := "") : IO Running := do
  let dom ← IO.mkRef ({} : Dom)
  let host : Host := { flush := fun ops strs => dom.modify (·.apply ops strs) }
  let inst ← start p host flags "#app" false
  return { inst, dom }

namespace Running

def root (r : Running) : IO UInt32 := do
  let some h := (← r.dom.get).rootOf "#app" | throw (IO.userError "nothing mounted")
  return h

/-- The first node under the root whose attribute `name` equals `value`. -/
def find (r : Running) (name value : String) : IO UInt32 := do
  let d ← r.dom.get
  let all := d.reachable (← r.root)
  match all.find? fun h => (d.get h).attrs.any (· == (name, value)) with
  | some h => return h
  | none => throw (IO.userError s!"no node with {name}={value}")

/-- Fire `event` on a node, as the browser's delegated listener would (bubbling to ancestors). -/
partial def fire (r : Running) (h : UInt32) (event : String) (payload := "") : IO Unit := do
  let d ← r.dom.get
  match (d.get h).listeners.find? (·.1 == event) with
  | some (_, slot, _, _) => r.inst.event slot payload
  | none => match (d.get h).parent with
    | some p => r.fire p event payload
    | none => throw (IO.userError s!"no {event} listener on node {h} or its ancestors")

def click (r : Running) (name value : String) : IO Unit := do r.fire (← r.find name value) "click"

def canon (r : Running) : IO String := do return (← r.dom.get).canon (← r.root)

/-- Check the invariants every update must keep: the DOM equals the view, the protocol was
followed, and no handle or listener slot leaked. -/
def check {Msg : Type} (r : Running) (expected : Html Msg) (what : String) : IO Unit := do
  let d ← r.dom.get
  let root ← r.root
  unless d.errors.isEmpty do throw (IO.userError s!"{what}: protocol errors {d.errors}")
  let got := d.canon root
  let want := canonHtml expected
  unless got == want do throw (IO.userError s!"{what}: DOM differs\n got: {got.take 400}\nwant: {want.take 400}")
  let live := (d.reachable root).size
  unless live == d.nodes.size do
    throw (IO.userError s!"{what}: {d.nodes.size - live} leaked handles ({d.nodes.size} known, {live} attached)")

end Running
end LeanUI.Testing
