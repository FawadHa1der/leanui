module
public import LeanUI.Html
public import LeanUI.Patch
public import LeanUI.Keyed
/-!
# Mounting and diffing

`mount` turns a view into commands that build it; `patch` compares a mounted node with a new view
and emits only the changes. Both run in `DiffM`, a pure state monad over `DiffState`, so the whole
engine is testable natively (`LeanUI.Testing`) and the same code runs in the browser and on a
server.

Handles (DOM nodes) and slots (event handlers) are allocated by Lean from free lists, so a long
session reuses them instead of growing. Listener slots are what the browser reports back: an
event on a node carrying slot `s` calls `handlerOf s`.
-/
public section
namespace LeanUI

/-- A mounted node: the view it came from, its handle, its key and its size (both cached), and its
listener slots. `size` counts the DOM nodes (elements and texts) of the subtree. -/
inductive Node (Msg : Type) where
  | text (h : UInt32) (s : String)
  | elem (h : UInt32) (ns : Ns) (tag : String) (key : Option String) (attrs : Array (Attr Msg))
      (listeners : Array (String × UInt32)) (kids : Array (Node Msg)) (size : Nat)
  | lazy (key : Option String) (deps : Dep) (inner : Node Msg)

instance : Inhabited (Node Msg) := ⟨.text 0 ""⟩

namespace Node
def handle : Node Msg → UInt32
  | .text h _ => h
  | .elem h .. => h
  | .lazy _ _ n => n.handle
def key? : Node Msg → Option String
  | .elem _ _ _ k .. => k
  | .lazy k _ _ => k
  | _ => none
/-- Number of DOM nodes (elements and texts) in the subtree (cached in elements). -/
def size : Node Msg → Nat
  | .text .. => 1
  | .elem _ _ _ _ _ _ _ s => s
  | .lazy _ _ n => n.size

/-- The size of an element with these children. -/
@[inline] def sizeOf (kids : Array (Node Msg)) : Nat := kids.foldl (fun n k => n + k.size) 1
end Node

/-- How a template holds an element's attributes, and what a clone re-sends (`attrMode`). -/
inductive AttrMode where
  /-- The template holds the attributes before the first property; a clone re-sets those whose
  value differs from the template's. -/
  | values
  /-- As `values`, but the values are part of the shape: a clone never re-sets one. -/
  | exact
  /-- The template holds none; a clone gets every attribute, in view order, as a mount does. -/
  | bare
  deriving BEq, Inhabited

/-- What a template fixes about a subtree (`docs/PROTOCOL.md`, section 7): namespaces and tags,
each element's attribute names (in order), property names (in order), where its first property
comes (`pre`: the number of attributes before it) and its `AttrMode`, and the tree's structure.
The template's own attribute values and texts are kept, so a clone only re-sends those that
differ. Listeners and keys are not part of a shape. -/
inductive TplShape where
  | text (s : String)
  | elem (ns : Ns) (tag : String) (attrs : Array (String × String)) (props : Array String) (pre : Nat)
      (mode : AttrMode) (kids : Array TplShape)
  deriving Inhabited

/-- The templates of a session (`mountShape`). -/
structure TplState where
  /-- Hashes of shapes seen once (cleared when it reaches `tplSeenLimit`). -/
  seen : Std.HashMap UInt64 Unit := {}
  /-- Shape hash → template id. -/
  ids : Std.HashMap UInt64 UInt32 := {}
  /-- The shape of template `i + 1`, and its number of nodes. -/
  shapes : Array TplShape := #[]
  sizes : Array Nat := #[]
  /-- The template made or cloned last (0: none): the first one tried, so the rows of a list
  that share a shape cost one comparison each instead of counting and hashing. -/
  last : UInt32 := 0

structure DiffState (Msg : Type) where
  buf : Buf := {}
  nextNode : UInt32 := 1
  freeNodes : Array UInt32 := #[]
  /-- Slot `s` holds the handler the browser's slot `s` stands for. Slot 0 is never used. -/
  slots : Array (Option (Handler Msg)) := #[none]
  freeSlots : Array UInt32 := #[]
  /-- While hydrating, `mount` claims existing DOM nodes in pre-order instead of creating them. -/
  hydrating : Bool := false
  /-- Create repeated subtrees by cloning a template (`mountShape`). Off: every node is created
  by its own commands (the tests compare both). -/
  templates : Bool := true
  tpl : TplState := {}

abbrev DiffM (Msg : Type) := StateM (DiffState Msg)

variable {Msg : Type}

@[inline] def emit (f : Buf → Buf) : DiffM Msg Unit := modify fun s => { s with buf := f s.buf }

def allocNode : DiffM Msg UInt32 := modifyGet fun s =>
  if s.hydrating || s.freeNodes.isEmpty then (s.nextNode, { s with nextNode := s.nextNode + 1 })
  else (s.freeNodes.back!, { s with freeNodes := s.freeNodes.pop })

def allocSlot (h : Handler Msg) : DiffM Msg UInt32 := modifyGet fun s =>
  if s.freeSlots.isEmpty then (s.slots.size.toUInt32, { s with slots := s.slots.push (some h) })
  else
    let i := s.freeSlots.back!
    (i, { s with freeSlots := s.freeSlots.pop, slots := s.slots.set! i.toNat (some h) })

@[inline] def setSlot (i : UInt32) (h : Handler Msg) : DiffM Msg Unit :=
  modify fun s => { s with slots := s.slots.set! i.toNat (some h) }

def freeSlot (i : UInt32) : DiffM Msg Unit :=
  modify fun s => { s with slots := s.slots.set! i.toNat none, freeSlots := s.freeSlots.push i }

@[noinline] private def freeNodeS (s : DiffState Msg) (h : UInt32) : DiffState Msg :=
  { s with buf := s.buf.free h, freeNodes := s.freeNodes.push h }

@[noinline] private def freeSlotS (s : DiffState Msg) (i : UInt32) : DiffState Msg :=
  { s with slots := s.slots.set! i.toNat none, freeSlots := s.freeSlots.push i }

/-- `release` in state-passing style: no allocation per node (in `DiffM`, every `for` iteration
and every call returns a fresh pair). Children first, then the element's slots, then its handle. -/
partial def releaseS : Node Msg → DiffState Msg → DiffState Msg
  | .text h _, s => freeNodeS s h
  | .elem h _ _ _ _ ls kids _, s =>
    let s := kids.foldl (fun s k => releaseS k s) s
    freeNodeS (ls.foldl (fun s l => freeSlotS s l.2) s) h
  | .lazy _ _ n, s => releaseS n s

/-- Forget a whole mounted subtree: free its handles and slots. The caller detaches its root. -/
@[inline] def release (n : Node Msg) : DiffM Msg Unit := fun s => ((), releaseS n s)

/-! ## State passing

`DiffM` is `StateM`, so every call that is not inlined and every iteration of a `for` loop
returns a freshly allocated pair. The paths that run once per created or removed node (mounting,
cloning, releasing) are written in plain state-passing style instead: functions
`DiffState Msg → DiffState Msg`, or returning one pair at the end. Lean 4.34's compiler allocates
a new state cell wherever two branches that update the state differently meet again inside one
function (it passes the fields to the join point), and returns an inline helper's pair as an
object, so each update below is its own small `@[noinline]` function that returns the reused
cell, and what an update hands out (a handle, a slot) is read first by a separate `peek`. -/

/-- The listener table of an element without listeners, and the children of a childless
element: shared constants. A `#[]` in an argument position is allocated where it is written,
once per element (`testSharedEmpty` pins both). -/
@[noinline] def noListeners : Array (String × UInt32) := #[]
@[noinline] def noKids : Array (Node Msg) := #[]

@[noinline] private def bumpNode (s : DiffState Msg) : DiffState Msg := { s with nextNode := s.nextNode + 1 }
@[noinline] private def popNode (s : DiffState Msg) : DiffState Msg := { s with freeNodes := s.freeNodes.pop }

/-- The handle `allocNode` would return. -/
@[inline] private def peekNode (s : DiffState Msg) : UInt32 :=
  if s.hydrating || s.freeNodes.isEmpty then s.nextNode else s.freeNodes.back!

/-- Take the handle `peekNode` names (each way is its own function, see above). -/
@[inline] private def takeNode (s : DiffState Msg) : DiffState Msg :=
  if s.hydrating || s.freeNodes.isEmpty then bumpNode s else popNode s

/-- Node `i` of `n` handles taken in a row (`takeNodes`; never while hydrating), the order `n`
calls of `allocNode` take them in: the free list `fs` from its end, then fresh ones from
`next`. -/
@[inline] private def handleAt (fs : Array UInt32) (next : UInt32) (i : Nat) : UInt32 :=
  if h : i < fs.size then fs[fs.size - 1 - i]'(by omega) else next + (i - fs.size).toUInt32

/-- Take the `n` handles `handleAt` names. -/
@[noinline] private def takeNodes (s : DiffState Msg) (n : Nat) : DiffState Msg :=
  let f := s.freeNodes.size
  { s with freeNodes := s.freeNodes.shrink (f - n), nextNode := s.nextNode + (n - f).toUInt32 }

@[noinline] private def pushSlot (s : DiffState Msg) (hd : Handler Msg) : DiffState Msg :=
  { s with slots := s.slots.push (some hd) }
@[noinline] private def reuseSlot (s : DiffState Msg) (hd : Handler Msg) : DiffState Msg :=
  let i := s.freeSlots.back!   -- read before the pop, which then updates the array in place
  { s with freeSlots := s.freeSlots.pop, slots := s.slots.set! i.toNat (some hd) }

/-- The slot the `k`-th `allocSlot` from here would return: the free slots from the end, then
new ones. -/
@[inline] private def peekSlotAt (s : DiffState Msg) (k : Nat) : UInt32 :=
  let f := s.freeSlots.size
  if h : k < f then s.freeSlots[f - 1 - k]'(by omega) else (s.slots.size + (k - f)).toUInt32

/-- Take the next slot (`peekSlotAt s 0`), for `hd`. -/
@[inline] private def takeSlot (s : DiffState Msg) (hd : Handler Msg) : DiffState Msg :=
  if s.freeSlots.isEmpty then pushSlot s hd else reuseSlot s hd

-- the commands of a fresh node (none while hydrating: the node exists)
@[noinline] private def emitCreateText (s : DiffState Msg) (h : UInt32) (t : String) : DiffState Msg :=
  if s.hydrating then s else { s with buf := s.buf.createText h t }
@[noinline] private def emitCreateElement (s : DiffState Msg) (h : UInt32) (ns : Ns) (tag : String) : DiffState Msg :=
  if s.hydrating then s else { s with buf := s.buf.createElement h ns tag }
@[noinline] private def emitAppend (s : DiffState Msg) (p c : UInt32) : DiffState Msg :=
  if s.hydrating then s else { s with buf := s.buf.appendChild p c }

@[noinline] private def emitAppendChild (s : DiffState Msg) (p c : UInt32) : DiffState Msg :=
  { s with buf := s.buf.appendChild p c }
@[noinline] private def emitReplace (s : DiffState Msg) (old new : UInt32) : DiffState Msg :=
  { s with buf := s.buf.replace old new }
@[noinline] private def emitInsertBefore (s : DiffState Msg) (p c r : UInt32) : DiffState Msg :=
  { s with buf := s.buf.insertBefore p c r }
@[noinline] private def emitSetText (s : DiffState Msg) (h : UInt32) (t : String) : DiffState Msg :=
  { s with buf := s.buf.setText h t }
@[noinline] private def emitSetAttr (s : DiffState Msg) (h : UInt32) (n v : String) : DiffState Msg :=
  { s with buf := s.buf.setAttr h n v }
@[noinline] private def emitSetProp (s : DiffState Msg) (h : UInt32) (n : String) (v : PropValue) : DiffState Msg :=
  { s with buf := s.buf.setProp h n v }
@[noinline] private def emitListener (s : DiffState Msg) (h : UInt32) (ev : String) (sl : UInt32)
    (hd : Handler Msg) : DiffState Msg :=
  { s with buf := s.buf.setListener h ev sl hd.payload hd.flags }

/-- A repeated listener for one event: the last one wins, in the slot the first one took. -/
@[noinline] private def resetListener (s : DiffState Msg) (h : UInt32) (ev : String) (sl : UInt32)
    (hd : Handler Msg) : DiffState Msg :=
  { s with slots := s.slots.set! sl.toNat (some hd), buf := s.buf.setListener h ev sl hd.payload hd.flags }

/-- One attribute or property of a fresh element (attributes are in the HTML when hydrating). -/
@[noinline] private def emitAttr (s : DiffState Msg) (h : UInt32) : Attr Msg → DiffState Msg
  | .attr n v => if s.hydrating then s else { s with buf := s.buf.setAttr h n v }
  | .prop n v => { s with buf := s.buf.setProp h n v }
  | _ => s

/-- The first `key` attribute from `i` on (a plain loop: no `Option` per attribute). -/
def attrsKeyFrom (attrs : Array (Attr Msg)) (i : Nat) : Option String :=
  if h : i < attrs.size then
    match attrs[i] with
    | .key k => some k
    | _ => attrsKeyFrom attrs (i + 1)
  else none
termination_by attrs.size - i

/-- The `key` attribute, if any (scanned once per node). -/
@[inline] def attrsKey (attrs : Array (Attr Msg)) : Option String := attrsKeyFrom attrs 0

/-- The key of a view node (a lazy node carries its own, so it is read without rendering). -/
@[inline] def viewKey : Html Msg → Option String
  | .elem _ _ attrs _ => attrsKey attrs
  | .lazy k _ _ => k
  | _ => none

/-! ## Attributes -/

private def sameShape (a b : Attr Msg) : Bool :=
  match a, b with
  | .attr n _, .attr m _ => n == m
  | .prop n _, .prop m _ => n == m
  | .on e _, .on f _ => e == f
  | .key _, .key _ => true
  | _, _ => false

/-- Is `as[i]` overridden by a later attribute of the same kind and name? The last one is the one
the DOM shows (`setAttribute` keeps the last value), so the earlier ones are never sent. -/
private def shadowed (as : Array (Attr Msg)) (i : Nat) : Bool := Id.run do
  let a := as[i]!
  for j in [i + 1:as.size] do
    if sameShape a as[j]! then return true
  return false

-- the value the DOM shows: the last attribute of that name
private def findAttr (n : String) (as : Array (Attr Msg)) : Option String :=
  as.findSomeRev? fun | .attr m v => if m == n then some v else none | _ => none
private def findProp (n : String) (as : Array (Attr Msg)) : Option PropValue :=
  as.findSomeRev? fun | .prop m v => if m == n then some v else none | _ => none
private def findOn (e : String) (as : Array (Attr Msg)) : Option (Handler Msg) :=
  as.findSomeRev? fun | .on f hd => if f == e then some hd else none | _ => none

/-- Update one listener in place: same event, so keep the slot and swap the handler; re-send the
listener only if what the browser extracts or does changed (and report that as a change). -/
private def updateListener (h : UInt32) (ev : String) (sl : UInt32) (old new : Handler Msg) : DiffM Msg Bool := do
  setSlot sl new
  if old.payload != new.payload || old.flags != new.flags then
    emit (·.setListener h ev sl new.payload new.flags); return true
  return false

/-- Diff attributes. Returns the listener table and whether anything other than a handler's
message changed; when nothing did, the caller keeps the old attribute array (handlers live in
their slots, and only payload and flags are ever compared). -/
def patchAttrs (h : UInt32) (old : Array (Attr Msg)) (ls : Array (String × UInt32))
    (new : Array (Attr Msg)) : DiffM Msg (Array (String × UInt32) × Bool) := do
  let n := old.size
  let mut same := n == new.size
  let mut k := 0
  while same && k < n do
    same := sameShape old[k]! new[k]!
    k := k + 1
  if same then
    -- fast path: same attributes in the same order, so the same ones are shadowed on both sides.
    -- A shadowed (overridden) attribute is never sent, but any difference counts as a change,
    -- so the stored attributes always equal the last view's.
    let mut changed := false
    for j in [0:n] do
      match old[j]!, new[j]! with
      | .attr _ v, .attr nm w =>
        if v != w then
          changed := true
          if !shadowed new j then emit (·.setAttr h nm w)
      | .prop _ v, .prop nm w =>
        if v != w then
          changed := true
          if !shadowed new j then emit (·.setProp h nm w)
      | .on ev ho, .on _ hn =>
        if !shadowed new j then
          match ls.find? (·.1 == ev) with
          | some (_, sl) => if ← updateListener h ev sl ho hn then changed := true
          | none => pure ()
        else if ho.payload != hn.payload || ho.flags != hn.flags then changed := true
      | .key a, .key b => if a != b then changed := true
      | _, _ => pure ()
    return (ls, changed)
  -- general path: attribute lists are short, so linear scans
  for i in [0:old.size] do
    if shadowed old i then continue
    match old[i]! with
    | .attr n _ => if (findAttr n new).isNone then emit (·.removeAttr h n)
    | .prop n _ => if (findProp n new).isNone then emit (·.removeProp h n)
    | _ => pure ()
  for i in [0:new.size] do
    if shadowed new i then continue
    match new[i]! with
    | .attr n w => if findAttr n old != some w then emit (·.setAttr h n w)
    | .prop n w => if findProp n old != some w then emit (·.setProp h n w)
    | _ => pure ()
  let mut out := #[]
  for (ev, sl) in ls do
    match findOn ev new, findOn ev old with
    | some hn, some ho => let _ ← updateListener h ev sl ho hn; out := out.push (ev, sl)
    | some hn, none => setSlot sl hn; out := out.push (ev, sl)
    | none, _ => emit (·.removeListener h ev); freeSlot sl
  for i in [0:new.size] do
    match new[i]! with
    | .on ev hd =>
      if !shadowed new i && !(out.any (·.1 == ev)) then
        let sl ← allocSlot hd
        emit (·.setListener h ev sl hd.payload hd.flags)
        out := out.push (ev, sl)
    | _ => pure ()
  -- the attribute list changed shape: always store the new one
  return (out, true)

/-! ## Unchanged subtrees

Most of a re-render is unchanged. `sameF` decides, purely and without allocating, that showing a
view where a node is mounted needs no command at all; `rebind` then re-points the subtree's
listener slots at the new handlers (their messages may differ even when nothing visible does).
The diff consults this before doing any monadic work, so an unchanged subtree costs comparisons
and one state update, and returns the *same* mounted node. -/

/-- Pure attribute equality, exactly as `patchAttrs` judges it: names and values, listener
events, payloads and flags (never the handlers' messages), keys. -/
@[inline] private def attrEq : Attr Msg → Attr Msg → Bool
  | .attr n v, .attr m w => n == m && v == w
  | .prop n v, .prop m w => n == m && v == w
  | .on e h, .on f g => e == f && h.payload == g.payload && h.flags == g.flags
  | .key a, .key b => a == b
  | _, _ => false

private def attrsSame (a b : Array (Attr Msg)) (i : Nat := 0) : Bool :=
  if h : i < a.size then
    if h' : i < b.size then attrEq a[i] b[i] && attrsSame a b (i + 1) else false
  else true
termination_by a.size - i

/-- The slot of the first listener for `ev` (0, never a real slot, if none). -/
def slotOf (ls : Array (String × UInt32)) (ev : String) (i : Nat := 0) : UInt32 :=
  if h : i < ls.size then (if ls[i].1 == ev then ls[i].2 else slotOf ls ev (i + 1)) else 0
termination_by ls.size - i

/-- How many nodes one `sameF` call may look at. Bounding it keeps re-checking linear: a subtree
too big to check in one go is patched node by node and its children are checked instead, so no
node is examined by more than one failed check per patched ancestor within this budget. -/
def sameBudget : Nat := 256

mutual
/-- `sameF f n v` is 0 if showing `v` where `n` is mounted needs a command, or if deciding that
would take more than `f` nodes; otherwise the fuel left (at least 1). -/
partial def sameF (f : Nat) (n : Node Msg) (v : Html Msg) : Nat :=
  if f ≤ 1 then 0 else
  match n, v with
  | .text _ s, .text t => if s == t then f - 1 else 0
  | .lazy k d _, .lazy k' e _ => if k == k' && d == e then f - 1 else 0
  | .elem _ ns tag _ attrs _ kids _, .elem ns' tag' attrs' kids' =>
    -- a void element was mounted without the children its view may name
    let kids' := if kids.size == kids'.size then kids' else effectiveKids tag kids'
    if ns == ns' && tag == tag' && kids.size == kids'.size && attrs.size == attrs'.size &&
        attrsSame attrs attrs' then
      kidsSameF (f - 1) kids kids' 0
    else 0
  | _, _ => 0

partial def kidsSameF (f : Nat) (ks : Array (Node Msg)) (vs : Array (Html Msg)) (i : Nat) : Nat :=
  if f == 0 then 0
  else if i < ks.size then kidsSameF (sameF f ks[i]! vs[i]!) ks vs (i + 1)
  else f
end

mutual
/-- Re-point the listener slots of an unchanged subtree (`sameF` succeeded) at the new view's
handlers, in the order `patchAttrs` would. Lazy subtrees with equal dependencies keep theirs. -/
partial def rebind (sl : Array (Option (Handler Msg))) : Node Msg → Html Msg → Array (Option (Handler Msg))
  | .elem _ _ tag _ _ ls kids _, .elem _ _ attrs' kids' =>
    let kids' := if kids.size == kids'.size then kids' else effectiveKids tag kids'
    let sl := attrs'.foldl (init := sl) fun sl a => match a with
      | .on ev hn => let s := slotOf ls ev; if s == 0 then sl else sl.set! s.toNat (some hn)
      | _ => sl
    rebindKids sl kids kids' 0
  | _, _ => sl

partial def rebindKids (sl : Array (Option (Handler Msg))) (ks : Array (Node Msg)) (vs : Array (Html Msg))
    (i : Nat) : Array (Option (Handler Msg)) :=
  if i < ks.size && i < vs.size then rebindKids (rebind sl ks[i]! vs[i]!) ks vs (i + 1) else sl
end

/-- Is showing `v` where `n` is mounted command-free? Only subtrees within the budget are checked
(their size is cached), so a check never runs out of fuel and each node is examined by the checks
of at most `sameBudget` ancestors: re-checking stays linear however deep the tree. -/
@[inline] def unchanged (n : Node Msg) (v : Html Msg) : Bool :=
  n.size < sameBudget && sameF sameBudget n v != 0

/-- First index `j ≥ i` whose child is not unchanged (or `old.size`). -/
private partial def runSame (old : Array (Node Msg)) (new : Array (Html Msg)) (i : Nat) : Nat :=
  if i < old.size && i < new.size && unchanged old[i]! new[i]! then runSame old new (i + 1) else i

private partial def rebindRange (sl : Array (Option (Handler Msg))) (old : Array (Node Msg))
    (new : Array (Html Msg)) (i j : Nat) : Array (Option (Handler Msg)) :=
  if i < j then rebindRange (rebind sl old[i]! new[i]!) old new (i + 1) j else sl

/-- Does mounted `n` carry the key that view `v` asks for? (No allocation.) -/
private def firstKeyIs (attrs : Array (Attr Msg)) (k : String) (i : Nat := 0) : Bool :=
  if h : i < attrs.size then
    match attrs[i] with
    | .key k' => k' == k
    | _ => firstKeyIs attrs k (i + 1)
  else false
termination_by attrs.size - i

private def keyIs (n : Node Msg) (v : Html Msg) : Bool :=
  match n.key?, v with
  | some k, .elem _ _ attrs _ => firstKeyIs attrs k
  | some k, .lazy (some k') _ _ => k == k'
  | _, _ => false

/-- Every child pair carries the same key, in order. -/
private partial def keysAligned (old : Array (Node Msg)) (new : Array (Html Msg)) (i : Nat) : Bool :=
  if i < old.size && i < new.size then keyIs old[i]! new[i]! && keysAligned old new (i + 1) else true

/-! ## Templates

Most created DOM comes from lists whose rows share one shape. The second time a subtree of a
shape is mounted, it is built as a *prototype* first: its elements and texts, and each element's
attributes up to its first property, which is all a mount has done to an element before it sets
a property or a listener (an `input` gets none, `AttrMode.bare`). That DOM becomes the template
(`TEMPLATE`), and the subtree is then finished like every later one of its shape: those are
created with one `CLONE` (one `cloneNode(true)` in the browser) plus what a clone lacks: the
texts and attribute values that differ from the template's, then, element by element and in view
order, every property, every listener and the attributes that follow the first property. So each
element of a clone gets, from the point where a mount sets its first property on, exactly the
commands a mount sends it, starting from the same state; a property that reflects onto an
attribute, or a guard that skips a property already equal, sees what it would see in a mount.
Hashing and matching walk the view without allocating; a stored `TplShape` is compared exactly,
so a hash collision never clones the wrong thing.

Policy: element subtrees of `tplMin`..`tplMax` DOM nodes, without `lazy` nodes (mounting would
force them) and without properties on elements that have children (mount sets properties before
the children exist, a clone after: `select.value`, `textContent`), never while hydrating, at most
`tplLimit` templates per session. Candidates are the children `patchKids` mounts, and the
children of an element with at least two that have a neighbouring sibling of their kind (the same
tag, or both lazy): the rows of a list. A `[label, sublist]` pair or a chain of single children is
never hashed, so mounting a deep tree stays linear. -/

def tplMin : Nat := 4
def tplMax : Nat := 64
def tplLimit : Nat := 256
def tplSeenLimit : Nat := 4096

mutual
/-- Fuel left after counting the DOM nodes of `v` (void elements get no children); 0 when that
takes more than `f`, or when `v` holds a lazy node. -/
partial def shapeFuel (f : Nat) (v : Html Msg) : Nat :=
  if f == 0 then 0 else
  match v with
  | .text _ => f - 1
  | .elem _ tag _ kids => kidsFuel (f - 1) (effectiveKids tag kids) 0
  | .lazy .. => 0

partial def kidsFuel (f : Nat) (ks : Array (Html Msg)) (i : Nat) : Nat :=
  if f == 0 then 0 else if h : i < ks.size then kidsFuel (shapeFuel f ks[i]) ks (i + 1) else f
end

/-- Does an attribute name repeat? (Linear scans: attribute lists are short.) -/
private def dupAttr (attrs : Array (Attr Msg)) (i : Nat := 0) : Bool :=
  if hi : i < attrs.size then
    match attrs[i] with
    | .attr n _ =>
      (attrs.extract (i + 1) attrs.size).any (fun | .attr m _ => m == n | _ => false) || dupAttr attrs (i + 1)
    | _ => dupAttr attrs (i + 1)
  else false
termination_by attrs.size - i

/-- How a template holds an element's attributes. An `input` is `bare`: its value and checkedness
follow its attributes through a history (sanitization against `min`/`max` set later, type
changes), which `cloneNode` does not replay the way a mount's attribute-by-attribute sequence
does, so every copy gets its attributes one by one. `exact`: other form controls, elements that
load or run something when an attribute is set (a clone would start with the template's
resource), custom elements (`attributeChangedCallback`), and elements that repeat an attribute
name. Elsewhere an attribute does nothing but hold its value, so a clone re-sets the values that
differ from the template's. -/
def attrMode (ns : Ns) (tag : String) (attrs : Array (Attr Msg)) : AttrMode :=
  match ns with
  | .html =>
    if tag == "input" then .bare
    else if tag == "select" || tag == "textarea" || tag == "option" || tag == "img" || tag == "source" ||
        tag == "video" || tag == "audio" || tag == "track" || tag == "iframe" || tag == "embed" ||
        tag == "object" || tag == "script" || tag == "link" || tag == "style" || tag.contains '-' ||
        dupAttr attrs then .exact
    else .values
  | .svg =>
    if tag == "image" || tag == "use" || tag == "script" || tag == "feImage" || dupAttr attrs then .exact
    else .values
  | .mathml => if dupAttr attrs then .exact else .values

@[inline] private def mixStr (h : UInt64) (s : String) : UInt64 := mixHash h (hash s)

private def attrsHash (h : UInt64) (exact : Bool) (attrs : Array (Attr Msg)) (i : Nat := 0) : UInt64 :=
  if hi : i < attrs.size then
    match attrs[i] with
    | .attr n v => attrsHash (let h := mixStr (mixHash h 3) n; if exact then mixStr h v else h) exact attrs (i + 1)
    | .prop n _ => attrsHash (mixStr (mixHash h 5) n) exact attrs (i + 1)
    | _ => attrsHash h exact attrs (i + 1)
  else h
termination_by attrs.size - i

private def hasProp (attrs : Array (Attr Msg)) (i : Nat := 0) : Bool :=
  if hi : i < attrs.size then
    match attrs[i] with
    | .prop .. => true
    | _ => hasProp attrs (i + 1)
  else false
termination_by attrs.size - i

mutual
/-- The shape hash of a view (no allocation); 0: not templatable (a lazy node, or a property on an
element with children). The position of the first property is implied by the names in order. -/
partial def shapeHash (h : UInt64) (v : Html Msg) : UInt64 :=
  match v with
  | .text _ => mixHash h 1
  | .elem ns tag attrs kids =>
    let kids := effectiveKids tag kids
    if !kids.isEmpty && hasProp attrs then 0
    else
      let h := attrsHash (mixStr (mixHash h (2 + ns.code.toUInt64)) tag) (attrMode ns tag attrs == .exact) attrs
      kidsHash (mixHash h kids.size.toUInt64) kids 0
  | .lazy .. => 0

partial def kidsHash (h : UInt64) (ks : Array (Html Msg)) (i : Nat) : UInt64 :=
  if h == 0 then 0 else if hi : i < ks.size then kidsHash (shapeHash h ks[i]) ks (i + 1) else h
end

/-- Do the attributes of a view element match a shape's attributes (names in order, and values if
`exact`) and property names (in order, the first after exactly `pre` attributes)? Listeners and
keys are skipped. No allocation. (The mode follows from the tag and the names, which match.) -/
private def attrsMatch (as : Array (String × String)) (ps : Array String) (pre : Nat) (exact : Bool)
    (attrs : Array (Attr Msg)) (i ai pi : Nat) : Bool :=
  if hi : i < attrs.size then
    match attrs[i] with
    | .attr n v =>
      if ha : ai < as.size then
        as[ai].1 == n && (!exact || as[ai].2 == v) && attrsMatch as ps pre exact attrs (i + 1) (ai + 1) pi
      else false
    | .prop n _ =>
      if hp : pi < ps.size then
        (pi != 0 || ai == pre) && ps[pi] == n && attrsMatch as ps pre exact attrs (i + 1) ai (pi + 1)
      else false
    | _ => attrsMatch as ps pre exact attrs (i + 1) ai pi
  else ai == as.size && pi == ps.size
termination_by attrs.size - i

mutual
/-- Does view `v` have shape `sh` (texts and non-exact attribute values aside)? Exact, without
allocating. -/
partial def TplShape.matches (sh : TplShape) (v : Html Msg) : Bool :=
  match sh, v with
  | .text _, .text _ => true
  | .elem ns tag as ps pre m ks, .elem ns' tag' attrs kids =>
    ns == ns' && tag == tag' && attrsMatch as ps pre (m == .exact) attrs 0 0 0 &&
      (let kids := if kids.size == ks.size then kids else effectiveKids tag kids
       ks.size == kids.size && TplShape.kidsMatch ks kids 0)
  | _, _ => false

partial def TplShape.kidsMatch (ks : Array TplShape) (vs : Array (Html Msg)) (i : Nat) : Bool :=
  if i < ks.size then ks[i]!.matches vs[i]! && TplShape.kidsMatch ks vs (i + 1) else true
end

/-- The number of attributes before the first property (all of them if there is none). -/
private def preCount (attrs : Array (Attr Msg)) (i n : Nat := 0) : Nat :=
  if hi : i < attrs.size then
    match attrs[i] with
    | .attr .. => preCount attrs (i + 1) (n + 1)
    | .prop .. => n
    | _ => preCount attrs (i + 1) n
  else n
termination_by attrs.size - i

/-- The shape of a (templatable, so lazy-free) view. -/
partial def TplShape.ofHtml : Html Msg → TplShape
  | .text s => .text s
  | .elem ns tag attrs kids =>
    .elem ns tag (attrs.filterMap fun | .attr n v => some (n, v) | _ => none)
      (attrs.filterMap fun | .prop n _ => some n | _ => none) (preCount attrs) (attrMode ns tag attrs)
      ((effectiveKids tag kids).map TplShape.ofHtml)
  | .lazy .. => .text ""

/-- What `mountShape` does with a templatable subtree: `0` mount it, `tplMake` make it the
template, any other value: clone that template. -/
def tplMake : UInt32 := 0xFFFFFFFF

/-- `tplAction`: mount the subtree and remember its hash (its shape is seen for the first time). -/
def tplSee : UInt32 := 0xFFFFFFFE

/-- What `mountShape` does with a templatable subtree of hash `h`: `0` mount it, `tplSee` mount it
and remember the hash, `tplMake` make it the template, any other value: clone that template. -/
private def tplAction (h : UInt64) (v : Html Msg) (s : DiffState Msg) : UInt32 :=
  let t := s.tpl
  let tid := t.ids.getD h 0
  if tid != 0 then (if t.shapes[tid.toNat - 1]!.matches v then tid else 0)
  else if t.seen.contains h then (if t.shapes.size < tplLimit then tplMake else 0)
  else tplSee

@[noinline] private def markSeen (s : DiffState Msg) (h : UInt64) : DiffState Msg :=
  let t := s.tpl
  let seen := if t.seen.size ≥ tplSeenLimit then {} else t.seen
  { s with tpl := { t with seen := seen.insert h () } }

private def addTemplate (h : UInt64) (sh : TplShape) (size : Nat) : DiffM Msg UInt32 := modifyGet fun s =>
  let t := s.tpl
  let tid := (t.shapes.size + 1).toUInt32
  (tid, { s with tpl := { shapes := t.shapes.push sh, sizes := t.sizes.push size, ids := t.ids.insert h tid,
                          seen := t.seen.erase h, last := tid } })

/-- 0 when templates are off (or hydrating), the last template if `v` has its shape, else
`tplMake`. -/
@[inline] private def lastTemplate (v : Html Msg) (s : DiffState Msg) : UInt32 :=
  if !s.templates || s.hydrating then 0 else
  let t := s.tpl.last
  if t != 0 && s.tpl.shapes[t.toNat - 1]!.matches v then t else tplMake

@[noinline] private def setLast (s : DiffState Msg) (tid : UInt32) : DiffState Msg :=
  if s.tpl.last == tid then s else { s with tpl := { s.tpl with last := tid } }

/-- Append `handleAt fs next i` for `i` from `i` to `n - 1`. -/
private def pushHandles (ops : ByteArray) (fs : Array UInt32) (next : UInt32) (n i : Nat) : ByteArray :=
  if i < n then pushHandles (pushU32 ops (handleAt fs next i)) fs next n (i + 1) else ops
termination_by n - i

/-- `CLONE tid n` and the `n` handles `takeNodes` will take, as `Buf.clone` writes them; read from
the free list, so no array of handles is built. -/
@[noinline] private def emitClone (s : DiffState Msg) (tid : UInt32) (n : Nat) : DiffState Msg :=
  let b := s.buf.w Op.clone |>.w tid |>.w n.toUInt32
  { s with buf := { b with ops := pushHandles b.ops s.freeNodes s.nextNode n 0 } }

/-- The attributes of a prototype element: those before its first property, as a mount sets
them. -/
private def protoAttrs (h : UInt32) (attrs : Array (Attr Msg)) (i : Nat := 0) : DiffM Msg Unit :=
  if hi : i < attrs.size then
    match attrs[i] with
    | .attr n v => do emit (·.setAttr h n v); protoAttrs h attrs (i + 1)
    | .prop .. => pure ()
    | _ => protoAttrs h attrs (i + 1)
  else pure ()
termination_by attrs.size - i

/-- Build `v` (templatable) as a prototype: every element and text, and each element's attributes
before its first property (none on a `bare` element); no property, no listener. Handles are
allocated as `mount` allocates them; returns them in pre-order. (Once per template: `DiffM`.) -/
partial def mountProto (v : Html Msg) (acc : Array UInt32) : DiffM Msg (Array UInt32) := do
  match v with
  | .text s => let h ← allocNode; emit (·.createText h s); return acc.push h
  | .elem ns tag attrs kids =>
    let h ← allocNode
    emit (·.createElement h ns tag)
    if attrMode ns tag attrs != .bare then protoAttrs h attrs
    let mut acc := acc.push h
    for k in effectiveKids tag kids do
      let n := acc.size
      acc ← mountProto k acc
      emit (·.appendChild h acc[n]!)
    return acc
  | .lazy .. => return acc  -- unreachable: a templatable view has no lazy node

/-- The listener table of a fresh element: one entry per event, in the order the events first
appear, each with the slot its first listener will take (`peekSlotAt`: an element's slots are
taken one after the other, by `mountAttrs` or `cloneAttrs`). Pure, so that building an element
returns no pair for it; elements without listeners share `noListeners`. -/
private def listenersOf (s : DiffState Msg) (attrs : Array (Attr Msg)) (i : Nat := 0)
    (ls : Array (String × UInt32) := noListeners) : Array (String × UInt32) :=
  if hi : i < attrs.size then
    match attrs[i] with
    | .on ev _ => listenersOf s attrs (i + 1) (if slotOf ls ev != 0 then ls else ls.push (ev, peekSlotAt s ls.size))
    | _ => listenersOf s attrs (i + 1) ls
  else ls
termination_by attrs.size - i

/-- Does an attribute before `i` listen for `ev`? (Then the listener at `i` repeats an event.) -/
private def onBefore (attrs : Array (Attr Msg)) (ev : String) (i : Nat) (j : Nat := 0) : Bool :=
  if h : j < i ∧ j < attrs.size then
    (match attrs[j]'h.2 with | .on e _ => e == ev | _ => false) || onBefore attrs ev i (j + 1)
  else false
termination_by i - j

/-- Set every attribute and listener of a freshly mounted (or claimed) element, in view order,
with its listener table `ls` (`listenersOf`): the first listener for an event takes its slot, a
repeated one replaces the handler in that slot (the last one wins, as for attributes), so an
element holds exactly one slot per event. While hydrating, attributes are already in the
server-rendered HTML, so only properties and listeners are sent. -/
private def mountAttrs (h : UInt32) (attrs : Array (Attr Msg)) (ls : Array (String × UInt32)) (i : Nat)
    (s : DiffState Msg) : DiffState Msg :=
  if hi : i < attrs.size then
    match attrs[i] with
    | .on ev hd =>
      let sl := slotOf ls ev
      mountAttrs h attrs ls (i + 1)
        (if onBefore attrs ev i then resetListener s h ev sl hd else emitListener (takeSlot s hd) h ev sl hd)
    | a => mountAttrs h attrs ls (i + 1) (emitAttr s h a)
  else s
termination_by attrs.size - i

/-- The commands a cloned element still needs, in view order: the attributes before the first
property whose value differs from the template's (`tas`), then from the first property on (from
the start with `afterProp`: a `bare` element) every property and every attribute, as a mount
sends them, and every listener (listeners are never cloned), as `mountAttrs` sends them. -/
private def cloneAttrs (h : UInt32) (tas : Array (String × String)) (attrs : Array (Attr Msg))
    (ls : Array (String × UInt32)) (i ai : Nat) (afterProp : Bool) (s : DiffState Msg) : DiffState Msg :=
  if hi : i < attrs.size then
    match attrs[i] with
    | .on ev hd =>
      let sl := slotOf ls ev
      cloneAttrs h tas attrs ls (i + 1) ai afterProp
        (if onBefore attrs ev i then resetListener s h ev sl hd else emitListener (takeSlot s hd) h ev sl hd)
    | .attr n v =>
      cloneAttrs h tas attrs ls (i + 1) (ai + 1) afterProp (if afterProp || tas[ai]!.2 != v then emitSetAttr s h n v else s)
    | .prop n v => cloneAttrs h tas attrs ls (i + 1) ai true (emitSetProp s h n v)
    | .key _ => cloneAttrs h tas attrs ls (i + 1) ai afterProp s
  else s
termination_by attrs.size - i

mutual
/-- Finish node `i` of a copy of the template of shape `sh` (a clone, or the prototype itself);
node `j` of the copy has the handle `handleAt fs next j`. Returns the mounted node `mount` would
have built, with the same handles and slots. -/
partial def cloneWalk (fs : Array UInt32) (next : UInt32) (sh : TplShape) (v : Html Msg) (i : Nat)
    (s : DiffState Msg) : Node Msg × DiffState Msg :=
  match v, sh with
  | .elem ns tag attrs kids, .elem _ _ tas _ _ m sks =>
    let h := handleAt fs next i
    -- a void element's view may name children it never gets
    let kids := if kids.size == sks.size then kids else effectiveKids tag kids
    let ls := listenersOf s attrs
    cloneKids fs next h ns tag attrs ls sks kids 0 (i + 1) (if kids.isEmpty then noKids else Array.mkEmpty kids.size) i
      (cloneAttrs h tas attrs ls 0 0 (m == .bare) s)
  | .text t, .text t0 => let h := handleAt fs next i; (.text h t, if t != t0 then emitSetText s h t else s)
  | _, _ => (.text (handleAt fs next i) "", s)  -- unreachable: `v` matches `sh`

/-- Children `k..` of element node `i` (handle `h`), the first of them node `j`, then the element
itself: an element with children costs the one pair it is returned in, a text or a childless
element none. -/
partial def cloneKids (fs : Array UInt32) (next : UInt32) (h : UInt32) (ns : Ns) (tag : String)
    (attrs : Array (Attr Msg)) (ls : Array (String × UInt32)) (sks : Array TplShape)
    (kids : Array (Html Msg)) (k j : Nat) (acc : Array (Node Msg)) (i : Nat) (s : DiffState Msg) :
    Node Msg × DiffState Msg :=
  if hk : k < kids.size then
    match kids[k], sks[k]! with
    | .text t, .text t0 =>
      let hj := handleAt fs next j
      cloneKids fs next h ns tag attrs ls sks kids (k + 1) (j + 1) (acc.push (.text hj t)) i
        (if t != t0 then emitSetText s hj t else s)
    | .elem ns' tag' attrs' _, .elem _ _ tas _ _ m sks' =>
      if sks'.isEmpty then
        -- childless (a void element's view may name children it never gets): built here
        let hj := handleAt fs next j
        let ls' := listenersOf s attrs'
        cloneKids fs next h ns tag attrs ls sks kids (k + 1) (j + 1)
          (acc.push (.elem hj ns' tag' (attrsKey attrs') attrs' ls' noKids 1)) i
          (cloneAttrs hj tas attrs' ls' 0 0 (m == .bare) s)
      else
        let (n, s) := cloneWalk fs next sks[k]! kids[k] j s
        cloneKids fs next h ns tag attrs ls sks kids (k + 1) (j + n.size) (acc.push n) i s
    | _, _ => cloneKids fs next h ns tag attrs ls sks kids (k + 1) (j + 1) acc i s  -- unreachable
  else (.elem h ns tag (attrsKey attrs) attrs ls acc (j - i), s)
end

/-- Create `v` as a clone of template `tid` (`v` has its shape): `CLONE`, then the commands the
copy still needs. The walk reads the copy's handles from the free list (`handleAt`); they are
taken after it. -/
def cloneOf (tid : UInt32) (v : Html Msg) (s : DiffState Msg) : Node Msg × DiffState Msg :=
  let k := tid.toNat - 1
  let sh := s.tpl.shapes[k]!
  let n := s.tpl.sizes[k]!
  let fs := s.freeNodes
  let next := s.nextNode
  let (node, s) := cloneWalk fs next sh v 0 (emitClone (setLast s tid) tid n)
  (node, takeNodes s n)

/-- Build the prototype of `v`'s shape, make it the template (`TEMPLATE`, before anything else
touches the subtree) and finish it as a clone is. Once per template. -/
def makeTemplate (h : UInt64) (v : Html Msg) (size : Nat) (s : DiffState Msg) : Node Msg × DiffState Msg :=
  let (hs, s) := (mountProto v #[]).run s
  let sh := TplShape.ofHtml v
  let (tid, s) := (addTemplate h sh size).run s
  -- node `j` of the prototype is `hs[j]` (`handleAt` reads its list from the end)
  cloneWalk hs.reverse 0 sh v 0 { s with buf := s.buf.template tid hs }

/-- Siblings of a kind (template candidates): elements with the same tag, or two lazy nodes. -/
@[inline] private def alike : Html Msg → Html Msg → Bool
  | .elem _ t _ _, .elem _ u _ _ => t == u
  | .lazy .., .lazy .. => true
  | _, _ => false

/-- Has child `i` a neighbouring sibling of its kind? -/
private def likeNeighbour (ks : Array (Html Msg)) (i : Nat) : Bool :=
  (i > 0 && alike ks[i - 1]! ks[i]!) || (i + 1 < ks.size && alike ks[i]! ks[i + 1]!)

/-! ## Trees -/

/-- True if the keys are pairwise distinct. -/
private def uniqueKeys (ks : Array String) : Bool := Id.run do
  let mut seen : Std.HashMap String Unit := Std.HashMap.emptyWithCapacity ks.size
  for k in ks do
    if seen.contains k then return false else seen := seen.insert k ()
  return true

mutual
/-- Build a view: allocate handles in pre-order, emit the commands (none while hydrating, where
the nodes already exist), and return the mounted node (state passing, see above). With `tpl`, an
element subtree may be created from a template (`mountShape`); the result is the same either
way. -/
partial def mountS (v : Html Msg) (tpl : Bool) (s : DiffState Msg) : Node Msg × DiffState Msg :=
  match v with
  | .text t => let h := peekNode s; (.text h t, emitCreateText (takeNode s) h t)
  | .elem ns tag attrs kids => if tpl then mountCandidate v s else mountElem ns tag attrs kids true s
  | .lazy k deps r => let (n, s) := mountS (r ()) tpl s; (.lazy k deps n, s)

/-- Mount an element that may be created from a template: a clone of the last template if it has
its shape, else `mountShape` if it is templatable, else node by node. -/
partial def mountCandidate (v : Html Msg) (s : DiffState Msg) : Node Msg × DiffState Msg :=
  let last := lastTemplate v s
  if last != 0 && last != tplMake then cloneOf last v s
  else
    let left := if last != 0 then shapeFuel (tplMax + 1) v else 0
    if left != 0 && left + tplMin ≤ tplMax + 1 then mountShape v (tplMax + 1 - left) s
    else match v with
      | .elem ns tag attrs kids => mountElem ns tag attrs kids true s
      | _ => mountS v false s

/-- Mount an element node by node. With `tplKids`, its children that have a neighbouring sibling
of their kind are template candidates. -/
partial def mountElem (ns : Ns) (tag : String) (attrs : Array (Attr Msg)) (kids : Array (Html Msg))
    (tplKids : Bool) (s : DiffState Msg) : Node Msg × DiffState Msg :=
  let kids := effectiveKids tag kids
  let h := peekNode s
  let s := emitCreateElement (takeNode s) h ns tag
  let ls := listenersOf s attrs
  mountKids h ns tag attrs ls kids (tplKids && kids.size ≥ 2) 0 (if kids.isEmpty then noKids else Array.mkEmpty kids.size) 1
    (mountAttrs h attrs ls 0 s)

/-- Mount the children from `i` on, then return the element itself: an element with children
costs the one pair it is returned in, a text or a childless element none (a childless element is
too small to be cloned, so it is mounted here even when it is a template candidate). -/
partial def mountKids (h : UInt32) (ns : Ns) (tag : String) (attrs : Array (Attr Msg))
    (ls : Array (String × UInt32)) (kids : Array (Html Msg)) (tk : Bool) (i : Nat)
    (ks : Array (Node Msg)) (size : Nat) (s : DiffState Msg) : Node Msg × DiffState Msg :=
  if hi : i < kids.size then
    match kids[i] with
    | .text t =>
      let hk := peekNode s
      mountKids h ns tag attrs ls kids tk (i + 1) (ks.push (.text hk t)) (size + 1)
        (emitAppend (emitCreateText (takeNode s) hk t) h hk)
    | .elem ns' tag' attrs' kids' =>
      if (effectiveKids tag' kids').isEmpty then
        let hk := peekNode s
        let s := emitCreateElement (takeNode s) hk ns' tag'
        let ls' := listenersOf s attrs'
        mountKids h ns tag attrs ls kids tk (i + 1) (ks.push (.elem hk ns' tag' (attrsKey attrs') attrs' ls' noKids 1))
          (size + 1) (emitAppend (mountAttrs hk attrs' ls' 0 s) h hk)
      else
        let (n, s) := mountS kids[i] (tk && likeNeighbour kids i) s
        mountKids h ns tag attrs ls kids tk (i + 1) (ks.push n) (size + n.size) (emitAppend s h n.handle)
    | k =>
      let (n, s) := mountS k (tk && likeNeighbour kids i) s
      mountKids h ns tag attrs ls kids tk (i + 1) (ks.push n) (size + n.size) (emitAppend s h n.handle)
  else (.elem h ns tag (attrsKey attrs) attrs ls ks size, s)

/-- Mount an element subtree of `size` (`tplMin`..`tplMax`) nodes: clone its shape's template if
there is one; the second time its shape is seen, build its prototype, make that the template
and finish it as a clone (`makeTemplate`); else mount it node by node. Inside a candidate,
children are not candidates themselves. -/
partial def mountShape (v : Html Msg) (size : Nat) (s : DiffState Msg) : Node Msg × DiffState Msg :=
  match v with
  | .elem ns tag attrs kids =>
    let h := shapeHash 7 v
    if h == 0 then mountElem ns tag attrs kids true s
    else
      let act := tplAction h v s
      if act == 0 then mountElem ns tag attrs kids false s
      else if act == tplSee then mountElem ns tag attrs kids false (markSeen s h)
      else if act == tplMake then makeTemplate h v size s
      else cloneOf act v s
  | _ => mountS v false s
end

/-- Build a view (`mountS` in `DiffM`). -/
@[inline] def mount (v : Html Msg) (tpl : Bool := false) : DiffM Msg (Node Msg) := fun s => mountS v tpl s

/-- Mount `new[i:]` (template candidates) and append them to `parent` and to `out`. -/
partial def mountAppend (parent : UInt32) (new : Array (Html Msg)) (i : Nat) (out : Array (Node Msg))
    (s : DiffState Msg) : Array (Node Msg) × DiffState Msg :=
  if h : i < new.size then
    let (n, s) := mountS new[i] true s
    mountAppend parent new (i + 1) (out.push n) (emitAppendChild s parent n.handle)
  else (out, s)

mutual

/-- Update `old` (a child of `parent`) to show `new`; returns the updated mounted node. -/
partial def patch (parent : UInt32) (old : Node Msg) (new : Html Msg) : DiffM Msg (Node Msg) :=
  return (← patchC parent old new).1

/-- `patch`, also reporting whether the mounted node changed. An unchanged subtree returns the
*same* mounted node, so a no-op re-render costs comparisons only. -/
partial def patchC (parent : UInt32) (old : Node Msg) (new : Html Msg) : DiffM Msg (Node Msg × Bool) := do
  if unchanged old new then
    modify fun s => { s with slots := rebind s.slots old new }
    return (old, false)
  patchNode parent old new

/-- The node-by-node diff (`patchC` without the unchanged-subtree check). -/
partial def patchNode (parent : UInt32) (old : Node Msg) (new : Html Msg) : DiffM Msg (Node Msg × Bool) := do
  match old, new with
  | .lazy k d o, .lazy k' e r =>
    if k == k' && d == e then return (old, false)
    let (n, _) ← patchC parent o (r ())
    return (.lazy k' e n, true)
  | .lazy _ _ o, _ => let (n, _) ← patchC parent o new; return (n, true)
  | _, .lazy k e r => let (n, _) ← patchC parent old (r ()); return (.lazy k e n, true)
  | .text h s, .text t =>
    if s == t then return (old, false)
    emit (·.setText h t)
    return (.text h t, true)
  | .elem h ns tag k attrs ls kids sz, .elem ns' tag' attrs' kids' =>
    if ns == ns' && tag == tag' && k == attrsKey attrs' then
      let (ls', ac) ← patchAttrs h attrs ls attrs'
      let (ks, kc) ← patchKidsC h kids (effectiveKids tag kids')
      if !ac && !kc then return (old, false)
      return (.elem h ns tag k (if ac then attrs' else attrs) ls' ks (if kc then Node.sizeOf ks else sz), true)
    else return (← replaceNode old new, true)
  | _, _ => return (← replaceNode old new, true)

partial def replaceNode (old : Node Msg) (new : Html Msg) : DiffM Msg (Node Msg) := fun s =>
  let (n, s) := mountS new true s
  (n, releaseS old (emitReplace s old.handle n.handle))

/-- Diff a child list. Keyed when every child on both sides has a key and the keys are unique on
each side (keys cached in mounted nodes; new keys scanned once); positional otherwise. A list
whose keys did not change order is patched pairwise without allocating; otherwise the common
prefix and suffix are patched in place and only the middle is planned (`Keyed.plan`). -/
partial def patchKids (parent : UInt32) (old : Array (Node Msg)) (new : Array (Html Msg)) :
    DiffM Msg (Array (Node Msg)) :=
  return (← patchKidsC parent old new).1

partial def patchKidsC (parent : UInt32) (old : Array (Node Msg)) (new : Array (Html Msg)) :
    DiffM Msg (Array (Node Msg) × Bool) := do
  if old.isEmpty && new.isEmpty then return (old, false)
  -- cheap test first: a list is keyed only if its first children are
  let maybeKeyed := !old.isEmpty && !new.isEmpty && old[0]!.key?.isSome && (viewKey new[0]!).isSome
  -- the common case, allocation-free: same length and (if keyed) the same keys in the same order
  if old.size == new.size && (!maybeKeyed || keysAligned old new 0) then
    return (← patchSame parent old new)
  let nk := if maybeKeyed then new.map viewKey else #[]
  let keyed := maybeKeyed && old.all (·.key?.isSome) && nk.all (·.isSome)
  -- keyed only when the keys are unique on each side; otherwise positional (below)
  let ok := if keyed then old.map fun n => n.key?.getD "" else #[]
  let nk := if keyed then nk.map (·.getD "") else #[]
  if keyed && uniqueKeys ok && uniqueKeys nk then
    let mut pre := 0
    while pre < old.size && pre < new.size && ok[pre]! == nk[pre]! do pre := pre + 1
    let mut suf := 0
    while suf < old.size - pre && suf < new.size - pre && ok[old.size - 1 - suf]! == nk[new.size - 1 - suf]! do
      suf := suf + 1
    let okMid := ok.extract pre (old.size - suf)
    let nkMid := nk.extract pre (new.size - suf)
    if okMid.isEmpty && nkMid.isEmpty then
      -- same keys in the same order: patch in place, allocate only if a child changed
      return (← patchSame parent old new)
    let mut out : Array (Node Msg) := Array.replicate new.size default
    for i in [0:pre] do
      out := out.set! i (← patch parent old[i]! new[i]!)
    for j in [0:suf] do
      out := out.set! (new.size - 1 - j) (← patch parent old[old.size - 1 - j]! new[new.size - 1 - j]!)
    let oldMid := old.extract pre (old.size - suf)
    let newMid := new.extract pre (new.size - suf)
    let p := Keyed.plan okMid nkMid
    for j in p.removed do
      emit (·.remove oldMid[j]!.handle)
      release oldMid[j]!
    out ← fun s => placeMid parent pre p oldMid newMid newMid.size out s
    return (out, true)
  if old.size == new.size then return (← patchSame parent old new)
  -- positional, different lengths
  let common := min old.size new.size
  let mut out := Array.mkEmpty new.size
  for i in [0:common] do
    out := out.push (← patch parent old[i]! new[i]!)
  out ← fun s => mountAppend parent new common out s
  for i in [common:old.size] do
    emit (·.remove old[i]!.handle)
    release old[i]!
  return (out, true)

/-- The middle of a keyed list (`newMid`, at `pre` in `out`), from `i - 1` down to 0: right to
left, so the anchor (the node after) is already final. Node `i` is the old child `p.src[i]`
patched, or `newMid[i]` mounted, then inserted if the plan moves it (state passing: no
allocation per child). -/
partial def placeMid (parent : UInt32) (pre : Nat) (p : Keyed.Plan) (oldMid : Array (Node Msg))
    (newMid : Array (Html Msg)) (i : Nat) (out : Array (Node Msg)) (s : DiffState Msg) :
    Array (Node Msg) × DiffState Msg :=
  if i == 0 then (out, s) else
  let i := i - 1
  let (n, s) := match p.src[i]! with
    | some j => patch parent oldMid[j]! newMid[i]! s
    | none => mountS newMid[i]! true s
  let nxt := pre + i + 1
  let s := if !p.move[i]! then s
    else if nxt < out.size then emitInsertBefore s parent n.handle out[nxt]!.handle
    else emitAppendChild s parent n.handle
  placeMid parent pre p oldMid newMid i (out.set! (pre + i) n) s

/-- Pairwise patch of two equally long child lists. Runs of unchanged children are found purely
and rebound with one state update; only the others go through `patchNode`. Returns the old array
itself until a child changes. -/
partial def patchSame (parent : UInt32) (old : Array (Node Msg)) (new : Array (Html Msg)) :
    DiffM Msg (Array (Node Msg) × Bool) := do
  let mut out := old
  let mut changed := false
  let mut i := 0
  while i < old.size do
    let j := runSame old new i
    if j > i then modify fun s => { s with slots := rebindRange s.slots old new i j }
    if j < old.size then
      let (n, c) ← patchNode parent old[j]! new[j]!
      if c then
        changed := true
        out := out.set! j n
    i := j + 1
  return (out, changed)

end

/-- The handler behind a slot the browser reported. -/
def handlerOf (s : DiffState Msg) (slot : UInt32) : Option (Handler Msg) :=
  s.slots[slot.toNat]?.join

end LeanUI
