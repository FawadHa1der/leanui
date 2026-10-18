module
public import TodoMVC
/-!
# What is proved about TodoMVC

The app's model logic is the pure function `TodoMVC.step`. Its todo ids are the keys of the keyed
`<ul class="todo-list">`, and the keyed planner is proved correct only for duplicate-free keys
(`LeanUI.Proofs.Keyed.plan_correct`). So the property that matters is:

* `step_inv`: every message keeps the ids duplicate-free and below `nextId` (so the next todo
  gets a fresh id), whatever the model and whatever was read back from storage.

And the bulk operations do what the specification says:

* `toggleAll_sets`: after "toggle all" every todo has the requested state;
* `clearCompleted_active`: after "clear completed" no completed todo is left, and every active
  todo is still there (`clearCompleted_keeps`);
* `addTodo_blank`: a blank title adds nothing.
-/
@[expose] public section
namespace TodoMVC.Proofs
open TodoMVC

def ids (ts : Array Todo) : List Nat := ts.toList.map (·.id)

/-- Ids are distinct and below `nextId`. -/
def Inv (m : Model) : Prop := (ids m.todos).Nodup ∧ ∀ x ∈ ids m.todos, x < m.nextId

/-- Removing todos (and not lowering `nextId`) keeps the invariant. -/
theorem inv_of_sublist {m m' : Model} (h : Inv m) (hs : (ids m'.todos).Sublist (ids m.todos))
    (hn : m.nextId ≤ m'.nextId) : Inv m' :=
  ⟨h.1.sublist hs, fun x hx => Nat.lt_of_lt_of_le (h.2 x (hs.subset hx)) hn⟩

theorem ids_map_of_id (ts : Array Todo) (f : Todo → Todo) (hf : ∀ t, (f t).id = t.id) :
    ids (ts.map f) = ids ts := by
  simp only [ids, Array.toList_map, List.map_map]
  exact List.map_congr_left (fun t _ => hf t)

theorem ids_modify (i : Nat) (f : Todo → Todo) (hf : ∀ t, (f t).id = t.id) (ts : Array Todo) :
    ids (modify i f ts) = ids ts := by
  unfold modify
  apply ids_map_of_id
  intro t; by_cases h : t.id = i <;> simp [h, hf]

theorem ids_filter_sublist (p : Todo → Bool) (ts : Array Todo) : (ids (ts.filter p)).Sublist (ids ts) := by
  simp only [ids, Array.toList_filter]
  exact (List.filter_sublist).map _

theorem ids_renumberFrom (k : Nat) (l : List Todo) : (renumberFrom k l).map (·.id) = List.range' k l.length := by
  induction l generalizing k with
  | nil => rfl
  | cons t ts ih => simp [renumberFrom, ih, List.range'_succ]

theorem length_renumberFrom (k : Nat) (l : List Todo) : (renumberFrom k l).length = l.length := by
  induction l generalizing k with
  | nil => rfl
  | cons t ts ih => simp [renumberFrom, ih]

/-- Whatever storage held, loading numbers the todos `1 … n` and sets `nextId` to `n + 1`. -/
theorem inv_load (json : Option String) (m : Model) : Inv (load json m) := by
  simp only [Inv, load, ids, renumber, List.size_toArray, length_renumberFrom]
  refine ⟨?_, fun x hx => ?_⟩
  · rw [ids_renumberFrom]; exact List.nodup_range'
  · rw [ids_renumberFrom, List.mem_range'_1] at hx; omega

theorem inv_addTodo (m : Model) (h : Inv m) : Inv (addTodo m) := by
  unfold addTodo
  dsimp only
  split
  · exact h
  · refine ⟨?_, ?_⟩
    · simp only [ids, Array.toList_push, List.map_append, List.map_cons, List.map_nil]
      exact List.nodup_append.2 ⟨h.1, by simp, fun x hx y hy => by
        simp at hy; subst hy; exact Nat.ne_of_lt (h.2 x hx)⟩
    · intro x hx
      simp only [ids, Array.toList_push, List.map_append, List.mem_append, List.map_cons, List.map_nil,
        List.mem_singleton] at hx
      rcases hx with hx | hx
      · exact Nat.lt_succ_of_lt (h.2 x hx)
      · subst hx; exact Nat.lt_succ_self _

theorem inv_modify {m : Model} (h : Inv m) (i : Nat) (f : Todo → Todo)
    (m' : Model) (ht : m'.todos = modify i f m.todos) (hn : m'.nextId = m.nextId) (hf : ∀ t, (f t).id = t.id) : Inv m' :=
  inv_of_sublist h (by rw [ht, ids_modify _ _ hf]; exact List.Sublist.refl _) (by rw [hn]; exact Nat.le_refl _)

theorem inv_filter {m : Model} (h : Inv m) (p : Todo → Bool)
    (m' : Model) (ht : m'.todos = m.todos.filter p) (hn : m'.nextId = m.nextId) : Inv m' :=
  inv_of_sublist h (by rw [ht]; exact ids_filter_sublist _ _) (by rw [hn]; exact Nat.le_refl _)

theorem inv_same {m : Model} (h : Inv m) (m' : Model) (ht : m'.todos = m.todos) (hn : m'.nextId = m.nextId) : Inv m' :=
  inv_of_sublist h (by rw [ht]; exact List.Sublist.refl _) (by rw [hn]; exact Nat.le_refl _)

theorem inv_commitEdit (m : Model) (h : Inv m) : Inv (commitEdit m) := by
  unfold commitEdit
  split
  · exact h
  · dsimp only
    split
    · exact inv_filter h _ _ rfl rfl
    · exact inv_modify h _ _ _ rfl rfl (fun _ => rfl)

/-- Every message keeps todo ids distinct and below `nextId`. -/
theorem step_inv (msg : Msg) (m : Model) (h : Inv m) : Inv (step msg m) := by
  cases msg with
  | field s => exact inv_same h _ rfl rfl
  | newKey k =>
    simp only [step]
    split
    · exact inv_addTodo m h
    · exact h
  | toggle i b => exact inv_modify h i _ _ rfl rfl (fun _ => rfl)
  | toggleAll b =>
    exact inv_of_sublist h (by simp only [step]; rw [ids_map_of_id m.todos (fun t => { t with completed := b }) (fun _ => rfl)]; exact List.Sublist.refl _) (Nat.le_refl _)
  | destroy i => exact inv_filter h _ _ rfl rfl
  | edit i =>
    simp only [step]
    split
    · exact inv_same h _ rfl rfl
    · exact h
  | draft s => exact inv_same h _ rfl rfl
  | editKey k =>
    simp only [step]
    split
    · exact inv_commitEdit m h
    · split
      · exact inv_same h _ rfl rfl
      · exact h
  | commit => exact inv_commitEdit m h
  | clearCompleted => exact inv_filter h _ _ rfl rfl
  | urlChanged u => exact inv_same h _ rfl rfl
  | loaded json => exact inv_load json m

/-- Any sequence of messages, from the initial model. -/
theorem steps_inv (msgs : List Msg) (url : String) : Inv (msgs.foldl (fun m msg => step msg m) (init url).1) := by
  suffices ∀ m, Inv m → Inv (msgs.foldl (fun m msg => step msg m) m) from
    this _ ⟨List.nodup_nil, fun _ h => by simp [ids, init] at h⟩
  induction msgs with
  | nil => intro m h; exact h
  | cons msg rest ih => intro m h; exact ih _ (step_inv msg m h)

theorem toggleAll_sets (b : Bool) (m : Model) : ∀ t ∈ (step (.toggleAll b) m).todos.toList, t.completed = b := by
  intro t ht
  simp only [step, Array.toList_map, List.mem_map] at ht
  obtain ⟨u, _, rfl⟩ := ht
  rfl

theorem clearCompleted_active (m : Model) : ∀ t ∈ (step .clearCompleted m).todos.toList, t.completed = false := by
  intro t ht
  simp only [step, Array.toList_filter, List.mem_filter] at ht
  simpa using ht.2

theorem clearCompleted_keeps (m : Model) (t : Todo) (ht : t ∈ m.todos.toList) (ha : t.completed = false) :
    t ∈ (step .clearCompleted m).todos.toList := by
  simp only [step, Array.toList_filter, List.mem_filter]
  exact ⟨ht, by simp [ha]⟩

theorem addTodo_blank (m : Model) (h : m.field.trimAscii.toString.isEmpty = true) : (addTodo m).todos = m.todos := by
  unfold addTodo; dsimp only; split
  · rfl
  · contradiction

/-! The build fails if any of these ever depends on `sorryAx` or on a non-standard axiom. -/

/-- info: 'TodoMVC.Proofs.step_inv' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms step_inv
/-- info: 'TodoMVC.Proofs.steps_inv' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms steps_inv
/-- info: 'TodoMVC.Proofs.toggleAll_sets' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms toggleAll_sets
/-- info: 'TodoMVC.Proofs.clearCompleted_active' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms clearCompleted_active
/-- info: 'TodoMVC.Proofs.clearCompleted_keeps' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms clearCompleted_keeps
/-- info: 'TodoMVC.Proofs.addTodo_blank' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms addTodo_blank

end TodoMVC.Proofs
