/-
One critical section, written once and proved once for every lock that implements iris-lean's
`Lock` interface:

  critical acquire release lk a b :=
    acquire lk; let x := !a; let y := !b; a ← x + 1; b ← y + 1; release lk; x = y

The lock guards the invariant "the two cells are equal" (`pairInv a b`), so the check inside
always succeeds: `critical_spec` says the section returns `true`, for any `Lock` instance.
`SpinLock`, `TicketLock` and `FutexMutex` are such instances, so the three locks get the same
theorem (`criticalSpin`, `criticalTicket`, `criticalFutex`) while they behave very differently
under contention (S2 in `iris/README.md`). The theorem says nothing about fairness or progress.

`racy` is the same body without a lock, the negative control: it has no proof, since the two
loads may see different values while another thread is between its two stores.
-/
import Iris.HeapLang.Lib.SpinLock
import Iris.HeapLang.Lib.TicketLock
import LeanUIIris.Kernels.FutexMutex

namespace LeanUIIris.Critical
open Iris Iris.HeapLang BI ProgramLogic

def critical (acquire release : Val) : Val := hl_val%
  λ lk a b,
    &acquire lk;
    let x := !a;
    let y := !b;
    a ← x + #(1 : Int);
    b ← y + #(1 : Int);
    &release lk;
    x = y

def racy : Val := hl_val%
  λ a b,
    let x := !a;
    let y := !b;
    a ← x + #(1 : Int);
    b ← y + #(1 : Int);
    x = y

def criticalSpin : Val := critical SpinLock.acquire SpinLock.release
def criticalTicket : Val := critical TicketLock.acquire TicketLock.release
def criticalFutex : Val := critical FutexMutex.acquire FutexMutex.release

variable {GF : BundledGFunctors} [HeapLangGS hlc GF]
local bi (IProp GF)

/-- What the lock protects: two cells holding the same integer. -/
def pairInv (a b : Loc) : IProp GF := iprop% ∃ n : Int, a ↦ some hl_val(#n) ∗ b ↦ some hl_val(#n)

theorem critical_spec [L : Lock GF] (N : L.lockG GF) (γ : L.name) (lk : Val) (a b : Loc) :
    {{ L.isLock N γ lk (pairInv a b) }}
      hl(&(critical L.acquire L.release) &lk #a #b)
    {{ RET hl_val(#true); True }} := by
  iintro %Φ #Hlock HΦ
  unfold critical
  wp_pures
  wp_apply (L.acquire_spec (N := N) γ lk (pairInv a b)) $$ [Hlock] with ⟨Hlocked, HR⟩
  · iexact Hlock
  iunfold pairInv at HR
  icases HR with ⟨%n, Ha, Hb⟩
  wp_pures
  wp_load
  wp_pures
  wp_load
  wp_pures
  wp_store
  wp_pures
  wp_store
  wp_pures
  wp_apply (L.release_spec (N := N) γ lk (pairInv a b)) $$ [Hlock Hlocked Ha Hb] with -
  · isplitr [Hlocked Ha Hb]
    · iexact Hlock
    iframe Hlocked
    iunfold pairInv
    iexists (n + 1)
    iframe
  wp_pures
  rw [beq_self_eq_true]
  iapply HΦ
  itrivial


/-! The same theorem for each lock, about the three Vals the harness runs. (By tactic: elaborating
the instantiation against the stated type in term mode times out.) -/

theorem criticalSpin_eq :
    criticalSpin = critical (SpinLock.instLock (hlc := hlc) (GF := GF)).acquire
      (SpinLock.instLock (hlc := hlc) (GF := GF)).release := rfl

theorem criticalSpin_spec [SpinLock.SpinLockG GF] (γ : GName) (lk : Val) (a b : Loc) :
    {{ SpinLock.isLock γ lk (pairInv a b) }}
      hl(&criticalSpin &lk #a #b)
    {{ RET hl_val(#true); True }} := by
  have h := critical_spec (L := SpinLock.instLock (hlc := hlc) (GF := GF))
    (inferInstanceAs (SpinLock.SpinLockG GF)) γ lk a b
  rw [criticalSpin_eq (hlc := hlc) (GF := GF)]
  exact h

theorem criticalTicket_eq :
    criticalTicket = critical (TicketLock.instLock (hlc := hlc) (GF := GF)).acquire
      (TicketLock.instLock (hlc := hlc) (GF := GF)).release := rfl

theorem criticalTicket_spec [TicketLock.TicketLockG GF] (γ : GName) (lk : Val) (a b : Loc) :
    {{ TicketLock.isLock γ lk (pairInv a b) }}
      hl(&criticalTicket &lk #a #b)
    {{ RET hl_val(#true); True }} := by
  have h := critical_spec (L := TicketLock.instLock (hlc := hlc) (GF := GF))
    (inferInstanceAs (TicketLock.TicketLockG GF)) γ lk a b
  rw [criticalTicket_eq (hlc := hlc) (GF := GF)]
  exact h

theorem criticalFutex_eq :
    criticalFutex = critical (FutexMutex.instLock (hlc := hlc) (GF := GF)).acquire
      (FutexMutex.instLock (hlc := hlc) (GF := GF)).release := rfl

theorem criticalFutex_spec [TokenG GF] (γ : GName) (lk : Val) (a b : Loc) :
    {{ FutexMutex.isLock γ lk (pairInv a b) }}
      hl(&criticalFutex &lk #a #b)
    {{ RET hl_val(#true); True }} := by
  have h := critical_spec (L := FutexMutex.instLock (hlc := hlc) (GF := GF))
    (inferInstanceAs (TokenG GF)) γ lk a b
  rw [criticalFutex_eq (hlc := hlc) (GF := GF)]
  exact h

end LeanUIIris.Critical
