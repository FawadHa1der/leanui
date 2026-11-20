/-
The same Treiber stack constants as `Treiber.lean`, with logically atomic specifications against
an abstract list owned by the client:

  <<{ ∀∀ xs, stackContent γ xs }>> push s x @ ↑N <<{ stackContent γ (x :: xs) | RET () }>>
  <<{ ∀∀ xs, stackContent γ xs }>> pop s    @ ↑N <<{ stackContent γ xs.tail | RET popRet xs }>>

Each call takes effect at one instant (the successful CAS; for a pop of an empty stack, the load
that saw `none`). This is a logically atomic spec, the Iris form of linearizability; the link to
linearizability over histories is not formalised in Lean.
-/
import LeanUIIris.Kernels.Treiber
import Iris.ProgramLogic.Atomic
import Iris.Instances.Lib.GhostVar

namespace LeanUIIris.TreiberAtomic
open Iris Iris.HeapLang BI ProgramLogic
open LeanUIIris.Treiber (newStack push pop stackN)

variable {GF : BundledGFunctors} [HeapLangGS hlc GF] [GhostVarG GF (List Val)]
local bi (IProp GF)
set_option linter.unusedSectionVars false

/-- The physical list from `hd` spells `xs`. Fully persistent: nodes are immutable. -/
def isListA (hd : Val) : List Val → IProp GF
  | [] => iprop% ⌜hd = hl_val(none())⌝
  | x :: xs => iprop% ∃ (c : Loc) (tl : Val), ⌜hd = hl_val(some(#c))⌝ ∗
      c ↦{.discard} some hl_val((&x, &tl)) ∗ isListA tl xs

theorem isListA_nil {hd : Val} : isListA (GF := GF) hd [] ⊣⊢ iprop(⌜hd = hl_val(none())⌝) := .rfl

theorem isListA_cons {hd x : Val} {xs : List Val} :
    isListA (GF := GF) hd (x :: xs) ⊣⊢ iprop(∃ (c : Loc) (tl : Val), ⌜hd = hl_val(some(#c))⌝ ∗
      c ↦{.discard} some hl_val((&x, &tl)) ∗ isListA tl xs) := .rfl

instance isListA_persistent (hd : Val) (xs : List Val) : Persistent (isListA (GF := GF) hd xs) := by
  induction xs generalizing hd with
  | nil => unfold isListA; infer_instance
  | cons x xs ih => unfold isListA; infer_instance

theorem isListA_head (hd : Val) (xs : List Val) :
    isListA (GF := GF) hd xs ⊢ ⌜hd = hl_val(none()) ∨ ∃ c : Loc, hd = hl_val(some(#c))⌝ := by
  cases xs with
  | nil => unfold isListA; iintro %h; ipureintro; exact .inl h
  | cons x xs => unfold isListA; iintro ⟨%c, %tl, %h, -⟩; ipureintro; exact .inr ⟨c, h⟩

abbrev stackInvA (γ : GName) (s : Loc) : IProp GF := iprop%
  ∃ (hd : Val) (xs : List Val), s ↦ some hd ∗ isListA hd xs ∗ γ ↪VAR{.own (1 : Qp).half} xs

/-- Persistent handle: the stack lives at `s`. -/
abbrev isStackA (γ : GName) (sv : Val) : IProp GF := iprop%
  ∃ s : Loc, ⌜sv = hl_val(#s)⌝ ∗ inv stackN (stackInvA γ s)

/-- The abstract content, owned by the client. -/
abbrev stackContent (γ : GName) (xs : List Val) : IProp GF := γ ↪VAR{.own (1 : Qp).half} xs

def popRet : List Val → Val
  | [] => hl_val(none())
  | x :: _ => hl_val(some(&x))

theorem newStackA_spec :
    {{ True }} hl(&newStack #()) {{ sv, RET sv; ∃ γ, isStackA γ sv ∗ stackContent γ [] }} := by
  iintro %Φ - HΦ
  wp_lam
  wp_alloc s with Hs
  imod ghost_var_alloc (GF := GF) ([] : List Val) with ⟨%γ, Hγ⟩
  ihave ⟨Hγ1, Hγ2⟩ := ghost_var_split γ ([] : List Val) (1 : Qp).half (1 : Qp).half $$ [Hγ]
  · rw [Qp.half_add_half]; iexact Hγ
  imod inv_alloc stackN ⊤ (stackInvA γ s) $$ [Hs Hγ1] with #Hinv
  · inext; iexists hl_val(none()), []; iframe; iapply isListA_nil.mpr; itrivial
  imodintro
  iapply HΦ
  iexists γ
  iframe Hγ2
  iexists s
  iframe Hinv
  itrivial

theorem pushA_spec (γ : GName) (sv x : Val) :
    isStackA γ sv ⊢
      <<{ ∀∀ (xs : List Val), stackContent γ xs }>> hl(&push &sv &x) @ ↑stackN
      <<{ stackContent γ (x :: xs) | RET hl_val(#()) }>> := by
  iintro ⟨%s, %rfl, #Hinv⟩
  iunfold atomic_wp
  iintro %Φ
  iloeb as IH
  iintro AU
  wp_rec
  wp_pures
  wp_bind !_
  iinv Hinv with ⟨%hd, %xs, >Hs, #Hlist, >Hγ⟩ Hclose
  wp_load
  ihave %Hhd := isListA_head hd xs $$ Hlist
  imod Hclose $$ [Hs Hγ] with -
  · inext; iexists hd, xs; iframe; iframe Hlist
  imodintro
  wp_pures
  wp_alloc c with Hc
  imod pointsTo_persist $$ Hc with #Hc
  wp_pures
  wp_bind cmpXchg(_, _, _)
  iinv Hinv with ⟨%hd', %xs', >Hs, #Hlist', >Hγ⟩ Hclose
  wp_cmpxchg with hsuc hfail
  · rcases Hhd with rfl | ⟨c', rfl⟩ <;>
      simp [Val.compareSafe, Val.isUnboxed, BaseLit.isUnboxed]
  · -- linearisation point: open the client's atomic update and commit `xs ↦ x :: xs`
    subst hsuc
    imod AU with ⟨%⟨ys, ⟨⟩⟩, Hys, Hacc⟩
    isimp only [Std.Tele.app] at Hys
    icombine Hγ Hys gives %⟨-, rfl⟩
    imod ghost_var_update_halves (x :: xs') γ xs' xs' $$ Hγ Hys with ⟨Hγ, Hys⟩
    icases Hacc with ⟨-, Hcommit⟩
    isimp only [Std.Tele.app] at Hcommit
    imod Hcommit $$ %⟨⟩ Hys with HΦ
    isimp only [Std.Tele.app, Std.Tele.lam, Std.Tele.bind, Std.Tele.app_bind] at HΦ
    ispecialize HΦ $$ %⟨⟩
    isimp only [BIBase.wandM] at HΦ
    imod Hclose $$ [Hs Hγ] with -
    · inext
      iexists hl_val(some(#c)), (x :: xs')
      iframe
      iapply isListA_cons.mpr
      iexists c, hd'
      iframe Hc Hlist'
      itrivial
    imodintro
    wp_pures
    iexact HΦ
  · imod Hclose $$ [Hs Hγ] with -
    · inext; iexists hd', xs'; iframe; iframe Hlist'
    imodintro
    wp_pures
    iapply IH $$ AU

theorem popA_spec (γ : GName) (sv : Val) :
    isStackA γ sv ⊢
      <<{ ∀∀ (xs : List Val), stackContent γ xs }>> hl(&pop &sv) @ ↑stackN
      <<{ stackContent γ xs.tail | RET popRet xs }>> := by
  iintro ⟨%s, %rfl, #Hinv⟩
  iunfold atomic_wp
  iintro %Φ
  iloeb as IH
  iintro AU
  wp_rec
  wp_bind !_
  iinv Hinv with ⟨%hd, %xs, >Hs, #Hlist, >Hγ⟩ Hclose
  wp_load
  cases xs with
  | nil =>
    -- linearisation point of an empty pop: the load that saw `none`
    icases isListA_nil.mp $$ Hlist with %Hhd
    subst Hhd
    imod AU with ⟨%⟨ys, ⟨⟩⟩, Hys, Hacc⟩
    isimp only [Std.Tele.app] at Hys
    icombine Hγ Hys gives %⟨-, rfl⟩
    icases Hacc with ⟨-, Hcommit⟩
    isimp only [Std.Tele.app, List.tail_nil] at Hcommit
    imod Hcommit $$ %⟨⟩ Hys with HΦ
    isimp only [Std.Tele.app, Std.Tele.lam, Std.Tele.bind, Std.Tele.app_bind] at HΦ
    ispecialize HΦ $$ %⟨⟩
    isimp only [BIBase.wandM, popRet] at HΦ
    imod Hclose $$ [Hs Hγ] with -
    · inext; iexists hl_val(none()), []; iframe; iapply isListA_nil.mpr; itrivial
    imodintro
    wp_pures
    iexact HΦ
  | cons x xs =>
    icases isListA_cons.mp $$ Hlist with ⟨%c, %tl, %Hhd, #Hc, #Hrest⟩
    subst Hhd
    imod Hclose $$ [Hs Hγ] with -
    · inext; iexists hl_val(some(#c)), (x :: xs); iframe; iframe Hlist
    imodintro
    wp_pures
    wp_load
    wp_pures
    wp_bind cmpXchg(_, _, _)
    iinv Hinv with ⟨%hd', %xs', >Hs, #Hlist', >Hγ⟩ Hclose
    wp_cmpxchg with hsuc hfail
    · simp [Val.compareSafe, Val.isUnboxed, BaseLit.isUnboxed]
    · -- linearisation point of a successful pop
      subst hsuc
      cases xs' with
      | nil =>
        icases isListA_nil.mp $$ Hlist' with %Hhd'
        simp at Hhd'
      | cons x' xs'' =>
        icases isListA_cons.mp $$ Hlist' with ⟨%c', %tl', %Hhd', #Hc', #Hrest'⟩
        obtain rfl : c' = c := by simp at Hhd'; exact Hhd'.symm
        icombine Hc Hc' gives %Hagree
        simp at Hagree
        obtain ⟨-, rfl, rfl⟩ := Hagree
        imod AU with ⟨%⟨ys, ⟨⟩⟩, Hys, Hacc⟩
        isimp only [Std.Tele.app] at Hys
        icombine Hγ Hys gives %⟨-, rfl⟩
        imod ghost_var_update_halves xs'' γ (x :: xs'') (x :: xs'') $$ Hγ Hys with ⟨Hγ, Hys⟩
        icases Hacc with ⟨-, Hcommit⟩
        isimp only [Std.Tele.app, List.tail_cons] at Hcommit
        imod Hcommit $$ %⟨⟩ Hys with HΦ
        isimp only [Std.Tele.app, Std.Tele.lam, Std.Tele.bind, Std.Tele.app_bind] at HΦ
        ispecialize HΦ $$ %⟨⟩
        isimp only [BIBase.wandM, popRet, List.tail_cons] at HΦ
        imod Hclose $$ [Hs Hγ] with -
        · inext; iexists tl, xs''; iframe; iframe Hrest'
        imodintro
        wp_pures
        iexact HΦ
    · imod Hclose $$ [Hs Hγ] with -
      · inext; iexists hd', xs'; iframe; iframe Hlist'
      imodintro
      wp_pures
      iapply IH $$ AU

end LeanUIIris.TreiberAtomic
