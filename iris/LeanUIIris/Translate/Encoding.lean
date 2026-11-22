/-
The value encoding shared by the translator and the runtimes (`rt/runtime.mjs`, `rt/hl_rt.h`):
one Int32 word per HeapLang value, tag in the low 3 bits.

  tag 0  int n = w >> 3           29-bit signed: |n| < 2^28, anything else traps
      1  loc l = w >> 3           the index of an Int32 cell of the shared heap
      2/3, 4/5                    injL / injR of an int or a loc: w - 2, w - 4
      6  boxed: w >> 3 points at an immutable block [hdr, fields…] (pairs, closures, inj of non-literals)
      7  misc: (w >> 3) & 3 is unit/false/true/poison; (w >> 5) & 3 is plain/injL/injR

Every unboxed HeapLang value (`Val.isUnboxed`) has exactly one immediate word, and no immediate
word has tag 6. `cas_word_iff` proves the consequence the translator relies on: whenever HeapLang's
`CmpXchg` is defined (the expected value is unboxed), comparing words is comparing values, so a CAS
is one `Atomics.compareExchange`. Still trusted: that the runtimes build the same words
(`mkInjL`, `mkInjR`, literals; about 20 lines each) and tag every block pointer 6.
-/
import Iris.HeapLang.Syntax

namespace LeanUIIris.Translate
open Iris.HeapLang

def INTMIN : Int := -(2 ^ 28)
def INTMAX : Int := 2 ^ 28 - 1
def W_UNIT : Int := 7
def W_FALSE : Int := 15
def W_TRUE : Int := 23
def W_POISON : Int := 31
def HDR_PAIR : Int := 1
def HDR_INJL : Int := 2
def HDR_INJR : Int := 3
def hdrClo (k : Nat) : Int := (k : Int) * 8 + 4
/-- First cell of the static-constant region; `STATIC_BASE` in the runtimes. -/
def STATIC_BASE : Nat := 4160

def encLit : BaseLit → Except String Int
  | .int n => if INTMIN ≤ n ∧ n ≤ INTMAX then pure (n * 8)
              else throw s!"integer literal {n} outside the 29-bit range of the encoding"
  | .bool true => pure W_TRUE
  | .bool false => pure W_FALSE
  | .unit => pure W_UNIT
  | .poison => pure W_POISON
  | .loc l => if 0 ≤ l.n ∧ l.n < 2 ^ 28 then pure (l.n * 8 + 1)
              else throw s!"location literal {l.n} outside the heap"
  -- prophecies are erased (iris-lean's `HeapLang/ProphErasure.lean` justifies erasure)
  | .prophecy _ => pure W_POISON

/-- The immediate word of `injL lit` / `injR lit`, both unboxed in HeapLang. -/
def encInj (left : Bool) (w : Int) : Int :=
  let tag := w % 8
  if tag == 0 ∨ tag == 1 then w + (if left then 2 else 4)
  else w + (if left then 32 else 64)

/-! ## Comparing words is comparing values -/

/-- The word of an immediate value; `none` for a boxed one. -/
def encImm : Val → Option Int
  | .lit l => (encLit l).toOption
  | .injL (.lit l) => (encLit l).toOption.map (encInj true)
  | .injR (.lit l) => (encLit l).toOption.map (encInj false)
  | _ => none

/-- How a value may sit in a cell: its immediate word or, if boxed, any word tagged 6. -/
def Repr (v : Val) (w : Int) : Prop :=
  encImm v = some w ∨ (encImm v = none ∧ w % 8 = 6)

theorem encLit_ok_iff (l : BaseLit) (w : Int) : (encLit l).toOption = some w ↔ encLit l = .ok w := by
  cases h : encLit l <;> simp [Except.toOption]

theorem encInj_int (b : Bool) (n : Int) : encInj b (n * 8) = n * 8 + (if b then 2 else 4) := by
  unfold encInj; rw [ite_eq_left (.inl (by simp only [beq_iff_eq]; omega))]
theorem encInj_loc (b : Bool) (n : Int) : encInj b (n * 8 + 1) = n * 8 + 1 + (if b then 2 else 4) := by
  unfold encInj; rw [ite_eq_left (.inr (by simp only [beq_iff_eq]; omega))]
theorem encInj_misc (b : Bool) (k : Int) (hk : k % 8 = 7) : encInj b k = k + (if b then 32 else 64) := by
  unfold encInj; rw [ite_eq_right (by simp only [beq_iff_eq]; omega)]

/-- What `encLit` produces, literal by literal. -/
theorem encLit_cases (l : BaseLit) (w : Int) (h : encLit l = .ok w) :
    (∃ n, l = .int n ∧ w = n * 8 ∧ INTMIN ≤ n ∧ n ≤ INTMAX) ∨
    (l = .bool true ∧ w = 23) ∨ (l = .bool false ∧ w = 15) ∨
    (l = .unit ∧ w = 7) ∨ (l = .poison ∧ w = 31) ∨
    (∃ a : Loc, l = .loc a ∧ w = a.n * 8 + 1 ∧ 0 ≤ a.n ∧ a.n < 2 ^ 28) ∨
    (∃ p, l = .prophecy p ∧ w = 31) := by
  cases l with
  | int n =>
    simp only [encLit] at h
    split at h
    · rename_i hr; cases h; exact .inl ⟨n, rfl, rfl, hr.1, hr.2⟩
    · cases h
  | bool b => cases b <;> simp only [encLit, W_TRUE, W_FALSE] at h <;> cases h <;> simp
  | unit => simp only [encLit, W_UNIT] at h; cases h; simp
  | poison => simp only [encLit, W_POISON] at h; cases h; simp
  | loc a =>
    simp only [encLit] at h
    split at h
    · rename_i hr; cases h
      exact .inr (.inr (.inr (.inr (.inr (.inl ⟨a, rfl, rfl, hr.1, hr.2⟩)))))
    · cases h
  | prophecy p => simp only [encLit, W_POISON] at h; cases h; simp

/-- Distinct unboxed literals get distinct words (ints `8n`, locs `8l+1`, 7, 15, 23). -/
theorem encLit_unboxed_inj (l₁ l₂ : BaseLit) (h₁ : l₁.isUnboxed) (h₂ : l₂.isUnboxed) (w : Int)
    (e₁ : encLit l₁ = .ok w) (e₂ : encLit l₂ = .ok w) : l₁ = l₂ := by
  rcases encLit_cases l₁ w e₁ with ⟨n, rfl, hw, -⟩ | ⟨rfl, hw⟩ | ⟨rfl, hw⟩ | ⟨rfl, hw⟩ | ⟨rfl, -⟩ | ⟨a, rfl, hw, -⟩ | ⟨p, rfl, -⟩ <;>
  rcases encLit_cases l₂ w e₂ with ⟨n', rfl, hw', -⟩ | ⟨rfl, hw'⟩ | ⟨rfl, hw'⟩ | ⟨rfl, hw'⟩ | ⟨rfl, -⟩ | ⟨a', rfl, hw', -⟩ | ⟨p', rfl, -⟩ <;>
  simp_all [BaseLit.isUnboxed] <;> (try omega); try (ext; omega)

/-- Tags: literals are 0 (int), 1 (loc) or 7 (misc); never 6 (pointer). -/
theorem encLit_tag (l : BaseLit) (w : Int) (h : encLit l = .ok w) :
    w % 8 = 0 ∨ w % 8 = 1 ∨ w % 8 = 7 := by
  rcases encLit_cases l w h with ⟨n, -, rfl, -⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨a, -, rfl, -⟩ | ⟨p, -, rfl⟩ <;> omega

theorem encImm_some_cases (v : Val) (x : Int) (h : encImm v = some x) :
    (∃ l, v = .lit l ∧ encLit l = .ok x) ∨
    (∃ l y, v = .injL (.lit l) ∧ encLit l = .ok y ∧ x = encInj true y) ∨
    (∃ l y, v = .injR (.lit l) ∧ encLit l = .ok y ∧ x = encInj false y) := by
  match v, h with
  | .lit l, h => exact .inl ⟨l, rfl, (encLit_ok_iff l x).mp h⟩
  | .injL (.lit l), h =>
    simp only [encImm, Option.map_eq_some_iff] at h
    obtain ⟨y, hy, rfl⟩ := h
    exact .inr (.inl ⟨l, y, rfl, (encLit_ok_iff l y).mp hy, rfl⟩)
  | .injR (.lit l), h =>
    simp only [encImm, Option.map_eq_some_iff] at h
    obtain ⟨y, hy, rfl⟩ := h
    exact .inr (.inr ⟨l, y, rfl, (encLit_ok_iff l y).mp hy, rfl⟩)

/-- Every immediate word of an unboxed value has tag ≠ 6, and distinct values never share one. -/
theorem encImm_unboxed_inj (v w : Val) (hv : v.isUnboxed) (x : Int)
    (ev : encImm v = some x) (ew : encImm w = some x) : v = w := by
  rcases encImm_some_cases v x ev with ⟨l, rfl, e⟩ | ⟨l, y, rfl, e, hx⟩ | ⟨l, y, rfl, e, hx⟩ <;>
  rcases encImm_some_cases w x ew with ⟨l', rfl, e'⟩ | ⟨l', y', rfl, e', hx'⟩ | ⟨l', y', rfl, e', hx'⟩ <;>
  rcases encLit_cases l _ e with ⟨n, rfl, hw, -⟩ | ⟨rfl, hw⟩ | ⟨rfl, hw⟩ | ⟨rfl, hw⟩ | ⟨rfl, hw⟩ | ⟨a, rfl, hw, -⟩ | ⟨p, rfl, hw⟩ <;>
  rcases encLit_cases l' _ e' with ⟨n', rfl, hw', -⟩ | ⟨rfl, hw'⟩ | ⟨rfl, hw'⟩ | ⟨rfl, hw'⟩ | ⟨rfl, hw'⟩ | ⟨a', rfl, hw', -⟩ | ⟨p', rfl, hw'⟩ <;>
  subst_vars
  all_goals (try simp only [Val.isUnboxed, BaseLit.isUnboxed, Bool.false_eq_true] at hv)
  all_goals (try simp only [encInj_int, encInj_loc, encInj_misc _ 7 (by decide), encInj_misc _ 15 (by decide),
    encInj_misc _ 23 (by decide), encInj_misc _ 31 (by decide), ↓reduceIte, Bool.false_eq_true] at *)
  all_goals (first | omega | rfl | (simp only [Val.lit.injEq, Val.injL.injEq, Val.injR.injEq, BaseLit.int.injEq, BaseLit.loc.injEq]; first | omega | (ext; omega)))

theorem encImm_unboxed_tag (v : Val) (hv : v.isUnboxed) (x : Int) (ev : encImm v = some x) :
    x % 8 ≠ 6 := by
  rcases encImm_some_cases v x ev with ⟨l, rfl, e⟩ | ⟨l, y, rfl, e, rfl⟩ | ⟨l, y, rfl, e, rfl⟩ <;>
  rcases encLit_cases l _ e with ⟨n, rfl, hw, -⟩ | ⟨rfl, hw⟩ | ⟨rfl, hw⟩ | ⟨rfl, hw⟩ | ⟨rfl, hw⟩ | ⟨a, rfl, hw, -⟩ | ⟨p, rfl, hw⟩ <;>
  subst_vars
  all_goals (try simp only [encInj_int, encInj_loc, encInj_misc _ 7 (by decide), encInj_misc _ 15 (by decide),
    encInj_misc _ 23 (by decide), encInj_misc _ 31 (by decide), ↓reduceIte, Bool.false_eq_true])
  all_goals omega

/-- **CAS soundness of the encoding.**  If the expected value `v` is unboxed and encodable, a
cell holding any value `w` (immediate or a pointer to a block) has the same machine word iff
`w = v`.  So `Atomics.compareExchange` on words succeeds exactly when HeapLang's `cmpXchgS`
(with `vl.compareSafe v1`) succeeds. -/
theorem cas_word_iff (v w : Val) (hv : v.isUnboxed) (x y : Int)
    (ev : encImm v = some x) (rw : Repr w y) : x = y ↔ v = w := by
  constructor
  · rintro rfl
    rcases rw with ew | ⟨-, ht⟩
    · exact encImm_unboxed_inj v w hv x ev ew
    · exact absurd ht (encImm_unboxed_tag v hv x ev)
  · rintro rfl
    rcases rw with ew | ⟨hn, -⟩
    · rw [ev] at ew; exact Option.some.inj ew
    · rw [ev] at hn; cases hn

end LeanUIIris.Translate
