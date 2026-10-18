import LeanUI.Testing.Harness
import Notes
open LeanUI LeanUI.Testing

/-! The test from docs/GUIDE.md section 3 (plus a line of output), so the guide's code is compiled and run. -/

def main : IO UInt32 := do
  let r ← run Notes.program
  r.fire (← r.find "placeholder" "A note") "input" "buy milk"
  r.fire (← r.find "placeholder" "A note") "submit" "" -- from the input, it bubbles to the form
  r.check (Notes.view { notes := #[⟨1, "buy milk"⟩], nextId := 2 }) "after adding"
  IO.println "docs/GUIDE.md example: ok"
  return 0
