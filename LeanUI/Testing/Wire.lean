module
public import Std.Data.HashMap
public import Std.Data.HashSet
public import LeanUI.Patch
public import LeanUI.Testing.Dom
/-!
# The wire protocol, decoded and checked strictly

`decode` turns a command buffer into typed commands (with their word ranges, so a buffer can be
re-encoded with commands dropped: mutation testing). `Shadow` is an independent model of what
the browser holds (live handles, parents, listener slots, interned names) that rejects every
command the browser could not apply as intended, even those `Dom.apply` tolerates:

* creating a handle that is still live (reuse without `free`), or using a handle that is not;
* `setText` on an element, attributes or listeners on a text node;
* `appendChild`/`insertBefore`/`replace` that would form a cycle, or an `insertBefore` whose
  reference is not a child of the parent;
* `free` of a node still in the document, a freed node left inside a live parent (a ghost
  child), and live nodes that are no longer reachable at the end of a buffer (leaks);
* a listener slot bound to two (node, event) pairs at once (ambiguous routing), slot 0;
* names used before `INTERN`, an id interned twice;
* a `TEMPLATE` that does not name a live subtree completely (every node of the root's subtree,
  each after its parent), or redefines an id; a `CLONE` of an unknown template, with a count that
  is not the template's size, or onto handles that are live or repeated;
* string slices outside the string area, truncated operands, unknown opcodes.

It also counts redundancies (a `remove` of a node that has no parent, a `removeListener` with
no listener, a name interned twice) as warnings.
-/
public section
namespace LeanUI.Testing.Wire

inductive WOp where
  | createElement (h ns name : UInt32)
  | createText (h : UInt32) (s : String)
  | setAttr (h name : UInt32) (v : String)
  | removeAttr (h name : UInt32)
  | setPropStr (h name : UInt32) (v : String)
  | setPropBool (h name b : UInt32)
  | setPropNum (h name : UInt32) (v : String)
  | removeProp (h name : UInt32)
  | setText (h : UInt32) (s : String)
  | appendChild (p c : UInt32)
  | insertBefore (p c r : UInt32)
  | remove (h : UInt32)
  | replace (old new : UInt32)
  | free (h : UInt32)
  | setListener (h ev slot payload flags : UInt32)
  | removeListener (h ev : UInt32)
  | intern (id : UInt32) (s : String)
  | mount (sel : String) (h : UInt32)
  | hydrate (sel : String) (first count : UInt32)
  | template (tid : UInt32) (hs : Array UInt32)
  | clone (tid : UInt32) (hs : Array UInt32)
  | effect (op : UInt32)
  deriving Inhabited, Repr

def WOp.name : WOp → String
  | .createElement .. => "createElement" | .createText .. => "createText" | .setAttr .. => "setAttr"
  | .removeAttr .. => "removeAttr" | .setPropStr .. => "setPropStr" | .setPropBool .. => "setPropBool"
  | .setPropNum .. => "setPropNum" | .removeProp .. => "removeProp" | .setText .. => "setText"
  | .appendChild .. => "appendChild" | .insertBefore .. => "insertBefore" | .remove .. => "remove"
  | .replace .. => "replace" | .free .. => "free" | .setListener .. => "setListener"
  | .removeListener .. => "removeListener" | .intern .. => "intern" | .mount .. => "mount"
  | .hydrate .. => "hydrate" | .template .. => "template" | .clone .. => "clone"
  | .effect op => s!"effect{op}"

/-- A decoded command and the word range `[start, start + len)` it occupies. -/
structure Cmd where
  op : WOp
  start : Nat
  len : Nat
  deriving Inhabited

/-- Words per command, by opcode (`none`: unknown). -/
def width (op : UInt32) : Option Nat :=
  if op == Op.createElement then some 4 else if op == Op.createText then some 4
  else if op == Op.setAttr then some 5 else if op == Op.removeAttr then some 3
  else if op == Op.setPropStr then some 5 else if op == Op.setPropBool then some 4
  else if op == Op.setPropNum then some 5 else if op == Op.removeProp then some 3
  else if op == Op.setText then some 4 else if op == Op.appendChild then some 3
  else if op == Op.insertBefore then some 4 else if op == Op.remove then some 2
  else if op == Op.replace then some 3 else if op == Op.free then some 2
  else if op == Op.setListener then some 6 else if op == Op.removeListener then some 3
  else if op == Op.intern then some 4 else if op == Op.mount then some 4
  else if op == Op.hydrate then some 5 else if op == Op.fetch then some 10
  else if op == Op.timeout || op == Op.intervalSet then some 3
  else if op == Op.intervalClear || op == Op.urlListen || op == Op.frame then some 2
  else if op == Op.storageSet then some 5 else if op == Op.storageGet then some 4
  else if op == Op.storageRemove || op == Op.urlPush || op == Op.urlReplace || op == Op.focus ||
    op == Op.log || op == Op.title || op == Op.blur || op == Op.scrollIntoView then some 3
  else none

def words (ops : ByteArray) : Array UInt32 := Id.run do
  let mut out := Array.mkEmpty (ops.size / 4)
  let mut i := 0
  while i + 3 < ops.size do
    out := out.push (ops[i]!.toUInt32 ||| (ops[i+1]!.toUInt32 <<< 8) ||| (ops[i+2]!.toUInt32 <<< 16) ||| (ops[i+3]!.toUInt32 <<< 24))
    i := i + 4
  return out

/-- Decode a buffer. Fails on an unknown opcode, truncated operands, a ragged word stream or a
string slice outside the string area. -/
def decode (ops strs : ByteArray) : Except String (Array Cmd) := do
  if ops.size % 4 != 0 then throw s!"ops area is {ops.size} bytes, not a whole number of words"
  let us := utf16Units strs
  let w := words ops
  let mut out : Array Cmd := Array.mkEmpty (w.size / 3)
  let mut i := 0
  while i < w.size do
    let op := w[i]!
    -- TEMPLATE and CLONE carry a count, then that many handles
    let n? := if op == Op.template || op == Op.clone then
        some (if i + 2 < w.size then 3 + w[i + 2]!.toNat else 3)
      else width op
    let some n := n? | throw s!"unknown opcode {op} at word {i}"
    if i + n > w.size then throw s!"opcode {op} at word {i} needs {n} words, {w.size - i} left"
    let a (k : Nat) : UInt32 := w[i + k]!
    let str (k : Nat) : Except String String := do
      let off := (a k).toNat; let len := (a (k + 1)).toNat
      if off + len > us.size then throw s!"string ({off}, {len}) of opcode {op} at word {i} is outside the {us.size}-unit string area"
      return fromUnits us off len
    let c ← if op == Op.createElement then pure (WOp.createElement (a 1) (a 2) (a 3))
      else if op == Op.createText then pure (.createText (a 1) (← str 2))
      else if op == Op.setAttr then pure (.setAttr (a 1) (a 2) (← str 3))
      else if op == Op.removeAttr then pure (.removeAttr (a 1) (a 2))
      else if op == Op.setPropStr then pure (.setPropStr (a 1) (a 2) (← str 3))
      else if op == Op.setPropBool then pure (.setPropBool (a 1) (a 2) (a 3))
      else if op == Op.setPropNum then pure (.setPropNum (a 1) (a 2) (← str 3))
      else if op == Op.removeProp then pure (.removeProp (a 1) (a 2))
      else if op == Op.setText then pure (.setText (a 1) (← str 2))
      else if op == Op.appendChild then pure (.appendChild (a 1) (a 2))
      else if op == Op.insertBefore then pure (.insertBefore (a 1) (a 2) (a 3))
      else if op == Op.remove then pure (.remove (a 1))
      else if op == Op.replace then pure (.replace (a 1) (a 2))
      else if op == Op.free then pure (.free (a 1))
      else if op == Op.setListener then pure (.setListener (a 1) (a 2) (a 3) (a 4) (a 5))
      else if op == Op.removeListener then pure (.removeListener (a 1) (a 2))
      else if op == Op.intern then pure (.intern (a 1) (← str 2))
      else if op == Op.mount then pure (.mount (← str 1) (a 3))
      else if op == Op.hydrate then pure (.hydrate (← str 1) (a 3) (a 4))
      else if op == Op.template then pure (.template (a 1) ((Array.range (a 2).toNat).map fun k => a (3 + k)))
      else if op == Op.clone then pure (.clone (a 1) ((Array.range (a 2).toNat).map fun k => a (3 + k)))
      else pure (.effect op)
    out := out.push { op := c, start := i, len := n }
    i := i + n
  return out

/-- Re-encode the commands `keep` selects (the string area is reused as is). -/
def reencode (ops : ByteArray) (cmds : Array Cmd) (keep : Nat → Bool) : ByteArray := Id.run do
  let mut out := ByteArray.emptyWithCapacity ops.size
  for h : i in [0:cmds.size] do
    if keep i then
      let c := cmds[i]
      out := out ++ ops.extract (4 * c.start) (4 * (c.start + c.len))
  return out

/-! ## The shadow model -/

inductive Kind where | elem | text
  deriving BEq, Inhabited

structure Shadow where
  kind : Std.HashMap UInt32 Kind := {}
  /-- Which DOM node a handle names: a new number for every node created. -/
  inc : Std.HashMap UInt32 Nat := {}
  nextInc : Nat := 1
  parent : Std.HashMap UInt32 UInt32 := {}
  roots : Array (String × UInt32) := #[]
  names : Std.HashMap UInt32 String := {}
  nameIds : Std.HashMap String UInt32 := {}
  /-- slot → (node, event name id) -/
  slotAt : Std.HashMap UInt32 (UInt32 × UInt32) := {}
  /-- node → (event name id, slot) -/
  listeners : Std.HashMap UInt32 (Array (UInt32 × UInt32)) := {}
  /-- Templates: per node in pre-order, its kind and the index of its parent (none: the root). -/
  templates : Std.HashMap UInt32 (Array (Kind × Option Nat)) := {}
  errors : Array String := #[]
  warnings : Array String := #[]
  /-- Commands checked so far, by kind. -/
  counts : Std.HashMap String Nat := {}
  deriving Inhabited

namespace Shadow

def err (s : Shadow) (m : String) : Shadow := { s with errors := s.errors.push m }
def warn (s : Shadow) (m : String) : Shadow := { s with warnings := s.warnings.push m }
def live (s : Shadow) (h : UInt32) : Bool := s.kind.contains h
def isRoot (s : Shadow) (h : UInt32) : Bool := s.roots.any (·.2 == h)

/-- Is `a` an ancestor of (or equal to) `b`? -/
partial def ancestor (s : Shadow) (a b : UInt32) (fuel : Nat := 1000000) : Bool :=
  if a == b then true
  else match fuel, s.parent.get? b with
    | 0, _ => false
    | _, none => false
    | f + 1, some p => s.ancestor a p f

partial def attached (s : Shadow) (h : UInt32) (fuel : Nat := 1000000) : Bool :=
  if s.isRoot h then true
  else match fuel, s.parent.get? h with
    | 0, _ => false
    | _, none => false
    | f + 1, some p => s.attached p f

def detach (s : Shadow) (c : UInt32) : Shadow := { s with parent := s.parent.erase c }

def needLive (s : Shadow) (what : String) (h : UInt32) : Shadow :=
  if s.live h then s else s.err s!"{what}: handle {h} is not live"

def needElem (s : Shadow) (what : String) (h : UInt32) : Shadow :=
  match s.kind.get? h with
  | some .elem => s
  | some .text => s.err s!"{what}: handle {h} is a text node"
  | none => s.err s!"{what}: handle {h} is not live"

def needName (s : Shadow) (what : String) (n : UInt32) : Shadow :=
  if s.names.contains n then s else s.err s!"{what}: name id {n} used before INTERN"

def dropListeners (s : Shadow) (h : UInt32) : Shadow :=
  let ls := s.listeners.getD h #[]
  let slotAt := ls.foldl (fun m (_, sl) => m.erase sl) s.slotAt
  { s with slotAt, listeners := s.listeners.erase h }

def created (s : Shadow) (h : UInt32) (k : Kind) : Shadow :=
  { s with kind := s.kind.insert h k, parent := s.parent.erase h, inc := s.inc.insert h s.nextInc, nextInc := s.nextInc + 1 }

/-- Check and apply one command. `ghosts` collects (freed node, its parent, the parent's
incarnation) for nodes freed while still inside a parent. -/
def step (s : Shadow) (ghosts : Array (UInt32 × UInt32 × Nat)) (c : WOp) : Shadow × Array (UInt32 × UInt32 × Nat) :=
  let s := { s with counts := s.counts.insert c.name (s.counts.getD c.name 0 + 1) }
  match c with
  | .createElement h _ n =>
    let s := s.needName "createElement" n
    let s := if h == 0 then s.err "createElement: handle 0"
      else if s.live h then s.err s!"createElement: handle {h} is live (reused without free)" else s
    (s.created h .elem, ghosts)
  | .createText h _ =>
    let s := if h == 0 then s.err "createText: handle 0"
      else if s.live h then s.err s!"createText: handle {h} is live (reused without free)" else s
    (s.created h .text, ghosts)
  | .setAttr h n _ | .removeAttr h n | .setPropStr h n _ | .setPropBool h n _ | .setPropNum h n _ | .removeProp h n =>
    ((s.needElem c.name h).needName c.name n, ghosts)
  | .setText h _ =>
    match s.kind.get? h with
    | some .text => (s, ghosts)
    | some .elem => (s.err s!"setText: handle {h} is an element", ghosts)
    | none => (s.err s!"setText: handle {h} is not live", ghosts)
  | .appendChild p ch =>
    let s := (s.needElem "appendChild" p).needLive "appendChild" ch
    let s := if s.ancestor ch p then s.err s!"appendChild: {ch} is an ancestor of {p} (cycle)" else s
    ({ s with parent := s.parent.insert ch p }, ghosts)
  | .insertBefore p ch r =>
    let s := ((s.needElem "insertBefore" p).needLive "insertBefore" ch).needLive "insertBefore" r
    let s := if s.ancestor ch p then s.err s!"insertBefore: {ch} is an ancestor of {p} (cycle)" else s
    let s := if r == ch then s.warn s!"insertBefore: {ch} before itself"
      else if s.parent.get? r != some p then s.err s!"insertBefore: reference {r} is not a child of {p}" else s
    ({ s with parent := s.parent.insert ch p }, ghosts)
  | .remove h =>
    let s := s.needLive "remove" h
    let s := if s.parent.contains h then s else s.warn s!"remove: {h} has no parent (no-op)"
    (s.detach h, ghosts)
  | .replace o n =>
    let s := (s.needLive "replace" o).needLive "replace" n
    let s := if s.ancestor n o then s.err s!"replace: {n} contains {o} (cycle)" else s
    match s.parent.get? o with
    | some p =>
      ({ s with parent := (s.parent.erase o).insert n p }, ghosts)
    | none =>
      if s.isRoot o then ({ s.detach n with roots := s.roots.map fun (sel, r) => if r == o then (sel, n) else (sel, r) }, ghosts)
      else (s.err s!"replace: {o} has no parent and is not a root (the browser ignores it)", ghosts)
  | .free h =>
    if !s.live h then (s.err s!"free: handle {h} is not live", ghosts)
    else
      let s := if s.attached h then s.err s!"free: {h} is still in the document" else s
      let ghosts := match s.parent.get? h with
        | some p => if s.live p then ghosts.push (h, p, s.inc.getD p 0) else ghosts
        | none => ghosts
      let s := s.dropListeners h
      ({ s with kind := s.kind.erase h, parent := s.parent.erase h, roots := s.roots.filter (·.2 != h) }, ghosts)
  | .setListener h ev slot _ _ =>
    let s := (s.needElem "setListener" h).needName "setListener" ev
    let s := if slot == 0 then s.err "setListener: slot 0" else s
    let s := match s.slotAt.get? slot with
      | some (h', ev') => if h' != h || ev' != ev then s.err s!"setListener: slot {slot} already routes ({h'}, {s.names.getD ev' "?"}); now also ({h}, {s.names.getD ev "?"})" else s
      | none => s
    -- the previous slot for (h, ev), if any, is unbound in the browser now
    let ls := s.listeners.getD h #[]
    let (old, rest) := ls.partition (·.1 == ev)
    let slotAt := old.foldl (fun m (_, sl) => if sl != slot then m.erase sl else m) s.slotAt
    ({ s with slotAt := slotAt.insert slot (h, ev), listeners := s.listeners.insert h (rest.push (ev, slot)) }, ghosts)
  | .removeListener h ev =>
    let s := (s.needElem "removeListener" h).needName "removeListener" ev
    let ls := s.listeners.getD h #[]
    let (old, rest) := ls.partition (·.1 == ev)
    let s := if old.isEmpty then s.warn s!"removeListener: {h} has no {s.names.getD ev "?"} listener" else s
    ({ s with slotAt := old.foldl (fun m (_, sl) => m.erase sl) s.slotAt, listeners := s.listeners.insert h rest }, ghosts)
  | .intern id str =>
    let s := if s.names.contains id then s.err s!"intern: id {id} interned twice" else s
    let s := if s.nameIds.contains str then s.warn s!"intern: {str.quote} interned again as {id}" else s
    ({ s with names := s.names.insert id str, nameIds := s.nameIds.insert str id }, ghosts)
  | .mount sel h =>
    let s := s.needLive "mount" h
    ({ s.detach h with roots := (s.roots.filter (·.1 != sel)).push (sel, h) }, ghosts)
  | .hydrate .. => (s, ghosts)
  | .template tid hs => Id.run do
    let mut s := s
    if tid == 0 then s := s.err "template: id 0"
    if s.templates.contains tid then s := s.err s!"template: id {tid} defined twice"
    if hs.isEmpty then return (s.err s!"template {tid}: no nodes", ghosts)
    -- every node live, listed after its parent; the root's whole subtree listed
    let mut pos : Std.HashMap UInt32 Nat := {}
    let mut shape : Array (Kind × Option Nat) := #[]
    for h : k in [0:hs.size] do
      let x := hs[k]
      match s.kind.get? x with
      | none => s := s.err s!"template {tid}: handle {x} is not live"
      | some kd =>
        if pos.contains x then s := s.err s!"template {tid}: handle {x} listed twice"
        let par := if k == 0 then none else (s.parent.get? x).bind pos.get?
        if k > 0 && par.isNone then s := s.err s!"template {tid}: handle {x} is not inside the subtree of {hs[0]!} (or comes before its parent)"
        shape := shape.push (kd, par)
      pos := pos.insert x k
    for (c, p) in s.parent.toList do
      if pos.contains p && !pos.contains c && s.live c then
        s := s.err s!"template {tid}: {c} is in the subtree of {hs[0]!} but not listed"
    return ({ s with templates := s.templates.insert tid shape }, ghosts)
  | .clone tid hs => Id.run do
    let mut s := s
    let some shape := s.templates.get? tid | return (s.err s!"clone: no template {tid}", ghosts)
    if shape.size != hs.size then return (s.err s!"clone: template {tid} has {shape.size} nodes, not {hs.size}", ghosts)
    let mut seen : Std.HashSet UInt32 := {}
    for x in hs do
      if x == 0 then s := s.err "clone: handle 0"
      else if s.live x then s := s.err s!"clone: handle {x} is live (reused without free)"
      if seen.contains x then s := s.err s!"clone: handle {x} listed twice"
      seen := seen.insert x
    for h : k in [0:hs.size] do
      let (kd, par) := shape[k]!
      s := s.created hs[k] kd
      if let some p := par then s := { s with parent := s.parent.insert hs[k] hs[p]! }
    return (s, ghosts)
  | .effect _ => (s, ghosts)

/-- Every live node, by reachability from the roots. -/
partial def reachableCount (s : Shadow) : Nat := Id.run do
  -- children index from parent links
  let mut kids : Std.HashMap UInt32 (Array UInt32) := {}
  for (c, p) in s.parent.toList do kids := kids.insert p ((kids.getD p #[]).push c)
  let mut stack := s.roots.map (·.2)
  let mut seen : Std.HashSet UInt32 := {}
  while !stack.isEmpty do
    let h := stack.back!
    stack := stack.pop
    if seen.contains h then continue
    seen := seen.insert h
    for k in kids.getD h #[] do stack := stack.push k
  return seen.size

/-- Check a whole buffer, then the end-of-buffer invariants. -/
def checkBuffer (s : Shadow) (ops strs : ByteArray) (what : String := "") : Shadow :=
  match decode ops strs with
  | .error e => s.err s!"{what}decode: {e}"
  | .ok cmds => Id.run do
    let start := s.errors.size
    let mut s := s
    let mut ghosts : Array (UInt32 × UInt32 × Nat) := #[]
    for c in cmds do
      let (s', g) := s.step ghosts c.op
      s := s'; ghosts := g
    -- a node freed while inside a parent stays in that parent's DOM children for good, unless
    -- the parent itself is gone by the end of the buffer
    for (h, p, i) in ghosts do
      if s.live p && s.inc.get? p == some i then
        s := s.err s!"ghost: {h} was freed while still a child of {p}, which stays live"
    let reach := s.reachableCount
    if reach != s.kind.size then
      s := s.err s!"leak: {s.kind.size - reach} live handles are unreachable ({s.kind.size} live, {reach} reachable)"
    if what != "" then
      s := { s with errors := s.errors.extract 0 start ++ (s.errors.extract start s.errors.size).map (what ++ ·) }
    return s

/-- A shadow for a page whose container already holds the nodes of `d` (after hydration). -/
def ofDom (d : Dom) : Shadow := Id.run do
  let mut s : Shadow := { roots := d.roots }
  for (h, n) in d.nodes.toList do
    s := s.created h (if n.isText then .text else .elem)
    if let some p := n.parent then s := { s with parent := s.parent.insert h p }
  return s

end Shadow

/-- Commands of a buffer by kind, e.g. `createElement:3 setAttr:2`. -/
def summary (ops strs : ByteArray) : String :=
  match decode ops strs with
  | .error e => s!"<undecodable: {e}>"
  | .ok cmds =>
    let m : Std.HashMap String Nat := cmds.foldl (fun m c => m.insert c.op.name (m.getD c.op.name 0 + 1)) {}
    " ".intercalate ((m.toList.toArray.qsort (fun a b => a.1 < b.1)).toList.map fun (k, v) => s!"{k}:{v}")

end LeanUI.Testing.Wire
