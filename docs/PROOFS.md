# Keyed reconciliation: what is proved, tested and assumed

When a keyed child list changes, `LeanUI.Diff.patchKids` asks `LeanUI.Keyed.plan` which old
children to reuse, which to remove and which to move. That planner is proved correct and optimal
in Lean (`LeanUI/Proofs/Keyed.lean`, about 1,270 lines, no `sorry`, standard axioms only). This
document states exactly what the theorems say, what is only tested, and what has to be trusted.

```
lake build                               # checks every proof (LeanUIProofs is a default target)
./.lake/build/bin/leanui-tests           # 20,000 random planner cases + keyed lists through the runtime
node tests/browser/keyed-dom.mjs         # real DOM, Chromium and Firefox (see below)
```

Browser runs go through the host lock (`docs/DESIGN.md`, section 3):
`"/Users/fawadhaider/code/lean questions/infoview-widget-research/widgets-v4.34/qed64-showcase/scripts/with-browser-lock.sh" proofs node tests/browser/keyed-dom.mjs [steps] [seed] [engines]`.

The proofs take about a second to check. The end of `LeanUI/Proofs/Keyed.lean` runs
`#print axioms` on the main theorems inside `#guard_msgs`, so `lake build` fails if any of them
ever depends on `sorryAx` or on any axiom beyond `propext`, `Classical.choice` and `Quot.sound`.

## 1. The model

The theorems are about two functions in `LeanUI/Keyed.lean`.

`plan old new` computes the `Plan` that `Diff` uses: `src[i]` is the old index reused at new
position `i` (or `none`), `removed` lists the old indices that are not reused, and `move[i]` says
the child at `i` must be inserted.

`applyList old new p` is the list model of what the browser does with a plan:

```lean
def placeBefore (k : String) (anchor : Option String) (xs : List String) : List String :=
  let ys := xs.filter (· != k)                 -- insertBefore/appendChild first detach the node
  match anchor with
  | none => ys ++ [k]
  | some a =>
    match ys.idxOf? a with
    | some i => ys.take i ++ k :: ys.drop i
    | none => ys ++ [k]

def applyList (old new : Array String) (p : Plan) : List String :=
  let keep := (List.range old.size).filter fun j => !(p.removed.contains j)
  (List.range new.size).foldr (init := keep.map fun j => old[j]!) fun i xs =>
    if p.move[i]! then
      placeBefore new[i]! (if i + 1 < new.size then some new[i + 1]! else none) xs
    else xs
```

The `foldr` visits `i = n-1 … 0`, the same order as the loop in `patchKids`, so when child `i`
moves, its anchor `new[i+1]` is already in its final place.

## 2. What is proved

All names are in the namespace `LeanUI.Proofs.Keyed`. Key lists are `Array String`.
"Duplicate-free" means `old.toList.Nodup` (`h1`) and `new.toList.Nodup` (`h2`).

### Correctness

```lean
theorem plan_correct (old new : Array String) (h1 : old.toList.Nodup) (h2 : new.toList.Nodup) :
    Keyed.applyList old new (Keyed.plan old new) = new.toList
```

Removing `removed` and then inserting every child that has `move`, right to left, before its
successor turns the old keys into exactly the new keys.

### What the fields mean

```lean
theorem plan_src_size  : (plan old new).src.size = new.size
theorem plan_move_size : (plan old new).move.size = new.size
theorem plan_src_some (h1) (hi : i < new.size) :
    (plan old new).src[i]! = some j ↔ j < old.size ∧ old[j]! = new[i]
theorem plan_src_none (h1) (hi : i < new.size) :
    (plan old new).src[i]! = none ↔ new[i] ∉ old
theorem plan_src_inj (h1) (h2) (hi : i < new.size) (hi' : i' < new.size)
    (h : (plan old new).src[i]! = some j) (h' : (plan old new).src[i']! = some j) : i = i'
theorem mem_plan_removed :            j ∈ (plan old new).removed ↔ j < old.size ∧ some j ∉ (plan old new).src
theorem mem_plan_removed_iff (h1) :   j ∈ (plan old new).removed ↔ j < old.size ∧ old[j]! ∉ new
theorem plan_removed_sorted :         (plan old new).removed.toList.Pairwise (· < ·)
theorem plan_create_moves (hi : i < new.size) (h : (plan old new).src[i]! = none) :
    (plan old new).move[i]! = true
```

`src` points at the old child with the same key, and is `none` exactly for keys that are new.
No old child is reused at two positions, so the diff never patches one DOM node into two places.
`removed` is exactly the set of old indices no `src` entry points at (this one needs no
uniqueness assumption), equivalently the old children whose key is gone, in increasing order.
Every created child has `move`, so the diff inserts every node it mounts.

### Placement, in both directions

For any move flags `mv`, let `step new mv` be one iteration of the loop above, and
`stableBelow new mv s` the keys at the positions below `s` whose flag is `false`, in order.

```lean
theorem place_correct (new : Array String) (mv : Nat → Bool) (xs₀ : List String)
    (hN : new.toList.Nodup) (hxs : xs₀.Nodup) (hsub : ∀ x ∈ xs₀, x ∈ new.toList)
    (hst : stableBelow new mv new.size <+ xs₀) :
    (List.range new.size).foldr (step new mv) xs₀ = new.toList

theorem stable_sublist_of_correct (new : Array String) (mv : Nat → Bool) (xs₀ : List String)
    (hN : new.toList.Nodup) (h : (List.range new.size).foldr (step new mv) xs₀ = new.toList) :
    stableBelow new mv new.size <+ xs₀

theorem place_correct_iff ... :
    (List.range new.size).foldr (step new mv) xs₀ = new.toList ↔ stableBelow new mv new.size <+ xs₀
```

The right-to-left pass is correct **exactly** when the children it leaves alone already appear in
the start list in the order `new` wants (`<+` is `List.Sublist`). This holds for any flags, not
only the planner's; `plan_correct` is `place_correct` plus the fact that the planner's stable
positions have increasing old indices. The converse says children that are not moved never change
their relative order, which is what makes the optimality result below possible.

### Optimality

```lean
theorem lis_valid (xs : Array Nat) :
    (lis xs).toList.Pairwise (IncRel xs) ∧ ∀ k ∈ (lis xs).toList, k < xs.size
theorem lis_longest (xs : Array Nat) (l : List Nat) (hl : l <+ xs.toList)
    (hinc : l.Pairwise (· < ·)) : l.length ≤ (lis xs).size
theorem lis_spec (xs : Array Nat) :
    (lis xs).toList.map (xs[·]!) <+ xs.toList ∧
      ((lis xs).toList.map (xs[·]!)).Pairwise (· < ·) ∧
      ∀ l, l <+ xs.toList → l.Pairwise (· < ·) →
        l.length ≤ ((lis xs).toList.map (xs[·]!)).length

theorem plan_keeps_most (old new : Array String) (h1 : old.toList.Nodup) (h2 : new.toList.Nodup)
    (p : Plan) (hm : applyList old new p = new.toList) :
    (List.range new.size).countP (fun i => !p.move[i]!) ≤
      (List.range new.size).countP (fun i => !(plan old new).move[i]!)
theorem plan_moves_fewest (old new : Array String) (h1 : old.toList.Nodup) (h2 : new.toList.Nodup)
    (p : Plan) (hm : applyList old new p = new.toList) :
    (List.range new.size).countP (fun i => (plan old new).move[i]!) ≤
      (List.range new.size).countP (fun i => p.move[i]!)
```

`lis` (patience sorting with a binary search, O(n log n)) returns the indices of a strictly
increasing subsequence (`IncRel xs a b` is `a < b ∧ xs[a]! < xs[b]!`), and no strictly increasing
subsequence is longer. Consequently no plan at all, whatever it removes and moves, turns `old`
into `new` in this model with fewer insertions than `plan old new`.

### Axioms

```
'LeanUI.Proofs.Keyed.plan_correct' depends on axioms: [propext, Classical.choice, Quot.sound]
'LeanUI.Proofs.Keyed.place_correct_iff' depends on axioms: [propext, Classical.choice, Quot.sound]
'LeanUI.Proofs.Keyed.plan_moves_fewest' depends on axioms: [propext, Classical.choice, Quot.sound]
'LeanUI.Proofs.Keyed.lis_spec' depends on axioms: [propext, Classical.choice, Quot.sound]
'LeanUI.Proofs.Keyed.lis_valid' depends on axioms: [propext, Quot.sound]
'LeanUI.Proofs.Keyed.lis_longest' depends on axioms: [propext, Quot.sound]
```

The field lemmas (`plan_src_some`, `plan_src_inj`, `mem_plan_removed_iff`,
`plan_removed_sorted`, `plan_create_moves`, `plan_keeps_most`) report the same three axioms.

## 3. How the proofs go

**Placement** (`Inv`, `inv_step`). Once positions `s … n-1` are done, the list is `P ++ Q` where
`P` contains no finished key, the finished keys `new[s:]` appear in `Q` in order (possibly with
unvisited keys between them), and the stable keys below `s` are still a sublist of `P`. A moving
step lifts `new[s-1]` out and drops it right before the first finished key, which is the anchor;
a stable step finds `new[s-1]` as the last stable key of `P` and moves the split point in front of
it. At `s = 0` nothing is unfinished, so `P = []` and `Q = new`.

**`lis` is valid.** The binary search returns a position whose left neighbour in `tails` has a
smaller value, so every predecessor link goes to a smaller index with a smaller value; walking the
links back from the last tail gives an increasing subsequence. This part needs no sortedness.

**`lis` is longest.** On top of validity the scan keeps three invariants (`ScanBest`): the values
at `tails` strictly increase, so the binary search returns the exact lower bound
(`lisSearch_exact`); for every strictly increasing subsequence of the prefix seen so far, of
length `k+1` and ending in value `v`, `tails` has an entry at `k` whose value is at most `v`; and
the chain of predecessor links from `tails[k]` has `k+1` entries, so the walk back from the last
tail is exactly `tails.size` long.

**Fewest moves.** By the converse, the positions any correct plan leaves alone carry keys that
appear in old order; their old indices form a strictly increasing subsequence of the reused old
indices, which `lis` beats.

**Code shape.** `while` loops elaborate to `repeatM`, a fixpoint that is awkward to reason about,
so the planner is written with structural and well-founded recursion, which gives every loop its
own induction principle: `lisSearch` (binary search, by `hi - lo`), `lisScan` (by
`xs.size - i`), `lisWalk` (by fuel), `keyIndex` (`Nat.fold`), `markUsed` and `markStable`
(`Array.foldl`), and `applyList` (a `foldr`). The proofs use functional induction
(`fun_induction`) on them and only Lean core and `Std` lemmas.

## 4. What is tested, not proved

* **The diff uses the plan the way the model does.** `leanui-tests` drives keyed lists through
  the real runtime (`LeanUI.start`, `LeanUI.Diff`) under 400 random edits and checks the native
  DOM model (`LeanUI.Testing.Dom`) against the view after every edit, and checks
  `applyList old new (plan old new) = new.toList` on 20,000 random key lists.
* **Real browsers.** `tests/browser/keyed-dom.mjs` takes the command buffers the real runtime emits
  for 1,500 random keyed edits (`tests/KeyedDom.lean`, run natively), applies them with
  `runtime/leanui.js` in Chromium and Firefox, and checks independently of Lean, after every
  update, that the rows are in the model's order, that every surviving row is the same DOM node,
  and that the number of `insertBefore`/`appendChild` calls on the list is exactly
  `|new| - LIS(old positions of the kept rows)`. Measured on 2026-10-18 in Chromium 151 and
  Firefox 153: seed 1 (1,500 edits) gave 1,231 updates, 13,618 rows kept (each the same node) and
  6,496 insertions; seed 7 (4,000 edits) gave 3,334 updates, 38,819 rows kept and 19,259
  insertions; the insertions equal the minimum at every step. Replacing `insertBefore` by
  `appendChild` in the runtime makes the test fail at the first reorder. The wasm64 counter app
  built with the rewritten planner passes `tests/browser/counter.mjs` in both engines.
* **The rewrite against the previous planner** (commit `e49edac`, measured with a scratch harness):
  on 50,000 random pairs of key lists (random overlap, about a third with a sorted new list) both
  give the same `src`, the same `removed` and the same number of moves. Native timings, ms per
  plan:

  | n | edit | before | after |
  |---|---|---|---|
  | 10,000 | shuffle | 1.17 | 1.00–1.05 |
  | 100,000 | shuffle | 14.1 | 13.2 |
  | 100,000 | reverse | 6.75 | 6.59–6.67 |
  | 100,000 | swap two | 12.6 | 11.1–11.6 |
  | 100,000 | prepend 10 | 12.6 | 11.1–11.2 |

  Smaller lists (n = 1,000) are within noise (0.05–0.09 ms either way).

## 5. What is assumed

* **The DOM calls behave like `placeBefore`.** `parent.insertBefore(node, ref)` and
  `parent.appendChild(node)` first remove `node` from wherever it is, then insert it (the DOM
  standard's insert steps adopt the node, which removes it from its old parent), and `remove()`
  removes. The proofs model the children of one parent as a list of keys. The browser test above
  checks this in two engines.
* **`patchKids` follows `applyList`.** `LeanUI.Diff` is `partial` and writes a command buffer, so
  it is not part of the proofs. The correspondence, checked by reading the code and by the tests:
  the diff trims the common prefix and suffix and plans only the middle; it removes the nodes in
  `removed`; it visits the middle right to left; a moving child is inserted before the node at the
  next new position, which is already final, or appended when it is last. Because the prefix and
  suffix are never touched, inserting before the first suffix node is the model's "append to the
  middle". Created nodes are mounted and then inserted (`plan_create_moves` guarantees they have
  `move`). The diff only reaches `plan` when every child on both sides has a key and the keys
  are unique (`uniqueKeys`); otherwise it diffs by position. The trimmed middles of duplicate-free
  arrays are duplicate-free, which is what `h1` and `h2` ask.
* **In-range indexing is not a stated theorem.** Lean's logic reads `xs[i]!` as "the element, or
  a default", so the theorems hold whatever the accessors return out of range. The planner's
  indices are in range by construction, and the proofs establish the bounds they need (for
  example `lis_valid` gives `k < xs.size` for the positions looked up in `reusedPos`), but "the
  planner never falls back to a default" is not proved as a theorem of its own.
* **The usual trusted base**: the Lean kernel that checks the proofs, the Lean compiler and the C
  and wasm toolchains that turn the same definitions into the code that runs, and `Std.HashMap`
  (its lemmas are proofs, but its compiled implementation is trusted like any code).

## 6. Not covered

Positional diffing, attributes and listeners, `lazy` nodes, hydration, effects, and the rest of
the command protocol are outside these theorems; they are covered by the native harness
(`leanui-tests`) and the browser tests of the other lanes.
