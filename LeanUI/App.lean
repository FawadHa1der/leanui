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

/-- A running app as its host drives it. -/
structure Instance where
  /-- The browser reports an event on a listener slot, with the extracted payload. -/
  event : UInt32 → String → IO Unit
  /-- An effect finished (`ok`, payload), or a subscription fired. -/
  callback : UInt32 → Bool → String → IO Unit

structure Callback (Msg : Type) where
  decode : Bool → String → Option Msg
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
    let cb ← allocCb { decode := fun ok p => some (k (parseResponse ok p)), persistent := false }
    emitR (·.fetchCmd cb req); return acc
  | .after ms m =>
    let cb ← allocCb { decode := fun _ _ => some m, persistent := false }
    emitR (·.timeoutCmd cb ms); return acc
  | .storageSet k v => emitR (·.storageSetCmd k v); return acc
  | .storageGet k f =>
    let cb ← allocCb { decode := fun ok v => some (f (if ok then some v else none)), persistent := false }
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
    let cb ← allocCb { decode := fun _ t => some (k (Float.ofNat (t.toNat?.getD 0))), persistent := false }
    emitR (·.frameCmd cb); return acc

/-- Start, stop and retarget subscriptions so the active set matches `sub`. -/
def syncSubs (sub : Sub Msg) : RunM Model Msg Unit := do
  let want := sub.flatten
  let st ← get
  -- stop the ones no longer wanted
  let mut keep := #[]
  for (ident, cb) in st.subs do
    if want.any (·.1 == ident) then keep := keep.push (ident, cb)
    else emitR (·.subClear cb); freeCb cb
  -- start new ones; retarget kept ones (their message may have changed)
  for (ident, ms, f) in want do
    match keep.find? (·.1 == ident) with
    | some (_, cb) => modify fun s => { s with cbs := s.cbs.set! cb.toNat (some { decode := fun _ p => f p, persistent := true }) }
    | none =>
      let cb ← allocCb { decode := fun _ p => f p, persistent := true }
      if ident == "url" then emitR (·.urlListen cb) else emitR (·.intervalSet cb ms)
      keep := keep.push (ident, cb)
  modify fun s => { s with subs := keep }

/-- Process messages (and the messages their commands send), then render once and reconcile
subscriptions. Bounded, so an app that sends messages forever cannot hang the page. -/
def stepMsgs (p : Program Model Msg) (msgs : Array Msg) : RunM Model Msg Unit := do
  let mut queue := msgs
  let mut fuel := 10000
  while !queue.isEmpty && fuel > 0 do
    let mut next := #[]
    for m in queue do
      let (model, cmd) := p.update m (← get).model
      modify fun s => { s with model }
      next ← execCmd cmd next
      fuel := fuel - 1
    queue := next
  let s ← get
  let (tree, diff) := (patch 0 s.tree (p.view s.model)).run s.diff
  set { s with tree, diff }
  syncSubs (p.subscriptions s.model)

/-- Count the DOM nodes a view produces (what hydration claims). -/
partial def countNodes : Html Msg → Nat
  | .text _ => 1
  | .elem _ _ _ kids => kids.foldl (fun n k => n + countNodes k) 1
  | .lazy _ r => countNodes (r ())

/-- The first state: mount (or hydrate) the initial view into `selector` and run `init`'s
commands. -/
def initState (p : Program Model Msg) (flags selector : String) (hydrate : Bool) : State Model Msg :=
  let (model, cmd) := p.init flags
  let v := p.view model
  let (tree, diff) :=
    if hydrate then
      (mount v).run { hydrating := true, buf := ({} : Buf).hydrate selector 1 (countNodes v).toUInt32 }
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
        match c.decode ok payload with
        | some m => ((stepMsgs p #[m]).run st).2
        | none => st }

end LeanUI
