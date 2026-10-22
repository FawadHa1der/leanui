module
public import Roster
/-!
# What is proved about the Roster app

The solver is not trusted, and with the "Lying solver" switch on it lies on purpose. What the app
shows is decided by `Problem.checkAnswer`, proved sound in `Roster.Core`, and the app's model
logic is the pure function `update`. So the property that matters is:

* `steps_inv`: after any sequence of messages, a roster on screen is valid for the problem on
  screen, and a set of shifts on screen means that no valid roster exists.

It holds because only `ask` sets a result, through `judge`, which keeps an answer only if the
checker accepts it (`judge_inv`); edits clear the result; and the other messages change neither
the problem nor the result.
-/
@[expose] public section
namespace Roster.Proofs
open Roster

def step (msg : Msg) (m : Model) : Model := (update msg m).1

/-- The app never shows an unchecked answer. -/
def Inv (m : Model) : Prop :=
  (∀ r, m.result = .staffed r → m.problem.Valid r) ∧
  (∀ T, m.result = .impossible T → ¬ ∃ r, m.problem.Valid r)

/-- With no result on screen there is nothing to be wrong. -/
theorem inv_none {m : Model} (h : m.result = .none) : Inv m :=
  ⟨fun _ e => by simp [h] at e, fun _ e => by simp [h] at e⟩

/-- `judge` shows an answer only if the checker accepts it, so it means what `checkAnswer_sound`
says. -/
theorem judge_inv (p : Problem) (a : Answer) (lie : String) :
    (∀ r, judge p a lie = .staffed r → p.Valid r) ∧
    (∀ T, judge p a lie = .impossible T → ¬ ∃ r, p.Valid r) := by
  unfold judge
  split
  · rename_i ok
    cases a with
    | staffed r => exact ⟨fun _ e => by cases e; exact p.checkAnswer_sound.1 r ok, nofun⟩
    | impossible T => exact ⟨nofun, fun _ e => by cases e; exact p.checkAnswer_sound.2 T ok⟩
  · exact ⟨nofun, nofun⟩

theorem ask_inv (m : Model) : Inv (ask m) := by
  unfold ask; split <;> exact judge_inv _ _ _

/-- Every message keeps the invariant. -/
theorem step_inv (msg : Msg) (m : Model) (h : Inv m) : Inv (step msg m) := by
  cases msg with
  -- edits clear the result
  | toggle _ _ | more _ | fewer _ | preset _ | random => exact inv_none rfl
  | ask => exact ask_inv m
  -- the rest change neither the problem nor the result
  | liar _ => exact h
  | notarize | notarized _ _ => simp only [step, update]; (repeat' split) <;> exact h

/-- Any sequence of messages, from the initial model. -/
theorem steps_inv (msgs : List Msg) : Inv (msgs.foldl (fun m msg => step msg m) init) := by
  suffices ∀ m, Inv m → Inv (msgs.foldl (fun m msg => step msg m) m) from
    this _ (inv_none rfl)
  induction msgs with
  | nil => intro m h; exact h
  | cons msg rest ih => intro m h; exact ih _ (step_inv msg m h)

/-! The build fails if any of these ever depends on `sorryAx` or on a non-standard axiom. -/

/-- info: 'Roster.Proofs.step_inv' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms step_inv
/-- info: 'Roster.Proofs.steps_inv' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms steps_inv

end Roster.Proofs
