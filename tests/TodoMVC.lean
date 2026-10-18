import LeanUI
import LeanUI.Testing.Harness
import TodoMVC
open LeanUI LeanUI.Testing

/-! TodoMVC against the DOM model, following the TodoMVC specification step by step. Every action
goes through the same event path the browser uses (delegated listener slots, extracted payloads,
effect callbacks). After each one the test replays the message on its own copy of the model with
`TodoMVC.step` and checks that the DOM equals that model's view (and that no handle leaked), then
checks the spec's visible behaviour directly. -/

structure T where
  r : Running
  model : IO.Ref TodoMVC.Model

def fail (what : String) : IO α := throw (IO.userError what)
def expect (what : String) (ok : Bool) (detail := "") : IO Unit :=
  unless ok do fail s!"{what} {detail}"

/-- Handles of the elements whose class list contains `c`, in document order. -/
def withClass (d : Dom) (root : UInt32) (c : String) : Array UInt32 :=
  (d.reachable root).filter fun h => ((d.get h).attrs.find? (·.1 == "class")).any fun (_, v) => (v.splitOn " ").contains c

def T.dom (t : T) : IO Dom := t.r.dom.get
def T.nth (t : T) (c : String) (i : Nat := 0) : IO UInt32 := do
  let d ← t.dom
  match (withClass d (← t.r.root) c)[i]? with
  | some h => return h
  | none => fail s!"no element .{c} #{i}"
def T.count (t : T) (c : String) : IO Nat := do return (withClass (← t.dom) (← t.r.root) c).size
partial def textIn (d : Dom) (h : UInt32) : String :=
  let n := d.get h
  if n.isText then n.text else String.join (n.kids.toList.map (textIn d))
def T.text (t : T) (c : String) (i : Nat := 0) : IO String := do return textIn (← t.dom) (← t.nth c i)
def T.prop (t : T) (h : UInt32) (k : String) : IO (Option String) := do
  return ((← t.dom).get h).props.find? (·.1 == k) |>.map (·.2)

/-- Deliver `msg`'s event, mirror it on the model, check the DOM against the mirrored view. -/
def T.act (t : T) (what : String) (msg : TodoMVC.Msg) (deliver : IO Unit) : IO Unit := do
  deliver
  t.model.modify (TodoMVC.step msg)
  t.r.check (TodoMVC.view (← t.model.get)) what

/-- Double-click a todo's label (the second child of its `.view`). -/
def T.dblclick (t : T) (what : String) (i : Nat) (msg : TodoMVC.Msg) : IO Unit :=
  t.act what msg do
    let label := ((← t.dom).get (← t.nth "view" i)).kids[1]!
    t.r.fire label "dblclick" ""

def T.fire (t : T) (what : String) (c : String) (i : Nat) (event : String) (payload : String) (msg : TodoMVC.Msg) : IO Unit :=
  t.act what msg do t.r.fire (← t.nth c i) event payload

/-- The callback id of the last effect that starts with `pfx`. -/
def lastCb (t : T) (pfx : String) : IO UInt32 := do
  let some e := (← t.dom).effects.reverse.find? (·.startsWith pfx) | fail s!"no effect {pfx}"
  let rest := e.drop pfx.length
  let digits := rest.takeWhile Char.isDigit
  return digits.toString.toNat!.toUInt32

def lastStored (t : T) : IO String := do
  let pfx := s!"storageSet {TodoMVC.storageKey}="
  let some e := (← t.dom).effects.reverse.find? (·.startsWith pfx) | fail "nothing stored"
  return (e.drop pfx.length).toString

def type (t : T) (s : String) : IO Unit := t.fire s!"type {s.quote}" "new-todo" 0 "input" s (.field s)
def enter (t : T) : IO Unit := t.fire "Enter in new-todo" "new-todo" 0 "keydown" "Enter" (.newKey "Enter")
def add (t : T) (s : String) : IO Unit := do type t s; enter t

def main : IO UInt32 := do
  IO.println "TodoMVC (DOM model)"
  let r ← run TodoMVC.program "/index.html#/"
  let t : T := { r, model := ← IO.mkRef (TodoMVC.init "/index.html#/").1 }
  r.check (TodoMVC.view (← t.model.get)) "first render"
  expect "no todos: main and footer hidden" ((← t.count "main") == 0 && (← t.count "footer") == 0)
  expect "focus on new-todo at start" ((← t.dom).effects.any (·.endsWith ".new-todo"))
  -- the stored list arrives
  let stored := "[{\"title\":\"read the spec\",\"completed\":true},{\"title\":\"write Lean\"}]"
  let cb ← lastCb t "storageGet cb="
  t.act "load from storage" (.loaded (some stored)) (r.inst.callback cb true stored)
  expect "two loaded todos" ((← t.count "todo-list") == 1 && (← t.text "todo-count") == "1 item left") (← t.text "todo-count")
  -- add: trimmed, empty ignored, field cleared
  add t "  buy milk  "
  expect "added trimmed" ((← t.text "view" 2) == "buy milk")
  expect "field cleared" ((← t.prop (← t.nth "new-todo") "value") == some "")
  add t "   "
  expect "blank not added" ((← t.count "toggle") == 3)
  expect "stored as JSON" ((← lastStored t) == "[{\"title\":\"read the spec\",\"completed\":true},{\"title\":\"write Lean\",\"completed\":false},{\"title\":\"buy milk\",\"completed\":false}]") (← lastStored t)
  expect "counter pluralises" ((← t.text "todo-count") == "2 items left")
  -- toggle one
  t.fire "toggle 'write Lean'" "toggle" 1 "change" "true" (.toggle 2 true)
  expect "completed class" ((← t.count "completed") == 2 && (← t.text "todo-count") == "1 item left")
  -- edit: Escape cancels, Enter saves trimmed, blur saves, empty deletes
  t.dblclick "double-click label" 2 (.edit 3)
  expect "editing" ((← t.count "editing") == 1 && (← t.prop (← t.nth "edit") "value") == some "buy milk")
  expect "editor focused" ((← t.dom).effects.back?.any (·.endsWith ".todo-list li.editing .edit"))
  t.fire "draft" "edit" 0 "input" "oat milk" (.draft "oat milk")
  t.fire "Escape" "edit" 0 "keydown" "Escape" (.editKey "Escape")
  expect "escape cancels" ((← t.count "editing") == 0 && (← t.text "view" 2) == "buy milk")
  t.dblclick "edit again" 2 (.edit 3)
  t.fire "draft 2" "edit" 0 "input" "  oat milk " (.draft "  oat milk ")
  t.fire "Enter saves" "edit" 0 "keydown" "Enter" (.editKey "Enter")
  expect "saved trimmed" ((← t.text "view" 2) == "oat milk" && (← t.count "editing") == 0)
  t.dblclick "edit first" 0 (.edit 1)
  t.fire "draft 3" "edit" 0 "input" "read the whole spec" (.draft "read the whole spec")
  t.fire "blur saves" "edit" 0 "focusout" "" .commit
  expect "blur saved" ((← t.text "view" 0) == "read the whole spec")
  t.dblclick "edit second" 1 (.edit 2)
  t.fire "empty draft" "edit" 0 "input" "  " (.draft "  ")
  t.fire "Enter with empty title deletes" "edit" 0 "keydown" "Enter" (.editKey "Enter")
  expect "deleted by empty edit" ((← t.count "toggle") == 2)
  -- destroy
  add t "walk"
  t.fire "destroy" "destroy" 2 "click" "" (.destroy 4)
  expect "destroyed" ((← t.count "toggle") == 2)
  -- toggle all, both ways
  t.fire "toggle all on" "toggle-all" 0 "change" "true" (.toggleAll true)
  expect "all completed" ((← t.count "completed") == 2 && (← t.text "todo-count") == "0 items left")
  expect "toggle-all checked" ((← t.prop (← t.nth "toggle-all") "checked") == some "true")
  t.fire "toggle all off" "toggle-all" 0 "change" "false" (.toggleAll false)
  expect "none completed" ((← t.count "completed") == 0 && (← t.count "clear-completed") == 0)
  -- filters from the URL fragment (the url subscription)
  t.fire "complete first" "toggle" 0 "change" "true" (.toggle 1 true)
  let sub ← lastCb t s!"op{Op.urlListen} "
  t.act "#/active" (.urlChanged "/index.html#/active") (r.inst.callback sub true "/index.html#/active")
  expect "active filter" ((← t.count "toggle") == 1 && (← t.text "selected") == "Active")
  t.act "#/completed" (.urlChanged "/index.html#/completed") (r.inst.callback sub true "/index.html#/completed")
  expect "completed filter" ((← t.count "toggle") == 1 && (← t.text "view" 0) == "read the whole spec")
  t.act "#/" (.urlChanged "/index.html#/") (r.inst.callback sub true "/index.html#/")
  expect "all filter" ((← t.count "toggle") == 2 && (← t.text "selected") == "All")
  -- clear completed
  expect "clear-completed shown" ((← t.count "clear-completed") == 1)
  t.fire "clear completed" "clear-completed" 0 "click" "" .clearCompleted
  expect "cleared" ((← t.count "toggle") == 1 && (← t.count "completed") == 0 && (← t.count "clear-completed") == 0)
  expect "stored after clear" ((← lastStored t) == "[{\"title\":\"oat milk\",\"completed\":false}]") (← lastStored t)
  -- a first render at #/completed shows that filter
  let r2 ← run TodoMVC.program "/index.html#/completed"
  let t2 : T := { r := r2, model := ← IO.mkRef (TodoMVC.init "/index.html#/completed").1 }
  let cb2 ← lastCb t2 "storageGet cb="
  t2.act "reload at #/completed" (.loaded (some stored)) (r2.inst.callback cb2 true stored)
  expect "initial filter from flags" ((← t2.text "selected") == "Completed" && (← t2.count "toggle") == 1)
  IO.println "  spec walk-through: ok"
  return 0
