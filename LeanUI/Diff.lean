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

/-- A mounted node: the view it came from, its handle, and its listener slots. -/
inductive Node (Msg : Type) where
  | text (h : UInt32) (s : String)
  | elem (h : UInt32) (ns : Ns) (tag : String) (attrs : Array (Attr Msg))
      (listeners : Array (String × UInt32)) (kids : Array (Node Msg))
  | lazy (deps : UInt64) (inner : Node Msg)

instance : Inhabited (Node Msg) := ⟨.text 0 ""⟩

namespace Node
def handle : Node Msg → UInt32
  | .text h _ => h
  | .elem h .. => h
  | .lazy _ n => n.handle
def key? : Node Msg → Option String
  | .elem _ _ _ attrs _ _ => attrs.findSome? fun | .key k => some k | _ => none
  | .lazy _ n => n.key?
  | _ => none
/-- Number of DOM nodes (elements and texts) in the subtree. -/
partial def size : Node Msg → Nat
  | .text .. => 1
  | .elem _ _ _ _ _ kids => kids.foldl (fun n k => n + k.size) 1
  | .lazy _ n => n.size
end Node

structure DiffState (Msg : Type) where
  buf : Buf := {}
  nextNode : UInt32 := 1
  freeNodes : Array UInt32 := #[]
  /-- Slot `s` holds the handler the browser's slot `s` stands for. Slot 0 is never used. -/
  slots : Array (Option (Handler Msg)) := #[none]
  freeSlots : Array UInt32 := #[]
  /-- While hydrating, `mount` claims existing DOM nodes in pre-order instead of creating them. -/
  hydrating : Bool := false

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
  | .elem h _ _ _ ls kids => do
    for k in kids do release k
    for (_, sl) in ls do freeSlot sl
    emit (·.free h); modify fun s => { s with freeNodes := s.freeNodes.push h }
  | .lazy _ n => release n

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
listener only if what the browser extracts or does changed. -/
private def updateListener (h : UInt32) (ev : String) (sl : UInt32) (old new : Handler Msg) : DiffM Msg Unit := do
  setSlot sl new
  if old.payload != new.payload || old.flags != new.flags then
    emit (·.setListener h ev sl new.payload new.flags)

def patchAttrs (h : UInt32) (old : Array (Attr Msg)) (ls : Array (String × UInt32))
    (new : Array (Attr Msg)) : DiffM Msg (Array (String × UInt32)) := do
  if old.size == new.size && (old.zip new).all fun (a, b) => sameShape a b then
    -- fast path: same attributes in the same order (so the same ones are shadowed on both sides)
    for i in [0:new.size] do
      match old[i]!, new[i]! with
      | .attr _ v, .attr n w => if v != w && !shadowed new i then emit (·.setAttr h n w)
      | .prop _ v, .prop n w => if v != w && !shadowed new i then emit (·.setProp h n w)
      | .on ev ho, .on _ hn =>
        if !shadowed new i then
          match ls.find? (·.1 == ev) with
          | some (_, sl) => updateListener h ev sl ho hn
          | none => pure ()
      | _, _ => pure ()
    return ls
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
    | some hn, some ho => updateListener h ev sl ho hn; out := out.push (ev, sl)
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
  return out

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
the nodes already exist), and return the mounted node. -/
partial def mount (v : Html Msg) : DiffM Msg (Node Msg) := do
  match v with
  | .text s =>
    let h ← allocNode
    if !(← get).hydrating then emit (·.createText h s)
    return .text h s
  | .elem ns tag attrs kids =>
    let h ← allocNode
    let hydrating := (← get).hydrating
    if !hydrating then emit (·.createElement h ns tag)
    let ls ← mountAttrs h attrs
    let mut ks := Array.mkEmpty kids.size
    for k in kids do
      let n ← mount k
      if !hydrating then emit (·.appendChild h n.handle)
      ks := ks.push n
    return .elem h ns tag attrs ls ks
  | .lazy deps r => return .lazy deps (← mount (r ()))

/-- Update `old` (a child of `parent`) to show `new`; returns the updated mounted node. -/
partial def patch (parent : UInt32) (old : Node Msg) (new : Html Msg) : DiffM Msg (Node Msg) := do
  match old, new with
  | .lazy d o, .lazy e r => if d == e then return old else return .lazy e (← patch parent o (r ()))
  | .lazy _ o, _ => patch parent o new
  | _, .lazy e r => return .lazy e (← patch parent old (r ()))
  | .text h s, .text t =>
    if s != t then emit (·.setText h t)
    return .text h t
  | .elem h ns tag attrs ls kids, .elem ns' tag' attrs' kids' =>
    if ns == ns' && tag == tag' && old.key? == (Html.elem ns' tag' attrs' kids').key? then
      let ls ← patchAttrs h attrs ls attrs'
      let ks ← patchKids h kids kids'
      return .elem h ns tag attrs' ls ks
    else replaceNode old new
  | _, _ => replaceNode old new

partial def replaceNode (old : Node Msg) (new : Html Msg) : DiffM Msg (Node Msg) := do
  let n ← mount new
  emit (·.replace old.handle n.handle)
  release old
  return n

/-- Diff a child list. Keyed when every child on both sides has a unique key; positional otherwise. -/
partial def patchKids (parent : UInt32) (old : Array (Node Msg)) (new : Array (Html Msg)) :
    DiffM Msg (Array (Node Msg)) := do
  if old.isEmpty && new.isEmpty then return old
  let keyed := !old.isEmpty && !new.isEmpty &&
    uniqueKeys (old.map Node.key?) && uniqueKeys (new.map Html.key?)
  if !keyed then
    -- positional
    let common := min old.size new.size
    let mut out := Array.mkEmpty new.size
    for i in [0:common] do
      out := out.push (← patch parent old[i]! new[i]!)
    for i in [common:new.size] do
      let n ← mount new[i]!
      emit (·.appendChild parent n.handle)
      out := out.push n
    for i in [common:old.size] do
      emit (·.remove old[i]!.handle)
      release old[i]!
    return out
  -- keyed: trim the common prefix and suffix, plan the middle
  let ok := old.map fun n => n.key?.getD ""
  let nk := new.map fun n => n.key?.getD ""
  let mut pre := 0
  while pre < old.size && pre < new.size && ok[pre]! == nk[pre]! do pre := pre + 1
  let mut suf := 0
  while suf < old.size - pre && suf < new.size - pre && ok[old.size - 1 - suf]! == nk[new.size - 1 - suf]! do
    suf := suf + 1
  let mut out : Array (Node Msg) := Array.replicate new.size default
  for i in [0:pre] do
    out := out.set! i (← patch parent old[i]! new[i]!)
  for j in [0:suf] do
    out := out.set! (new.size - 1 - j) (← patch parent old[old.size - 1 - j]! new[new.size - 1 - j]!)
  let oldMid := old.extract pre (old.size - suf)
  let newMid := new.extract pre (new.size - suf)
  let p := Keyed.plan (ok.extract pre (old.size - suf)) (nk.extract pre (new.size - suf))
  for j in p.removed do
    emit (·.remove oldMid[j]!.handle)
    release oldMid[j]!
  -- right to left, so the anchor (the node after i) is already final
  let mut i := newMid.size
  while i > 0 do
    i := i - 1
    let n ← match p.src[i]! with
      | some j => patch parent oldMid[j]! newMid[i]!
      | none => mount newMid[i]!
    out := out.set! (pre + i) n
    if p.move[i]! then
      let nxt := pre + i + 1
      if nxt < new.size then emit (·.insertBefore parent n.handle out[nxt]!.handle)
      else emit (·.appendChild parent n.handle)
  return out

end

/-- The handler behind a slot the browser reported. -/
def handlerOf (s : DiffState Msg) (slot : UInt32) : Option (Handler Msg) :=
  s.slots[slot.toNat]?.join

end LeanUI
