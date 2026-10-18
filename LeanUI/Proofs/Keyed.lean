module
public import LeanUI.Keyed
@[expose] public section
namespace LeanUI.Keyed
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

theorem lisScan_ok (xs : Array Nat) (i : Nat) (tails : Array Nat) (prev : Array (Option Nat))
    (hi : i ≤ xs.size) (h : ScanOk xs i tails prev) :
    ScanOk xs xs.size (lisScan xs i tails prev).1 (lisScan xs i tails prev).2 := by
  fun_induction lisScan xs i tails prev with
  | case1 i tails prev hlt x lo prev' tails' ih =>
    have hlo : lo = lisSearch xs tails x 0 tails.size := rfl
    have hprev' : prev' = if lo = 0 then prev else prev.set! i (some tails[lo - 1]!) := by
      simp [prev']
    have htails' : tails' = if lo < tails.size then tails.set! lo i else tails.push i := by
      simp [tails']
    obtain ⟨-, hs2, hs3⟩ := lisSearch_spec xs tails x 0 tails.size (Nat.zero_le _)
    rw [← hlo] at hs2 hs3
    apply ih (by omega)
    refine ⟨?_, ?_, ?_⟩
    · rw [hprev']; split <;> simp [h.size]
    · intro t ht
      rw [htails'] at ht
      split at ht
      · rcases Array.mem_or_eq_of_mem_setIfInBounds ht with ht | rfl
        · exact Nat.lt_succ_of_lt (h.tails_lt t ht)
        · omega
      · rcases Array.mem_push.1 ht with ht | rfl
        · exact Nat.lt_succ_of_lt (h.tails_lt t ht)
        · omega
    · intro j p hp
      rw [hprev'] at hp
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
          · rw [getElem!_pos xs i hlt]; exact hs3
        · exact h.prev_ok j p hp
  | case2 i tails prev hge =>
    have : i = xs.size := by omega
    subst this
    exact h

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
    applyList old new (plan old new) = new.toList := by
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
