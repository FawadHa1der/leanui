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
already in place. Correctness does **not** depend on the LIS being longest, only on the stable
positions being increasing; the LIS only minimises the number of moves. `LeanUI.Proofs.Keyed`
states and proves this on a list model (`applyList`).
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

/-- Indices (into `xs`) of a longest strictly increasing subsequence, in increasing order.
Patience sorting with predecessor links, O(n log n). -/
def lis (xs : Array Nat) : Array Nat := Id.run do
  if xs.isEmpty then return #[]
  -- tails[k] = index into xs of the smallest tail of an increasing subsequence of length k+1
  let mut tails : Array Nat := #[]
  let mut prev : Array (Option Nat) := Array.replicate xs.size none
  for i in [0:xs.size] do
    let x := xs[i]!
    -- binary search: first k with xs[tails[k]] >= x
    let mut lo := 0
    let mut hi := tails.size
    while lo < hi do
      let mid := (lo + hi) / 2
      if xs[tails[mid]!]! < x then lo := mid + 1 else hi := mid
    if lo > 0 then prev := prev.set! i (some tails[lo - 1]!)
    if lo == tails.size then tails := tails.push i else tails := tails.set! lo i
  -- walk back from the last tail
  let mut out : Array Nat := Array.mkEmpty tails.size
  let mut cur : Option Nat := some tails[tails.size - 1]!
  let mut fuel := tails.size
  while fuel > 0 do
    match cur with
    | none => fuel := 0
    | some j => out := out.push j; cur := prev[j]!; fuel := fuel - 1
  return out.reverse

/-- The reconciliation plan. Keys must be unique within `old` and within `new` (the diff checks
this and falls back to positional diffing otherwise). -/
def plan (old new : Array String) : Plan := Id.run do
  let mut index : Std.HashMap String Nat := Std.HashMap.emptyWithCapacity old.size
  for h : i in [0:old.size] do
    index := index.insert old[i] i
  let src : Array (Option Nat) := new.map index.get?
  let mut used : Array Bool := Array.replicate old.size false
  for o in src do
    if let some j := o then used := used.set! j true
  let removed := (Array.range old.size).filter fun j => !used[j]!
  -- positions (in `new`) of reused nodes, and their old indices
  let reusedPos := (Array.range new.size).filter fun i => (src[i]!).isSome
  let reusedOld := reusedPos.map fun i => (src[i]!).getD 0
  let stable := (lis reusedOld).map fun k => reusedPos[k]!
  let mut move : Array Bool := Array.replicate new.size true
  for i in stable do move := move.set! i false
  return { src, removed, move }

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

/-- Apply a plan to the old key list, exactly as the browser applies it to the DOM. -/
def applyList (old new : Array String) (p : Plan) : List String := Id.run do
  let keep := (List.range old.size).filter fun j => !(p.removed.contains j)
  let mut xs := keep.map fun j => old[j]!
  let mut i := new.size
  while i > 0 do
    i := i - 1
    if p.move[i]! then
      let anchor := if i + 1 < new.size then some new[i + 1]! else none
      xs := placeBefore new[i]! anchor xs
  return xs

end LeanUI.Keyed
