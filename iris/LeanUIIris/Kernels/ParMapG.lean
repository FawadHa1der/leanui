/-
`ParMap` with a grain size: halve the array until a part has at most `g` cells, then map over
that part sequentially.

  seqMap f a n    := for i < n: a[i] ← f a[i]
  pmapG f a n g   := if n ≤ g then seqMap f a n
                     else let h := n / 2 in (pmapG f a h g ‖ pmapG f (a + h) (n - h) g)

`ParMap.pmap` forks once per split down to single cells, so `n` cells need `n - 1` threads, each
parent spinning in `join`: fine for a proof, not for a 256×256 image. With `g = ⌈n / W⌉` this is
`W` threads, each owning one band. The proof is ParMap's (disjoint halves at each `‖`, no
invariant, no ghost state, no atomics) plus an induction for the sequential leaf. Like ParMap's,
the spec is pointwise: each cell becomes `g` of itself.
-/
import LeanUIIris.Kernels.ParMap

namespace LeanUIIris.ParMapG
open Iris Iris.HeapLang BI ProgramLogic Par Spawn LeanUIIris.ParMap

def seqMap : Val := hl_val%
  rec go f a n :=
    if n ≤ #(0 : Int) then #()
    else (a ← f (!a); go f (a +ₗ #(1 : Int)) (n - #(1 : Int)))

def pmapG : Val := hl_val%
  rec pmapG f a n g :=
    if n ≤ g then &seqMap f a n
    else
      let h := n / #(2 : Int);
      ((pmapG f a h g) ‖ (pmapG f (a +ₗ h) (n - h) g));
      #()

variable {GF : BundledGFunctors} [HeapLangGS hlc GF]
local bi (IProp GF)

theorem seqMap_spec (g : Int → Int) (f : Val) (a : Loc) (zs : List Int) :
    {{ fSpec g f ∗ a ↦∗ ints zs }}
      hl(&seqMap &f #a #(zs.length : Int))
    {{ RET hl_val(#()); a ↦∗ ints (zs.map g) }} := by
  induction zs generalizing a with
  | nil =>
    iintro %Φ ⟨#Hf, Ha⟩ HΦ
    wp_rec
    wp_pures
    have h0 : (((([] : List Int).length : Nat) : Int) ≤ 0) := by simp
    simp only [h0, _root_.decide_true]
    wp_pures
    iapply HΦ
    simp only [List.map_nil]
    iexact Ha
  | cons z rest ih =>
    iintro %Φ ⟨#Hf, Ha⟩ HΦ
    wp_rec
    wp_pures
    have h1 : ¬ ((((z :: rest).length : Nat) : Int) ≤ 0) := by simp
    simp only [h1, decide_false]
    wp_pures
    isimp only [ints, List.map_cons] at Ha
    ihave ⟨Ha0, Ha1⟩ := array_cons.mp $$ Ha
    wp_load
    wp_apply wp_wand $$ (Hf $$ %z) with %w %hw
    subst hw
    wp_store
    wp_pures
    rw [show (((z :: rest).length : Nat) : Int) - 1 = ((rest.length : Nat) : Int) by simp]
    iapply (ih (a + (1 : Int))) $$ [Ha1]
    · iframe Hf
      iexact Ha1
    inext
    iintro Hrest
    iapply HΦ
    isimp only [ints, List.map_cons]
    iapply array_cons.mpr
    iframe

theorem pmapG_spec [SpawnG GF] (g : Int → Int) (f : Val) (a : Loc) (zs : List Int) (n gr : Int) :
    {{ ⌜n = zs.length⌝ ∗ fSpec g f ∗ a ↦∗ ints zs }}
      hl(&pmapG &f #a #n #gr)
    {{ RET hl_val(#()); a ↦∗ ints (zs.map g) }} := by
  iintro %Φ
  iloeb as IH generalizing %a %zs %n %Φ
  iintro ⟨%hn, #Hf, Ha⟩ HΦ
  subst hn
  wp_rec
  wp_pures
  by_cases hle : (zs.length : Int) ≤ gr
  · simp only [hle, _root_.decide_true]
    wp_pures
    iapply seqMap_spec $$ [Ha] HΦ
    iframe Hf
    iexact Ha
  · simp only [hle, decide_false]
    wp_pures
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

end LeanUIIris.ParMapG
