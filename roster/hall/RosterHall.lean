module
public import Mathlib.Algebra.BigOperators.Group.Finset.Sigma
public import Mathlib.Combinatorics.Hall.Finite
public import Mathlib.Data.Fintype.Sigma
public import Roster.Core
/-!
# Completeness: a roster, or a Hall violator that explains why there is none

`Roster.Core` proves the checkers sound: a roster they accept is valid, and a violator they accept
means no roster is. This is the other direction: whenever no valid roster exists, a violator does.
So every problem has an answer the checker accepts, and a correct solver is never stuck.

* `complete`: `(∃ r, p.Valid r) ∨ ∃ T, p.checkViolator T = true`;
* `impossible_iff`: so a problem has no valid roster exactly when it has a violator.

The argument is Hall's marriage theorem (Mathlib's
`Finset.all_card_le_biUnion_card_iff_existsInjective'`, the version for a finite index type: it
keeps Mathlib's topology and category theory out of the build). Make `needOf s` *copies* of each
shift `s` and look for a different person for each copy, one who can do its shift:

* if every set of copies has at least as many able people (people who can do one of them) as it
  has copies, Hall gives a different person for each copy. Each person works the shift of the copy
  they were chosen for, if any; one copy at most, so the roster is well defined, and every shift
  gets one person per copy (`valid_of_injective`);
* otherwise some set of copies has fewer able people than copies. Its shifts `T` need at least as
  many people as it has copies, and the people able to do a shift of `T` are those able to do one
  of the copies: `T` is a violator (`violator_of_short`).

A project of its own, apart from the main build (Mathlib is large): see `README.md`.
-/
public section
namespace Roster.Problem
open Finset Function

variable (p : Problem)

/-- Shift `s`, repeated `needOf s` times: each copy needs a person of its own. -/
abbrev Copy := (s : Fin p.shifts.length) × Fin (p.needOf s)

/-- The people who can work copy `c`. -/
def canDo (c : p.Copy) : Finset ℕ := {i ∈ range p.people.length | p.canWork i c.1}

/-- Counting in `List.range` is counting in `Finset.range` (`Roster.Core` counts with lists). -/
theorem length_filter_range (n : ℕ) (q : ℕ → Bool) :
    ((List.range n).filter q).length = #{i ∈ range n | q i} := by
  simp [Finset.card, Finset.filter_val, Finset.range_val, Multiset.range]

/-- A different person for each copy gives a valid roster: each person works the shift of the copy
they were chosen for, if any. -/
theorem valid_of_injective (f : p.Copy → ℕ) (hf : Injective f) (hfc : ∀ c, f c ∈ p.canDo c) :
    p.Valid ((List.range p.people.length).map fun i => (partialInv f i).map (·.1.val)) := by
  refine ⟨by simp, fun i s h => ?_, fun s hs => ?_⟩
  · -- person `i` was chosen for a copy `c` of shift `s`
    simp only [List.getElem?_map, Option.map_eq_some_iff, List.getElem?_eq_some_iff,
      List.getElem_range] at h
    obtain ⟨_, ⟨_, rfl⟩, c, hc, rfl⟩ := h
    obtain rfl := (hf.isPartialInv c i).1 hc
    exact (mem_filter.1 (hfc c)).2
  · -- the copies of `s` were chosen different people, each of whom works `s`
    rw [List.count_eq_countP, List.countP_map, List.countP_eq_length_filter, length_filter_range]
    calc p.needOf s = #(univ : Finset (Fin (p.needOf s))) := by simp
      _ ≤ _ := card_le_card_of_injOn (fun k => f ⟨⟨s, hs⟩, k⟩) (fun k _ => ?_)
          fun k _ k' _ h => by simpa using hf h
    simpa [partialInv_left hf] using (mem_filter.1 (hfc ⟨⟨s, hs⟩, k⟩)).1

/-- A set of copies with fewer able people than copies: its shifts are a violator. -/
theorem violator_of_short (S : Finset p.Copy) (hS : #(S.biUnion p.canDo) < #S) :
    p.checkViolator ((S.image Sigma.fst).map Fin.valEmbedding).toList = true := by
  set U := S.image Sigma.fst
  simp only [checkViolator, Bool.and_eq_true, decide_eq_true_eq, List.all_eq_true]
  refine ⟨⟨nodup_toList _, fun s hs => ?_⟩, ?_⟩
  · -- shifts of the problem
    simp only [mem_toList, mem_map, Fin.valEmbedding_apply] at hs
    obtain ⟨s, -, rfl⟩ := hs
    exact s.isLt
  -- the copies in `S` are at most as many as their shifts need
  have hneed : #S ≤ ∑ s ∈ U, p.needOf s :=
    calc #S ≤ #(U.sigma fun _ => univ) := card_le_card fun c hc => by simpa [U] using ⟨c.2, hc⟩
      _ = ∑ s ∈ U, p.needOf s := by simp [card_sigma]
  -- and the people able to do one of the shifts can do one of the copies
  have hable : (p.able ((U.map Fin.valEmbedding).toList)).length ≤ #(S.biUnion p.canDo) := by
    rw [able, length_filter_range]
    refine card_le_card fun i hi => ?_
    simp only [mem_filter, mem_range, List.any_eq_true, mem_toList, mem_map,
      Fin.valEmbedding_apply] at hi
    obtain ⟨hi, _, ⟨s, hs, rfl⟩, hw⟩ := hi
    obtain ⟨c, hc, rfl⟩ := mem_image.1 hs
    exact mem_biUnion.2 ⟨c, hc, mem_filter.2 ⟨mem_range.2 hi, hw⟩⟩
  rw [sum_map_toList, sum_map]
  simp only [Fin.valEmbedding_apply]
  omega

/-- Every problem has an answer the checker accepts: a valid roster, or a Hall violator. -/
theorem complete : (∃ r, p.Valid r) ∨ ∃ T, p.checkViolator T = true := by
  by_cases h : ∀ S : Finset p.Copy, #S ≤ #(S.biUnion p.canDo)
  · -- Hall's condition holds: a different person for each copy
    obtain ⟨f, hf, hfc⟩ := (all_card_le_biUnion_card_iff_existsInjective' p.canDo).1 h
    exact .inl ⟨_, p.valid_of_injective f hf hfc⟩
  · -- some set of copies has fewer able people than copies
    push Not at h
    obtain ⟨S, hS⟩ := h
    exact .inr ⟨_, p.violator_of_short S hS⟩

/-- With `checkViolator_sound`: a problem has no valid roster exactly when it has a violator. -/
theorem impossible_iff : (¬ ∃ r, p.Valid r) ↔ ∃ T, p.checkViolator T = true :=
  ⟨p.complete.resolve_left, fun ⟨T, h⟩ => p.checkViolator_sound T h⟩

/-! The build fails if these ever depend on `sorryAx` or on a non-standard axiom. -/

/-- info: 'Roster.Problem.complete' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms complete
/-- info: 'Roster.Problem.impossible_iff' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms impossible_iff

end Roster.Problem
