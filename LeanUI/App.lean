module
public import LeanUI.Diff
public import LeanUI.Effect
/-!
# Programs and the runtime

A LeanUI app is a `Program`: `init`, `update`, `view` and `subscriptions`, all pure (The Elm
Architecture). The runtime owns the model, the mounted tree and the effect callbacks; each event
runs `update`, re-renders, diffs, reconciles subscriptions and flushes one command buffer through
the `Host`.

The runtime's state lives in an `IO.Ref` created by `start`, never in a global (`initialize`d)
ref: globals are persistent, persistent refs mark what they hold as multi-threaded, and
multi-threaded objects are never updated in place, which would turn every array push into a copy.
The step itself (`stepMsgs`) is a pure `StateM` function, so it is tested natively.

`update` receives the model uniquely owned: the step takes the state apart before calling
`update` (`updateModel`) and builds it again from the result. So a model that holds a large array (an editor's pixels) can be
updated in place, without a copy per message, as long as the app itself keeps one reference to
it (`tests/Kit.lean`, `testUniqueModel`).
-/
public section
namespace LeanUI

structure Program (Model Msg : Type) where
  init : String → Model × Cmd Msg
  update : Msg → Model → Model × Cmd Msg
  view : Model → Html Msg
  subscriptions : Model → Sub Msg := fun _ => .none

/-- Where finished updates go: the page (wasm), a server response, or a test. -/
structure Host where
  /-- Called once per update with the command words and the string area. -/
  flush : ByteArray → ByteArray → IO Unit
  /-- Called before `flush` when the update's commands refer to byte arrays (`Buf.blobs`: the
  pixels of `Cmd.putImage`, the bytes of `Cmd.download`). The wasm host hands the browser their
  addresses; hosts that cannot carry bytes (a server driving the page) ignore them. -/
  blobs : Array ByteArray → IO Unit := fun _ => pure ()

/-- A running app as its host drives it. -/
structure Instance where
  /-- The browser reports an event on a listener slot, with the extracted payload. -/
  event : UInt32 → String → IO Unit
  /-- An effect finished (`ok`, payload), or a subscription fired. -/
  callback : UInt32 → Bool → String → IO Unit
  /-- An effect finished with bytes (`Cmd.readFile`, `Cmd.decodeImage`): `ok`, a payload, the
  bytes. -/
  callbackBytes : UInt32 → Bool → String → ByteArray → IO Unit

structure Callback (Msg : Type) where
  /-- The messages the result produces: one for a command's continuation, one per subscriber for
  a subscription that several parts of the app share. -/
  decode : Bool → String → Array Msg
  /-- For effects that answer with bytes (`callbackBytes`); without it, the bytes are dropped
  and `decode` gets the rest. -/
  decodeBytes? : Option (Bool → String → ByteArray → Array Msg) := none
  /-- Subscription callbacks persist; command continuations are freed after one call. -/
  persistent : Bool

structure State (Model Msg : Type) where
  model : Model
  tree : Node Msg
  diff : DiffState Msg
  cbs : Array (Option (Callback Msg)) := #[none]
  freeCbs : Array UInt32 := #[]
  /-- Active subscriptions: identity and callback slot. -/
  subs : Array (String × UInt32) := #[]

variable {Model Msg : Type}

abbrev RunM (Model Msg : Type) := StateM (State Model Msg)

@[inline] def emitR (f : Buf → Buf) : RunM Model Msg Unit :=
  modify fun s => { s with diff := { s.diff with buf := f s.diff.buf } }

def allocCb (c : Callback Msg) : RunM Model Msg UInt32 := modifyGet fun s =>
  if s.freeCbs.isEmpty then (s.cbs.size.toUInt32, { s with cbs := s.cbs.push (some c) })
  else
    let i := s.freeCbs.back!
    (i, { s with freeCbs := s.freeCbs.pop, cbs := s.cbs.set! i.toNat (some c) })

def freeCb (i : UInt32) : RunM Model Msg Unit :=
  modify fun s => { s with cbs := s.cbs.set! i.toNat none, freeCbs := s.freeCbs.push i }

/-- `"<status>\n<body>"`, as the browser reports a finished fetch. -/
def parseResponse (ok : Bool) (payload : String) : Response :=
  match payload.splitOn "\n" with
  | st :: rest => { ok, status := st.toNat?.getD 0, body := "\n".intercalate rest }
  | [] => { ok, status := 0, body := "" }

/-- Emit a command's effects; returns the messages it sends synchronously. -/
partial def execCmd (c : Cmd Msg) (acc : Array Msg) : RunM Model Msg (Array Msg) := do
  match c with
  | .none => return acc
  | .batch cs => cs.foldlM (fun acc c => execCmd c acc) acc
  | .send m => return acc.push m
  | .fetch req k =>
    let cb ← allocCb { decode := fun ok p => #[k (parseResponse ok p)], persistent := false }
    emitR (·.fetchCmd cb req); return acc
  | .after ms m =>
    let cb ← allocCb { decode := fun _ _ => #[m], persistent := false }
    emitR (·.timeoutCmd cb ms); return acc
  | .storageSet k v => emitR (·.storageSetCmd k v); return acc
  | .storageGet k f =>
    let cb ← allocCb { decode := fun ok v => #[f (if ok then some v else none)], persistent := false }
    emitR (·.storageGetCmd cb k); return acc
  | .storageRemove k => emitR (·.storageRemoveCmd k); return acc
  | .pushUrl u => emitR (·.urlCmd true u); return acc
  | .replaceUrl u => emitR (·.urlCmd false u); return acc
  | .focus sel => emitR (·.focusCmd sel); return acc
  | .blur sel => emitR (·.blurCmd sel); return acc
  | .scrollIntoView sel => emitR (·.scrollCmd sel); return acc
  | .log s => emitR (·.logCmd s); return acc
  | .title s => emitR (·.titleCmd s); return acc
  | .nextFrame k =>
    let cb ← allocCb { decode := fun _ t => #[k (Float.ofNat (t.toNat?.getD 0))], persistent := false }
    emitR (·.frameCmd cb); return acc
  | .putImage c img r => emitR (·.putImageCmd c img r); return acc
  | .download n t d => emitR (·.downloadCmd n t d); return acc
  | .readFile file k =>
    let cb ← allocCb { decode := fun _ p => #[k (.error p)], persistent := false,
                       decodeBytes? := some fun ok p b => #[k (if ok then .ok b else .error p)] }
    emitR (·.fileReadCmd cb file); return acc
  | .decodeImage file k =>
    let size (p : String) : Option (Nat × Nat) := match p.splitOn " " with
      | [w, h] => do pure (← w.toNat?, ← h.toNat?)
      | _ => none
    let cb ← allocCb { decode := fun _ p => #[k (.error p)], persistent := false,
                       decodeBytes? := some fun ok p b => #[k (match ok, size p with
                         | true, some (w, h) =>
                           if b.size == 4 * w * h then .ok { width := w, height := h, data := b }
                           else .error s!"decoded {b.size} bytes for {w}×{h} pixels"
                         | _, _ => .error p)] }
    emitR (·.imageDecodeCmd cb file); return acc
  | .grabFrame video k =>
    let frameInfo (p : String) : Option (Nat × Nat × Nat) := match p.splitOn " " with
      | [w, h, t] => do pure (← w.toNat?, ← h.toNat?, ← t.toNat?)
      | _ => none
    let cb ← allocCb { decode := fun _ p => #[k (.error p)], persistent := false,
                       decodeBytes? := some fun ok p b => #[k (match ok, frameInfo p with
                         | true, some (w, h, t) =>
                           if b.size == 4 * w * h then .ok ({ width := w, height := h, data := b }, t)
                           else .error s!"grabbed {b.size} bytes for {w}×{h} pixels"
                         | _, _ => .error p)] }
    emitR (·.frameGrabCmd cb video); return acc
  | .fileUrl file k =>
    let cb ← allocCb { decode := fun _ p => #[k p], persistent := false }
    emitR (·.fileUrlCmd cb file); return acc

/-- The wanted subscriptions grouped by identity, in first-seen order: one browser subscription
per identity, whose callback delivers a message to every part of the app that wants it (two
components can both follow the URL, or both tick every second). -/
def groupSubs (want : Array (String × Nat × (String → Option Msg))) :
    Array (String × Nat × Array (String → Option Msg)) :=
  want.foldl (init := #[]) fun acc (ident, ms, f) =>
    match acc.findIdx? (·.1 == ident) with
    | some i => acc.modify i fun (k, ms, fs) => (k, ms, fs.push f)
    | none => acc.push (ident, ms, #[f])

/-- Start, stop and retarget subscriptions so the active set matches `sub`. -/
def syncSubs (sub : Sub Msg) : RunM Model Msg Unit := do
  let want := groupSubs sub.flatten
  let st ← get
  -- stop the ones no longer wanted
  let mut keep := #[]
  for (ident, cb) in st.subs do
    if want.any (·.1 == ident) then keep := keep.push (ident, cb)
    else emitR (·.subClear cb); freeCb cb
  -- start new ones; retarget kept ones (their messages may have changed)
  for (ident, ms, fs) in want do
    let c : Callback Msg := { decode := fun _ p => fs.filterMap (· p), persistent := true }
    match keep.find? (·.1 == ident) with
    | some (_, cb) => modify fun s => { s with cbs := s.cbs.set! cb.toNat (some c) }
    | none =>
      let cb ← allocCb c
      if ident == "url" then emitR (·.urlListen cb)
      else if ident == "keys" then emitR (·.keysListen cb)
      else emitR (·.intervalSet cb ms)
      keep := keep.push (ident, cb)
  modify fun s => { s with subs := keep }

/-- Run `update` on the state's model, which is taken out of the state first (the state is taken
apart field by field, so when it is unique the model it held is too): an `update` that changes
an array of the model in place does so without copying it. -/
@[inline] def updateModel (p : Program Model Msg) (m : Msg) (s : State Model Msg) : Cmd Msg × State Model Msg :=
  match s with
  | { model, tree, diff, cbs, freeCbs, subs } =>
    let (model, cmd) := p.update m model
    (cmd, { model, tree, diff, cbs, freeCbs, subs })

/-- Process messages (and the messages their commands send), then render once and reconcile
subscriptions. Bounded, so an app that sends messages forever cannot hang the page. -/
def stepMsgs (p : Program Model Msg) (msgs : Array Msg) : RunM Model Msg Unit := do
  let mut queue := msgs
  let mut fuel := 10000
  while !queue.isEmpty && fuel > 0 do
    let mut next := #[]
    for m in queue do
      let cmd ← modifyGet (updateModel p m)
      next ← execCmd cmd next
      fuel := fuel - 1
    queue := next
  -- take the tree and diff state out of the state first, so the diff owns them uniquely and
  -- updates its arrays in place instead of copying them
  let (tree, diff, model) ← modifyGet fun s => ((s.tree, s.diff, s.model), { s with tree := default, diff := {} })
  let (tree, diff) := (patch 0 tree (p.view model)).run diff
  modify fun s => { s with tree, diff }
  syncSubs (p.subscriptions model)

/-- Count the DOM nodes a view produces (what hydration claims; void elements get no children). -/
partial def countNodes : Html Msg → Nat
  | .text _ => 1
  | .elem _ tag _ kids => (effectiveKids tag kids).foldl (fun n k => n + countNodes k) 1
  | .lazy _ _ r => countNodes (r ())

/-- The first state: mount (or hydrate) the initial view into `selector` and run `init`'s
commands. -/
def initState (p : Program Model Msg) (flags selector : String) (hydrate : Bool) : State Model Msg :=
  let (model, cmd) := p.init flags
  let v := p.view model
  let (tree, diff) :=
    if hydrate then
      -- claim first, then say how many nodes were claimed: the view is forced once
      let (n, d) := (mount v).run { hydrating := true }
      (n, { d with buf := d.buf.prependHydrate selector 1 n.size.toUInt32 })
    else
      (do let n ← mount v; emit (·.mount selector n.handle); pure n).run {}
  let st : State Model Msg := { model, tree, diff := { diff with hydrating := false } }
  let (msgs, st) := (execCmd cmd #[]).run st
  let ((), st) := (do if !msgs.isEmpty then stepMsgs p msgs else syncSubs (p.subscriptions model)).run st
  st

/-- Start an app and return the handle its host drives. The state lives in a ref created here,
taken out (uniquely owned) for every step and put back after the flush. -/
def start (p : Program Model Msg) (host : Host) (flags selector : String) (hydrate : Bool) : IO Instance := do
  let ref ← IO.mkRef (none : Option (State Model Msg))
  let finish (st : State Model Msg) : IO Unit := do
    if !st.diff.buf.blobs.isEmpty then host.blobs st.diff.buf.blobs
    if !st.diff.buf.isEmpty then host.flush st.diff.buf.ops st.diff.buf.strs
    ref.set (some { st with diff := { st.diff with buf := st.diff.buf.reset } })
  finish (initState p flags selector hydrate)
  let run (f : State Model Msg → State Model Msg) : IO Unit := do
    -- `none` while a step is running: a re-entrant call (an event fired while a buffer was being
    -- applied) is dropped here; the browser runtime queues such events instead.
    let some st ← ref.modifyGet (fun o => (o, none)) | return
    finish (f st)
  return {
    event := fun slot payload => run fun st =>
      match (handlerOf st.diff slot).bind (·.decode payload) with
      | some m => ((stepMsgs p #[m]).run st).2
      | none => st
    callback := fun cb ok payload => run fun st =>
      match st.cbs[cb.toNat]?.join with
      | none => st
      | some c =>
        let st := if c.persistent then st else ((freeCb cb).run st).2
        let msgs := c.decode ok payload
        if msgs.isEmpty then st else ((stepMsgs p msgs).run st).2
    callbackBytes := fun cb ok payload bytes => run fun st =>
      match st.cbs[cb.toNat]?.join with
      | none => st
      | some c =>
        let st := if c.persistent then st else ((freeCb cb).run st).2
        let msgs := match c.decodeBytes? with
          | some f => f ok payload bytes
          | none => c.decode ok payload
        if msgs.isEmpty then st else ((stepMsgs p msgs).run st).2 }

end LeanUI
