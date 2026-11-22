/-
Fork-join map over a shared array with no synchronisation besides fork and join:

  pmap f a n := if n ≤ 1 then (if n = 1 then a[0] ← f a[0])
                else let h := n / 2 in (pmap f a h ‖ pmap f (a + h) (n - h))

The pattern of Workers that each own a disjoint slice of one SharedArrayBuffer. `a ↦∗ (xs ++ ys)`
splits into two disjoint arrays, each thread owns one, and `par` gives both back: no invariant, no
ghost state, no atomics. The spec is pointwise (`f` implements `g : Int → Int` per element); a
stencil such as a blur reads its neighbours and needs a different spec (fractional input).
-/
import Iris.HeapLang.Lib.Par

namespace LeanUIIris.ParMap
open Iris Iris.HeapLang BI ProgramLogic Par Spawn

def pmap : Val := hl_val%
  rec pmap f a n :=
    if n ≤ #(1 : Int) then
      (if n = #(1 : Int) then a ← f (!a) else #())
    else
      let h := n / #(2 : Int);
      ((pmap f a h) ‖ (pmap f (a +ₗ h) (n - h)));
      #()

/-- An array of HeapLang integers. -/
abbrev ints (zs : List Int) : List Val := zs.map fun (z : Int) => hl_val(#z)

variable {GF : BundledGFunctors} [HeapLangGS hlc GF] [SpawnG GF]
local bi (IProp GF)

/-- `f` implements the pure function `g`, and may be called any number of times, by any thread. -/
abbrev fSpec (g : Int → Int) (f : Val) : IProp GF :=
  iprop(□ ∀ z : Int, WP hl(&f #z) {{ w, ⌜w = hl_val(#(g z))⌝ }})

theorem loc_add_nat_int (a : Loc) (k : Nat) : a + k = a + (k : Int) := rfl

omit [SpawnG GF] in
/-- Splitting an owned array into two disjoint owned halves (and back). -/
theorem array_split (a : Loc) (zs : List Int) (k : Nat) (hk : k ≤ zs.length) :
    (a ↦∗ ints zs : IProp GF) ⊣⊢ a ↦∗ ints (zs.take k) ∗ (a + (k : Int)) ↦∗ ints (zs.drop k) := by
  have hl : (ints (zs.take k)).length = k := by simp [ints]; omega
  conv => lhs; rw [← List.take_append_drop k zs]
  rw [show ints (zs.take k ++ zs.drop k) = ints (zs.take k) ++ ints (zs.drop k) by simp [ints]]
  refine array_app.trans ?_
  rw [hl, loc_add_nat_int]
  exact .rfl

theorem pmap_spec (g : Int → Int) (f : Val) (a : Loc) (zs : List Int) (n : Int) :
    {{ ⌜n = zs.length⌝ ∗ fSpec g f ∗ a ↦∗ ints zs }}
      hl(&pmap &f #a #n)
    {{ RET hl_val(#()); a ↦∗ ints (zs.map g) }} := by
  iintro %Φ
  iloeb as IH generalizing %a %zs %n %Φ
  iintro ⟨%hn, #Hf, Ha⟩ HΦ
  wp_rec
  wp_pures
  match zs with
  | [] =>
    subst hn
    isimp
    wp_pures
    rw [beq_eq_false_iff_ne.mpr (by simp only [ne_eq, Val.lit.injEq, BaseLit.int.injEq]; omega)]
    wp_pures
    imodintro
    iapply HΦ
    simp only [List.map_nil]
    iapply array_nil.mpr
    iempintro
  | [z] =>
    subst hn
    isimp
    wp_pures
    rw [beq_self_eq_true]
    wp_pures
    isimp only [ints, List.map_cons, List.map_nil] at Ha
    ihave Ha := array_singleton.mp $$ Ha
    wp_load
    wp_apply wp_wand $$ (Hf $$ %z) with %w %hw
    subst hw
    wp_store
    imodintro
    iapply HΦ
    isimp only [ints, List.map_cons, List.map_nil]
    iapply array_singleton.mpr $$ Ha
  | z1 :: z2 :: rest =>
    subst hn
    have hlen : ¬ (((z1 :: z2 :: rest).length : Int) ≤ 1) := by simp; omega
    simp only [hlen, decide_false]
    wp_pures
    -- split the array at k = len / 2
    generalize hzs : z1 :: z2 :: rest = zs at *
    have hk : Int.tdiv (zs.length : Int) 2 = ((zs.length / 2 : Nat) : Int) := by
      rw [Int.tdiv_eq_ediv_of_nonneg (by omega)]; omega
    rw [hk]
    let k := zs.length / 2
    have hkle : k ≤ zs.length := Nat.div_le_self _ _
    have htk : (zs.take k).length = k := by simp [k]; omega
    have hdk : ((zs.drop k).length : Int) = (zs.length : Int) - (k : Int) := by simp; omega
    ihave ⟨H1, H2⟩ := (array_split a zs k hkle).mp $$ Ha
    wp_pures
    wp_bind &par _ _
    iapply wp_par (fun _ => a ↦∗ ints ((zs.take k).map g))
      (fun _ => (a + (k : Int)) ↦∗ ints ((zs.drop k).map g)) $$ [H1] [H2]
    · wp_apply IH $$ [H1] with H1
      · iframe H1 Hf; ipureintro; rw [htk]
      iexact H1
    · wp_pures
      wp_apply IH $$ [H2] with H2
      · iframe H2 Hf; ipureintro; exact hdk.symm
      iexact H2
    iintro %v1 %v2 ⟨H1, H2⟩
    inext
    wp_pures
    imodintro
    iapply HΦ
    have hkle' : k ≤ (zs.map g).length := by simp [hkle]
    iapply (array_split a (zs.map g) k hkle').mpr
    rw [List.map_take, List.map_drop]
    iframe

end LeanUIIris.ParMap
