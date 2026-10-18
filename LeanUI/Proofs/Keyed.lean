module
public import LeanUI.Keyed
/-!
# Keyed reconciliation, machine-checked

Everything here is proved with no `sorry` and only the standard axioms (`propext`,
`Classical.choice`, `Quot.sound`); the `#guard_msgs` blocks at the end make `lake build` fail if
that ever changes. `docs/PROOFS.md` explains what is proved, what is tested and what is assumed.

**Correctness.** For duplicate-free key lists, applying the plan (`LeanUI.Keyed.applyList`: drop
`removed`, then right to left insert every child with `move` before its successor) yields the new
keys: `plan_correct`.

**The plan's fields.** `plan_src_some` / `plan_src_none` (`src` points at the old child with the
same key, `none` exactly for new keys), `plan_src_inj` (no old child is reused twice),
`mem_plan_removed` / `mem_plan_removed_iff` / `plan_removed_sorted` (`removed` is exactly the
unused old indices, increasing), `plan_create_moves` (every created child is inserted).

**Placement, both directions.** `place_correct_iff`: for any move flags, the right-to-left pass
is correct exactly when the keys at the non-moving positions appear in the start list in the
order `new` wants.

**Optimality.** `lis_spec`: `lis` returns a longest strictly increasing subsequence.
`plan_moves_fewest`: every plan that turns `old` into `new` (whatever it removes and moves)
inserts at least as many children as `plan old new`.

The proof of correctness follows one invariant through the right-to-left pass (`Inv`): once
positions `s … n-1` are done, the list is `P ++ Q` where `P` holds no finished key, the finished
keys `new[s:]` appear in `Q` in order, and the stable keys below `s` are still in `P` in order.
-/
@[expose] public section
namespace LeanUI.Proofs.Keyed
open LeanUI.Keyed
open scoped List

/-! ## `placeBefore` -/

theorem placeBefore_none (k : String) (xs : List String) :
    placeBefore k none xs = xs.filter (· != k) ++ [k] := rfl

theorem idxOf?_append_cons {A B : List String} {a : String} (h : a ∉ A) :
    (A ++ a :: B).idxOf? a = some A.length := by
  induction A with
  | nil => simp [List.idxOf?_cons]
  | cons x A ih =>
    simp only [List.mem_cons, not_or] at h
    have hx : (x == a) = false := by simpa [beq_eq_false_iff_ne] using Ne.symm h.1
    simp [List.idxOf?_cons, hx, ih h.2]

theorem placeBefore_some {k a : String} {xs A B : List String}
    (h : xs.filter (· != k) = A ++ a :: B) (ha : a ∉ A) :
    placeBefore k (some a) xs = A ++ k :: a :: B := by
  simp only [placeBefore, h, idxOf?_append_cons ha]
  simp

/-- `placeBefore k a xs` is `xs` without `k`, with `k` inserted somewhere. -/
theorem placeBefore_shape (k : String) (a : Option String) (xs : List String) :
    ∃ A B, placeBefore k a xs = A ++ k :: B ∧ A ++ B = xs.filter (· != k) := by
  unfold placeBefore
  split
  · exact ⟨_, [], rfl, by simp⟩
  · dsimp only
    split
    · exact ⟨_, _, rfl, List.take_append_drop _ _⟩
    · exact ⟨_, [], rfl, by simp⟩

theorem placeBefore_nodup {k : String} {a : Option String} {xs : List String} (h : xs.Nodup) :
    (placeBefore k a xs).Nodup := by
  obtain ⟨A, B, h1, h2⟩ := placeBefore_shape k a xs
  rw [h1, List.perm_middle.nodup_iff, List.nodup_cons, h2]
  exact ⟨by simp, h.sublist (List.filter_sublist)⟩

theorem mem_placeBefore {k x : String} {a : Option String} {xs : List String} :
    x ∈ placeBefore k a xs → x = k ∨ x ∈ xs := by
  obtain ⟨A, B, h1, h2⟩ := placeBefore_shape k a xs
  rw [h1, List.perm_middle.mem_iff, List.mem_cons, h2, List.mem_filter]
  rintro (h | ⟨h, -⟩)
  · exact .inl h
  · exact .inr h

/-! ## Right-to-left placement -/

/-- One step of `applyList`: visit new position `i`; if it moves, insert `new[i]` before
`new[i+1]` (or append it when `i` is last). -/
def step (new : Array String) (mv : Nat → Bool) (i : Nat) (xs : List String) : List String :=
  if mv i then placeBefore new[i]! (if i + 1 < new.size then some new[i + 1]! else none) xs else xs

/-- The keys at the stable (non-moving) positions below `s`, in order. -/
def stableBelow (new : Array String) (mv : Nat → Bool) (s : Nat) : List String :=
  ((List.range s).filter (fun i => !mv i)).map (new[·]!)

/-- The invariant of the right-to-left pass once positions `s … n-1` are done: the list is
`P ++ Q` where `P` holds no finished key, `Q` holds the finished keys `new[s:]` in order (with
possibly some not-yet-visited keys between them), and every stable key below `s` is still in `P`
in the order `new` wants. -/
structure Inv (new : Array String) (mv : Nat → Bool) (s : Nat) (ys : List String) : Prop where
  nodup : ys.Nodup
  sub : ∀ x ∈ ys, x ∈ new.toList
  split : ∃ P Q, ys = P ++ Q ∧ (∀ x ∈ P, x ∉ new.toList.drop s) ∧
    Q.filter (· ∈ new.toList.drop s) = new.toList.drop s ∧ stableBelow new mv s <+ P

theorem stableBelow_succ (new : Array String) (mv : Nat → Bool) (s : Nat) :
    stableBelow new mv (s + 1) = stableBelow new mv s ++ (if mv s then [] else [new[s]!]) := by
  simp only [stableBelow, List.range_succ, List.filter_append]
  by_cases h : mv s <;> simp [h]

theorem mem_stableBelow {new : Array String} {mv : Nat → Bool} {s : Nat} {x : String} :
    x ∈ stableBelow new mv s → ∃ i, i < s ∧ mv i = false ∧ x = new[i]! := by
  simp only [stableBelow, List.mem_map, List.mem_filter, List.mem_range]
  rintro ⟨i, ⟨hi, hm⟩, rfl⟩
  exact ⟨i, hi, by simpa using hm, rfl⟩

/-- A moving step, abstractly: `k` lands right before the first finished key. -/
theorem split_move {k : String} {D P Q SP : List String} (hnd : (P ++ Q).Nodup)
    (hP : ∀ x ∈ P, x ∉ D) (hQ : Q.filter (· ∈ D) = D) (hkD : k ∉ D) (hSP : SP <+ P)
    (hkSP : k ∉ SP) :
    ∃ P' Q', placeBefore k D.head? (P ++ Q) = P' ++ Q' ∧ (∀ x ∈ P', x ∉ k :: D) ∧
      Q'.filter (· ∈ k :: D) = k :: D ∧ SP <+ P' := by
  have hSPf : SP <+ P.filter (· != k) := by
    have := hSP.filter (· != k)
    rwa [List.filter_eq_self.2 (fun x hx => by
      simpa using (fun h : x = k => hkSP (h ▸ hx)))] at this
  cases D with
  | nil =>
    refine ⟨(P ++ Q).filter (· != k), [k], placeBefore_none .., ?_, by simp, ?_⟩
    · intro x hx
      simp only [List.mem_filter, bne_iff_ne, ne_eq] at hx
      simpa using hx.2
    · exact hSPf.trans (by simp [List.filter_append])
  | cons a D =>
    obtain ⟨Q1, Q2, rfl, hQ1, -, hQ2⟩ := List.filter_eq_cons_iff.1 hQ
    have hak : a ≠ k := fun h => hkD (h ▸ List.mem_cons_self ..)
    have hfilt : (P ++ (Q1 ++ a :: Q2)).filter (· != k) =
        (P.filter (· != k) ++ Q1.filter (· != k)) ++ a :: Q2.filter (· != k) := by
      simp [List.filter_append, hak]
    have haA : a ∉ P.filter (· != k) ++ Q1.filter (· != k) := by
      simp only [List.mem_append, List.mem_filter, not_or]
      exact ⟨fun h => hP a h.1 (List.mem_cons_self ..), fun h => hQ1 a h.1 (by simp)⟩
    refine ⟨P.filter (· != k) ++ Q1.filter (· != k), k :: a :: Q2.filter (· != k),
      placeBefore_some hfilt haA, ?_, ?_, hSPf.trans (List.sublist_append_left ..)⟩
    · intro x hx hx'
      simp only [List.mem_append, List.mem_filter, bne_iff_ne, ne_eq] at hx
      rcases List.mem_cons.1 hx' with rfl | hxD
      · rcases hx with h | h <;> exact h.2 rfl
      · rcases hx with h | h
        · exact hP x h.1 hxD
        · exact hQ1 x h.1 (by simpa using hxD)
    · have hkD' : k ∉ a :: D := hkD
      rw [List.filter_cons_of_pos (by simp), List.filter_cons_of_pos (by simp), List.filter_filter]
      congr 2
      refine Eq.trans (List.filter_congr fun x _ => ?_) hQ2
      by_cases hxk : x = k
      · subst hxk; simp [hkD']
      · simp [hxk]

/-- A stable step, abstractly: `k` is already right before the finished keys. -/
theorem split_stable {k : String} {D P Q SP : List String} (hnd : (P ++ Q).Nodup)
    (hP : ∀ x ∈ P, x ∉ D) (hQ : Q.filter (· ∈ D) = D) (hSP : SP ++ [k] <+ P) :
    ∃ P' Q', P ++ Q = P' ++ Q' ∧ (∀ x ∈ P', x ∉ k :: D) ∧
      Q'.filter (· ∈ k :: D) = k :: D ∧ SP <+ P' := by
  obtain ⟨r₁, r₂, rfl, h1, h2⟩ := List.append_sublist_iff.1 hSP
  obtain ⟨A, B, rfl⟩ := List.append_of_mem (List.singleton_sublist.1 h2)
  have hnd' : (r₁ ++ A ++ k :: (B ++ Q)).Nodup := by simpa [List.append_assoc] using hnd
  have hk1 : k ∉ r₁ ++ A := fun h =>
    (List.nodup_append.1 hnd').2.2 k h k (List.mem_cons_self ..) rfl
  have hk2 : k ∉ B ++ Q := (List.nodup_cons.1 (List.nodup_append.1 hnd').2.1).1
  refine ⟨r₁ ++ A, k :: (B ++ Q), by simp, ?_, ?_, h1.trans (List.sublist_append_left ..)⟩
  · intro x hx hx'
    rcases List.mem_cons.1 hx' with rfl | hxD
    · exact hk1 hx
    · exact hP x (by
        simp only [List.mem_append] at hx
        rcases hx with h | h <;> simp [h]) hxD
  · rw [List.filter_cons_of_pos (by simp), List.filter_append]
    have hB : B.filter (· ∈ k :: D) = [] := by
      rw [List.filter_eq_nil_iff]
      intro x hx
      have hxk : x ≠ k := fun h => hk2 (h ▸ List.mem_append_left _ hx)
      have hxD : x ∉ D := hP x (by simp [hx])
      simp [hxk, hxD]
    have hQ' : Q.filter (· ∈ k :: D) = Q.filter (· ∈ D) := by
      apply List.filter_congr
      intro x hx
      have hxk : x ≠ k := fun h => hk2 (h ▸ List.mem_append_right _ hx)
      simp [hxk]
    rw [hB, hQ', hQ]
    rfl

theorem inv_step {new : Array String} {mv : Nat → Bool} {s : Nat} {ys : List String}
    (hN : new.toList.Nodup) (hs : s < new.size) (h : Inv new mv (s + 1) ys) :
    Inv new mv s (step new mv s ys) := by
  obtain ⟨hnd, hsub, P, Q, rfl, hP, hQ, hSP⟩ := h
  have hk! : new[s]! = new[s] := getElem!_pos new s hs
  have hD : new.toList.drop s = new[s] :: new.toList.drop (s + 1) := by
    rw [List.drop_eq_getElem_cons (by simpa using hs)]; simp
  have hkD : new[s] ∉ new.toList.drop (s + 1) := by
    have := hN.sublist (List.drop_sublist s _)
    rw [hD] at this
    exact (List.nodup_cons.1 this).1
  have hkN : new[s] ∈ new.toList := Array.getElem_mem_toList hs
  have hkSP : new[s] ∉ stableBelow new mv s := by
    intro hm
    obtain ⟨i, hi, -, he⟩ := mem_stableBelow hm
    rw [getElem!_pos new i (by omega)] at he
    have := (hN.getElem_inj (i := s) (j := i) (hi := by simpa using hs)
      (hj := by simp; omega)).1 (by simpa using he)
    omega
  have hanchor : (if s + 1 < new.size then some new[s + 1]! else none) =
      (new.toList.drop (s + 1)).head? := by
    split
    · rename_i h
      rw [List.drop_eq_getElem_cons (by simpa using h)]
      simp [getElem!_pos new (s + 1) h]
    · rename_i h
      rw [List.drop_of_length_le (by simp; omega)]
      rfl
  unfold step
  rw [hk!, hanchor]
  refine ⟨?_, ?_, ?_⟩
  · split
    · exact placeBefore_nodup hnd
    · exact hnd
  · split
    · intro x hx
      rcases mem_placeBefore hx with rfl | h
      · exact hkN
      · exact hsub x h
    · exact hsub
  · rw [hD]
    rw [stableBelow_succ, hk!] at hSP
    by_cases hm : mv s
    · simp only [hm, ite_true, List.append_nil] at hSP ⊢
      exact split_move hnd hP hQ hkD hSP hkSP
    · simp only [hm, Bool.false_eq_true, ite_false] at hSP ⊢
      exact split_stable hnd hP hQ hSP

theorem inv_start {new : Array String} {mv : Nat → Bool} {xs₀ : List String} (hxs : xs₀.Nodup)
    (hsub : ∀ x ∈ xs₀, x ∈ new.toList) (hst : stableBelow new mv new.size <+ xs₀) :
    Inv new mv new.size xs₀ := by
  refine ⟨hxs, hsub, xs₀, [], by simp, ?_, ?_, hst⟩
  · simp [List.drop_of_length_le]
  · simp [List.drop_of_length_le]

theorem inv_finish {new : Array String} {mv : Nat → Bool} {ys : List String}
    (h : Inv new mv 0 ys) : ys = new.toList := by
  obtain ⟨-, hsub, P, Q, rfl, hP, hQ, -⟩ := h
  simp only [List.drop_zero] at hP hQ
  have hP0 : P = [] := List.eq_nil_iff_forall_not_mem.2 fun x hx =>
    hP x hx (hsub x (List.mem_append_left _ hx))
  subst hP0
  rw [List.nil_append, ← hQ, List.filter_eq_self.2]
  intro x hx
  simpa using hsub x (by simpa using hx)

/-- **Right-to-left placement is correct.** Whatever the move flags, if the start list has no
duplicates and only keys of `new`, and the keys at stable positions appear in it in the order
`new` wants, then visiting `n-1 … 0` and inserting every moved key before its successor
produces exactly `new`. -/
theorem place_correct (new : Array String) (mv : Nat → Bool) (xs₀ : List String)
    (hN : new.toList.Nodup) (hxs : xs₀.Nodup) (hsub : ∀ x ∈ xs₀, x ∈ new.toList)
    (hst : stableBelow new mv new.size <+ xs₀) :
    (List.range new.size).foldr (step new mv) xs₀ = new.toList := by
  have key : ∀ t s, s + t = new.size →
      Inv new mv s ((List.range' s t).foldr (step new mv) xs₀) := by
    intro t
    induction t with
    | zero => intro s hs; simp only [Nat.add_zero] at hs; subst hs; exact inv_start hxs hsub hst
    | succ t ih =>
      intro s hs
      rw [List.range'_succ, List.foldr_cons]
      exact inv_step hN (by omega) (ih (s + 1) (by omega))
  apply inv_finish
  rw [List.range_eq_range']
  exact key new.size 0 (by simp)


/-! ## LIS: the result is a strictly increasing subsequence -/

theorem lisSearch_spec (xs tails : Array Nat) (x lo hi : Nat) (h : lo ≤ hi) :
    lo ≤ lisSearch xs tails x lo hi ∧ lisSearch xs tails x lo hi ≤ hi ∧
      (lisSearch xs tails x lo hi = lo ∨ xs[tails[lisSearch xs tails x lo hi - 1]!]! < x) := by
  fun_induction lisSearch xs tails x lo hi with
  | case1 lo hi hlt mid hv ih =>
    have hm : mid = (lo + hi) / 2 := rfl
    obtain ⟨h1, h2, h3⟩ := ih (by omega)
    refine ⟨by omega, h2, .inr ?_⟩
    rcases h3 with h3 | h3
    · rw [h3, Nat.add_sub_cancel]; exact hv
    · exact h3
  | case2 lo hi hlt mid hv ih =>
    have hm : mid = (lo + hi) / 2 := rfl
    obtain ⟨h1, h2, h3⟩ := ih (by omega)
    exact ⟨h1, by omega, h3⟩
  | case3 lo hi hlt => simp [h]

theorem getElem!_setIfInBounds' {α : Type} [Inhabited α] {xs : Array α} {i j : Nat} {v : α} :
    (xs.setIfInBounds i v)[j]! = if i = j ∧ j < xs.size then v else xs[j]! := by
  by_cases hj : j < xs.size
  · rw [getElem!_pos (xs.setIfInBounds i v) j (by simpa using hj), Array.getElem_setIfInBounds hj,
      getElem!_pos xs j hj]
    by_cases hij : i = j <;> simp [hij, hj]
  · rw [getElem!_neg (xs.setIfInBounds i v) j (by simpa using hj), getElem!_neg xs j hj]
    simp [hj]

/-- `a` may come right before `b` in an increasing subsequence of `xs`. -/
def IncRel (xs : Array Nat) (a b : Nat) : Prop := a < b ∧ xs[a]! < xs[b]!

theorem IncRel.trans {xs : Array Nat} {a b c : Nat} (h1 : IncRel xs a b) (h2 : IncRel xs b c) :
    IncRel xs a c := ⟨Nat.lt_trans h1.1 h2.1, Nat.lt_trans h1.2 h2.2⟩

/-- What patience sorting keeps true (all that validity needs). -/
structure ScanOk (xs : Array Nat) (i : Nat) (tails : Array Nat) (prev : Array (Option Nat)) :
    Prop where
  size : prev.size = xs.size
  tails_lt : ∀ t ∈ tails, t < i
  prev_ok : ∀ j p, prev[j]! = some p → IncRel xs p j ∧ j < xs.size

/-- One patience-sorting step, as `lisScan` takes it. -/
def scanTails (xs tails : Array Nat) (i : Nat) : Array Nat :=
  if lisSearch xs tails xs[i]! 0 tails.size < tails.size then
    tails.set! (lisSearch xs tails xs[i]! 0 tails.size) i
  else tails.push i
def scanPrev (xs tails : Array Nat) (prev : Array (Option Nat)) (i : Nat) : Array (Option Nat) :=
  if lisSearch xs tails xs[i]! 0 tails.size = 0 then prev
  else prev.set! i (some tails[lisSearch xs tails xs[i]! 0 tails.size - 1]!)

theorem scanOk_step {xs : Array Nat} {i : Nat} {tails : Array Nat} {prev : Array (Option Nat)}
    (hlt : i < xs.size) (h : ScanOk xs i tails prev) :
    ScanOk xs (i + 1) (scanTails xs tails i) (scanPrev xs tails prev i) := by
  obtain ⟨-, hs2, hs3⟩ := lisSearch_spec xs tails xs[i]! 0 tails.size (Nat.zero_le _)
  generalize hlo : lisSearch xs tails xs[i]! 0 tails.size = lo at hs2 hs3
  simp only [scanTails, scanPrev, hlo]
  refine ⟨?_, ?_, ?_⟩
  · split <;> simp [h.size]
  · intro t ht
    split at ht
    · rcases Array.mem_or_eq_of_mem_setIfInBounds ht with ht | rfl
      · exact Nat.lt_succ_of_lt (h.tails_lt t ht)
      · omega
    · rcases Array.mem_push.1 ht with ht | rfl
      · exact Nat.lt_succ_of_lt (h.tails_lt t ht)
      · omega
  · intro j p hp
    split at hp
    · exact h.prev_ok j p hp
    · rename_i hlo0
      rw [Array.set!_eq_setIfInBounds, getElem!_setIfInBounds'] at hp
      split at hp
      · rename_i hij
        obtain ⟨rfl, hjs⟩ := hij
        cases hp
        have hmem : tails[lo - 1]! ∈ tails := by
          rw [getElem!_pos tails (lo - 1) (by omega)]; exact Array.getElem_mem (by omega)
        refine ⟨⟨h.tails_lt _ hmem, ?_⟩, by rwa [h.size] at hjs⟩
        rcases hs3 with hs3 | hs3
        · omega
        · exact hs3
      · exact h.prev_ok j p hp

/-- Run an invariant through the whole scan. -/
theorem lisScan_induct (xs : Array Nat) (Inv : Nat → Array Nat → Array (Option Nat) → Prop)
    (step : ∀ i tails prev, i < xs.size → Inv i tails prev →
      Inv (i + 1) (scanTails xs tails i) (scanPrev xs tails prev i)) :
    ∀ i tails prev, i ≤ xs.size → Inv i tails prev →
      Inv xs.size (lisScan xs i tails prev).1 (lisScan xs i tails prev).2 := by
  intro i tails prev hi h
  fun_induction lisScan xs i tails prev with
  | case1 i tails prev hlt x lo prev' tails' ih =>
    have e1 : tails' = scanTails xs tails i := by
      simp [tails', lo, x, scanTails, getElem!_pos xs i hlt]
    have e2 : prev' = scanPrev xs tails prev i := by
      simp [prev', lo, x, scanPrev, getElem!_pos xs i hlt]
    rw [e1, e2] at ih ⊢
    exact ih (by omega) (step i tails prev hlt h)
  | case2 i tails prev hge =>
    have : i = xs.size := by omega
    subst this
    exact h

theorem lisScan_ok (xs : Array Nat) (i : Nat) (tails : Array Nat) (prev : Array (Option Nat))
    (hi : i ≤ xs.size) (h : ScanOk xs i tails prev) :
    ScanOk xs xs.size (lisScan xs i tails prev).1 (lisScan xs i tails prev).2 :=
  lisScan_induct xs (ScanOk xs) (fun _ _ _ hlt h => scanOk_step hlt h) i tails prev hi h

/-- Walking back along `prev` yields an increasing subsequence. -/
theorem lisWalk_ok (xs : Array Nat) (prev : Array (Option Nat))
    (hprev : ∀ j p, prev[j]! = some p → IncRel xs p j ∧ j < xs.size) :
    ∀ fuel cur acc, (∀ j, cur = some j → j < xs.size ∧ ∀ b ∈ acc.head?, IncRel xs j b) →
      acc.Pairwise (IncRel xs) → (∀ b ∈ acc, b < xs.size) →
      (lisWalk prev fuel cur acc).Pairwise (IncRel xs) ∧
        ∀ b ∈ lisWalk prev fuel cur acc, b < xs.size := by
  intro fuel
  induction fuel with
  | zero => intro cur acc _ h1 h2; exact ⟨by simpa [lisWalk] using h1, by simpa [lisWalk] using h2⟩
  | succ fuel ih =>
    intro cur acc hcur h1 h2
    cases cur with
    | none => exact ⟨by simpa [lisWalk] using h1, by simpa [lisWalk] using h2⟩
    | some j =>
      simp only [lisWalk]
      obtain ⟨hj, hjacc⟩ := hcur j rfl
      apply ih
      · intro p hp
        obtain ⟨hr, -⟩ := hprev j p hp
        exact ⟨Nat.lt_trans hr.1 hj, by simpa using hr⟩
      · rw [List.pairwise_cons]
        refine ⟨?_, h1⟩
        intro b hb
        cases acc with
        | nil => simp at hb
        | cons a acc =>
          have hja := hjacc a rfl
          rcases List.mem_cons.1 hb with rfl | hb
          · exact hja
          · exact hja.trans (List.rel_of_pairwise_cons h1 hb)
      · intro b hb
        rcases List.mem_cons.1 hb with rfl | hb
        · exact hj
        · exact h2 b hb

/-- **`lis` is valid**: its indices increase, so do the values at them, and all are in range. -/
theorem lis_valid (xs : Array Nat) :
    (lis xs).toList.Pairwise (IncRel xs) ∧ ∀ k ∈ (lis xs).toList, k < xs.size := by
  have hscan := lisScan_ok xs 0 #[] (Array.replicate xs.size none) (Nat.zero_le _)
    ⟨by simp, by simp, fun j p hp => by
      by_cases hj : j < xs.size
      · simp [getElem!_pos (Array.replicate xs.size (none : Option Nat)) j (by simpa using hj)] at hp
      · simp [getElem!_neg (Array.replicate xs.size (none : Option Nat)) j (by simpa using hj)] at hp⟩
  simp only [lis]
  generalize lisScan xs 0 #[] (Array.replicate xs.size none) = r at hscan ⊢
  obtain ⟨tails, prev⟩ := r
  refine lisWalk_ok xs prev hscan.prev_ok _ _ _ ?_ List.Pairwise.nil (by simp)
  intro j hj
  exact ⟨hscan.tails_lt j (Array.mem_of_back? hj), by simp⟩

/-! ## List facts -/

theorem sublist_range' {l : List Nat} {s n : Nat} (hl : l.Pairwise (· < ·))
    (hb : ∀ x ∈ l, s ≤ x ∧ x < s + n) : l <+ List.range' s n := by
  induction n generalizing s l with
  | zero =>
    cases l with
    | nil => exact List.nil_sublist _
    | cons x l => have := hb x (List.mem_cons_self ..); omega
  | succ n ih =>
    rw [List.range'_succ]
    cases l with
    | nil => exact List.nil_sublist _
    | cons x l =>
      rw [List.pairwise_cons] at hl
      by_cases hx : x = s
      · subst hx
        refine (ih hl.2 fun y hy => ?_).cons_cons x
        have := hb y (List.mem_cons_of_mem _ hy); have := hl.1 y hy; omega
      · refine (ih (List.pairwise_cons.2 hl) fun y hy => ?_).cons s
        rcases List.mem_cons.1 hy with rfl | hy
        · have := hb y (List.mem_cons_self ..); omega
        · have := hb y (List.mem_cons_of_mem _ hy); have := hl.1 y hy
          have := hb x (List.mem_cons_self ..); omega

/-- A strictly increasing list of indices, all in `filter p (range m)`, is a sublist of it. -/
theorem sublist_filter_range {l : List Nat} {m : Nat} {p : Nat → Bool}
    (hl : l.Pairwise (· < ·)) (hb : ∀ x ∈ l, x < m ∧ p x) :
    l <+ (List.range m).filter p := by
  have h1 : l <+ List.range m := by
    rw [List.range_eq_range']
    exact sublist_range' hl fun x hx => ⟨Nat.zero_le _, by simpa using (hb x hx).1⟩
  have h2 := h1.filter p
  rwa [List.filter_eq_self.2 fun x hx => (hb x hx).2] at h2

theorem Pairwise.rel_or_rel {α : Type} {R : α → α → Prop} {l : List α} (h : l.Pairwise R)
    {a b : α} (ha : a ∈ l) (hb : b ∈ l) (hab : a ≠ b) : R a b ∨ R b a := by
  induction l with
  | nil => simp at ha
  | cons x l ih =>
    rw [List.pairwise_cons] at h
    rcases List.mem_cons.1 ha with rfl | ha'
    · rcases List.mem_cons.1 hb with rfl | hb'
      · exact absurd rfl hab
      · exact .inl (h.1 b hb')
    · rcases List.mem_cons.1 hb with rfl | hb'
      · exact .inr (h.1 a ha')
      · exact ih h.2 ha' hb'

/-! ## LIS: the result is a *longest* strictly increasing subsequence -/

theorem lisSearch_exact (xs tails : Array Nat) (x : Nat)
    (hs : ∀ k k', k < k' → k' < tails.size → xs[tails[k]!]! < xs[tails[k']!]!) (lo hi : Nat)
    (hlh : lo ≤ hi) (hhi : hi ≤ tails.size) (hlo : ∀ k < lo, xs[tails[k]!]! < x)
    (hhi' : ∀ k, hi ≤ k → k < tails.size → x ≤ xs[tails[k]!]!) :
    lisSearch xs tails x lo hi ≤ tails.size ∧
      (∀ k < lisSearch xs tails x lo hi, xs[tails[k]!]! < x) ∧
      (∀ k, lisSearch xs tails x lo hi ≤ k → k < tails.size → x ≤ xs[tails[k]!]!) := by
  fun_induction lisSearch xs tails x lo hi with
  | case1 lo hi hlt mid hv ih =>
    have hm : mid = (lo + hi) / 2 := rfl
    refine ih (by omega) hhi (fun k hk => ?_) hhi'
    by_cases hkl : k < lo
    · exact hlo k hkl
    · rcases Nat.lt_or_eq_of_le (Nat.le_of_lt_succ hk) with hk' | rfl
      · exact Nat.lt_trans (hs k mid hk' (by omega)) hv
      · exact hv
  | case2 lo hi hlt mid hv ih =>
    have hm : mid = (lo + hi) / 2 := rfl
    refine ih (by omega) (by omega) hlo (fun k hk hkt => ?_)
    rcases Nat.lt_or_eq_of_le hk with hk' | rfl
    · exact Nat.le_trans (Nat.le_of_not_lt hv) (Nat.le_of_lt (hs mid k hk' hkt))
    · exact Nat.le_of_not_lt hv
  | case3 lo hi hlt =>
    have : lo = hi := by omega
    subst this
    exact ⟨hhi, hlo, hhi'⟩

/-- `j` starts a chain of `d` indices along `prev`. -/
def Reach (prev : Array (Option Nat)) : Nat → Nat → Prop
  | _, 0 => True
  | _, 1 => True
  | j, d + 2 => ∃ p, prev[j]! = some p ∧ p < j ∧ Reach prev p (d + 1)

theorem lisWalk_length {prev : Array (Option Nat)} :
    ∀ d j acc, Reach prev j (d + 1) →
      (lisWalk prev (d + 1) (some j) acc).length = d + 1 + acc.length
  | 0, j, acc, _ => by simp only [lisWalk]; simp; omega
  | d + 1, j, acc, h => by
    obtain ⟨p, hp, -, hr⟩ := h
    rw [lisWalk.eq_3, hp, lisWalk_length d p (j :: acc) hr, List.length_cons]
    omega

theorem Reach.frame {prev prev' : Array (Option Nat)} :
    ∀ d j, Reach prev j d → (∀ j' ≤ j, prev'[j']! = prev[j']!) → Reach prev' j d
  | 0, _, _, _ => trivial
  | 1, _, _, _ => trivial
  | d + 2, j, ⟨p, hp, hpj, hr⟩, hf =>
    ⟨p, by rw [hf j (Nat.le_refl _)]; exact hp, hpj,
      Reach.frame (d + 1) p hr fun j' hj' => hf j' (by omega)⟩

theorem sublist_singleton' {α : Type} {l : List α} {a : α} (h : l <+ [a]) :
    l = [] ∨ l = [a] := by
  cases h with
  | cons _ h => exact .inl (List.sublist_nil.1 h)
  | cons_cons _ h => exact .inr (by rw [List.sublist_nil.1 h])

/-- What patience sorting keeps true (all that optimality needs). -/
structure ScanBest (xs : Array Nat) (i : Nat) (tails : Array Nat) (prev : Array (Option Nat)) :
    Prop where
  ok : ScanOk xs i tails prev
  sorted : ∀ k k', k < k' → k' < tails.size → xs[tails[k]!]! < xs[tails[k']!]!
  reach : ∀ k < tails.size, Reach prev tails[k]! (k + 1)
  best : ∀ l v, l ++ [v] <+ xs.toList.take i → (l ++ [v]).Pairwise (· < ·) →
    l.length < tails.size ∧ xs[tails[l.length]!]! ≤ v

theorem scanTails_spec {xs tails : Array Nat} {i : Nat} :
    (scanTails xs tails i).size = (if lisSearch xs tails xs[i]! 0 tails.size < tails.size then
      tails.size else tails.size + 1) ∧
    ∀ k < (scanTails xs tails i).size, (scanTails xs tails i)[k]! =
      if k = lisSearch xs tails xs[i]! 0 tails.size then i else tails[k]! := by
  have hle := (lisSearch_spec xs tails xs[i]! 0 tails.size (Nat.zero_le _)).2.1
  simp only [scanTails]
  generalize lisSearch xs tails xs[i]! 0 tails.size = lo at hle ⊢
  split
  · refine ⟨by simp, fun k hk => ?_⟩
    simp only [Array.set!_eq_setIfInBounds, Array.size_setIfInBounds] at hk ⊢
    rw [getElem!_setIfInBounds']
    by_cases hk' : k = lo
    · subst hk'; simp [hk]
    · simp [hk', Ne.symm hk']
  · rename_i hlt
    refine ⟨by simp, fun k hk => ?_⟩
    rw [getElem!_pos _ k hk, Array.getElem_push]
    by_cases hk' : k < tails.size
    · rw [dite_eq_left hk', getElem!_pos tails k hk', ite_eq_right (by omega)]
    · rw [dite_eq_right hk', ite_eq_left (by simp at hk; omega)]

theorem scanBest_step {xs : Array Nat} {i : Nat} {tails : Array Nat} {prev : Array (Option Nat)}
    (hlt : i < xs.size) (h : ScanBest xs i tails prev) :
    ScanBest xs (i + 1) (scanTails xs tails i) (scanPrev xs tails prev i) := by
  obtain ⟨hloL, hbelow, habove⟩ := lisSearch_exact xs tails xs[i]! h.sorted 0 tails.size
    (Nat.zero_le _) (Nat.le_refl _) (fun k hk => absurd hk (Nat.not_lt_zero k))
    (fun k hk hkt => absurd hkt (Nat.not_lt.2 hk))
  obtain ⟨hTs, hTg⟩ := scanTails_spec (xs := xs) (tails := tails) (i := i)
  have hok := scanOk_step hlt h.ok
  have hPdef : scanPrev xs tails prev i = if lisSearch xs tails xs[i]! 0 tails.size = 0 then prev
      else prev.set! i (some tails[lisSearch xs tails xs[i]! 0 tails.size - 1]!) := rfl
  generalize scanTails xs tails i = T at hTs hTg hok ⊢
  generalize scanPrev xs tails prev i = P at hPdef hok ⊢
  generalize lisSearch xs tails xs[i]! 0 tails.size = lo at hloL hbelow habove hTs hTg hPdef
  have hTsz1 : lo < T.size := by split at hTs <;> omega
  have hTsz2 : tails.size ≤ T.size := by split at hTs <;> omega
  -- the predecessor array only changes at `i`
  have hframe : ∀ j' < i, P[j']! = prev[j']! := by
    intro j' hj'
    rw [hPdef]
    split
    · rfl
    · rw [Array.set!_eq_setIfInBounds, getElem!_setIfInBounds', ite_eq_right (by omega)]
  refine ⟨hok, ?_, ?_, ?_⟩
  · -- sorted
    intro k k' hkk hk'
    rw [hTg k (by omega), hTg k' hk']
    by_cases h1 : k' = lo
    · rw [ite_eq_left h1, ite_eq_right (by omega)]
      exact hbelow k (by omega)
    · have hk'L : k' < tails.size := by split at hTs <;> omega
      rw [ite_eq_right h1]
      by_cases h2 : k = lo
      · rw [ite_eq_left h2]
        subst h2
        exact Nat.lt_of_le_of_lt (habove k (Nat.le_refl _) (by omega)) (h.sorted k k' hkk hk'L)
      · rw [ite_eq_right h2]
        exact h.sorted k k' hkk hk'L
  · -- reach
    intro k hk
    rw [hTg k hk]
    split
    · rename_i hklo
      subst hklo
      cases k with
      | zero => trivial
      | succ k =>
        have hkL : k < tails.size := by omega
        have hmem : tails[k]! ∈ tails := by
          rw [getElem!_pos tails k hkL]; exact Array.getElem_mem hkL
        refine ⟨tails[k]!, ?_, h.ok.tails_lt _ hmem, ?_⟩
        · rw [hPdef, ite_eq_right (by omega), Array.set!_eq_setIfInBounds, getElem!_setIfInBounds',
            ite_eq_left ⟨rfl, by rw [h.ok.size]; exact hlt⟩]
          rfl
        · exact Reach.frame _ _ (h.reach k hkL) fun j' hj' =>
            hframe j' (Nat.lt_of_le_of_lt hj' (h.ok.tails_lt _ hmem))
    · rename_i hklo
      have hkL : k < tails.size := by split at hTs <;> omega
      have hmem : tails[k]! ∈ tails := by
        rw [getElem!_pos tails k hkL]; exact Array.getElem_mem hkL
      exact Reach.frame _ _ (h.reach k hkL) fun j' hj' =>
        hframe j' (Nat.lt_of_le_of_lt hj' (h.ok.tails_lt _ hmem))
  · -- best
    intro l v hl hinc
    have htake : xs.toList.take (i + 1) = xs.toList.take i ++ [xs[i]!] := by
      rw [List.take_add_one, getElem!_pos xs i hlt]; simp [hlt]
    rw [htake] at hl
    -- the value stored at position `k` never grows
    have hdown : ∀ k < tails.size, xs[T[k]!]! ≤ xs[tails[k]!]! := by
      intro k hk
      rw [hTg k (by omega)]
      split
      · rename_i hklo; subst hklo; exact habove k (Nat.le_refl _) hk
      · exact Nat.le_refl _
    obtain ⟨l₁, l₂, he, h1, h2⟩ := List.sublist_append_iff.1 hl
    rcases sublist_singleton' h2 with rfl | rfl
    · rw [List.append_nil] at he
      subst he
      obtain ⟨hlen, hv⟩ := h.best l v h1 hinc
      exact ⟨by omega, Nat.le_trans (hdown _ hlen) hv⟩
    · obtain ⟨rfl, rfl⟩ := List.append_singleton_inj.1 he
      rcases List.eq_nil_or_concat l with rfl | ⟨l', u, rfl⟩
      · refine ⟨by simp; omega, ?_⟩
        simp only [List.length_nil]
        rw [hTg 0 (by omega)]
        split
        · exact Nat.le_refl _
        · exact Nat.le_of_lt (hbelow 0 (by omega))
      · simp only [List.concat_eq_append] at h1 hinc ⊢
        rw [List.pairwise_append] at hinc
        have hux : u < xs[i]! := hinc.2.2 u (by simp) xs[i]! (by simp)
        obtain ⟨hlen, hv⟩ := h.best l' u h1 hinc.1
        have hlo' : l'.length < lo := by
          refine Nat.lt_of_not_le fun hge => ?_
          have := habove l'.length hge hlen
          omega
        simp only [List.length_append, List.length_singleton]
        refine ⟨by omega, ?_⟩
        rw [hTg _ (by omega)]
        split
        · exact Nat.le_refl _
        · exact Nat.le_of_lt (hbelow _ (by omega))

theorem lisScan_best (xs : Array Nat) :
    ScanBest xs xs.size (lisScan xs 0 #[] (Array.replicate xs.size none)).1
      (lisScan xs 0 #[] (Array.replicate xs.size none)).2 := by
  refine lisScan_induct xs (ScanBest xs) (fun _ _ _ hlt h => scanBest_step hlt h) 0 _ _
    (Nat.zero_le _) ⟨⟨by simp, by simp, fun j p hp => ?_⟩, by simp, by simp, ?_⟩
  · by_cases hj : j < xs.size
    · simp [getElem!_pos (Array.replicate xs.size (none : Option Nat)) j (by simpa using hj)] at hp
    · simp [getElem!_neg (Array.replicate xs.size (none : Option Nat)) j (by simpa using hj)] at hp
  · intro l v hl _
    simp at hl

/-- The scan's `tails.size` is the length of `lis`. -/
theorem lis_size (xs : Array Nat) :
    (lis xs).size = (lisScan xs 0 #[] (Array.replicate xs.size none)).1.size := by
  have hb := lisScan_best xs
  simp only [lis]
  generalize lisScan xs 0 #[] (Array.replicate xs.size none) = r at hb ⊢
  obtain ⟨tails, prev⟩ := r
  dsimp only at hb ⊢
  simp only [List.size_toArray]
  cases hL : tails.size with
  | zero =>
    have : tails = #[] := Array.eq_empty_of_size_eq_zero hL
    subst this; rfl
  | succ d =>
    have hback : tails.back? = some tails[d]! := by
      rw [Array.back?_eq_getElem?, hL, Nat.add_sub_cancel, getElem!_pos tails d (by omega)]
      exact getElem?_pos tails d (by omega)
    rw [hback, lisWalk_length d _ [] (hb.reach d (by omega))]
    rfl

/-- **`lis` is longest**: no strictly increasing subsequence of `xs` is longer. -/
theorem lis_longest (xs : Array Nat) (l : List Nat) (hl : l <+ xs.toList)
    (hinc : l.Pairwise (· < ·)) : l.length ≤ (lis xs).size := by
  rw [lis_size]
  rcases List.eq_nil_or_concat l with rfl | ⟨l', v, rfl⟩
  · exact Nat.zero_le _
  · simp only [List.concat_eq_append] at hl hinc ⊢
    have hl' : l' ++ [v] <+ xs.toList.take xs.size := by
      rw [List.take_of_length_le (by simp)]; exact hl
    have := ((lisScan_best xs).best l' v hl' hinc).1
    simp only [List.length_append, List.length_singleton]
    omega

theorem map_getElem!_range {α : Type} [Inhabited α] (xs : Array α) :
    (List.range xs.size).map (xs[·]!) = xs.toList := by
  apply List.ext_getElem (by simp)
  intro k h1 h2
  simp only [List.getElem_map, List.getElem_range]
  rw [getElem!_pos xs k (by simpa using h2)]
  simp

/-- **`lis` is a longest strictly increasing subsequence** of `xs`: the values at its indices
are a strictly increasing sublist of `xs`, and no strictly increasing sublist is longer. -/
theorem lis_spec (xs : Array Nat) :
    (lis xs).toList.map (xs[·]!) <+ xs.toList ∧
      ((lis xs).toList.map (xs[·]!)).Pairwise (· < ·) ∧
      ∀ l, l <+ xs.toList → l.Pairwise (· < ·) →
        l.length ≤ ((lis xs).toList.map (xs[·]!)).length := by
  obtain ⟨hv, hb⟩ := lis_valid xs
  refine ⟨?_, ?_, fun l hl hinc => ?_⟩
  · rw [← map_getElem!_range xs]
    apply List.Sublist.map
    rw [List.range_eq_range']
    exact sublist_range' (hv.imp fun h => h.1) fun x hx => ⟨Nat.zero_le _, by simpa using hb x hx⟩
  · rw [List.pairwise_map]; exact hv.imp fun h => h.2
  · simpa using lis_longest xs l hl hinc

/-! ## The key index -/

theorem fold_insert_getElem? (g : Nat → String) (e : Std.HashMap String Nat)
    (he : ∀ k : String, e[k]? = none) (k : String) (j : Nat) : ∀ (n : Nat)
    (f : (i : Nat) → i < n → Std.HashMap String Nat → Std.HashMap String Nat),
    (∀ i h m, f i h m = m.insert (g i) i) →
    (∀ i i', i < n → i' < n → g i = g i' → i = i') →
    ((Nat.fold n f e)[k]? = some j ↔ j < n ∧ g j = k) := by
  intro n
  induction n with
  | zero => intro f _ _; simp [he]
  | succ n ih =>
    intro f hf hinj
    rw [Nat.fold_succ, hf, Std.HashMap.getElem?_insert]
    have ih' := ih (fun i h => f i (by omega)) (fun i h m => hf i _ m)
      (fun i i' hi hi' => hinj i i' (by omega) (by omega))
    by_cases hgk : g n = k
    · simp only [hgk, beq_self_eq_true, ite_true, Option.some.injEq]
      constructor
      · rintro rfl; exact ⟨by omega, hgk⟩
      · rintro ⟨hj, hgj⟩; exact hinj n j (by omega) hj (hgk.trans hgj.symm)
    · have : (g n == k) = false := by simpa using hgk
      simp only [this, Bool.false_eq_true, ite_false]
      rw [ih']
      constructor
      · rintro ⟨hj, h⟩; exact ⟨by omega, h⟩
      · rintro ⟨hj, h⟩
        refine ⟨?_, h⟩
        rcases Nat.lt_succ_iff_lt_or_eq.1 hj with hj | rfl
        · exact hj
        · exact absurd h hgk

/-- The index maps each old key to its position. -/
theorem keyIndex_getElem? {old : Array String} (h : old.toList.Nodup) (k : String) (j : Nat) :
    (keyIndex old)[k]? = some j ↔ j < old.size ∧ old[j]! = k := by
  refine fold_insert_getElem? (fun i => old[i]!) _ (fun _ => Std.HashMap.getElem?_emptyWithCapacity)
    k j old.size _ (fun i hi m => by rw [getElem!_pos old i hi]) ?_
  intro i i' hi hi' he
  have := (List.Nodup.getElem!_inj (xs := old.toList) (by simpa using hi) (by simpa using hi') h).1
  exact this (by rw [Array.getElem!_toList, Array.getElem!_toList]; exact he)

theorem keyIndex_getElem?_eq_none {old : Array String} (h : old.toList.Nodup) (k : String) :
    (keyIndex old)[k]? = none ↔ k ∉ old := by
  rw [Option.eq_none_iff_forall_ne_some]
  simp only [ne_eq, keyIndex_getElem? h, not_and, Array.mem_iff_getElem]
  constructor
  · rintro hn ⟨j, hj, rfl⟩
    exact hn j hj (getElem!_pos old j hj)
  · rintro hn j hj rfl
    exact hn ⟨j, hj, (getElem!_pos old j hj).symm⟩

/-! ## Flag arrays -/

theorem foldl_markUsed (l : List (Option Nat)) (u : Array Bool) :
    (l.foldl markSome u).size = u.size ∧
    ∀ j < u.size, ((l.foldl markSome u)[j]! = true ↔
        u[j]! = true ∨ some j ∈ l) := by
  induction l generalizing u with
  | nil => simp
  | cons o l ih =>
    cases o with
    | none =>
      simp only [List.foldl_cons, markSome]
      obtain ⟨ih1, ih2⟩ := ih u
      refine ⟨ih1, fun j hj => ?_⟩
      rw [ih2 j hj]
      simp
    | some j' =>
      simp only [List.foldl_cons, markSome]
      obtain ⟨ih1, ih2⟩ := ih (u.set! j' true)
      refine ⟨by simpa using ih1, fun j hj => ?_⟩
      rw [ih2 j (by simpa using hj)]
      simp only [Array.set!_eq_setIfInBounds, getElem!_setIfInBounds', List.mem_cons,
        Option.some.injEq]
      by_cases hjj : j' = j
      · subst hjj; simp [hj]
      · simp [hjj, Ne.symm hjj]

theorem markUsed_size (n : Nat) (src : Array (Option Nat)) : (markUsed n src).size = n := by
  unfold markUsed
  rw [← Array.foldl_toList, (foldl_markUsed _ _).1, Array.size_replicate]

theorem markUsed_spec {n : Nat} {src : Array (Option Nat)} {j : Nat} (hj : j < n) :
    (markUsed n src)[j]! = true ↔ some j ∈ src := by
  unfold markUsed
  rw [← Array.foldl_toList, (foldl_markUsed _ _).2 j (by simpa using hj),
    getElem!_pos (Array.replicate n false) j (by simpa using hj)]
  simp

theorem foldl_markStable (l : List Nat) (m : Array Bool) :
    (l.foldl (fun m i => m.set! i false) m).size = m.size ∧
    ∀ i < m.size, ((l.foldl (fun m i => m.set! i false) m)[i]! = false ↔ m[i]! = false ∨ i ∈ l) := by
  induction l generalizing m with
  | nil => simp
  | cons x l ih =>
    simp only [List.foldl_cons]
    obtain ⟨ih1, ih2⟩ := ih (m.set! x false)
    refine ⟨by simpa using ih1, fun i hi => ?_⟩
    rw [ih2 i (by simpa using hi)]
    simp only [Array.set!_eq_setIfInBounds, getElem!_setIfInBounds', List.mem_cons]
    by_cases hxi : x = i
    · subst hxi; simp [hi]
    · simp [hxi, Ne.symm hxi]

theorem markStable_size (n : Nat) (st : Array Nat) : (markStable n st).size = n := by
  unfold markStable
  rw [← Array.foldl_toList, (foldl_markStable _ _).1, Array.size_replicate]

theorem markStable_spec {n : Nat} {st : Array Nat} {i : Nat} (hi : i < n) :
    (markStable n st)[i]! = false ↔ i ∈ st := by
  unfold markStable
  rw [← Array.foldl_toList, (foldl_markStable _ _).2 i (by simpa using hi),
    getElem!_pos (Array.replicate n true) i (by simpa using hi)]
  simp

/-! ## What the plan says -/

/-- The pieces `plan` is built from, named for the proofs. -/
def planReusedPos (old new : Array String) : Array Nat :=
  (Array.range new.size).filter fun i => ((plan old new).src[i]!).isSome
def planReusedOld (old new : Array String) : Array Nat :=
  (planReusedPos old new).map fun i => ((plan old new).src[i]!).getD 0
def planStable (old new : Array String) : Array Nat :=
  (lis (planReusedOld old new)).map fun k => (planReusedPos old new)[k]!

theorem plan_src (old new : Array String) : (plan old new).src = new.map ((keyIndex old)[·]?) :=
  rfl
theorem plan_removed (old new : Array String) : (plan old new).removed =
    (Array.range old.size).filter (fun j => !(markUsed old.size (plan old new).src)[j]!) := rfl
theorem plan_move (old new : Array String) :
    (plan old new).move = markStable new.size (planStable old new) := rfl

theorem plan_src_size (old new : Array String) : (plan old new).src.size = new.size := by
  simp [plan_src]

theorem plan_move_size (old new : Array String) : (plan old new).move.size = new.size := by
  rw [plan_move, markStable_size]

theorem plan_src_getElem! {old new : Array String} {i : Nat} (hi : i < new.size) :
    (plan old new).src[i]! = (keyIndex old)[new[i]]? := by
  rw [getElem!_pos (plan old new).src i (by simpa [plan_src_size] using hi)]
  simp [plan_src]

/-- **`src` points at the old child with the same key.** -/
theorem plan_src_some {old new : Array String} (h1 : old.toList.Nodup) {i j : Nat}
    (hi : i < new.size) :
    (plan old new).src[i]! = some j ↔ j < old.size ∧ old[j]! = new[i] := by
  rw [plan_src_getElem! hi, keyIndex_getElem? h1]

/-- **A new child is created exactly when its key is not among the old keys.** -/
theorem plan_src_none {old new : Array String} (h1 : old.toList.Nodup) {i : Nat}
    (hi : i < new.size) : (plan old new).src[i]! = none ↔ new[i] ∉ old := by
  rw [plan_src_getElem! hi, keyIndex_getElem?_eq_none h1]

theorem mem_plan_src {old new : Array String} (h1 : old.toList.Nodup) (j : Nat) :
    some j ∈ (plan old new).src ↔ j < old.size ∧ old[j]! ∈ new := by
  rw [plan_src, Array.mem_map]
  simp only [keyIndex_getElem? h1]
  constructor
  · rintro ⟨k, hk, hj, rfl⟩; exact ⟨hj, hk⟩
  · rintro ⟨hj, hk⟩; exact ⟨_, hk, hj, rfl⟩

/-- **`removed` is exactly the old indices that no new child reuses.** -/
theorem mem_plan_removed (old new : Array String) (j : Nat) :
    j ∈ (plan old new).removed ↔ j < old.size ∧ some j ∉ (plan old new).src := by
  rw [plan_removed, Array.mem_filter, Array.mem_range]
  constructor
  · rintro ⟨hj, hu⟩
    refine ⟨hj, fun hm => ?_⟩
    rw [(markUsed_spec hj).2 hm] at hu
    exact absurd hu (by decide)
  · rintro ⟨hj, hm⟩
    refine ⟨hj, ?_⟩
    cases h : (markUsed old.size (plan old new).src)[j]!
    · rfl
    · exact absurd ((markUsed_spec hj).1 h) hm

/-- **…equivalently, the old children whose key is gone.** -/
theorem mem_plan_removed_iff {old new : Array String} (h1 : old.toList.Nodup) (j : Nat) :
    j ∈ (plan old new).removed ↔ j < old.size ∧ old[j]! ∉ new := by
  rw [mem_plan_removed, mem_plan_src h1]
  constructor
  · rintro ⟨hj, hn⟩; exact ⟨hj, fun h => hn ⟨hj, h⟩⟩
  · rintro ⟨hj, hn⟩; exact ⟨hj, fun h => hn h.2⟩

/-- **`removed` is in increasing order.** -/
theorem plan_removed_sorted (old new : Array String) :
    (plan old new).removed.toList.Pairwise (· < ·) := by
  rw [plan_removed, Array.toList_filter, Array.toList_range]
  exact List.pairwise_lt_range.filter _

/-- The stable positions increase, and so do their old indices. -/
theorem planStable_spec (old new : Array String) :
    (planStable old new).toList.Pairwise (fun a b =>
        a < b ∧ ((plan old new).src[a]!).getD 0 < ((plan old new).src[b]!).getD 0) ∧
      ∀ i ∈ planStable old new, i < new.size ∧ ((plan old new).src[i]!).isSome := by
  have hrp : (planReusedPos old new).toList.Pairwise (· < ·) := by
    rw [planReusedPos, Array.toList_filter, Array.toList_range]
    exact List.pairwise_lt_range.filter _
  have hrpmem : ∀ i ∈ planReusedPos old new, i < new.size ∧ ((plan old new).src[i]!).isSome := by
    intro i hi
    rw [← Array.mem_toList_iff, planReusedPos, Array.toList_filter, Array.toList_range,
      List.mem_filter, List.mem_range] at hi
    exact hi
  have hro : ∀ k (hk : k < (planReusedPos old new).size), (planReusedOld old new)[k]! =
      ((plan old new).src[(planReusedPos old new)[k]!]!).getD 0 := by
    intro k hk
    rw [getElem!_pos (planReusedOld old new) k (by simpa [planReusedOld] using hk),
      getElem!_pos (planReusedPos old new) k hk]
    simp [planReusedOld]
  have hsz : (planReusedOld old new).size = (planReusedPos old new).size := by
    simp [planReusedOld]
  obtain ⟨hv, hb⟩ := lis_valid (planReusedOld old new)
  constructor
  · rw [planStable, Array.toList_map, List.pairwise_map]
    refine hv.imp_of_mem fun {a b} ha hb' hab => ?_
    have ha' := hb a ha
    have hb'' := hb b hb'
    rw [hsz] at ha' hb''
    refine ⟨?_, ?_⟩
    · rw [getElem!_pos _ a ha', getElem!_pos _ b hb'']
      exact hrp.rel_getElem_of_lt (by simpa using ha') (by simpa using hb'') hab.1
    · have := hab.2
      rwa [hro a ha', hro b hb''] at this
  · intro i hi
    rw [planStable, Array.mem_map] at hi
    obtain ⟨k, hk, rfl⟩ := hi
    have hk' := hb k (by simpa using hk)
    rw [hsz] at hk'
    rw [getElem!_pos _ k hk']
    exact hrpmem _ (Array.getElem_mem hk')

/-- **No old child is reused twice** (so the diff never patches one DOM node into two places). -/
theorem plan_src_inj {old new : Array String} (h1 : old.toList.Nodup) (h2 : new.toList.Nodup)
    {i i' j : Nat} (hi : i < new.size) (hi' : i' < new.size)
    (h : (plan old new).src[i]! = some j) (h' : (plan old new).src[i']! = some j) : i = i' := by
  have e := ((plan_src_some h1 hi).1 h).2
  have e' := ((plan_src_some h1 hi').1 h').2
  exact (h2.getElem_inj (hi := by simpa using hi) (hj := by simpa using hi')).1
    (by simpa using e.symm.trans e')

/-- **Every created child is inserted**: a position with no old child always has `move`. -/
theorem plan_create_moves {old new : Array String} {i : Nat} (hi : i < new.size)
    (h : (plan old new).src[i]! = none) : (plan old new).move[i]! = true := by
  cases hm : (plan old new).move[i]!
  · rw [plan_move] at hm
    have := ((planStable_spec old new).2 i ((markStable_spec hi).1 hm)).2
    rw [h] at this
    exact absurd this (by decide)
  · rfl

/-! ## The main theorem -/

/-- The children `applyList` starts from: the old children that are not removed. -/
theorem mem_kept {old new : Array String} (j : Nat) :
    j ∈ (List.range old.size).filter (fun j => !((plan old new).removed.contains j)) ↔
      j < old.size ∧ some j ∈ (plan old new).src := by
  rw [List.mem_filter, List.mem_range]
  constructor
  · rintro ⟨hj, hc⟩
    refine ⟨hj, Classical.byContradiction fun hn => ?_⟩
    have := Array.contains_iff_mem.2 ((mem_plan_removed old new j).2 ⟨hj, hn⟩)
    rw [this] at hc
    exact absurd hc (by decide)
  · rintro ⟨hj, hm⟩
    refine ⟨hj, ?_⟩
    cases hc : (plan old new).removed.contains j
    · rfl
    · exact (((mem_plan_removed old new j).1 (Array.contains_iff_mem.1 hc)).2 hm).elim

/-- **Keyed reconciliation is correct**: removing `removed` and then, right to left, inserting
every child with `move` before its successor turns the old children into the new ones. -/
theorem plan_correct (old new : Array String) (h1 : old.toList.Nodup) (h2 : new.toList.Nodup) :
    Keyed.applyList old new (Keyed.plan old new) = new.toList := by
  unfold applyList
  refine place_correct new (fun i => (plan old new).move[i]!) _ h2 ?_ ?_ ?_
  · rw [List.Nodup, List.pairwise_map]
    refine (List.pairwise_lt_range.filter _).imp_of_mem fun {a b} ha hb hab => ?_
    have ha' := ((mem_kept a).1 ha).1
    have hb' := ((mem_kept b).1 hb).1
    have := (List.Nodup.getElem!_inj (xs := old.toList) (by simpa using ha') (by simpa using hb')
      h1).1
    rw [Array.getElem!_toList, Array.getElem!_toList] at this
    exact fun he => absurd (this he) (Nat.ne_of_lt hab)
  · intro x hx
    obtain ⟨j, hj, rfl⟩ := List.mem_map.1 hx
    exact Array.mem_toList_iff.2 ((mem_plan_src h1 j).1 ((mem_kept j).1 hj).2).2
  · -- the stable keys, in new order, are a sublist of the kept old keys
    unfold stableBelow
    obtain ⟨hst, hstm⟩ := planStable_spec old new
    have hF : ∀ i ∈ (List.range new.size).filter (fun i => !(plan old new).move[i]!),
        i < new.size ∧ (plan old new).src[i]! = some (((plan old new).src[i]!).getD 0) ∧
          i ∈ planStable old new := by
      intro i hi
      rw [List.mem_filter, List.mem_range] at hi
      have hs : i ∈ planStable old new := by
        rw [plan_move] at hi
        exact (markStable_spec hi.1).1 (by simpa using hi.2)
      obtain ⟨j, hj⟩ := Option.isSome_iff_exists.1 (hstm i hs).2
      exact ⟨hi.1, by rw [hj]; rfl, hs⟩
    have heq : ((List.range new.size).filter (fun i => !(plan old new).move[i]!)).map (new[·]!) =
        (((List.range new.size).filter (fun i => !(plan old new).move[i]!)).map
          (fun i => ((plan old new).src[i]!).getD 0)).map (old[·]!) := by
      rw [List.map_map]
      apply List.map_congr_left
      intro i hi
      obtain ⟨hi', hsrc, -⟩ := hF i hi
      rw [Function.comp_apply, ((plan_src_some h1 hi').1 hsrc).2, getElem!_pos new i hi']
    rw [heq]
    apply List.Sublist.map
    apply sublist_filter_range
    · rw [List.pairwise_map]
      refine (List.pairwise_lt_range.filter _).imp_of_mem fun {a b} ha hb hab => ?_
      obtain ⟨-, -, ha'⟩ := hF a ha
      obtain ⟨-, -, hb'⟩ := hF b hb
      rcases Pairwise.rel_or_rel hst (Array.mem_toList_iff.2 ha') (Array.mem_toList_iff.2 hb')
        (Nat.ne_of_lt hab) with h | h
      · exact h.2
      · exact absurd h.1 (Nat.lt_asymm hab)
    · intro x hx
      obtain ⟨i, hi, rfl⟩ := List.mem_map.1 hx
      obtain ⟨hi', hsrc, -⟩ := hF i hi
      have hmem : some (((plan old new).src[i]!).getD 0) ∈ (plan old new).src := by
        rw [← hsrc, getElem!_pos _ i (by simpa [plan_src_size] using hi')]
        exact Array.getElem_mem _
      have hk := List.mem_filter.1 ((mem_kept _).2 ⟨((plan_src_some h1 hi').1 hsrc).1, hmem⟩)
      exact ⟨List.mem_range.1 hk.1, hk.2⟩

/-! ## The converse: what any correct choice of moves must satisfy -/

/-- Moving `k` never changes the relative order of the other children. -/
theorem filter_placeBefore {p : String → Bool} {k : String} {a : Option String}
    {ys : List String} (hk : p k = false) :
    (placeBefore k a ys).filter p = ys.filter p := by
  obtain ⟨A, B, h1, h2⟩ := placeBefore_shape k a ys
  rw [h1, List.filter_append, List.filter_cons_of_neg (by simp [hk]), ← List.filter_append, h2,
    List.filter_filter]
  apply List.filter_congr
  intro x _
  by_cases hx : p x = true
  · have : x ≠ k := fun h => by simp [h, hk] at hx
    simp [hx, this]
  · simp [hx]

/-- With duplicate-free keys, filtering `new` by the stable keys gives the stable keys. -/
theorem filter_mem_stableBelow (new : Array String) (mv : Nat → Bool) (hN : new.toList.Nodup) :
    new.toList.filter (· ∈ stableBelow new mv new.size) = stableBelow new mv new.size := by
  conv => lhs; rw [← map_getElem!_range new]
  rw [List.filter_map]
  conv => rhs; rw [stableBelow]
  congr 1
  apply List.filter_congr
  intro i hi
  rw [List.mem_range] at hi
  simp only [Function.comp_apply]
  rw [Bool.eq_iff_iff, decide_eq_true_iff, Bool.not_eq_true']
  constructor
  · intro hm
    obtain ⟨i', hi', hm', he⟩ := mem_stableBelow hm
    rw [getElem!_pos new i hi, getElem!_pos new i' hi'] at he
    have := (hN.getElem_inj (i := i) (j := i') (hi := by simpa using hi)
      (hj := by simpa using hi')).1 (by simpa using he)
    subst this; exact hm'
  · intro hm
    simp only [stableBelow, List.mem_map, List.mem_filter, List.mem_range]
    exact ⟨i, ⟨hi, by simp [hm]⟩, rfl⟩

/-- **The converse of `place_correct`**: if visiting `n-1 … 0` with move flags `mv` turns `xs₀`
into `new`, then the keys at the stable positions already appear in `xs₀` in the order `new`
wants: children that are not moved never change their relative order. -/
theorem stable_sublist_of_correct (new : Array String) (mv : Nat → Bool) (xs₀ : List String)
    (hN : new.toList.Nodup) (h : (List.range new.size).foldr (step new mv) xs₀ = new.toList) :
    stableBelow new mv new.size <+ xs₀ := by
  let U := stableBelow new mv new.size
  have key : ∀ t s, s + t = new.size →
      ((List.range' s t).foldr (step new mv) xs₀).filter (· ∈ U) = xs₀.filter (· ∈ U) := by
    intro t
    induction t with
    | zero => intro s _; rfl
    | succ t ih =>
      intro s hs
      rw [List.range'_succ, List.foldr_cons, ← ih (s + 1) (by omega)]
      unfold step
      split
      · rename_i hm
        apply filter_placeBefore
        rw [decide_eq_false_iff_not]
        intro hmem
        obtain ⟨i, hi, hm', he⟩ := mem_stableBelow hmem
        rw [getElem!_pos new s (by omega), getElem!_pos new i hi] at he
        have := (hN.getElem_inj (i := s) (j := i) (hi := by simp; omega)
          (hj := by simpa using hi)).1 (by simpa using he)
        subst this
        rw [hm] at hm'; exact absurd hm' (by decide)
      · rfl
  have := key new.size 0 (by simp)
  rw [← List.range_eq_range', h, filter_mem_stableBelow new mv hN] at this
  rw [this]
  exact List.filter_sublist

/-- **Right-to-left placement is correct exactly when the stable keys are in order.** -/
theorem place_correct_iff (new : Array String) (mv : Nat → Bool) (xs₀ : List String)
    (hN : new.toList.Nodup) (hxs : xs₀.Nodup) (hsub : ∀ x ∈ xs₀, x ∈ new.toList) :
    (List.range new.size).foldr (step new mv) xs₀ = new.toList ↔
      stableBelow new mv new.size <+ xs₀ :=
  ⟨stable_sublist_of_correct new mv xs₀ hN, place_correct new mv xs₀ hN hxs hsub⟩

/-! ## Optimality: the plan moves the fewest children -/

theorem map_inj_on {α β : Type} {f : α → β} {l₁ l₂ : List α} {S : α → Prop}
    (hinj : ∀ a b, S a → S b → f a = f b → a = b) (h1 : ∀ a ∈ l₁, S a) (h2 : ∀ a ∈ l₂, S a)
    (h : l₁.map f = l₂.map f) : l₁ = l₂ := by
  induction l₁ generalizing l₂ with
  | nil => cases l₂ with | nil => rfl | cons => simp at h
  | cons a l₁ ih =>
    cases l₂ with
    | nil => simp at h
    | cons b l₂ =>
      simp only [List.map_cons, List.cons.injEq] at h
      rw [hinj a b (h1 a (List.mem_cons_self ..)) (h2 b (List.mem_cons_self ..)) h.1,
        ih (fun x hx => h1 x (List.mem_cons_of_mem _ hx)) (fun x hx => h2 x (List.mem_cons_of_mem _ hx)) h.2]

/-- **No correct plan keeps more children in place than `plan` does.** Whatever `p` removes and
moves, if applying it turns `old` into `new`, then `plan old new` leaves at least as many
children untouched. -/
theorem plan_keeps_most (old new : Array String) (h1 : old.toList.Nodup) (h2 : new.toList.Nodup)
    (p : Plan) (hm : applyList old new p = new.toList) :
    (List.range new.size).countP (fun i => !p.move[i]!) ≤
      (List.range new.size).countP (fun i => !(plan old new).move[i]!) := by
  unfold applyList at hm
  have hS := stable_sublist_of_correct new (fun i => p.move[i]!) _ h2 hm
  simp only [stableBelow] at hS
  rw [List.countP_eq_length_filter, List.countP_eq_length_filter]
  -- the alternative's stable positions `P`, and their old indices `L`
  generalize hP : (List.range new.size).filter (fun i => !p.move[i]!) = P at hS
  have hPmem : ∀ i ∈ P, i < new.size := fun i hi => by
    rw [← hP, List.mem_filter, List.mem_range] at hi; exact hi.1
  have hPsorted : P.Pairwise (· < ·) := hP ▸ List.pairwise_lt_range.filter _
  -- every stable position of the alternative reuses an old child
  have hreuse : ∀ i ∈ P, (plan old new).src[i]! = some (((plan old new).src[i]!).getD 0) := by
    intro i hi
    have hx : new[i]! ∈ ((List.range old.size).filter
        (fun j => !(p.removed.contains j))).map (old[·]!) :=
      hS.subset (List.mem_map_of_mem hi)
    obtain ⟨j, hj, he⟩ := List.mem_map.1 hx
    have hj' := List.mem_range.1 (List.mem_filter.1 hj).1
    rw [getElem!_pos new i (hPmem i hi)] at he
    rw [(plan_src_some h1 (hPmem i hi)).2 ⟨hj', he⟩]
    rfl
  let oi : Nat → Nat := fun i => ((plan old new).src[i]!).getD 0
  have hold : ∀ i ∈ P, old[oi i]! = new[i]! := by
    intro i hi
    rw [((plan_src_some h1 (hPmem i hi)).1 (hreuse i hi)).2, getElem!_pos new i (hPmem i hi)]
  have hoi_lt : ∀ i ∈ P, oi i < old.size := fun i hi =>
    ((plan_src_some h1 (hPmem i hi)).1 (hreuse i hi)).1
  -- `L` is a sublist of the reused old indices in new order …
  have hLsub : P.map oi <+ (planReusedOld old new).toList := by
    rw [planReusedOld, Array.toList_map]
    apply List.Sublist.map
    rw [planReusedPos, Array.toList_filter, Array.toList_range]
    exact sublist_filter_range hPsorted fun i hi =>
      ⟨hPmem i hi, by rw [hreuse i hi]; rfl⟩
  -- … and strictly increasing, because the stable keys are in old order
  have hLinc : (P.map oi).Pairwise (· < ·) := by
    have hmap : P.map (new[·]!) = (P.map oi).map (old[·]!) := by
      rw [List.map_map]
      exact List.map_congr_left fun i hi => (hold i hi).symm
    rw [hmap] at hS
    obtain ⟨l', hl', he⟩ := List.sublist_map_iff.1 hS
    have hkeep_lt : ∀ j ∈ (List.range old.size).filter
        (fun j => !(p.removed.contains j)), j < old.size :=
      fun j hj => List.mem_range.1 (List.mem_filter.1 hj).1
    have := map_inj_on (S := fun j => j < old.size) (fun a b ha hb hab => by
        have := (List.Nodup.getElem!_inj (xs := old.toList) (by simpa using ha)
          (by simpa using hb) h1).1
        exact this (by rw [Array.getElem!_toList, Array.getElem!_toList]; exact hab))
      (fun j hj => by
        obtain ⟨i, hi, rfl⟩ := List.mem_map.1 hj
        exact hoi_lt i hi)
      (fun j hj => hkeep_lt j (hl'.subset hj)) he
    rw [this]
    exact (List.pairwise_lt_range.filter _).sublist hl'
  have hlis := lis_longest (planReusedOld old new) (P.map oi) hLsub hLinc
  -- the plan keeps every position of `lis` in place
  obtain ⟨hst, hstm⟩ := planStable_spec old new
  have hplan : (planStable old new).toList <+
      (List.range new.size).filter (fun i => !(plan old new).move[i]!) :=
    sublist_filter_range (hst.imp fun h => h.1) fun i hi => by
      have hi' := Array.mem_toList_iff.1 hi
      refine ⟨(hstm i hi').1, ?_⟩
      rw [plan_move, (markStable_spec (hstm i hi').1).2 hi']
      rfl
  have hsz : (planStable old new).toList.length = (lis (planReusedOld old new)).size := by
    simp [planStable]
  have := hplan.length_le
  simp only [List.length_map] at hlis
  omega

/-- **The plan moves the fewest children**: every plan that turns `old` into `new` (whatever it
removes and moves) inserts at least as many children as `plan old new` does. -/
theorem plan_moves_fewest (old new : Array String) (h1 : old.toList.Nodup) (h2 : new.toList.Nodup)
    (p : Plan) (hm : applyList old new p = new.toList) :
    (List.range new.size).countP (fun i => (plan old new).move[i]!) ≤
      (List.range new.size).countP (fun i => p.move[i]!) := by
  have h := plan_keeps_most old new h1 h2 p hm
  have e1 := List.length_eq_countP_add_countP (fun i => p.move[i]!) (l := List.range new.size)
  have e2 := List.length_eq_countP_add_countP (fun i => (plan old new).move[i]!)
    (l := List.range new.size)
  have c1 : (List.range new.size).countP (fun i => ¬ p.move[i]! = true) =
      (List.range new.size).countP (fun i => !p.move[i]!) :=
    List.countP_congr fun i _ => by simp
  have c2 : (List.range new.size).countP (fun i => ¬ (plan old new).move[i]! = true) =
      (List.range new.size).countP (fun i => !(plan old new).move[i]!) :=
    List.countP_congr fun i _ => by simp
  omega

/-! ## Axiom audit (checked on every build) -/

/-- info: 'LeanUI.Proofs.Keyed.plan_correct' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms plan_correct
/-- info: 'LeanUI.Proofs.Keyed.place_correct_iff' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms place_correct_iff
/-- info: 'LeanUI.Proofs.Keyed.plan_moves_fewest' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms plan_moves_fewest
/-- info: 'LeanUI.Proofs.Keyed.lis_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms lis_spec

end LeanUI.Proofs.Keyed
