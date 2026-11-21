/-
A bounded single-producer, single-consumer ring: two monotone indices, slot `i % n`, no CAS.
The structure JavaScript uses between a Worker or an AudioWorklet and the main thread.

  tryPush buf hd tl n v := let t := !tl; let h := !hd;
                           if t - h < n then buf[t % n] ← v; tl ← t + 1; true else false
  tryPop  buf hd tl n   := let h := !hd; let t := !tl;
                           if h < t then let v := buf[h % n]; hd ← h + 1; some v else none

The i-th push gives up `P i v` and the i-th pop receives it. `P i v := ⌜v = msgs[i]⌝` gives FIFO
delivery (`SpscClient.lean`); `P i v :=` ownership of a buffer gives a hand-off without copies.
Both operations are loop-free. The indices grow without bound: the translation's 29-bit integers
trap after 2^28 pushes, and a modular-index ring would need its own proof.

In HeapLang every access is a sequentially consistent step. Translated, every access (slots
included) is an SC atomic. The faster variant that keeps the payload in a plain typed array is
outside this proof: there the proof covers the protocol, and the JavaScript that touches the bytes
is trusted.
-/
import Iris.HeapLang.PrimitiveLaws
import Iris.HeapLang.ProofMode
import Iris.Instances.Lib.Invariants
import Iris.Instances.Lib.GhostVar

namespace LeanUIIris.SpscRing
open Iris Iris.HeapLang BI ProgramLogic

def tryPush : Val := hl_val%
  λ buf hd tl n v,
    let t := !tl;
    let h := !hd;
    if t - h < n then
      ((buf +ₗ (t % n)) ← v;
       tl ← t + #(1 : Int);
       #true)
    else #false

def tryPop : Val := hl_val%
  λ buf hd tl n,
    let h := !hd;
    let t := !tl;
    if h < t then
      (let v := !(buf +ₗ (h % n));
       hd ← h + #(1 : Int);
       some(v))
    else none()

def rbN : Namespace := nroot .@ "spsc"

/-! ### Big-separating-conjunction helpers over index ranges -/

section Ranges
variable {PROP : Type _} [BI PROP] (Φ : Nat → PROP)

theorem range_take_head (s n k : Nat) (h : n = k + 1) :
    ([∗list] i ∈ List.range' s n, Φ i) ⊣⊢ Φ s ∗ [∗list] i ∈ List.range' (s + 1) k, Φ i := by
  subst h; rw [List.range'_succ]; exact BigSepL.bigSepL_cons

theorem range_put_tail (s n m k : Nat) (hm : m = n + 1) (hk : k = s + n) :
    ([∗list] i ∈ List.range' s n, Φ i) ∗ Φ k ⊣⊢ [∗list] i ∈ List.range' s m, Φ i := by
  subst hm hk; rw [List.range'_concat, Nat.one_mul]
  refine (BigSepL.bigSepL_snoc).symm.trans ?_
  exact .rfl

end Ranges

variable {GF : BundledGFunctors} [HeapLangGS hlc GF] [GhostVarG GF (Nat × Bool)]
local bi (IProp GF)
set_option linter.unusedSectionVars false

section Defs
variable (buf hd tl : Loc) (N : Nat) (P : Nat → Val → IProp GF) (γh γt : GName)

/-- Slot of logical index `i`. -/
abbrev slot (i : Nat) : Loc := buf + ((i % N : Nat) : Int)

abbrev fullSlot (i : Nat) : IProp GF := iprop(∃ v, (buf + ((i % N : Nat) : Int)) ↦ some v ∗ P i v)
abbrev freeSlot (i : Nat) : IProp GF := iprop(∃ v, (buf + ((i % N : Nat) : Int)) ↦ some v)

/-- `h`/`t`: consumer/producer counters. `c`/`p`: the consumer/producer is in the middle of an
operation and has taken slot `h`/`t` out of the shared state. -/
abbrev rbInv : IProp GF := iprop%
  ∃ (h t : Nat) (c p : Bool) (fs fn es en : Nat),
    hd ↦ some hl_val(#(h : Int)) ∗ tl ↦ some hl_val(#(t : Int)) ∗
    (γh ↪VAR{.own (1 : Qp).half} (h, c)) ∗ (γt ↪VAR{.own (1 : Qp).half} (t, p)) ∗
    ⌜h ≤ t ∧ t ≤ h + N ∧ (c = true → h < t) ∧ (p = true → t < h + N) ∧
      fs = h + (if c then 1 else 0) ∧ fs + fn = t ∧
      es = t + (if p then 1 else 0) ∧ es + en = h + N⌝ ∗
    ([∗list] i ∈ List.range' fs fn, fullSlot buf N P i) ∗
    ([∗list] i ∈ List.range' es en, freeSlot buf N i)

abbrev rbCtx : IProp GF := inv rbN (rbInv buf hd tl N P γh γt)
abbrev producer (γt : GName) (t : Nat) : IProp GF := γt ↪VAR{.own (1 : Qp).half} (t, false)
abbrev consumer (γh : GName) (h : Nat) : IProp GF := γh ↪VAR{.own (1 : Qp).half} (h, false)

end Defs

variable {buf hd tl : Loc} {N : Nat} {P : Nat → Val → IProp GF} {γh γt : GName}

/-! ### Creating a ring buffer from freshly owned memory -/

theorem array_to_free (buf : Loc) (N : Nat) :
    ∀ (vs : List Val) (s : Nat), s + vs.length ≤ N →
      ((buf + (s : Int)) ↦∗ vs : IProp GF) ⊢ [∗list] i ∈ List.range' s vs.length, freeSlot buf N i
  | [], _, _ => by
    simp only [List.length_nil, List.range'_zero]
    exact array_nil.mp.trans BigSepL.bigSepL_nil.mpr
  | v :: vs, s, hlen => by
    simp only [List.length_cons] at hlen ⊢
    rw [List.range'_succ]
    refine array_cons.mp.trans ((sep_mono ?_ ?_).trans BigSepL.bigSepL_cons.mpr)
    · iintro H
      iexists v
      rw [Nat.mod_eq_of_lt (by omega)]
      iexact H
    · have hl : buf + (s : Int) + (1 : Int) = buf + ((s + 1 : Nat) : Int) := by
        ext; simp only [loc_add_n]; omega
      rw [hl]
      exact array_to_free buf N vs (s + 1) (by omega)

theorem rb_init (vs : List Val) (hN : vs.length = N) :
    (buf ↦∗ vs ∗ hd ↦ some hl_val(#(0 : Int)) ∗ tl ↦ some hl_val(#(0 : Int)) : IProp GF) ⊢
      |={⊤}=> ∃ γh γt, rbCtx buf hd tl N P γh γt ∗ producer γt 0 ∗ consumer γh 0 := by
  iintro ⟨Hbuf, Hhd, Htl⟩
  imod ghost_var_alloc (GF := GF) ((0 : Nat), false) with ⟨%γh, Hgh⟩
  imod ghost_var_alloc (GF := GF) ((0 : Nat), false) with ⟨%γt, Hgt⟩
  ihave ⟨Hgh1, Hgh2⟩ := ghost_var_split γh ((0 : Nat), false) (1 : Qp).half (1 : Qp).half $$ [Hgh]
  · rw [Qp.half_add_half]; iexact Hgh
  ihave ⟨Hgt1, Hgt2⟩ := ghost_var_split γt ((0 : Nat), false) (1 : Qp).half (1 : Qp).half $$ [Hgt]
  · rw [Qp.half_add_half]; iexact Hgt
  ihave Hfree := array_to_free buf N vs 0 (by omega) $$ [Hbuf]
  · rw [show buf + ((0 : Nat) : Int) = buf by ext; simp]; iexact Hbuf
  rw [hN] at *
  imod inv_alloc rbN ⊤ (rbInv buf hd tl N P γh γt) $$ [Hhd Htl Hgh1 Hgt1 Hfree] with #Hinv
  · inext
    iexists 0, 0, false, false, 0, 0, 0, N
    simp only [Int.natCast_zero, List.range'_zero]
    iframe
    isplit
    · ipureintro; simp
    iapply BigSepL.bigSepL_nil.mpr
    iempintro
  imodintro
  iexists γh, γt
  iframe Hinv Hgt2 Hgh2

theorem tryPush_spec (t : Nat) (v : Val) :
    {{ rbCtx buf hd tl N P γh γt ∗ producer γt t ∗ P t v }}
      hl(&tryPush #buf #hd #tl #(N : Int) &v)
    {{ (b : Bool), RET hl_val(#b); if b then producer γt (t + 1) else producer γt t ∗ P t v }} := by
  iintro %Φ ⟨#Hinv, Hp, HP⟩ HΦ
  wp_rec
  wp_pures
  -- (1) read our own counter `tl` (we own half of its ghost variable, so we know it is `t`)
  wp_bind !_
  iinv Hinv with ⟨%h, %t', %c, %p, %fs, %fn, %es, %en, >Hhd, >Htl, >Hgh, >Hgt, >%Hc, Hfull, Hfree⟩
    Hclose
  icombine Hp Hgt gives %⟨-, Heq⟩
  simp only [Prod.mk.injEq] at Heq
  obtain ⟨rfl, rfl⟩ := Heq
  wp_load
  imod Hclose $$ [Hhd Htl Hgh Hgt Hfull Hfree] with -
  · inext; iexists h, t, c, false, fs, fn, es, en; iframe; ipureintro; exact Hc
  imodintro
  wp_pures
  -- (2) read the consumer's counter; if there is room, reserve slot `t` in the same atomic step
  wp_bind !_
  iinv Hinv with ⟨%h, %t', %c, %p, %fs, %fn, %es, %en, >Hhd, >Htl, >Hgh, >Hgt, >%Hc, Hfull, Hfree⟩
    Hclose
  icombine Hp Hgt gives %⟨-, Heq⟩
  simp only [Prod.mk.injEq] at Heq
  obtain ⟨rfl, rfl⟩ := Heq
  wp_load
  have hes : es = t := by simp at Hc; omega
  subst es
  by_cases hroom : t < h + N
  · ihave ⟨⟨%w, Hslot⟩, Hfree⟩ := (range_take_head (freeSlot buf N) t en (en - 1)
      (by cases c <;> simp at Hc <;> omega)).mp $$ Hfree
    imod ghost_var_update_halves (t, true) γt (t, false) (t, false) $$ Hp Hgt with ⟨Hp, Hgt⟩
    imod Hclose $$ [Hhd Htl Hgh Hgt Hfull Hfree] with -
    · inext
      iexists h, t, c, true, fs, fn, t + 1, en - 1
      iframe
      ipureintro
      cases c <;> simp at Hc ⊢ <;> omega
    imodintro
    wp_pures
    rw [show decide ((t : Int) - (h : Int) < (N : Int)) = true by simp; omega]
    wp_pures
    -- (3) write the reserved slot: no other thread can touch it now
    rw [← Int.ofNat_tmod]
    wp_store
    wp_pures
    -- (4) publish: bump `tl` and move the slot (with its resource) into the full region
    rw [show (t : Int) + 1 = ((t + 1 : Nat) : Int) by omega]
    wp_bind (_ ← _)
    iinv Hinv with ⟨%h, %t', %c, %p, %fs, %fn, %es, %en, >Hhd, >Htl, >Hgh, >Hgt, >%Hc, Hfull, Hfree⟩
      Hclose
    icombine Hp Hgt gives %⟨-, Heq⟩
    simp only [Prod.mk.injEq] at Heq
    obtain ⟨rfl, rfl⟩ := Heq
    wp_store
    ihave Hfs : fullSlot buf N P t $$ [Hslot HP]
    · iexists v; iframe
    ihave Hfull := (range_put_tail (fullSlot buf N P) fs fn (fn + 1) t rfl (by
      cases c <;> simp at Hc <;> omega)).mp $$ [Hfull Hfs]
    · iframe
    imod ghost_var_update_halves (t + 1, false) γt (t, true) (t, true) $$ Hp Hgt with ⟨Hp, Hgt⟩
    imod Hclose $$ [Hhd Htl Hgh Hgt Hfull Hfree] with -
    · inext
      iexists h, t + 1, c, false, fs, fn + 1, es, en
      iframe
      ipureintro
      cases c <;> simp at Hc ⊢ <;> omega
    imodintro
    wp_pures
    iapply HΦ $$ %true
    isimp
    iexact Hp
  · -- full: give everything back
    imod Hclose $$ [Hhd Htl Hgh Hgt Hfull Hfree] with -
    · inext; iexists h, t, c, false, fs, fn, t, en; iframe; ipureintro; exact Hc
    imodintro
    wp_pures
    rw [show decide ((t : Int) - (h : Int) < (N : Int)) = false by simp; omega]
    wp_pures
    iapply HΦ $$ %false
    isimp
    iframe

theorem tryPop_spec (h : Nat) :
    {{ rbCtx buf hd tl N P γh γt ∗ consumer γh h }}
      hl(&tryPop #buf #hd #tl #(N : Int))
    {{ r, RET r; (⌜r = hl_val(none())⌝ ∗ consumer γh h) ∨
                 (∃ v, ⌜r = hl_val(some(&v))⌝ ∗ P h v ∗ consumer γh (h + 1)) }} := by
  iintro %Φ ⟨#Hinv, Hcons⟩ HΦ
  wp_rec
  wp_pures
  -- (1) read our own counter `hd`
  wp_bind !_
  iinv Hinv with ⟨%h', %t, %c, %p, %fs, %fn, %es, %en, >Hhd, >Htl, >Hgh, >Hgt, >%Hc, Hfull, Hfree⟩
    Hclose
  icombine Hcons Hgh gives %⟨-, Heq⟩
  simp only [Prod.mk.injEq] at Heq
  obtain ⟨rfl, rfl⟩ := Heq
  wp_load
  imod Hclose $$ [Hhd Htl Hgh Hgt Hfull Hfree] with -
  · inext; iexists h, t, false, p, fs, fn, es, en; iframe; ipureintro; exact Hc
  imodintro
  wp_pures
  -- (2) read the producer's counter; if non-empty, take slot `h` in the same atomic step
  wp_bind !_
  iinv Hinv with ⟨%h', %t, %c, %p, %fs, %fn, %es, %en, >Hhd, >Htl, >Hgh, >Hgt, >%Hc, Hfull, Hfree⟩
    Hclose
  icombine Hcons Hgh gives %⟨-, Heq⟩
  simp only [Prod.mk.injEq] at Heq
  obtain ⟨rfl, rfl⟩ := Heq
  wp_load
  have hfs : fs = h := by simp at Hc; omega
  subst fs
  by_cases hne : h < t
  · ihave ⟨⟨%w, Hslot, HPw⟩, Hfull⟩ := (range_take_head (fullSlot buf N P) h fn (fn - 1)
      (by cases p <;> simp at Hc <;> omega)).mp $$ Hfull
    imod ghost_var_update_halves (h, true) γh (h, false) (h, false) $$ Hcons Hgh with ⟨Hcons, Hgh⟩
    imod Hclose $$ [Hhd Htl Hgh Hgt Hfull Hfree] with -
    · inext
      iexists h, t, true, p, h + 1, fn - 1, es, en
      iframe
      ipureintro
      cases p <;> simp at Hc ⊢ <;> omega
    imodintro
    wp_pures
    rw [show decide ((h : Int) < (t : Int)) = true by simp; omega]
    wp_pures
    -- (3) read the slot we own
    rw [← Int.ofNat_tmod]
    wp_load
    wp_pures
    -- (4) release: bump `hd` and give the slot back to the producer's free region (at h + N)
    rw [show (h : Int) + 1 = ((h + 1 : Nat) : Int) by omega]
    wp_bind (_ ← _)
    iinv Hinv with ⟨%h', %t, %c, %p, %fs, %fn, %es, %en, >Hhd, >Htl, >Hgh, >Hgt, >%Hc, Hfull, Hfree⟩
      Hclose
    icombine Hcons Hgh gives %⟨-, Heq⟩
    simp only [Prod.mk.injEq] at Heq
    obtain ⟨rfl, rfl⟩ := Heq
    wp_store
    ihave Hfs : freeSlot buf N (h + N) $$ [Hslot]
    · iexists w; rw [Nat.add_mod_right]; iframe
    ihave Hfree := (range_put_tail (freeSlot buf N) es en (en + 1) (h + N) rfl (by
      cases p <;> simp at Hc <;> omega)).mp $$ [Hfree Hfs]
    · iframe
    imod ghost_var_update_halves (h + 1, false) γh (h, true) (h, true) $$ Hcons Hgh
      with ⟨Hcons, Hgh⟩
    imod Hclose $$ [Hhd Htl Hgh Hgt Hfull Hfree] with -
    · inext
      iexists h + 1, t, false, p, fs, fn, es, en + 1
      iframe
      ipureintro
      cases p <;> simp at Hc ⊢ <;> omega
    imodintro
    wp_pures
    iapply HΦ
    iright
    iexists w
    iframe
    itrivial
  · -- empty
    imod Hclose $$ [Hhd Htl Hgh Hgt Hfull Hfree] with -
    · inext; iexists h, t, false, p, h, fn, es, en; iframe; ipureintro; exact Hc
    imodintro
    wp_pures
    rw [show decide ((h : Int) < (t : Int)) = false by simp; omega]
    wp_pures
    iapply HΦ
    ileft
    iframe
    itrivial

end LeanUIIris.SpscRing
