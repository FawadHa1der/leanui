/-
A closed FIFO theorem for a two-thread program using the ring:

  buf := allocn 2; hd := ref 0; tl := ref 0
  (pushLoop 10; pushLoop 20) ‖ (let a := popLoop (); let b := popLoop (); (a, b))

`spscClient_adequate`: in every interleaving nothing gets stuck and, if the program returns, the
consumer received exactly (10, 20): in order, none lost, none duplicated. The ring's resource is
`P i v := ⌜v = msgs[i]⌝`. The retry loops spin; nothing here says they terminate.
-/
import LeanUIIris.Kernels.SpscRing
import Iris.HeapLang.Lib.Par

namespace LeanUIIris.SpscClient
open Iris Iris.HeapLang BI ProgramLogic Par Spawn
open LeanUIIris.SpscRing

def pushLoop : Val := hl_val%
  rec push buf hd tl n v :=
    if &tryPush buf hd tl n v then #() else push buf hd tl n v

def popLoop : Val := hl_val%
  rec pop buf hd tl n :=
    match &tryPop buf hd tl n with
    | none() => pop buf hd tl n
    | some(x) => x

def spscClient : Exp := hl%
  let buf := allocn(#(2 : Int), #(0 : Int));
  let hd := ref(#(0 : Int));
  let tl := ref(#(0 : Int));
  let r := ((&pushLoop buf hd tl #(2 : Int) #(10 : Int); &pushLoop buf hd tl #(2 : Int) #(20 : Int))
            ‖ (let a := &popLoop buf hd tl #(2 : Int);
               let b := &popLoop buf hd tl #(2 : Int);
               (a, b)));
  snd(r)

/-- The messages: the i-th message is 10 * (i + 1). -/
def msg (i : Nat) : Val := hl_val(#((10 * (i + 1) : Nat) : Int))

section Proof
variable {GF : BundledGFunctors} [HeapLangGS hlc GF] [GhostVarG GF (Nat × Bool)] [SpawnG GF]
local bi (IProp GF)
set_option linter.unusedSectionVars false

abbrev Pmsg : Nat → Val → IProp GF := fun i v => iprop(⌜v = msg i⌝)

variable {buf hd tl : Loc} {γh γt : GName}

theorem pushLoop_spec (t : Nat) (v : Val) :
    {{ rbCtx buf hd tl 2 Pmsg γh γt ∗ producer γt t ∗ ⌜v = msg t⌝ }}
      hl(&pushLoop #buf #hd #tl #(2 : Int) &v)
    {{ RET hl_val(#()); producer γt (t + 1) }} := by
  iintro %Φ ⟨#Hinv, Hp, %hv⟩ HΦ
  iloeb as IH generalizing Hp
  wp_rec
  wp_pures
  wp_apply (tryPush_spec (N := 2) (P := Pmsg) t v) $$ [Hp] with %b Hb
  · iframe Hinv Hp; ipureintro; exact hv
  cases b
  · isimp at Hb
    icases Hb with ⟨Hp, -⟩
    wp_pures
    iapply IH $$ Hp HΦ
  · isimp at Hb
    wp_pures
    iapply HΦ $$ Hb

theorem popLoop_spec (h : Nat) :
    {{ rbCtx buf hd tl 2 Pmsg γh γt ∗ consumer γh h }}
      hl(&popLoop #buf #hd #tl #(2 : Int))
    {{ v, RET v; ⌜v = msg h⌝ ∗ consumer γh (h + 1) }} := by
  iintro %Φ ⟨#Hinv, Hc⟩ HΦ
  iloeb as IH generalizing Hc
  wp_rec
  wp_pures
  wp_apply (tryPop_spec (N := 2) (P := Pmsg) h) $$ [Hc] with %r Hr
  · iframe Hinv Hc
  icases Hr with (⟨%hr, Hc⟩ | ⟨%v, %hr, %hv, Hc⟩)
  · subst hr
    wp_pures
    iapply IH $$ Hc
    inext
    iexact HΦ
  · subst hr
    wp_pures
    iapply HΦ
    iframe Hc
    ipureintro
    exact hv

theorem spscClient_spec : ⊢ WP spscClient {{ v, ⌜v = hl_val((#(10 : Int), #(20 : Int)))⌝ }} := by
  unfold spscClient
  wp_alloc b with Hbuf
  wp_pures
  wp_alloc h0 with Hhd
  wp_pures
  wp_alloc t0 with Htl
  wp_pures
  imod rb_init (buf := b) (hd := h0) (tl := t0) (P := Pmsg) (N := 2)
    (List.replicate (Int.toNat 2) hl_val(#(0 : Int))) (by simp) $$ [Hbuf Hhd Htl] with ⟨%γh, %γt, #Hinv, Hp, Hc⟩
  · iframe
  wp_bind &par _ _
  iapply wp_par (fun _ => producer γt 2) (fun r => iprop(⌜r = hl_val((#(10 : Int), #(20 : Int)))⌝))
    $$ [Hp] [Hc]
  · wp_apply (pushLoop_spec 0 _) $$ [Hp] with Hp
    · iframe Hinv Hp; ipureintro; rfl
    wp_pures
    wp_apply (pushLoop_spec 1 _) $$ [Hp] with Hp
    · iframe Hinv Hp; ipureintro; rfl
    iexact Hp
  · wp_apply (popLoop_spec 0) $$ [Hc] with %a ⟨%ha, Hc⟩
    · iframe Hinv Hc
    wp_pures
    wp_apply (popLoop_spec 1) $$ [Hc] with %b ⟨%hb, Hc⟩
    · iframe Hinv Hc
    wp_pures
    subst ha hb
    ipureintro
    rfl
  iintro %v1 %v2 ⟨-, %h2⟩
  inext
  subst h2
  wp_pures
  ipureintro
  rfl

end Proof

/-! ## Adequacy with a concrete ghost-state signature -/

def RingS : BundledGFunctors
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
  | 10 => ⟨GhostVarF (Nat × Bool)⟩
  | _ => ⟨constOF Unit⟩

instance : HeapLangGpreS HasLC.hasLC RingS where
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

instance : TokenG RingS := @TokenG.mk _ ⟨9, rfl⟩
instance : GhostVarG RingS (Nat × Bool) := @GhostVarG.mk _ _ ⟨10, rfl⟩

/-- Every interleaving of the two-thread SPSC program is safe and delivers (10, 20) in order. -/
theorem spscClient_adequate (σ : State) :
    adequate .NotStuck spscClient σ (fun v _ => v = hl_val((#(10 : Int), #(20 : Int)))) := by
  apply heap_adequacy (GF := RingS)
  intro _
  iintro _
  iapply spscClient_spec

end LeanUIIris.SpscClient
