module
/-!
# Roster: the problem, the specification, and checkers proved sound

One day of an event: people (rows) tick the shifts (columns) they can do, each shift needs a
number of people, and each person works at most one shift. A roster gives each person their
shift, if any, so nobody can be booked twice; `Valid` says the rest: it has one entry per person,
puts people only on shifts they can do, and gives every shift enough people.

An untrusted solver (`Roster.Solver`) answers "can we staff this?" with a roster or with a set of
shifts that is a *Hall violator*: distinct shifts that together need more people than can do any of
them. `checkAnswer` decides whether to believe it, and is proved sound:

* `checkRoster_iff`: `checkRoster` accepts exactly the valid rosters;
* `checkViolator_sound`: if `checkViolator` accepts `T`, no valid roster exists (pigeonhole: the
  people working the shifts of `T` are distinct and can each do a shift of `T`);
* `checkAnswer_sound`: what an accepted answer means.

This file imports only `Init`: it is also compiled by `roster/notary` (Lean 4.35, whose kernel
evaluates `checkRoster` on a receipt's data with `decide +kernel`) and by `roster/hall`
(Mathlib, which proves that a violator exists whenever no roster does). So the checkers are
plain structural recursion over lists that the kernel reduces well, and the proofs use only
core lemmas.
-/
@[expose] public section
namespace Roster

structure Problem where
  people : List String          -- names, display only
  shifts : List String          -- names, display only
  need   : List Nat             -- shift s needs `needOf s` people
  avail  : List (List Bool)     -- person i can do shift s: `canWork i s`
  deriving Repr, Inhabited

def Problem.canWork (p : Problem) (i s : Nat) : Bool := (p.avail.getD i []).getD s false
def Problem.needOf (p : Problem) (s : Nat) : Nat := p.need.getD s 0

/-- For each person, the shift they work, if any: one entry per person, so nobody can be booked
twice. -/
abbrev Roster := List (Option Nat)

/-- The specification. -/
def Problem.Valid (p : Problem) (r : Roster) : Prop :=
  r.length = p.people.length ∧
  (∀ i s, r[i]? = some (some s) → p.canWork i s = true) ∧
  (∀ s, s < p.shifts.length → p.needOf s ≤ r.count (some s))

/-- `Valid`, with its quantifiers bounded: past the end of the roster nobody works. -/
def Problem.checkRoster (p : Problem) (r : Roster) : Bool :=
  r.length == p.people.length &&
  (List.range r.length).all (fun i => match r[i]? with | some (some s) => p.canWork i s | _ => true) &&
  (List.range p.shifts.length).all fun s => p.needOf s ≤ r.count (some s)

theorem Problem.checkRoster_iff (p : Problem) (r : Roster) : p.checkRoster r = true ↔ p.Valid r := by
  simp only [checkRoster, Valid, Bool.and_eq_true, beq_iff_eq, List.all_eq_true, List.mem_range,
    decide_eq_true_eq]
  constructor
  · rintro ⟨⟨hlen, hwork⟩, hneed⟩
    refine ⟨hlen, fun i s h => ?_, hneed⟩
    obtain ⟨hi, _⟩ := List.getElem?_eq_some_iff.1 h
    simpa [h] using hwork i hi
  · rintro ⟨hlen, hwork, hneed⟩
    refine ⟨⟨hlen, fun i _ => ?_⟩, hneed⟩
    split
    · exact hwork _ _ ‹_›
    · rfl

/-- The people who can do at least one shift of `T`. -/
def Problem.able (p : Problem) (T : List Nat) : List Nat :=
  (List.range p.people.length).filter fun i => T.any (p.canWork i)

/-- `T` is a Hall violator: distinct shifts that together need more people than can do any of them. -/
def Problem.checkViolator (p : Problem) (T : List Nat) : Bool :=
  decide T.Nodup && T.all (· < p.shifts.length) && decide ((p.able T).length < (T.map p.needOf).sum)

/-! The pigeonhole argument behind `checkViolator_sound`: in a valid roster, the shifts of `T`
need at most as many people as work them (`sum_need_le`; each person counts once because the
shifts of `T` are distinct), and those people can each do a shift of `T` (`countP_le_able`). -/

/-- Counting by two predicates that never hold together is counting by either. -/
theorem countP_or {α} (l : List α) (p q : α → Bool) (h : ∀ a ∈ l, p a = true → q a = true → False) :
    l.countP (fun a => p a || q a) = l.countP p + l.countP q := by
  induction l with
  | nil => rfl
  | cons a l ih =>
    simp only [List.countP_cons, ih (fun b hb => h b (List.mem_cons_of_mem _ hb))]
    have ha := h a (by simp)
    cases hp : p a <;> cases hq : q a <;> simp_all <;> omega

theorem Problem.sum_need_le (p : Problem) (r : Roster) (T : List Nat) (hT : T.Nodup)
    (hneed : ∀ s ∈ T, p.needOf s ≤ r.count (some s)) :
    (T.map p.needOf).sum ≤ r.countP fun o => T.any (o == some ·) := by
  induction T with
  | nil => simp
  | cons t T ih =>
    rw [List.nodup_cons] at hT
    have ht := hneed t (by simp)
    have ih := ih hT.2 (fun s hs => hneed s (by simp [hs]))
    simp only [List.map_cons, List.sum_cons, List.any_cons]
    rw [countP_or, ← List.count_eq_countP]
    · omega
    · intro o _ h1 h2
      simp only [beq_iff_eq, List.any_eq_true] at h1 h2
      obtain ⟨s, hs, rfl⟩ := h2
      cases h1
      exact hT.1 hs

/-- The people from position `k` on who work a shift of `T` can each do one: they are among those
who can. -/
theorem Problem.countP_le_able (p : Problem) (T : List Nat) (r : Roster) (k : Nat)
    (hwork : ∀ i s, r[i]? = some (some s) → p.canWork (k + i) s = true) :
    r.countP (fun o => T.any (o == some ·)) ≤
      (List.range' k r.length).countP fun i => T.any (p.canWork i) := by
  induction r generalizing k with
  | nil => simp
  | cons o r ih =>
    have ih := ih (k + 1) fun i s h => by
      rw [Nat.add_right_comm]; exact hwork (i + 1) s h
    simp only [List.length_cons, List.range'_succ, List.countP_cons]
    suffices (T.any (o == some ·)) = true → T.any (p.canWork k) = true by
      split <;> split <;> simp_all <;> omega
    intro h
    simp only [beq_iff_eq, List.any_eq_true] at h ⊢
    obtain ⟨s, hs, rfl⟩ := h
    exact ⟨s, hs, hwork 0 s rfl⟩

theorem Problem.checkViolator_sound (p : Problem) (T : List Nat) :
    p.checkViolator T = true → ¬ ∃ r, p.Valid r := by
  rintro h ⟨r, hlen, hwork, hneed⟩
  simp only [checkViolator, Bool.and_eq_true, decide_eq_true_eq, List.all_eq_true] at h
  obtain ⟨⟨hnd, hlt⟩, hgt⟩ := h
  have h1 := p.sum_need_le r T hnd fun s hs => hneed s (by simpa using hlt s hs)
  have h2 := p.countP_le_able T r 0 (by simpa using hwork)
  rw [able, ← List.countP_eq_length_filter, List.range_eq_range', ← hlen] at hgt
  omega

inductive Answer where
  | staffed (r : Roster)
  | impossible (T : List Nat)
  deriving Repr, Inhabited

def Problem.checkAnswer (p : Problem) : Answer → Bool
  | .staffed r => p.checkRoster r
  | .impossible T => p.checkViolator T

/-- What an accepted answer means. -/
theorem Problem.checkAnswer_sound (p : Problem) :
    (∀ r, p.checkAnswer (.staffed r) = true → p.Valid r) ∧
    (∀ T, p.checkAnswer (.impossible T) = true → ¬ ∃ r, p.Valid r) :=
  ⟨fun r => (p.checkRoster_iff r).mp, p.checkViolator_sound⟩

/-! The build fails if any of these ever depends on `sorryAx` or on a non-standard axiom. -/

/-- info: 'Roster.Problem.checkRoster_iff' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms Problem.checkRoster_iff
/-- info: 'Roster.Problem.checkViolator_sound' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Problem.checkViolator_sound
/-- info: 'Roster.Problem.checkAnswer_sound' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Problem.checkAnswer_sound

end Roster
