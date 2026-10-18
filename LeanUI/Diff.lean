module
public import LeanUI.Html
public import LeanUI.Patch
public import LeanUI.Keyed
public import Std.Data.HashSet
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

/-- What a template fixes about a subtree (`docs/PROTOCOL.md`, template cloning): namespaces and
tags, each element's attributes (names and values, in order) and property names (in order), and
the tree's structure. A text is a text whatever its content; the template's own texts are kept,
so a clone only re-sends the texts that differ. Listeners and keys are not part of a shape. -/
inductive TplShape where
  | text (s : String)
  | elem (ns : Ns) (tag : String) (attrs : Array (String × String)) (props : Array String) (kids : Array TplShape)
  deriving Inhabited

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
  /-- Hashes of shapes seen once (cleared when it reaches `tplSeenLimit`). -/
  tplSeen : Std.HashSet UInt64 := {}
  /-- Shape hash → template id. -/
  tplIds : Std.HashMap UInt64 UInt32 := {}
  /-- The shape of template `i + 1`. -/
  tplShapes : Array TplShape := #[]

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

/-- Forget a whole mounted subtree: free its handles and slots. The caller detaches its root. -/
partial def release : Node Msg → DiffM Msg Unit
  | .text h _ => do emit (·.free h); modify fun s => { s with freeNodes := s.freeNodes.push h }
  | .elem h _ _ _ _ ls kids _ => do
    for k in kids do release k
    for (_, sl) in ls do freeSlot sl
    emit (·.free h); modify fun s => { s with freeNodes := s.freeNodes.push h }
  | .lazy _ _ n => release n

/-- The `key` attribute, if any (scanned once per node). -/
@[inline] def attrsKey (attrs : Array (Attr Msg)) : Option String :=
  attrs.findSome? fun | .key k => some k | _ => none

/-- The key of a view node (a lazy node carries its own, so it is read without rendering). -/
@[inline] def viewKey : Html Msg → Option String
  | .elem _ _ attrs _ => attrsKey attrs
  | .lazy k _ _ => k
  | _ => none

/-! ## Attributes -/

private def setOne (h : UInt32) : Attr Msg → DiffM Msg Unit
  | .attr n v => emit (·.setAttr h n v)
  | .prop n v => emit (·.setProp h n v)
  | _ => pure ()

/-- Set every attribute and listener of a freshly mounted (or claimed) element. While hydrating,
attributes are already in the server-rendered HTML, so only properties and listeners are sent.
A repeated listener for one event replaces the earlier one (the last one wins, as for attributes),
so an element holds exactly one slot per event. -/
def mountAttrs (h : UInt32) (attrs : Array (Attr Msg)) : DiffM Msg (Array (String × UInt32)) := do
  let hydrating := (← get).hydrating
  -- most elements have no listener: they share the one empty array
  let mut ls := #[]
  for a in attrs do
    match a with
    | .on ev hd =>
      match ls.find? (·.1 == ev) with
      | some (_, sl) =>
        setSlot sl hd
        emit (·.setListener h ev sl hd.payload hd.flags)
      | none =>
        let sl ← allocSlot hd
        emit (·.setListener h ev sl hd.payload hd.flags)
        ls := ls.push (ev, sl)
    | .attr .. => if !hydrating then setOne h a
    | .prop .. => setOne h a
    | .key _ => pure ()
  return ls

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
shape is mounted, its finished DOM becomes a template (`TEMPLATE`); later subtrees of that shape
are created with one `CLONE` (one `cloneNode(true)` in the browser) plus what differs from a
fresh mount: the texts that differ from the template's, every property and every listener.
Hashing and matching walk the view without allocating; a stored `TplShape` is compared exactly, so
a hash collision never clones the wrong thing.

Policy: element subtrees of `tplMin`..`tplMax` DOM nodes, without `lazy` nodes (mounting would
force them) and without properties on elements that have children (mount sets properties before
the children exist, a clone after: `select.value`, `textContent`), never while hydrating, at most
`tplLimit` templates per session. Candidates are the children `patchKids` mounts and the
children of elements with at least two (a chain of single children is never hashed, so mounting
a deep chain stays linear). -/

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

@[inline] private def mixStr (h : UInt64) (s : String) : UInt64 := mixHash h (hash s)

private def attrsHash (h : UInt64) (attrs : Array (Attr Msg)) (i : Nat := 0) : UInt64 :=
  if hi : i < attrs.size then
    match attrs[i] with
    | .attr n v => attrsHash (mixStr (mixStr (mixHash h 3) n) v) attrs (i + 1)
    | .prop n _ => attrsHash (mixStr (mixHash h 5) n) attrs (i + 1)
    | _ => attrsHash h attrs (i + 1)
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
element with children). -/
partial def shapeHash (h : UInt64) (v : Html Msg) : UInt64 :=
  match v with
  | .text _ => mixHash h 1
  | .elem ns tag attrs kids =>
    let kids := effectiveKids tag kids
    if !kids.isEmpty && hasProp attrs then 0
    else kidsHash (mixHash (attrsHash (mixStr (mixHash h (2 + ns.code.toUInt64)) tag) attrs) kids.size.toUInt64) kids 0
  | .lazy .. => 0

partial def kidsHash (h : UInt64) (ks : Array (Html Msg)) (i : Nat) : UInt64 :=
  if h == 0 then 0 else if hi : i < ks.size then kidsHash (shapeHash h ks[i]) ks (i + 1) else h
end

/-- Do the attributes of a view element match a shape's attribute pairs and property names (in
order; listeners and keys are skipped)? No allocation. -/
private def attrsMatch (as : Array (String × String)) (ps : Array String) (attrs : Array (Attr Msg))
    (i ai pi : Nat) : Bool :=
  if hi : i < attrs.size then
    match attrs[i] with
    | .attr n v =>
      if ha : ai < as.size then as[ai].1 == n && as[ai].2 == v && attrsMatch as ps attrs (i + 1) (ai + 1) pi
      else false
    | .prop n _ =>
      if hp : pi < ps.size then ps[pi] == n && attrsMatch as ps attrs (i + 1) ai (pi + 1) else false
    | _ => attrsMatch as ps attrs (i + 1) ai pi
  else ai == as.size && pi == ps.size
termination_by attrs.size - i

mutual
/-- Does view `v` have shape `sh` (texts aside)? Exact, without allocating. -/
partial def TplShape.matches (sh : TplShape) (v : Html Msg) : Bool :=
  match sh, v with
  | .text _, .text _ => true
  | .elem ns tag as ps ks, .elem ns' tag' attrs kids =>
    ns == ns' && tag == tag' && attrsMatch as ps attrs 0 0 0 &&
      (let kids := effectiveKids tag kids; ks.size == kids.size && TplShape.kidsMatch ks kids 0)
  | _, _ => false

partial def TplShape.kidsMatch (ks : Array TplShape) (vs : Array (Html Msg)) (i : Nat) : Bool :=
  if i < ks.size then ks[i]!.matches vs[i]! && TplShape.kidsMatch ks vs (i + 1) else true
end

/-- The shape of a (templatable, so lazy-free) view. -/
partial def TplShape.ofHtml : Html Msg → TplShape
  | .text s => .text s
  | .elem ns tag attrs kids =>
    .elem ns tag (attrs.filterMap fun | .attr n v => some (n, v) | _ => none)
      (attrs.filterMap fun | .prop n _ => some n | _ => none) ((effectiveKids tag kids).map TplShape.ofHtml)
  | .lazy .. => .text ""

/-- The handles of a mounted subtree in pre-order. -/
partial def Node.handlesInto (acc : Array UInt32) : Node Msg → Array UInt32
  | .text h _ => acc.push h
  | .elem h _ _ _ _ _ kids _ => kids.foldl Node.handlesInto (acc.push h)
  | .lazy _ _ n => n.handlesInto acc

/-- What `mountShape` does with a templatable subtree: `0` mount it, `tplMake` mount it and keep
it as a template, any other value: clone that template. -/
def tplMake : UInt32 := 0xFFFFFFFF

private def tplAction (h : UInt64) (v : Html Msg) : DiffM Msg UInt32 := modifyGet fun s =>
  let tid := s.tplIds.getD h 0
  if tid != 0 then (if s.tplShapes[tid.toNat - 1]!.matches v then tid else 0, s)
  else if s.tplSeen.contains h then (if s.tplShapes.size < tplLimit then tplMake else 0, s)
  else
    let seen := if s.tplSeen.size ≥ tplSeenLimit then {} else s.tplSeen
    (0, { s with tplSeen := seen.insert h })

private def addTemplate (h : UInt64) (sh : TplShape) : DiffM Msg UInt32 := modifyGet fun s =>
  let tid := (s.tplShapes.size + 1).toUInt32
  (tid, { s with tplShapes := s.tplShapes.push sh, tplIds := s.tplIds.insert h tid, tplSeen := s.tplSeen.erase h })

@[inline] private def templatesOn : DiffM Msg Bool := modifyGet fun s => (s.templates && !s.hydrating, s)

private def allocLoop (s : DiffState Msg) (hs : Array UInt32) : Nat → Array UInt32 × DiffState Msg
  | 0 => (hs, s)
  | n + 1 =>
    -- read the handle before the update, so the free list is popped in place (not copied)
    if s.freeNodes.isEmpty then
      let h := s.nextNode
      allocLoop { s with nextNode := h + 1 } (hs.push h) n
    else
      let h := s.freeNodes.back!
      allocLoop { s with freeNodes := s.freeNodes.pop } (hs.push h) n

/-- `n` handles, in the order `n` calls of `allocNode` would return them (never while hydrating). -/
def allocNodes (n : Nat) : DiffM Msg (Array UInt32) := modifyGet fun s => allocLoop s (Array.mkEmpty n) n

/-- The commands a cloned element still needs: every property (a fresh mount sets them all),
every listener (listeners are never cloned), and the attributes that follow a property in the
view (re-sent: a property can reflect onto an attribute, and mount sets them in view order). -/
def cloneAttrs (h : UInt32) (attrs : Array (Attr Msg)) : DiffM Msg (Array (String × UInt32)) := do
  let mut ls := #[]
  let mut afterProp := false
  for a in attrs do
    match a with
    | .on ev hd =>
      match ls.find? (·.1 == ev) with
      | some (_, sl) =>
        setSlot sl hd
        emit (·.setListener h ev sl hd.payload hd.flags)
      | none =>
        let sl ← allocSlot hd
        emit (·.setListener h ev sl hd.payload hd.flags)
        ls := ls.push (ev, sl)
    | .attr n v => if afterProp then emit (·.setAttr h n v)
    | .prop n v => afterProp := true; emit (·.setProp h n v)
    | .key _ => pure ()
  return ls

/-- Finish a clone of a template with shape `sh`: node `i` of the clone (pre-order) is `hs[i]`.
Returns the mounted node `mount` would have built, with the same handles and slots. -/
partial def cloneWalk (hs : Array UInt32) (sh : TplShape) (v : Html Msg) (i : Nat) : DiffM Msg (Node Msg) := do
  let h := hs[i]!
  match v, sh with
  | .text s, .text t =>
    if s != t then emit (·.setText h s)
    return .text h s
  | .elem ns tag attrs kids, .elem _ _ _ _ sks =>
    let kids := effectiveKids tag kids
    let ls ← cloneAttrs h attrs
    let mut ks := if kids.isEmpty then #[] else Array.mkEmpty kids.size
    let mut j := i + 1
    for k in [0:kids.size] do
      let n ← cloneWalk hs sks[k]! kids[k]! j
      j := j + n.size
      ks := ks.push n
    return .elem h ns tag (attrsKey attrs) attrs ls ks (Node.sizeOf ks)
  | _, _ => return .text h ""  -- unreachable: `v` matches `sh`

/-- Insert the mounted nodes `ns[lo:hi]`, in order, into `parent` before `ref` (0: append), with
one command. -/
def insertRun (parent ref : UInt32) (ns : Array (Node Msg)) (lo hi : Nat) : DiffM Msg Unit :=
  if hi ≤ lo then pure ()
  else if hi == lo + 1 then
    let c := ns[lo]!.handle
    emit fun b => if ref == 0 then b.appendChild parent c else b.insertBefore parent c ref
  else
    let hs := (ns.extract lo hi).map (·.handle)
    emit (·.insertMany parent ref hs 0 hs.size)

/-! ## Trees -/

/-- True if every node has a key and the keys are pairwise distinct. -/
private def uniqueKeys (ks : Array (Option String)) : Bool := Id.run do
  let mut seen : Std.HashMap String Unit := Std.HashMap.emptyWithCapacity ks.size
  for k in ks do
    match k with
    | none => return false
    | some k => if seen.contains k then return false else seen := seen.insert k ()
  return true

mutual

/-- Build a view: allocate handles in pre-order, emit the commands (none while hydrating, where
the nodes already exist), and return the mounted node. With `tpl`, an element subtree may be
created from a template (`mountShape`); the result is the same either way. -/
partial def mount (v : Html Msg) (tpl : Bool := false) : DiffM Msg (Node Msg) := do
  match v with
  | .text s =>
    let h ← allocNode
    if !(← get).hydrating then emit (·.createText h s)
    return .text h s
  | .elem ns tag attrs kids =>
    if tpl && (← templatesOn) then
      let left := shapeFuel (tplMax + 1) v
      if left != 0 && left + tplMin ≤ tplMax + 1 then return ← mountShape v (tplMax + 1 - left)
    mountElem ns tag attrs kids true
  | .lazy k deps r => return .lazy k deps (← mount (r ()) tpl)

/-- Mount an element node by node. With `tplKids`, the children of an element with at least two
are template candidates. -/
partial def mountElem (ns : Ns) (tag : String) (attrs : Array (Attr Msg)) (kids : Array (Html Msg))
    (tplKids : Bool) : DiffM Msg (Node Msg) := do
  let kids := effectiveKids tag kids
  let h ← allocNode
  let hydrating := (← get).hydrating
  if !hydrating then emit (·.createElement h ns tag)
  let ls ← mountAttrs h attrs
  let tk := tplKids && kids.size ≥ 2
  let mut ks := if kids.isEmpty then #[] else Array.mkEmpty kids.size
  for k in kids do
    let n ← mount k tk
    if !hydrating then emit (·.appendChild h n.handle)
    ks := ks.push n
  return .elem h ns tag (attrsKey attrs) attrs ls ks (Node.sizeOf ks)

/-- Mount an element subtree of `size` (`tplMin`..`tplMax`) nodes: clone its shape's template if
there is one, make it the template the second time its shape is seen (`TEMPLATE` right after the
subtree is complete, before its parent takes it), else mount it node by node. Inside a
candidate, children are not candidates themselves. -/
partial def mountShape (v : Html Msg) (size : Nat) : DiffM Msg (Node Msg) := do
  match v with
  | .elem ns tag attrs kids =>
    let h := shapeHash 7 v
    if h == 0 then return ← mountElem ns tag attrs kids true
    let act ← tplAction h v
    if act == 0 then mountElem ns tag attrs kids false
    else if act == tplMake then
      let n ← mountElem ns tag attrs kids false
      let tid ← addTemplate h (TplShape.ofHtml v)
      emit (·.template tid (n.handlesInto #[]))
      return n
    else
      let hs ← allocNodes size
      emit (·.clone act hs)
      let sh ← modifyGet fun s => (s.tplShapes[act.toNat - 1]!, s)
      cloneWalk hs sh v 0
  | _ => mount v

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

partial def replaceNode (old : Node Msg) (new : Html Msg) : DiffM Msg (Node Msg) := do
  let n ← mount new true
  emit (·.replace old.handle n.handle)
  release old
  return n

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
  if keyed && uniqueKeys (ok.map some) && uniqueKeys (nk.map some) then
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
    -- right to left, so the anchor (the node after a child) is already final. Consecutive
    -- children that move (or are new) go before one anchor: each run is inserted with one
    -- command, once its leftmost child is known: `out[pre + i, pre + runEnd)`.
    let mut i := newMid.size
    let mut runEnd := 0
    let mut inRun := false
    while i > 0 do
      i := i - 1
      let n ← match p.src[i]! with
        | some j => patch parent oldMid[j]! newMid[i]!
        | none => mount newMid[i]! true
      out := out.set! (pre + i) n
      if p.move[i]! then
        if !inRun then
          inRun := true
          runEnd := i + 1
      else if inRun then
        inRun := false
        let nxt := pre + runEnd
        insertRun parent (if nxt < new.size then out[nxt]!.handle else 0) out (pre + i + 1) nxt
    if inRun then
      let nxt := pre + runEnd
      insertRun parent (if nxt < new.size then out[nxt]!.handle else 0) out pre nxt
    return (out, true)
  if old.size == new.size then return (← patchSame parent old new)
  -- positional, different lengths
  let common := min old.size new.size
  let mut out := Array.mkEmpty new.size
  for i in [0:common] do
    out := out.push (← patch parent old[i]! new[i]!)
  for i in [common:new.size] do
    out := out.push (← mount new[i]! true)
  insertRun parent 0 out common new.size
  for i in [common:old.size] do
    emit (·.remove old[i]!.handle)
    release old[i]!
  return (out, true)

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
