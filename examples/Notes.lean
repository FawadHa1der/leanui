module
public import LeanUI
meta import LeanUI.Syntax
public section
open LeanUI

namespace Notes

structure Note where
  id : Nat
  text : String

structure Model where
  notes : Array Note := #[]
  draft : String := ""
  nextId : Nat := 1

inductive Msg | draft (s : String) | add | remove (id : Nat)

def update : Msg → Model → Model × Cmd Msg
  | .draft s, m => ({ m with draft := s }, .none)
  | .add, m =>
    if m.draft.isEmpty then (m, .none)
    else ({ m with notes := m.notes.push ⟨m.nextId, m.draft⟩, nextId := m.nextId + 1, draft := "" }, .none)
  | .remove i, m => ({ m with notes := m.notes.filter (·.id != i) }, .none)

def view (m : Model) : Html Msg :=
  <main class="notes">
    <form onSubmit={fun _ => .add}>
      <input value={m.draft} onInput={.draft} placeholder="A note" />
      <button>Add</button>
    </form>
    <ul>
      {...m.notes.map fun n =>
        keyed (toString n.id) <li>{n.text}{" "}<button onClick={.remove n.id}>×</button></li>}
    </ul>
  </main>

def program : Program Model Msg := { init := fun _ => ({}, .none), update, view }

end Notes
