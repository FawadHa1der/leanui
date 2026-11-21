/-
Treiber's stack (CAS on the head), with a bag specification: each element carries a resource
`P x`, which `push` gives up and `pop` hands to its caller, so the stack moves ownership of
anything (a buffer, a job) between threads.

  push s x := let hd := !s; let n := some(ref (x, hd)); if cas(s, hd, n) then () else push s x
  pop s    := let hd := !s; match hd with none => none
              | some c => let p := !c; if cas(s, hd, snd p) then some (fst p) else pop s

Not proved here: LIFO order (`TreiberAtomic.lean`), and progress. The proof relies on nodes never
being freed (persistent points-to), which is why there is no ABA problem; a translation that
recycles nodes is a different program, outside this proof.
-/
import Iris.HeapLang.PrimitiveLaws
import Iris.HeapLang.ProofMode
import Iris.Instances.Lib.Invariants

namespace LeanUIIris.Treiber
open Iris Iris.HeapLang BI ProgramLogic

def newStack : Val := hl_val% λ _, ref(none())

def push : Val := hl_val%
  rec push s x :=
    let hd := !s;
    let n := some(ref((x, hd)));
    if cas(s, hd, n) then #() else push s x

def pop : Val := hl_val%
  rec pop s :=
    let hd := !s;
    match hd with
    | none() => none()
    | some(c) =>
      let p := !c;
      if cas(s, hd, snd(p)) then some(fst(p)) else pop s

def stackN : Namespace := nroot .@ "treiber"

variable {GF : BundledGFunctors} [HeapLangGS hlc GF]
local bi (IProp GF)

/-- The linked list from `hd` holds exactly `xs`; nodes are immutable (persistent points-to),
and each element carries its resource `P x`. -/
def isList (P : Val → IProp GF) (hd : Val) : List Val → IProp GF
  | [] => iprop% ⌜hd = hl_val(none())⌝
  | x :: xs => iprop% ∃ (c : Loc) (tl : Val), ⌜hd = hl_val(some(#c))⌝ ∗
      c ↦{.discard} some hl_val((&x, &tl)) ∗ P x ∗ isList P tl xs

theorem isList_nil {P : Val → IProp GF} {hd : Val} :
    isList P hd [] ⊣⊢ iprop(⌜hd = hl_val(none())⌝) := .rfl

theorem isList_cons {P : Val → IProp GF} {hd x : Val} {xs : List Val} :
    isList P hd (x :: xs) ⊣⊢ iprop(∃ (c : Loc) (tl : Val), ⌜hd = hl_val(some(#c))⌝ ∗
      c ↦{.discard} some hl_val((&x, &tl)) ∗ P x ∗ isList P tl xs) := .rfl

abbrev stackInv (P : Val → IProp GF) (s : Loc) : IProp GF := iprop%
  ∃ (hd : Val) (xs : List Val), s ↦ some hd ∗ isList P hd xs

abbrev isStack (P : Val → IProp GF) (sv : Val) : IProp GF := iprop%
  ∃ s : Loc, ⌜sv = hl_val(#s)⌝ ∗ inv stackN (stackInv P s)

instance (P : Val → IProp GF) (sv : Val) : Persistent (isStack P sv) := by
  unfold isStack; infer_instance

/-- The head of a list is always an unboxed value (`none()` or `some(#c)`), so CAS on it is safe. -/
theorem isList_head (P : Val → IProp GF) (hd : Val) (xs : List Val) :
    isList P hd xs ⊢ ⌜hd = hl_val(none()) ∨ ∃ c : Loc, hd = hl_val(some(#c))⌝ := by
  cases xs with
  | nil => unfold isList; iintro %h; ipureintro; exact .inl h
  | cons x xs => unfold isList; iintro ⟨%c, %tl, %h, -⟩; ipureintro; exact .inr ⟨c, h⟩

theorem newStack_spec (P : Val → IProp GF) :
    {{ True }} hl(&newStack #()) {{ sv, RET sv; isStack P sv }} := by
  iintro %Φ - HΦ
  wp_lam
  wp_alloc s with Hs
  imod inv_alloc stackN ⊤ (stackInv P s) $$ [Hs] with #Hinv
  · inext; iexists hl_val(none()), []; iframe; iapply isList_nil.mpr; itrivial
  imodintro
  iapply HΦ
  iexists s
  iframe Hinv
  itrivial

theorem push_spec (P : Val → IProp GF) (sv x : Val) :
    {{ isStack P sv ∗ P x }} hl(&push &sv &x) {{ RET hl_val(#()); True }} := by
  iintro %Φ ⟨#Hst, HP⟩ HΦ
  icases Hst with ⟨%s, %rfl, #Hinv⟩
  iloeb as IH
  wp_rec
  wp_pures
  wp_bind !_
  iinv Hinv with ⟨%hd, %xs, >Hs, Hlist⟩ Hclose
  wp_load
  ihave #Hhd : ▷ ⌜hd = hl_val(none()) ∨ ∃ c : Loc, hd = hl_val(some(#c))⌝ $$ [Hlist]
  · inext; iapply isList_head $$ Hlist
  icases Hhd with >%Hhd
  imod Hclose $$ [Hs Hlist] with -
  · inext; iexists hd, xs; iframe
  imodintro
  wp_pures
  wp_alloc c with Hc
  imod pointsTo_persist $$ Hc with #Hc
  wp_pures
  wp_bind cmpXchg(_, _, _)
  iinv Hinv with ⟨%hd', %xs', >Hs, Hlist⟩ Hclose
  wp_cmpxchg with hsuc hfail
  · -- CAS safety: the expected value is unboxed (the invariant says heads are none/some(#c))
    rcases Hhd with rfl | ⟨c', rfl⟩ <;>
      simp [Val.compareSafe, Val.isUnboxed, BaseLit.isUnboxed]
  · -- success: the head did not move; link the new node in front of it
    subst hsuc
    imod Hclose $$ [Hs Hlist HP] with -
    · inext
      iexists hl_val(some(#c)), (x :: xs')
      iframe Hs
      iapply isList_cons.mpr
      iexists c, hd'
      iframe
      iframe Hc
      itrivial
    imodintro
    wp_pures
    iapply HΦ
    itrivial
  · -- failure: someone else changed the head; retry (the node we allocated is garbage)
    imod Hclose $$ [Hs Hlist] with -
    · inext; iexists hd', xs'; iframe
    imodintro
    wp_pures
    iapply IH $$ HP HΦ

theorem pop_spec (P : Val → IProp GF) (sv : Val) :
    {{ isStack P sv }} hl(&pop &sv)
    {{ v, RET v; ⌜v = hl_val(none())⌝ ∨ ∃ x, ⌜v = hl_val(some(&x))⌝ ∗ P x }} := by
  iintro %Φ #Hst HΦ
  icases Hst with ⟨%s, %rfl, #Hinv⟩
  iloeb as IH
  wp_rec
  wp_bind !_
  iinv Hinv with ⟨%hd, %xs, >Hs, Hlist⟩ Hclose
  wp_load
  cases xs with
  | nil =>
    -- empty stack: return none
    isimp only [isList] at Hlist
    icases Hlist with %Hhd
    subst Hhd
    imod Hclose $$ [Hs] with -
    · inext; iexists hl_val(none()), []; iframe; iapply isList_nil.mpr; itrivial
    imodintro
    wp_pures
    iapply HΦ
    ileft
    itrivial
  | cons x xs =>
    -- non-empty: remember the (immutable) head node, close the invariant unchanged
    isimp only [isList] at Hlist
    icases Hlist with ⟨%c, %tl, %Hhd, #Hc, HP, Hrest⟩
    subst Hhd
    imod Hclose $$ [Hs HP Hrest] with -
    · inext
      iexists hl_val(some(#c)), (x :: xs)
      iframe Hs
      iapply isList_cons.mpr
      iexists c, tl
      iframe
      iframe Hc
      itrivial
    imodintro
    wp_pures
    wp_load
    wp_pures
    wp_bind cmpXchg(_, _, _)
    iinv Hinv with ⟨%hd', %xs', >Hs, Hlist⟩ Hclose
    wp_cmpxchg with hsuc hfail
    · simp [Val.compareSafe, Val.isUnboxed, BaseLit.isUnboxed]
    · -- success: the head is still node c, so the invariant's first node IS c (and has the same
      -- contents, by agreement of persistent points-to): take its resource out
      subst hsuc
      cases xs' with
      | nil =>
        isimp only [isList] at Hlist
        icases Hlist with %Hhd'
        simp at Hhd'
      | cons x' xs'' =>
        isimp only [isList] at Hlist
        icases Hlist with ⟨%c', %tl', %Hhd', #Hc', HP, Hrest⟩
        obtain rfl : c' = c := by simp at Hhd'; exact Hhd'.symm
        icombine Hc Hc' gives %Hagree
        simp at Hagree
        obtain ⟨-, rfl, rfl⟩ := Hagree
        imod Hclose $$ [Hs Hrest] with -
        · inext; iexists tl, xs''; iframe
        imodintro
        wp_pures
        iapply HΦ
        iright
        iexists x
        iframe
        itrivial
    · -- failure: retry
      imod Hclose $$ [Hs Hlist] with -
      · inext; iexists hd', xs'; iframe
      imodintro
      wp_pures
      iapply IH
      inext
      iexact HΦ

end LeanUIIris.Treiber
