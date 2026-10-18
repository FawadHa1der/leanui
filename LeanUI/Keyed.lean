module
public import Std.Data.HashMap
/-!
# Keyed reconciliation

Given the keys of the mounted children (`old`) and of the new children (`new`), `plan` decides,
for every new child, whether to reuse an old one or create one, which old children to remove, and
which new children must be (re)inserted. Children that are *stable* stay where they are: their old
positions form a longest increasing subsequence (LIS), so the fewest children move.

The browser applies a plan right to left: after removing `removed`, for `i = n-1 … 0`, a child
with `move[i]` is inserted before child `i+1` (or appended when `i` is last). Every other child is
already in place.

Everything here is written so it can be reasoned about: loops are structural or well-founded
recursion (no `partial`, no `while`), and `LeanUI.Proofs.Keyed` proves, with no `sorry` and only
the standard axioms, that

* `applyList old new (plan old new) = new.toList` whenever both key lists are duplicate-free;
* `src` points at the old child with the same key, and `removed` is exactly the unused old
  indices, in increasing order;
* `lis` returns a strictly increasing subsequence that is *longest*, so the plan moves the fewest
  children that any plan of this right-to-left shape can (`docs/PROOFS.md`).
-/
@[expose] public section
namespace LeanUI.Keyed

structure Plan where
  /-- For each new index: the reused old index, or `none` to create a node. -/
  src : Array (Option Nat)
  /-- Old indices that are not reused, in increasing order. -/
  removed : Array Nat
  /-- For each new index: must the node be inserted (created, or moved)? -/
  move : Array Bool
  deriving Repr, Inhabited

/-! ## Longest increasing subsequence (patience sorting, O(n log n)) -/

/-- Binary search in `tails[lo:hi]`: the first `k` with `xs[tails[k]] ≥ x`, or `hi` if there is
none. The values `xs[tails[k]]` increase with `k`, which makes this a lower bound. -/
def lisSearch (xs tails : Array Nat) (x lo hi : Nat) : Nat :=
  if lo < hi then
    let mid := (lo + hi) / 2
    if xs[tails[mid]!]! < x then lisSearch xs tails x (mid + 1) hi else lisSearch xs tails x lo mid
  else lo
termination_by hi - lo

/-- Patience sorting over `xs[i:]`. `tails[k]` is the index (into `xs`) of the smallest last value
of an increasing subsequence of length `k+1` among `xs[:i]`; `prev[j]` links index `j` to the
index before it in such a subsequence. -/
def lisScan (xs : Array Nat) (i : Nat) (tails : Array Nat) (prev : Array (Option Nat)) :
    Array Nat × Array (Option Nat) :=
  if h : i < xs.size then
    let x := xs[i]
    let lo := lisSearch xs tails x 0 tails.size
    let prev := if lo = 0 then prev else prev.set! i (some tails[lo - 1]!)
    let tails := if lo < tails.size then tails.set! lo i else tails.push i
    lisScan xs (i + 1) tails prev
  else (tails, prev)
termination_by xs.size - i

/-- Follow predecessor links from `cur` for at most `fuel` steps, prepending each index, so the
result comes out in increasing order. -/
def lisWalk (prev : Array (Option Nat)) : Nat → Option Nat → List Nat → List Nat
  | 0, _, acc => acc
  | _ + 1, none, acc => acc
  | fuel + 1, some j, acc => lisWalk prev fuel prev[j]! (j :: acc)

/-- Indices (into `xs`) of a longest strictly increasing subsequence, in increasing order. -/
def lis (xs : Array Nat) : Array Nat :=
  let (tails, prev) := lisScan xs 0 #[] (Array.replicate xs.size none)
  (lisWalk prev tails.size tails.back? []).toArray

/-! ## The plan -/

/-- The index of every old key: `old[j] ↦ j`. -/
def keyIndex (old : Array String) : Std.HashMap String Nat :=
  Nat.fold old.size (fun j h m => m.insert old[j] j) (Std.HashMap.emptyWithCapacity old.size)

/-- Set flag `j` when the entry is `some j`. -/
@[inline] def markSome (u : Array Bool) : Option Nat → Array Bool
  | some j => u.set! j true
  | none => u

/-- `n` flags; flag `j` is set when some entry of `src` is `some j`. -/
def markUsed (n : Nat) (src : Array (Option Nat)) : Array Bool :=
  src.foldl markSome (Array.replicate n false)

/-- `n` flags, all set except at the positions in `stable`. -/
def markStable (n : Nat) (stable : Array Nat) : Array Bool :=
  stable.foldl (fun m i => m.set! i false) (Array.replicate n true)

/-- The reconciliation plan. Keys must be unique within `old` and within `new` (the diff checks
this and falls back to positional diffing otherwise). -/
def plan (old new : Array String) : Plan :=
  let index := keyIndex old
  let src : Array (Option Nat) := new.map (index[·]?)
  let used := markUsed old.size src
  let removed := (Array.range old.size).filter fun j => !used[j]!
  -- positions (in `new`) of reused nodes, and their old indices
  let reusedPos := (Array.range new.size).filter fun i => (src[i]!).isSome
  let reusedOld := reusedPos.map fun i => (src[i]!).getD 0
  let stable := (lis reusedOld).map fun k => reusedPos[k]!
  { src, removed, move := markStable new.size stable }

/-! ## The list model the plan is proved against -/

/-- Insert `k` before `anchor` (or at the end if `anchor` is `none` or absent), after removing any
existing occurrence of `k`. This is what `insertBefore`/`appendChild` do to a child list. -/
def placeBefore (k : String) (anchor : Option String) (xs : List String) : List String :=
  let ys := xs.filter (· != k)
  match anchor with
  | none => ys ++ [k]
  | some a =>
    match ys.idxOf? a with
    | some i => ys.take i ++ k :: ys.drop i
    | none => ys ++ [k]

/-- Apply a plan to the old key list, exactly as the browser applies it to the DOM: drop the
removed children, then visit the new positions right to left (`i = n-1 … 0`, the same order as
`LeanUI.patchKids`), inserting each moved child before its successor `new[i+1]`. -/
def applyList (old new : Array String) (p : Plan) : List String :=
  let keep := (List.range old.size).filter fun j => !(p.removed.contains j)
  (List.range new.size).foldr (init := keep.map fun j => old[j]!) fun i xs =>
    if p.move[i]! then
      placeBefore new[i]! (if i + 1 < new.size then some new[i + 1]! else none) xs
    else xs

end LeanUI.Keyed
