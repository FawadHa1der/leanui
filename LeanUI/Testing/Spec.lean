module
public import Std.Data.HashSet
public import LeanUI.App
public import LeanUI.Testing.Dom
public import LeanUI.Testing.Tree
public import LeanUI.Testing.Wire
/-!
# The reference semantics, a checked session, and the invariants

`patchS` is a deliberately naive model of what a patch must achieve, written on first-order
trees: it matches children by key with a plain lookup (no prefix/suffix trimming, no LIS), and it
says which lazy thunks the diff forces. Its result is the *effective* view: the view the DOM must
show, where a lazy node whose deps did not change keeps the content it had (that is what makes a
pinned lazy node a stale probe: the DOM must keep the old content, and the thunk must not run).

A `Session` drives the real engine (`LeanUI.mount`/`patch` through `App.initState`), applies
every buffer to the DOM model (`Dom.apply`) and to the strict protocol checker
(`Wire.Shadow`), and `Session.check` verifies after every step:

* the DOM equals the effective view, strictly (namespaces, attributes, properties, listener
  payloads and flags, text boundaries) and by the harness's `canonHtml`;
* no protocol errors in either model; no leaked handles;
* the engine's mounted tree (`Node`) names exactly the DOM's handles and listener slots;
* handle allocator: free list without duplicates, disjoint from live handles, every allocated
  handle live or free;
* listener slots: slot 0 unused, free list without duplicates, a slot is live iff not free, the
  live slots are exactly the DOM's listener slots and as many as the view's listeners;
* routing: every listener's slot decodes test payloads to exactly the message the effective
  view's handler produces;
* lazy thunks forced == the model's count; re-patching the same view emits nothing and forces
  nothing (idempotence).
-/
public section
namespace LeanUI.Testing

/-! ## The model -/

abbrev SpecM := StateM Nat

private def tickS : SpecM Unit := modify (· + 1)

partial def mountS : T → SpecM T
  | .text s => pure (.text s)
  -- a void element gets no children, whatever the view names
  | .elem ns tag attrs kids => return .elem ns tag attrs (← (effectiveKids tag kids).mapM mountS)
  | .lazy pin b => do tickS; return .lazy (some (T.deps pin b)) (← mountS b)

def uniqueKeysS (ks : Array (Option String)) : Bool := Id.run do
  let mut seen : Std.HashSet String := {}
  for k in ks do
    match k with
    | none => return false
    | some k => if seen.contains k then return false else seen := seen.insert k
  return true

mutual

/-- `old` is effective (every lazy node carries the deps the engine stored); returns the new
effective view and counts forced thunks. -/
partial def patchS (old new : T) : SpecM T :=
  match old, new with
  | .lazy d o, .lazy pin r =>
    let e := T.deps pin r
    if d == some e then pure old else do tickS; return .lazy (some e) (← patchS o r)
  | .lazy _ o, n => patchS o n
  | o, .lazy pin r => do tickS; return .lazy (some (T.deps pin r)) (← patchS o r)
  | .text _, .text t => pure (.text t)
  | .elem ns tag _ kids, .elem ns' tag' attrs' kids' =>
    if ns == ns' && tag == tag' && old.keyOld == new.keyNew then
      return .elem ns tag attrs' (← patchKidsS kids (effectiveKids tag kids'))
    else mountS new
  | _, n => mountS n

partial def patchKidsS (old new : Array T) : SpecM (Array T) := do
  if old.isEmpty && new.isEmpty then return old
  let keyed := !old.isEmpty && !new.isEmpty && uniqueKeysS (old.map T.keyOld) && uniqueKeysS (new.map T.keyNew)
  if !keyed then
    let mut out := #[]
    for h : i in [0:new.size] do
      out := out.push (← if h' : i < old.size then patchS old[i] new[i] else mountS new[i])
    return out
  let index : Std.HashMap String T := old.foldl (fun m o => m.insert (o.keyOld.getD "") o) {}
  new.mapM fun n => match index.get? (n.keyNew.getD "") with
    | some o => patchS o n
    | none => mountS n

end

/-! ## Strict canonical form of the DOM model -/

/-- Same format as `T.canon`. `skip h name` hides attributes the engine does not know about
(server-rendered attributes that came from properties). `slots` adds listener slots. -/
partial def strictDom (d : Dom) (h : UInt32) (skip : UInt32 → String → Bool := fun _ _ => false)
    (slots : Bool := false) (props : Bool := true) : String :=
  let n := d.get h
  if n.isText then "#" ++ lp n.text
  else
    let ls := n.listeners.map fun (ev, sl, pl, fl) => (ev, if slots then s!"{pl}/{fl}@{sl}" else s!"{pl}/{fl}")
    canonElem n.ns n.tag (n.attrs.filter fun (k, _) => !skip h k) (if props then n.props else #[]) ls
      (String.join (n.kids.toList.map fun k => strictDom d k skip slots props))

/-! ## Sessions -/

structure Session where
  diff : DiffState String
  node : Node String
  dom : Dom
  shadow : Wire.Shadow
  /-- The effective view the DOM must show. -/
  eff : T
  renders : IO.Ref Nat
  /-- Server-rendered attributes (from properties) the engine does not track, by handle. -/
  ghosts : Std.HashMap UInt32 (Array String) := {}
  steps : Nat := 0
  /-- Commands sent so far. -/
  commands : Nat := 0
  bytes : Nat := 0
  /-- Keep every flushed buffer (`Buf.encode` format), e.g. to replay it in a browser. -/
  recording : Bool := false
  log : Array ByteArray := #[]
  /-- Rewrites the command words of every buffer before it is applied: a *mutant* engine, for
  testing the tests (the shrinker self-test and mutation scoring). -/
  mutant : Option (ByteArray → ByteArray → ByteArray) := none

/-- A program that shows `t` and never changes (to start sessions through `App.initState`). -/
def staticProgram (c : IO.Ref Nat) (t : T) : Program Unit String where
  init _ := ((), .none)
  update _ m := (m, .none)
  view _ := t.toHtml c

/-- The payloads every listener is fired with in routing checks. -/
def testPayloads : Array String := #["", "Enter", "x", "true", "a=1\nb=2", "v😀"]

namespace Session

/-- Apply the pending buffer to both models and reset it. -/
def flush (s : Session) (what : String) : Session :=
  let b0 := s.diff.buf
  if b0.isEmpty then s else
  let b := match s.mutant with | some f => { b0 with ops := f b0.ops b0.strs } | none => b0
  let shadow := s.shadow.checkBuffer b.ops b.strs (what ++ ": ")
  let dom := s.dom.apply b.ops b.strs
  -- server-rendered attributes stop being ghosts once the engine sets or removes them
  let ghosts := if s.ghosts.isEmpty then s.ghosts else
    match Wire.decode b.ops b.strs with
    | .error _ => s.ghosts
    | .ok cmds => cmds.foldl (init := s.ghosts) fun g c => match c.op with
      | .setAttr h n _ | .removeAttr h n =>
        let nm := shadow.names.getD n "?"
        g.modify h (·.filter (· != nm))
      | .free h | .createElement h .. => g.erase h
      | .clone _ hs => hs.foldl (·.erase ·) g
      | _ => g
  { s with shadow, dom, ghosts, diff := { s.diff with buf := b0.reset },
           log := if s.recording then s.log.push b.encode else s.log,
           commands := s.commands + (match Wire.decode b.ops b.strs with | .ok cs => cs.size | .error _ => 0),
           bytes := s.bytes + b.ops.size + b.strs.size }

def root (s : Session) : UInt32 := (s.dom.rootOf "#app").getD 0

/-- Start a session by mounting `t` (`App.initState`, hydrate = false). Returns the session and
the failures of the mount step. `templates := false` runs the engine without template cloning
(mounting as `initState` does, with that flag off). -/
def mount (c : IO.Ref Nat) (t : T) (recording := false) (mutant : Option (ByteArray → ByteArray → ByteArray) := none)
    (templates := true) : IO (Session × Array String) := do
  let r0 ← c.get
  let (tree, diff) ← if templates then do
      let st ← IO.lazyPure fun _ => initState (staticProgram c t) "" "#app" false
      pure (st.tree, st.diff)
    else IO.lazyPure fun _ =>
      (do let n ← LeanUI.mount (t.toHtml c); emit (·.mount "#app" n.handle); pure n).run ({ templates := false } : DiffState String)
  let r1 ← c.get
  let (eff, want) := (mountS t).run 0
  let s : Session := { diff, node := tree, dom := {}, shadow := {}, eff, renders := c, recording, mutant }
  let s := s.flush "mount"
  let fails := if r1 - r0 != want then #[s!"mount: forced {r1 - r0} lazy thunks, the model says {want}"] else #[]
  return (s, fails)

end Session

/-! ## Invariants -/

/-- Does a template the browser holds (the model's snapshot) show the engine's shape: the same
namespaces, tags, effective attributes (in DOM order) and texts? -/
partial def snapMatches : Snap → TplShape → Bool
  | .text a, .text b => a == b
  | .elem ns tag attrs kids, .elem ns' tag' as _ ks =>
    ns == ns'.code && tag == tag' && attrs == as.foldl (fun acc (k, v) => Dom.setKV acc k v) #[] &&
      kids.size == ks.size && (kids.zip ks).all fun (k, sh) => snapMatches k sh
  | _, _ => false

namespace Session

/-- Does the engine's mounted tree name exactly the DOM's nodes and listener slots? -/
partial def nodeMatches (d : Dom) : Node String → UInt32 → Array String
  | .lazy _ _ n, h => nodeMatches d n h
  | .text h' s, h =>
    let dn := d.get h
    if h' != h then #[s!"node: engine text handle {h'} where the DOM has {h}"]
    else if !dn.isText then #[s!"node: engine text {h} is a DOM element"]
    else if dn.text != s then #[s!"node: engine text {h} is {s.quote}, DOM has {dn.text.quote}"]
    else #[]
  | .elem h' _ tag _ _ ls kids _, h =>
    let dn := d.get h
    if h' != h then #[s!"node: engine element handle {h'} where the DOM has {h}"]
    else if dn.isText then #[s!"node: engine element {h} is a DOM text"]
    else if dn.tag != tag then #[s!"node: engine tag {tag} at {h}, DOM has {dn.tag}"]
    else if dn.kids.size != kids.size then #[s!"node: engine element {h} has {kids.size} children, DOM has {dn.kids.size}"]
    else
      let mine := (ls.map fun (e, s) => s!"{e}@{s}").qsort (· < ·)
      let theirs := (dn.listeners.map fun (e, s, _, _) => s!"{e}@{s}").qsort (· < ·)
      let here := if mine != theirs then #[s!"node: engine listeners of {h} are {mine}, DOM has {theirs}"] else #[]
      (kids.zip dn.kids).foldl (fun acc (k, dh) => acc ++ nodeMatches d k dh) here

/-- Routing: walk the effective view and the DOM together and fire every listener. -/
partial def routing (d : Dom) (diff : DiffState String) : T → UInt32 → Array String
  | .lazy _ b, h => routing d diff b h
  | .text _, _ => #[]
  | .elem _ _ attrs kids, h =>
    let dn := d.get h
    let want := effListeners attrs
    let here := Id.run do
      let mut out := #[]
      if want.size != dn.listeners.size then
        out := out.push s!"routing: {h} has {dn.listeners.size} listeners, the view {want.size}"
      for l in want do
        match dn.listeners.find? (·.1 == l.event) with
        | none => out := out.push s!"routing: {h} lacks its {l.event} listener"
        | some (_, sl, pl, fl) =>
          if pl != l.payload.code then out := out.push s!"routing: {h} {l.event} extracts payload {pl}, the view {l.payload.code}"
          if fl != l.flags then out := out.push s!"routing: {h} {l.event} has flags {fl}, the view {l.flags}"
          match handlerOf diff sl with
          | none => out := out.push s!"routing: {h} {l.event} slot {sl} has no handler"
          | some hd =>
            for p in testPayloads do
              let got := hd.decode p
              let exp := l.decode p
              if got != exp then
                out := out.push s!"routing: {h} {l.event} slot {sl} payload {p.quote} gives {got}, the view's handler {exp}"
      return out
    if dn.kids.size != kids.size then here
    else (kids.zip dn.kids).foldl (fun acc (k, dh) => acc ++ routing d diff k dh) here

partial def viewListeners : T → Nat
  | .lazy _ b => viewListeners b
  | .text _ => 0
  | .elem _ _ attrs kids => kids.foldl (fun n k => n + viewListeners k) (effListeners attrs).size

def hasDups (xs : Array UInt32) : Bool := Id.run do
  let mut seen : Std.HashSet UInt32 := {}
  for x in xs do
    if seen.contains x then return true
    seen := seen.insert x
  return false

/-- Every invariant (see the module doc). Empty means the step is correct. -/
def check (s : Session) (what : String) : Array String := Id.run do
  let mut out : Array String := #[]
  let d := s.dom
  for e in d.errors do out := out.push s!"{what}: Dom.apply: {e}"
  for e in s.shadow.errors do out := out.push s!"{what}: wire: {e}"
  -- the browser holds exactly the engine's templates (a lost TEMPLATE breaks a later CLONE)
  let shapes := s.diff.tplShapes
  if d.templates.size != shapes.size then
    out := out.push s!"{what}: the engine has {shapes.size} templates, the DOM {d.templates.size}"
  for h : i in [0:shapes.size] do
    match d.templates.get? (i + 1).toUInt32 with
    | none => out := out.push s!"{what}: template {i + 1} is missing in the DOM"
    | some t => if !snapMatches t shapes[i] then out := out.push s!"{what}: template {i + 1} differs from its shape"
  let some root := d.rootOf "#app" | return out.push s!"{what}: nothing mounted"
  -- the DOM shows the effective view
  let skip := fun h n => (s.ghosts.getD h #[]).contains n
  let got := strictDom d root skip
  let want := s.eff.canon
  if got != want then
    let i := (got.toList.zip want.toList).findIdx (fun (a, b) => a != b)
    out := out.push s!"{what}: DOM differs from the view at char {i}\n   got: {((got.drop (i - min i 60)).take 200)}\n  want: {((want.drop (i - min i 60)).take 200)}"
    return out
  if s.ghosts.isEmpty then
    let hg := d.canon root
    let hw := canonHtml s.eff.toHtml'
    if hg != hw then out := out.push s!"{what}: harness canon differs: {hg.take 200} vs {hw.take 200}"
  -- handles
  let live := d.reachable root
  if live.size != d.nodes.size then out := out.push s!"{what}: {d.nodes.size - live.size} leaked DOM handles"
  out := out ++ (nodeMatches d s.node root).map (what ++ ": " ++ ·)
  let free := s.diff.freeNodes
  if hasDups free then out := out.push s!"{what}: duplicate handles in the free list"
  let liveSet : Std.HashSet UInt32 := live.foldl (·.insert ·) {}
  for f in free do
    if liveSet.contains f then out := out.push s!"{what}: handle {f} is both live and free"; break
  if live.any (· ≥ s.diff.nextNode) || free.any (· ≥ s.diff.nextNode) then
    out := out.push s!"{what}: a handle at or above nextNode {s.diff.nextNode}"
  if live.size + free.size + 1 != s.diff.nextNode.toNat then
    out := out.push s!"{what}: {s.diff.nextNode.toNat - 1} handles allocated, {live.size} live + {free.size} free"
  -- slots
  let slots := s.diff.slots
  if (slots[0]?.join).isSome then out := out.push s!"{what}: slot 0 is in use"
  let fs := s.diff.freeSlots
  if hasDups fs then out := out.push s!"{what}: duplicate slots in the free list"
  let freeSet : Std.HashSet UInt32 := fs.foldl (·.insert ·) {}
  let mut liveSlots : Array UInt32 := #[]
  for h : i in [1:slots.size] do
    let used := slots[i].isSome
    if used == freeSet.contains i.toUInt32 then
      out := out.push s!"{what}: slot {i} is {if used then "live and free" else "neither live nor free"}"
    if used then liveSlots := liveSlots.push i.toUInt32
  if fs.any (fun x => x == 0 || x.toNat ≥ slots.size) then out := out.push s!"{what}: free slot out of range"
  let domSlots := (live.foldl (fun acc h => acc ++ (d.get h).listeners.map (·.2.1)) #[]).qsort (· < ·)
  if hasDups domSlots then out := out.push s!"{what}: one slot on two DOM listeners"
  if domSlots != liveSlots.qsort (· < ·) then
    out := out.push s!"{what}: {liveSlots.size} live slots but {domSlots.size} DOM listeners (slots {(liveSlots.qsort (· < ·)).toList.take 12} vs {domSlots.toList.take 12})"
  let vl := viewListeners s.eff
  if vl != domSlots.size then out := out.push s!"{what}: the view has {vl} listeners, the DOM {domSlots.size}"
  out := out ++ (routing d s.diff s.eff root).map (what ++ ": " ++ ·)
  return out

/-- Patch to `t`, apply, check every invariant, then check that patching to `t` again emits no
command and forces no thunk. -/
def step (s : Session) (t : T) (what : String) (idempotence := true) : IO (Session × Array String) := do
  let c := s.renders
  let r0 ← c.get
  let (node, diff) ← IO.lazyPure fun _ => (patch 0 s.node (t.toHtml c)).run s.diff
  let r1 ← c.get
  let (eff, want) := (patchS s.eff t).run 0
  let s := { s with node, diff, eff, steps := s.steps + 1 }.flush what
  let mut fails := s.check what
  if r1 - r0 != want then fails := fails.push s!"{what}: forced {r1 - r0} lazy thunks, the model says {want}"
  if !idempotence || !fails.isEmpty then return (s, fails)
  let (node, diff) ← IO.lazyPure fun _ => (patch 0 s.node (t.toHtml c)).run s.diff
  let r2 ← c.get
  if !diff.buf.isEmpty then
    fails := fails.push s!"{what}: re-patching the same view emitted {Wire.summary diff.buf.ops diff.buf.strs}"
  if r2 != r1 then fails := fails.push s!"{what}: re-patching the same view forced {r2 - r1} lazy thunks"
  let s := { s with node, diff }.flush (what ++ " (again)")
  return (s, fails)

end Session

end LeanUI.Testing
