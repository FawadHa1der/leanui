/-
Futex hints: two HeapLang functions that do nothing, which the translator turns into
`Atomics.wait` and `Atomics.notify` (C: `futex`).

HeapLang cannot block, so every verified wait is a spin, and spinning collapses once threads
outnumber cores. A futex wait writes no memory and only delays the calling thread (it returns on a
notify, a value mismatch, the timeout, or spuriously). A delay is one more interleaving of the same
HeapLang steps, and adequacy covers every interleaving, so the hints keep every safety theorem.
They prove nothing about liveness; the runtime's waits are timed (20 ms), so a lost wakeup
delays a waiter but cannot strand it.

Trusted: that the translator recognises exactly these two values (it compares them with `=`), and
the runtime's two functions.
-/
import Iris.HeapLang.PrimitiveLaws
import Iris.HeapLang.ProofMode

namespace LeanUIIris.Hints
open Iris Iris.HeapLang BI ProgramLogic

def futexWait : Val := hl_val% λ futex_wait_loc futex_wait_expected, #()
def futexWake : Val := hl_val% λ futex_wake_loc, #()

variable {GF : BundledGFunctors} [HeapLangGS hlc GF]
local bi (IProp GF)

theorem futexWait_spec (l v : Val) :
    {{ True }} hl(&futexWait &l &v) {{ RET hl_val(#()); True }} := by
  iintro %Φ - HΦ
  wp_rec
  wp_pures
  iapply HΦ
  itrivial

theorem futexWake_spec (l : Val) :
    {{ True }} hl(&futexWake &l) {{ RET hl_val(#()); True }} := by
  iintro %Φ - HΦ
  wp_rec
  iapply HΦ
  itrivial

end LeanUIIris.Hints
