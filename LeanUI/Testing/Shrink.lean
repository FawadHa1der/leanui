module
public import LeanUI.Testing.Tree
/-!
# Shrinking failing cases

A failing case is an initial view and an edit sequence. `minimize` makes it small:

1. delta debugging (`ddmin`) over the edit sequence: a 1-minimal subsequence that still fails
   (every edit applies to every tree, so any subsequence is a valid case);
2. greedy tree shrinking of the initial view: delete a child, hoist a child into its parent's
   place, turn an element into a text, drop an attribute, unwrap a lazy node, empty a text;
3. the same for subtrees carried by `insert` and `replace` edits;

repeated until nothing changes or the evaluation budget runs out. `Case.toLean` prints the
views the minimized case goes through as Lean code, ready for a bug report.
-/
public section
namespace LeanUI.Testing

structure Case where
  t0 : T
  edits : Array Edit
  deriving Inhabited

def Case.views (c : Case) : Array T := c.edits.foldl (fun vs e => vs.push (e.apply vs.back!)) #[c.t0]

def Case.weight (c : Case) : Nat := c.t0.size + c.edits.size * 4

/-- One-step-smaller variants of a tree, biggest reductions first. -/
partial def T.shrinks : T → Array T
  | .text s => if s.isEmpty then #[] else if s.length > 1 then #[.text "", .text (String.ofList [s.front])] else #[.text ""]
  | .lazy pin b => #[b] ++ (b.shrinks.map fun b' => .lazy pin b')
  | .elem ns tag attrs kids =>
    let dropKid := (Array.range kids.size).map fun i => T.elem ns tag attrs (kids.eraseIdxIfInBounds i)
    let hoist := kids.filter fun k => match k.force with | .elem .. => true | _ => false
    let clear := if kids.size > 1 then #[T.elem ns tag attrs #[]] else #[]
    let dropAttr := (Array.range attrs.size).map fun i => T.elem ns tag (attrs.eraseIdxIfInBounds i) kids
    let inner := (Array.range kids.size).foldl (init := #[]) fun acc i =>
      acc ++ (kids[i]!.shrinks.map fun k => T.elem ns tag attrs (kids.set! i k))
    clear ++ dropKid ++ hoist ++ dropAttr ++ inner

/-- `ddmin`: a 1-minimal subsequence of `xs` on which `fails` holds (assuming it holds on `xs`). -/
partial def ddmin {α : Type} (fails : Array α → IO Bool) (xs : Array α) : IO (Array α) := do
  if xs.isEmpty then return xs
  if ← fails #[] then return #[]
  let rec go (xs : Array α) (n : Nat) : IO (Array α) := do
    if xs.size ≤ 1 then return xs
    let chunk := (xs.size + n - 1) / n
    let parts := ((List.range n).map fun i => xs.extract (i * chunk) ((i + 1) * chunk)).filter (!·.isEmpty)
    for p in parts do
      if ← fails p then return ← go p 2
    if parts.length > 2 then
      for i in [0:parts.length] do
        let comp := (parts.eraseIdx i).foldl (· ++ ·) #[]
        if ← fails comp then return ← go comp (max (n - 1) 2)
    if n < xs.size then go xs (min (2 * n) xs.size) else return xs
  go xs 2

/-- Greedy: take the first smaller variant that still fails, until none does. -/
partial def shrinkTree (fails : T → IO Bool) (t : T) (budget : IO.Ref Nat) : IO T := do
  let rec loop (t : T) : IO T := do
    for c in t.shrinks do
      if (← budget.get) == 0 then return t
      budget.modify (· - 1)
      if ← fails c then return ← loop c
    return t
  loop t

def Edit.sub? : Edit → Option T
  | .insert _ _ s | .replace _ s => some s
  | _ => none

def Edit.withSub (e : Edit) (s : T) : Edit :=
  match e with
  | .insert p i _ => .insert p i s
  | .replace p _ => .replace p s
  | e => e

/-- Make a failing case small (see the module doc). `fails` must hold on `c`. -/
partial def minimize (fails : Case → IO Bool) (c : Case) (evals : Nat := 4000) : IO Case := do
  let budget ← IO.mkRef evals
  let counted (f : Case → IO Bool) (x : Case) : IO Bool := do
    if (← budget.get) == 0 then return false
    budget.modify (· - 1); f x
  let mut c := c
  for _ in [0:4] do
    let before := c.weight
    let es ← ddmin (fun es => counted fails { c with edits := es }) c.edits
    c := { c with edits := es }
    let t ← shrinkTree (fun t => fails { c with t0 := t }) c.t0 budget
    c := { c with t0 := t }
    for i in [0:c.edits.size] do
      if let some sub := c.edits[i]!.sub? then
        let s ← shrinkTree (fun s => fails { c with edits := c.edits.set! i (c.edits[i]!.withSub s) }) sub budget
        c := { c with edits := c.edits.set! i (c.edits[i]!.withSub s) }
    if c.weight == before || (← budget.get) == 0 then break
  return c

/-- The minimized case as Lean code: every view it goes through, and the edits between them. -/
def Case.toLean (c : Case) : String := Id.run do
  let vs := c.views
  let mut out := s!"-- {c.edits.size} edit(s), initial view of {c.t0.size} node(s)\n"
  for h : i in [0:vs.size] do
    if i > 0 then out := out ++ s!"-- edit: {c.edits[i - 1]!.toLean}\n"
    out := out ++ s!"def v{i} : Html String :=\n  {vs[i].toLean 2}\n"
  return out

end LeanUI.Testing
