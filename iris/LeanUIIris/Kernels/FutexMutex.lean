/-
Drepper's three-state futex mutex ("Futexes are tricky", mutex 3), and its proof: an instance of
iris-lean's `Lock` interface, the same specification as `SpinLock` and `TicketLock`.

The word is 0 (free), 1 (locked) or 2 (locked, maybe with waiters). `acquire` takes 0 → 1 with one
CAS; on contention it marks the word 2 and parks with `futexWait` until an exchange observes 0.
`release` decrements, and only when it was 2 stores 0 and wakes one waiter, so an uncontended
release makes no system call. The hints are discharged by their no-op specs (`Hints.lean`).

The invariant also keeps the word in {0, 1, 2}, so this word can never overflow the translator's
29-bit integers. Nothing here is about fairness or progress.
-/
import Iris.HeapLang.Lib.Lock
import Iris.Instances.Lib.Token
import Iris.Instances.Lib.Invariants
import LeanUIIris.Kernels.Hints

namespace LeanUIIris.FutexMutex
open Iris Iris.HeapLang BI ProgramLogic LeanUIIris.Hints

def newlock : Val := hl_val% λ _, ref(#0)

/-- The contended path: mark the word 2 and park until an exchange observes 0. -/
def slow : Val := hl_val%
  rec slow l c := if c = #0 then #() else (&futexWait l #2; slow l (xchg(l, #2)))

def acquire : Val := hl_val%
  λ l,
    let c := fst(cmpXchg(l, #0, #1));
    if c = #0 then #() else &slow l (if c = #2 then #2 else xchg(l, #2))

def release : Val := hl_val%
  λ l, if faa(l, #(-1 : Int)) = #1 then #() else (l ← #0; &futexWake l)

def mutexN : Namespace := ndot nroot "futexmutex"

section
variable {GF : BundledGFunctors} [HeapLangGS hlc GF] [TokenG GF]
local bi (IProp GF)

def locked (γ : GName) : IProp GF := token γ

/-- At 0 the lock holds the token and `R`; at 1 and 2 the holder has them. -/
def lockInv (γ : GName) (l : Loc) (R : IProp GF) : IProp GF := iprop%
  ∃ n : Int, (l ↦ some hl_val(#n)) ∗ ⌜n = 0 ∨ n = 1 ∨ n = 2⌝ ∗ (if n = 0 then locked γ ∗ R else True)

def isLock (γ : GName) (lk : Val) (R : IProp GF) : IProp GF := iprop%
  ∃ l : Loc, ⌜lk = Val.lit (.loc l)⌝ ∧ inv mutexN (lockInv γ l R)

instance (γ : GName) (lk : Val) (R : IProp GF) : Persistent (isLock γ lk R) := by
  unfold isLock; infer_instance

instance (γ : GName) : Timeless (locked (GF := GF) γ) := by
  unfold locked; infer_instance

theorem locked_exclusive (γ : GName) : locked (GF := GF) γ ∗ locked γ ⊢ False := token_exclusive γ

theorem isLock_iff (γ : GName) (lk : Val) (R₁ R₂ : IProp GF) :
    isLock γ lk R₁ ⊢ (▷ □ (R₁ ∗-∗ R₂)) -∗ isLock γ lk R₂ := by
  unfold isLock lockInv
  iintro ⟨%l, %H1, #H2⟩ #Heq
  iexists l
  isplit; itrivial
  iapply inv_iff $$ H2
  inext; imodintro
  isplit
  · iintro ⟨%n, H1, %Hn, H3⟩
    iexists n; iframe H1
    isplitr
    · ipureintro; exact Hn
    split
    · icases H3 with ⟨$, H3⟩
      iapply Heq $$ H3
    · itrivial
  · iintro ⟨%n, H1, %Hn, H3⟩
    iexists n; iframe H1
    isplitr
    · ipureintro; exact Hn
    split
    · icases H3 with ⟨$, H3⟩
      iapply Heq $$ H3
    · itrivial

/-- Decide `#a = #b` on integer literals inside a WP goal. -/
macro "hl_eq" : tactic => `(tactic| first
  | rw [beq_self_eq_true]
  | rw [beq_eq_false_iff_ne.mpr (by simp only [ne_eq, Val.lit.injEq, BaseLit.int.injEq]; omega)])

/-- Close the invariant at 1 or 2, where it holds no resources. -/
macro "close_nz" : tactic => `(tactic| (
  simp only [show ((1 : Int) = 0) = False by decide, show ((2 : Int) = 0) = False by decide, ↓reduceIte];
  isplitl []; (ipureintro; simp); itrivial))

theorem newlock_spec :
    {{ True }} hl(&newlock #())
    {{ v γ, RET v; ∀ R E, R ={E}=∗ isLock (GF := GF) γ v R }} := by
  iintro %Φ - Hcont
  wp_rec
  imod token_alloc with ⟨%γ, Hγ⟩
  wp_alloc l with Hpt
  imodintro
  iapply Hcont
  iintro %R %E HR
  imod inv_alloc mutexN E (lockInv γ l R) $$ [Hpt HR Hγ] with H
  · unfold lockInv locked
    iexists (0 : Int)
    simp only [↓reduceIte]
    iframe
    ipureintro; simp
  imodintro
  unfold isLock
  iexists l
  iframe
  itrivial

theorem slow_spec (γ : GName) (l : Loc) (R : IProp GF) (c : Int) :
    {{ inv mutexN (lockInv γ l R) ∗ (if c = 0 then locked γ ∗ R else True) }}
      hl(&slow #l #c) {{ RET hl_val(#()); locked γ ∗ R }} := by
  unfold lockInv
  iintro %Φ ⟨#Hinv, Hc⟩ Hcont
  iloeb as IH generalizing %c
  wp_rec
  wp_pures
  by_cases hc : c = 0
  · subst hc
    simp only [↓reduceIte]
    hl_eq
    wp_pures
    iapply Hcont
    iexact Hc
  · hl_eq
    wp_pures
    wp_apply (futexWait_spec hl_val(#l) hl_val(#2))
    all_goals (try itrivial)
    iintro -
    wp_pures
    wp_bind xchg(_, _)
    iinv Hinv with ⟨%n, >Hl, >%Hn, Hn⟩ Hclose
    wp_xchg
    by_cases hn : n = 0
    · subst hn
      simp only [↓reduceIte]
      imod Hclose $$ [Hl] with -
      · inext; iexists (2 : Int); iframe; close_nz
      imodintro
      iapply IH $$ [Hn] Hcont
      simp only [↓reduceIte]
      iexact Hn
    · imod Hclose $$ [Hl] with -
      · inext; iexists (2 : Int); iframe; close_nz
      imodintro
      iapply IH $$ [] Hcont
      simp only [hn, ↓reduceIte]
      itrivial

theorem acquire_spec (γ : GName) (lk : Val) (R : IProp GF) :
    {{ isLock γ lk R }} hl(&acquire &lk) {{ RET hl_val(#()); locked γ ∗ R }} := by
  unfold isLock
  iintro %Φ #Hlock Hcont
  icases Hlock with ⟨%l, %Heq, #Hinv⟩
  subst Heq
  wp_rec
  wp_bind cmpXchg(_, _, _)
  unfold lockInv
  iinv Hinv with ⟨%n, >Hl, >%Hn, Hn⟩ Hclose
  wp_cmpxchg with hsuc hfail
  · obtain rfl : n = 0 := by simpa using hsuc
    simp only [↓reduceIte]
    imod Hclose $$ [Hl] with -
    · inext; iexists (1 : Int); iframe; close_nz
    imodintro
    wp_pures
    hl_eq
    wp_pures
    iapply Hcont
    iexact Hn
  · have hn0 : n ≠ 0 := by intro h; subst h; simp at hfail
    imod Hclose $$ [Hl Hn] with -
    · inext; iexists n; iframe; ipureintro; exact Hn
    imodintro
    rcases Hn with h | h | h
    · exact absurd h hn0
    · subst h
      wp_pures
      hl_eq
      wp_pures
      hl_eq
      wp_pures
      wp_bind xchg(_, _)
      iinv Hinv with ⟨%m, >Hl, >%Hm, Hm⟩ Hclose
      wp_xchg
      by_cases hm : m = 0
      · subst hm
        simp only [↓reduceIte]
        imod Hclose $$ [Hl] with -
        · inext; iexists (2 : Int); iframe; close_nz
        imodintro
        iapply slow_spec $$ [Hm] Hcont
        unfold lockInv
        iframe Hinv
        simp only [↓reduceIte]
        iexact Hm
      · imod Hclose $$ [Hl] with -
        · inext; iexists (2 : Int); iframe; close_nz
        imodintro
        iapply slow_spec $$ [] Hcont
        unfold lockInv
        iframe Hinv
        simp only [hm, ↓reduceIte]
        itrivial
    · subst h
      wp_pures
      hl_eq
      wp_pures
      hl_eq
      wp_pures
      iapply slow_spec $$ [] Hcont
      unfold lockInv
      iframe Hinv
      simp only [show (2 : Int) ≠ 0 by omega, ↓reduceIte]
      itrivial

theorem release_spec (γ : GName) (lk : Val) (R : IProp GF) :
    {{ isLock γ lk R ∗ locked γ ∗ R }} hl(&release &lk) {{ RET hl_val(#()); True }} := by
  unfold isLock
  iintro %Φ ⟨#Hlock, Hl, HR⟩ Hcont
  icases Hlock with ⟨%l, %Heq, #Hinv⟩
  subst Heq
  wp_rec
  wp_bind faa(_, _)
  unfold lockInv
  iinv Hinv with ⟨%n, >Hpt, >%Hn, Hn⟩ Hclose
  wp_faa
  rcases Hn with h | h | h
  · -- 0: the invariant holds the token too, which contradicts ours
    subst h
    simp only [↓reduceIte]
    icases Hn with ⟨Htok, -⟩
    iexfalso
    iapply (locked_exclusive (GF := GF) γ) $$ [Hl Htok]
    iframe
  · subst h
    imod Hclose $$ [Hpt Hl HR] with -
    · inext; iexists (0 : Int)
      simp only [show (1 : Int) + -1 = 0 by omega, ↓reduceIte]
      iframe; ipureintro; simp
    imodintro
    wp_pures
    hl_eq
    wp_pures
    iapply Hcont; itrivial
  · subst h
    imod Hclose $$ [Hpt] with -
    · inext; iexists (1 : Int)
      simp only [show (2 : Int) + -1 = 1 by omega]
      iframe; close_nz
    imodintro
    wp_pures
    hl_eq
    wp_pures
    wp_bind (_ ← _)
    iinv Hinv with ⟨%m, >Hpt, >%Hm, Hm⟩ Hclose
    wp_store
    by_cases hm : m = 0
    · subst hm
      simp only [↓reduceIte]
      icases Hm with ⟨Htok, -⟩
      iexfalso
      iapply (locked_exclusive (GF := GF) γ) $$ [Hl Htok]
      iframe
    · imod Hclose $$ [Hpt Hl HR] with -
      · inext; iexists (0 : Int); simp only [↓reduceIte]; iframe; ipureintro; simp
      imodintro
      wp_pures
      wp_apply (futexWake_spec hl_val(#l))
      all_goals (try itrivial)

end

/-- The futex mutex as an iris-lean `Lock`: clients proved against the interface use it as is. -/
@[implicit_reducible]
def instLock [HeapLangGS hlc GF] : Lock GF where
  newlock := newlock
  acquire := acquire
  release := release
  lockG := TokenG
  name := GName
  isLock _ γ lk R := isLock γ lk R
  locked _ γ := locked γ
  isLock_persistent _ _ _ := inferInstance
  isLock_iff γ lk R₁ R₂ := isLock_iff γ lk R₁ R₂
  locked_timeless _ := inferInstance
  locked_exclusive γ := locked_exclusive γ
  newlock_spec_delay_init := newlock_spec
  acquire_spec γ lk R := acquire_spec γ lk R
  release_spec γ lk R := release_spec γ lk R

end LeanUIIris.FutexMutex
