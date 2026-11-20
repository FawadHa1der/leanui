/-
The lost-wakeup mutant of `FutexMutex`, and its proof: `release` without the `futexWake`.

  releaseNoWake l := if faa(l, -1) = 1 then () else l ← 0

A waiter parked in `futexWait` is now never woken; it runs again only when the runtime's timed
wait expires (20 ms). That is a liveness bug, and the proof does not see it: `futexWake` is a
proved no-op, so removing it changes no safety fact, and `releaseNoWake_spec` is the very
statement of `FutexMutex.release_spec`. `instLock` makes the mutant a lawful `Lock`, so
`Critical.critical_spec` covers `criticalNoWake` as well. S11 in `iris/README.md` runs both and
counts the expired waits: the theorems are the same, the behaviour is not.
-/
import LeanUIIris.Kernels.Critical

namespace LeanUIIris.FutexNoWake
open Iris Iris.HeapLang BI ProgramLogic LeanUIIris.FutexMutex

def releaseNoWake : Val := hl_val%
  λ l, if faa(l, #(-1 : Int)) = #1 then #() else (l ← #0)

def criticalNoWake : Val := Critical.critical FutexMutex.acquire releaseNoWake

variable {GF : BundledGFunctors} [HeapLangGS hlc GF] [TokenG GF]
local bi (IProp GF)

theorem releaseNoWake_spec (γ : GName) (lk : Val) (R : IProp GF) :
    {{ isLock γ lk R ∗ locked γ ∗ R }} hl(&releaseNoWake &lk) {{ RET hl_val(#()); True }} := by
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
  · subst h
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
      iapply Hcont; itrivial

/-- The mutant is a lawful `Lock`: the same interface, the same theorems. -/
@[implicit_reducible]
def instLock [HeapLangGS hlc GF] : Lock GF where
  newlock := FutexMutex.newlock
  acquire := FutexMutex.acquire
  release := releaseNoWake
  lockG := TokenG
  name := GName
  isLock _ γ lk R := FutexMutex.isLock γ lk R
  locked _ γ := FutexMutex.locked γ
  isLock_persistent _ _ _ := inferInstance
  isLock_iff γ lk R₁ R₂ := FutexMutex.isLock_iff γ lk R₁ R₂
  locked_timeless _ := inferInstance
  locked_exclusive γ := FutexMutex.locked_exclusive γ
  newlock_spec_delay_init := FutexMutex.newlock_spec
  acquire_spec γ lk R := FutexMutex.acquire_spec γ lk R
  release_spec γ lk R := releaseNoWake_spec γ lk R

omit [TokenG GF] in
theorem criticalNoWake_eq :
    criticalNoWake = Critical.critical (instLock (hlc := hlc) (GF := GF)).acquire
      (instLock (hlc := hlc) (GF := GF)).release := rfl

theorem criticalNoWake_spec (γ : GName) (lk : Val) (a b : Loc) :
    {{ FutexMutex.isLock γ lk (Critical.pairInv a b) }}
      hl(&criticalNoWake &lk #a #b)
    {{ RET hl_val(#true); True }} := by
  have h := Critical.critical_spec (L := instLock (hlc := hlc) (GF := GF))
    (inferInstanceAs (TokenG GF)) γ lk a b
  rw [criticalNoWake_eq (hlc := hlc) (GF := GF)]
  exact h

end LeanUIIris.FutexNoWake
