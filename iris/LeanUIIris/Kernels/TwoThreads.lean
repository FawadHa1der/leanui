/-
A closed theorem about a whole program:

  let l := ref 0; (faaIncr l ‖ faaIncr l); !l

`twoIncr_adequate`: from any initial state, in every interleaving, no thread gets stuck and the
main thread, if it returns, returns 2. Each thread uses only `faaIncr`'s logically atomic spec and
opens a shared invariant `l ↦ n ∗ ●F n` at the linearisation point to bump its own fractional
contribution `◯F{½} k`; the invariant replaces the mutex in the reasoning, not in the code.

Adequacy needs a concrete ghost-state signature. iris-lean has no `subG`-style composition, so
`CounterS` copies the nine entries of `HeapLangS` and adds spawn tokens and the counter.
-/
import LeanUIIris.Kernels.AtomicCounter
import Iris.HeapLang.Lib.Par

namespace LeanUIIris.TwoThreads
open Iris Iris.HeapLang BI ProgramLogic ORA OFE Auth Counter Par Spawn
open LeanUIIris.AtomicCounter

def twoIncr : Exp := hl%
  let l := ref(#0);
  ((&faaIncr l) ‖ (&faaIncr l));
  !l

def countN : Namespace := nroot .@ "count"

section Proof
variable {GF : BundledGFunctors} [HeapLangGS hlc GF] [SpawnG GF] [CCounterG GF]
local bi (IProp GF)

omit [SpawnG GF] in
/-- One thread: increment through the logically atomic spec, opening the shared invariant
around the linearisation point. -/
theorem incr_thread (γ : GName) (l : Loc) (q : Qp) (k : Nat) :
    inv countN (ccounterInv γ l) ∗ ccounter γ q k ⊢
      WP hl(&faaIncr #l) {{ _v, ccounter γ q (k + 1) }} := by
  iintro ⟨#Hinv, Hγf⟩
  ihave H := faaIncr_spec (GF := GF) l
  iunfold atomic_wp at H
  iapply H
  iauintro
  -- `iinv` with a closing hypothesis and `>` (timeless) patterns do not work on an
  -- `atomic_acc` goal in iris-lean (missing ElimModal instances), so unfold it to a plain
  -- fancy update and do the accessor by hand.
  iunfold atomic_acc
  iinv Hinv with ⟨%n, >Hγ, >Hl⟩ Hclose
  iapply fupd_mask_intro Std.LawfulSet.empty_subset
  iintro Hmask
  iexists ⟨(n : Int), ⟨⟩⟩
  isimp only [Std.Tele.app, Std.Tele.lam, Std.Tele.bind, Std.Tele.app_bind, BIBase.wandM]
  isplitl [Hl]
  · iexact Hl
  isplit
  · -- abort: the location is handed back unchanged; re-establish the invariant
    iintro Hl
    imod Hmask
    imod Hclose $$ [Hγ Hl] with -
    · inext; iexists n; iframe
    imodintro
    iframe
  · -- commit: the location now holds n+1; bump the ghost counter
    iintro %⟨⟩ Hl
    imod Hmask
    imod iOwn_update_op (a' := op (●F (n + 1)) (◯F{q} (k + 1))) $$ [$Hγ $Hγf] with ⟨Hγ, Hγf⟩
    · exact FracAuth.update (CommMonoidLike.leftCancelAdd_local_update (by grind))
    imod Hclose $$ [Hγ Hl] with -
    · inext; iexists (n + 1); rw [show ((n + 1 : Nat) : Int) = (n : Int) + 1 by omega]; iframe
    imodintro
    iintro %⟨⟩
    iexact Hγf

theorem twoIncr_spec : ⊢ WP twoIncr {{ v, ⌜v = hl_val(#(2 : Int))⌝ }} := by
  unfold twoIncr
  wp_alloc l with Hl
  imod iOwn_alloc (F := CCounterRF) (op (●F (0 : Nat)) (◯F (0 : Nat))) with ⟨%γ, Hγ, Hγf⟩
  · exact FracAuth.valid trivial
  imod inv_alloc countN ⊤ (ccounterInv γ l) $$ [Hl Hγ] with #Hinv
  · inext; iexists 0; iframe
  -- split the full contribution into two halves
  ihave ⟨H1, H2⟩ := (ccounter_op (GF := GF) γ (Qp.half 1) (Qp.half 1) 0 0).mp $$ [Hγf]
  · simp only [Qp.half_add_half]; iexact Hγf
  wp_pures
  wp_bind &par _ _
  iapply wp_par (fun _ => ccounter γ (Qp.half 1) 1) (fun _ => ccounter γ (Qp.half 1) 1)
    $$ [H1] [H2]
  · iapply incr_thread $$ [$Hinv $H1]
  · iapply incr_thread $$ [$Hinv $H2]
  iintro %v1 %v2 ⟨H1, H2⟩
  inext
  ihave Hfull := (ccounter_op (GF := GF) γ (Qp.half 1) (Qp.half 1) 1 1).mpr $$ [$H1 $H2]
  simp only [Qp.half_add_half] at *
  wp_pures
  iinv Hinv with ⟨%n, >Hγ, >Hl⟩ Hclose
  wp_load
  icombine Hγ Hfull gives %Hv
  have hn : n = 2 := FracAuth.agree Hv
  subst hn
  imod Hclose $$ [Hγ Hl] with -
  · inext; iexists 2; iframe
  imodintro
  ipureintro
  rfl

end Proof

/-! ## Closing the proof: adequacy needs a concrete ghost-state signature. -/

def CounterS : BundledGFunctors
  | 0 => ⟨InvMapF⟩
  | 1 => ⟨constOF CoPsetDisjL⟩
  | 2 => ⟨constOF (DisjointLeibnizSet PosSet)⟩
  | 3 => ⟨Auth.AuthURF (constOF Credit)⟩
  | 4 => ⟨constOF (HeapView Loc (Agree (DiscreteO (Option Val))) HeapF)⟩
  | 5 => ⟨constOF (HeapView Loc (Agree (DiscreteO GName)) HeapF)⟩
  | 6 => ⟨constOF MetaUR⟩
  | 7 => ⟨constOF (HeapView ProphId (Agree (DiscreteO (List (Val × Val)))) ProphMapF)⟩
  | 8 => ⟨constOF (Auth (InvHeapMapUR (Option Val) HeapF))⟩
  | 9 => ⟨TokenF⟩
  | 10 => ⟨CCounterRF⟩
  | _ => ⟨constOF Unit⟩

instance : HeapLangGpreS HasLC.hasLC CounterS where
  toWsatGpreS := by
    constructor
    · exists 0
    · exists 1
    · exists 2
  toLcGpreS := by
    constructor
    · exists 3
  heap_pre := by
    constructor
    · constructor
      exists 4
    · constructor
      exists 5
    · exists 6
  proph_pre := by
    constructor
    · constructor
      exists 7
  inv_heap_pre := by
    constructor
    exists 8

instance : TokenG CounterS := @TokenG.mk _ ⟨9, rfl⟩
instance : CCounterG CounterS := @CCounterG.mk _ ⟨10, rfl⟩

/-- The headline theorem: every execution of `twoIncr`, from any initial state, is safe and
returns 2 if it returns. A plain Lean `Prop` about the operational semantics; Iris is gone. -/
theorem twoIncr_adequate (σ : State) :
    adequate .NotStuck twoIncr σ (fun v _ => v = hl_val(#(2 : Int))) := by
  apply heap_adequacy (GF := CounterS)
  intro _
  iintro _
  iapply twoIncr_spec

end LeanUIIris.TwoThreads
