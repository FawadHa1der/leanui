/-
A sharded counter: `n` threads, each counting `k` in memory it owns, published into its own
shard of an array, summed after the join.

  bump l k         := k times: l ← !l + 1                      (an owned cell; no atomics needed)
  shardCount a n k := fork-join over the shards as ParMap does; each leaf counts in a fresh
                      cell of its own and adds it to its shard once

The proof is ParMap's: the array splits into disjoint halves at each `‖`, every thread owns its
part, and `par` gives both back. No invariant, no ghost state, no atomics: `shardCount_spec` says
every shard ends `k` higher. (iris-lean's `Counter` contribution spec is a different thing: ghost
fractions over one shared CAS cell.) The counting cell is allocated by the thread that uses it,
so translated it lies in that thread's allocation chunk, away from the others' cache lines.
-/
import Iris.HeapLang.Lib.Par

namespace LeanUIIris.Shards
open Iris Iris.HeapLang BI ProgramLogic Par Spawn

def bump : Val := hl_val%
  rec bump l k := if k ≤ #(0 : Int) then #() else (l ← !l + #(1 : Int); bump l (k - #(1 : Int)))

def shardCount : Val := hl_val%
  rec count a n k :=
    if n ≤ #(1 : Int) then
      (if n = #(1 : Int) then (let c := ref(#(0 : Int)); &bump c k; a ← !a + !c) else #())
    else
      let h := n / #(2 : Int);
      ((count a h k) ‖ (count (a +ₗ h) (n - h) k));
      #()

/-- An array of HeapLang integers. -/
abbrev ints (zs : List Int) : List Val := zs.map fun (z : Int) => hl_val(#z)

variable {GF : BundledGFunctors} [HeapLangGS hlc GF]
local bi (IProp GF)

theorem bump_spec (l : Loc) (z : Int) (k : Nat) :
    {{ l ↦ some hl_val(#z) }} hl(&bump #l #(k : Int)) {{ RET hl_val(#()); l ↦ some hl_val(#(z + (k : Int))) }} := by
  induction k generalizing z with
  | zero =>
    iintro %Φ Hl HΦ
    wp_rec
    wp_pures
    have h0 : (((0 : Nat) : Int) ≤ 0) := by omega
    simp only [h0, _root_.decide_true]
    wp_pures
    iapply HΦ
    rw [show z + ((0 : Nat) : Int) = z by omega]
    iexact Hl
  | succ k ih =>
    iintro %Φ Hl HΦ
    wp_rec
    wp_pures
    have hk : ¬ (((k + 1 : Nat) : Int) ≤ 0) := by omega
    simp only [hk, decide_false]
    wp_pures
    wp_load
    wp_pures
    wp_store
    wp_pures
    rw [show ((k + 1 : Nat) : Int) - 1 = (k : Int) by omega]
    iapply (ih (z + 1)) $$ Hl
    inext
    iintro Hl
    iapply HΦ
    rw [show z + 1 + (k : Int) = z + ((k + 1 : Nat) : Int) by omega]
    iexact Hl

theorem loc_add_nat_int (a : Loc) (k : Nat) : a + k = a + (k : Int) := rfl

/-- Splitting an owned array into two disjoint owned halves (and back). -/
theorem array_split (a : Loc) (zs : List Int) (k : Nat) (hk : k ≤ zs.length) :
    (a ↦∗ ints zs : IProp GF) ⊣⊢ a ↦∗ ints (zs.take k) ∗ (a + (k : Int)) ↦∗ ints (zs.drop k) := by
  have hl : (ints (zs.take k)).length = k := by simp [ints]; omega
  conv => lhs; rw [← List.take_append_drop k zs]
  rw [show ints (zs.take k ++ zs.drop k) = ints (zs.take k) ++ ints (zs.drop k) by simp [ints]]
  refine array_app.trans ?_
  rw [hl, loc_add_nat_int]
  exact .rfl

theorem shardCount_spec [SpawnG GF] (a : Loc) (zs : List Int) (n : Int) (k : Nat) :
    {{ ⌜n = zs.length⌝ ∗ a ↦∗ ints zs }}
      hl(&shardCount #a #n #(k : Int))
    {{ RET hl_val(#()); a ↦∗ ints (zs.map (· + (k : Int))) }} := by
  iintro %Φ
  iloeb as IH generalizing %a %zs %n %Φ
  iintro ⟨%hn, Ha⟩ HΦ
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
    wp_alloc c with Hc
    wp_pures
    wp_apply (bump_spec c 0 k) $$ Hc with Hc
    wp_pures
    wp_load
    wp_load
    wp_pures
    wp_store
    imodintro
    iapply HΦ
    isimp only [ints, List.map_cons, List.map_nil]
    iapply array_singleton.mpr
    rw [show z + (0 + (k : Int)) = z + k by omega]
    iexact Ha
  | z1 :: z2 :: rest =>
    subst hn
    have hlen : ¬ (((z1 :: z2 :: rest).length : Int) ≤ 1) := by simp; omega
    simp only [hlen, decide_false]
    wp_pures
    generalize hzs : z1 :: z2 :: rest = zs at *
    have hk : Int.tdiv (zs.length : Int) 2 = ((zs.length / 2 : Nat) : Int) := by
      rw [Int.tdiv_eq_ediv_of_nonneg (by omega)]; omega
    rw [hk]
    let h := zs.length / 2
    have hhle : h ≤ zs.length := Nat.div_le_self _ _
    have hth : (zs.take h).length = h := by simp [h]; omega
    have hdh : ((zs.drop h).length : Int) = (zs.length : Int) - (h : Int) := by simp; omega
    ihave ⟨H1, H2⟩ := (array_split a zs h hhle).mp $$ Ha
    wp_pures
    wp_bind &par _ _
    iapply wp_par (fun _ => a ↦∗ ints ((zs.take h).map (· + (k : Int))))
      (fun _ => (a + (h : Int)) ↦∗ ints ((zs.drop h).map (· + (k : Int)))) $$ [H1] [H2]
    · wp_apply IH $$ [H1] with H1
      · iframe H1; ipureintro; rw [hth]
      iexact H1
    · wp_pures
      wp_apply IH $$ [H2] with H2
      · iframe H2; ipureintro; exact hdh.symm
      iexact H2
    iintro %v1 %v2 ⟨H1, H2⟩
    inext
    wp_pures
    imodintro
    iapply HΦ
    have hhle' : h ≤ (zs.map (· + (k : Int))).length := by simp [hhle]
    iapply (array_split a (zs.map (· + (k : Int))) h hhle').mpr
    rw [List.map_take, List.map_drop]
    iframe

end LeanUIIris.Shards
