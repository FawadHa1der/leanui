/-
Two lock-free increments with logically atomic specifications:

  <<{ ∀∀ n, l ↦ #n }>> incr #l @ ∅ <<{ l ↦ #(n+1) | RET #n }>>

`faaIncr` is one `faa` (`Atomics.add`); `casIncr` is a load and a `cmpXchg` retry loop
(`Atomics.compareExchange`). A logically atomic spec lets a client open its own invariant around
the call, as it would around one hardware atomic, so the counters compose (`TwoThreads.lean`).
iris-lean has `atomic_wp` but, at the pinned commit, no HeapLang library specified with it.
`casIncr` is lock-free at best; termination of its loop is not proved.
-/
import Iris.HeapLang.Lib.Counter
import Iris.ProgramLogic.Atomic

namespace LeanUIIris.AtomicCounter
open Iris Iris.HeapLang BI ProgramLogic

/-- Fetch-and-add increment; returns the old value. -/
def faaIncr : Val := hl_val% λ l, faa(l, #1)

/-- CAS-loop increment; returns the old value. -/
def casIncr : Val := hl_val%
  rec incr l :=
    let n := !l;
    if cas(l, n, n + #1) then n else incr l

variable {GF : BundledGFunctors} [HeapLangGS hlc GF]
local bi (IProp GF)

/-- Logically atomic FAA increment. -/
theorem faaIncr_spec (l : Loc) :
    ⊢ <<{ ∀∀ (n : Int), l ↦ some hl_val(#n) }>> hl(&faaIncr #l) @ ∅
      <<{ l ↦ some hl_val(#((n + 1 : Int))) | RET hl_val(#n) }>> := by
  iunfold atomic_wp
  iintro %Φ AU
  wp_lam
  imod AU with ⟨%⟨n, ⟨⟩⟩, Hl, -, Hclose⟩
  isimp only [Std.Tele.app] at Hl Hclose
  wp_faa
  imod Hclose $$ %⟨⟩ Hl with HΦ
  isimp only [Std.Tele.app, Std.Tele.lam, Std.Tele.bind, Std.Tele.app_bind] at HΦ
  ispecialize HΦ $$ %⟨⟩
  isimp only [BIBase.wandM] at HΦ
  imodintro
  iexact HΦ

/-- Logically atomic CAS-loop increment. The linearisation point is the successful `cmpXchg`;
the load and failed CASes "abort" the atomic update and hand it back unchanged. -/
theorem casIncr_spec (l : Loc) :
    ⊢ <<{ ∀∀ (n : Int), l ↦ some hl_val(#n) }>> hl(&casIncr #l) @ ∅
      <<{ l ↦ some hl_val(#((n + 1 : Int))) | RET hl_val(#n) }>> := by
  iunfold atomic_wp
  iintro %Φ AU
  iloeb as IH
  wp_rec
  wp_bind !_
  imod AU with ⟨%⟨n, ⟨⟩⟩, Hl, Habort, -⟩
  isimp only [Std.Tele.app] at Hl Habort
  wp_load
  imod Habort $$ Hl with AU
  imodintro
  wp_pures
  wp_bind cmpXchg(_, _, _)
  imod AU with ⟨%⟨m, ⟨⟩⟩, Hl, Hclose⟩
  isimp only [Std.Tele.app] at Hl
  wp_cmpxchg with hsuc hfail
  · obtain rfl : m = n := by simpa using hsuc
    icases Hclose with ⟨-, Hcommit⟩
    isimp only [Std.Tele.app] at Hcommit
    imod Hcommit $$ %⟨⟩ Hl with HΦ
    isimp only [Std.Tele.app, Std.Tele.lam, Std.Tele.bind, Std.Tele.app_bind] at HΦ
    ispecialize HΦ $$ %⟨⟩
    isimp only [BIBase.wandM] at HΦ
    imodintro
    wp_pures
    iexact HΦ
  · icases Hclose with ⟨Habort, -⟩
    isimp only [Std.Tele.app] at Habort
    imod Habort $$ Hl with AU
    imodintro
    wp_pures
    iapply IH
    isimp only [Std.Tele.app]
    iexact AU

/-- The derived sequential spec (any client that owns the location outright). -/
theorem casIncr_seq (l : Loc) (n : Int) :
    {{ l ↦ some hl_val(#n) }} hl(&casIncr #l) {{ RET hl_val(#n); l ↦ some hl_val(#((n + 1 : Int))) }} := by
  iintro %Φ Hl HΦ
  ihave H := casIncr_spec (GF := GF) l
  ihave H2 := atomic_wp_seq_step $$ H
  ispecialize H2 $$ %Φ %⟨n, ⟨⟩⟩
  isimp only [Std.Tele.app, Std.Tele.lam, Std.Tele.bind, Std.Tele.app_bind, BIBase.wandM] at H2
  iapply H2 $$ Hl
  iintro !> %⟨⟩ Hl %⟨⟩
  iapply HΦ $$ Hl

end LeanUIIris.AtomicCounter
