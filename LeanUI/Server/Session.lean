module
public import Std.Sync
public import Std.Data.HashMap
public import LeanUI.App
public import LeanUI.Server.Http
/-!
# Server-driven sessions

A server-driven page is a thin client: the browser runtime applies command buffers and reports
events, and the program runs natively on the server. The remote protocol (`docs/DESIGN.md` §2) is
one `POST <endpoint>/<session>` per input, with a text body

* `h`: hydrate (the first request: adopt the server-rendered nodes, attach the listeners),
* `e\n<slot>\n<payload>`: an event on a listener slot, with the payload the browser extracted,
* `c\n<cb>\n<0|1>\n<payload>`: an effect finished (or a subscription fired),

and the response body is the update: `Buf.encode` = `[u32 opsBytes][ops][strs]`, possibly empty.
Error responses (`400`, `409`, `410`) also carry a valid buffer, holding one `log` command with
the reason, because the runtime applies whatever body it receives.

## Sessions are actors

Each session runs on its own dedicated thread (`IO.asTask (prio := .dedicated)`), which *creates*
the running program (`LeanUI.start`) and then serves the requests that arrive on its inbox, a
`Std.CloseableChannel`, replying through an `IO.Promise`. The HTTP handler only forwards. This
matters for speed, not just for ordering: Lean marks every object reachable from a value that
crosses threads (a task closure, a shared `IO.Ref` or `Mutex`) as *multi-threaded*, and a
multi-threaded object is never updated in place, so if session state lived in a shared table that
handler tasks step directly, every model array, slot table and command buffer would be copied on
each update (`tests/Server.lean` measures both designs). Inside the actor the state never crosses
a thread, so it stays single-threaded and uniquely owned, exactly as in the browser.

## Lifecycle

A session is *reserved* when a page is rendered (cheap: an id and a closure, no thread) and its
actor is spawned by the first request, so pages whose browser runs the wasm instead never cost a
thread. Reserved sessions expire after `pendingMs`, live ones after `idleMs` without requests; the
counts are capped (`maxPending`, `maxLive`), evicting the least recently used. A request for an
unknown or expired session gets `410 Gone`.
-/
public section
namespace LeanUI.Server

/-! ## The remote protocol -/

namespace Remote

/-- One request of the remote protocol. -/
inductive Msg where
  | hydrate
  | event (slot : UInt32) (payload : String)
  | callback (cb : UInt32) (ok : Bool) (payload : String)
  deriving BEq, Repr, Inhabited

private def u32? (s : String) : Option UInt32 :=
  match s.toNat? with
  | some n => if n < 4294967296 then some n.toUInt32 else none
  | none => none

/-- Parse a request body. Payloads may contain newlines (form data), so only the first fields
are split off. -/
def parse (body : String) : Except String Msg :=
  match body.splitOn "\n" with
  | ["h"] | ["h", ""] => .ok .hydrate
  | "e" :: slot :: rest =>
    match u32? slot with
    | some s => .ok (.event s ("\n".intercalate rest))
    | none => .error s!"bad listener slot {slot.quote}"
  | "c" :: cb :: ok :: rest =>
    match u32? cb, ok with
    | some c, "1" => .ok (.callback c true ("\n".intercalate rest))
    | some c, "0" => .ok (.callback c false ("\n".intercalate rest))
    | none, _ => .error s!"bad callback id {cb.quote}"
    | _, _ => .error s!"bad callback status {ok.quote} (expected 0 or 1)"
  | _ => .error s!"not a LeanUI request: {(body.take 40).toString.quote}"

/-- The body the browser runtime sends for a message (the inverse of `parse`). -/
def Msg.body : Msg → String
  | .hydrate => "h"
  | .event s p => s!"e\n{s}\n{p}"
  | .callback c ok p => s!"c\n{c}\n{if ok then 1 else 0}\n{p}"

end Remote

/-- The outcome of one request to a session. -/
inductive Reply where
  /-- The update (an encoded command buffer, empty if nothing changed). -/
  | update (buf : ByteArray)
  /-- The request was malformed. -/
  | bad (msg : String)
  /-- The request came out of order (an event before hydration, a second hydration). -/
  | conflict (msg : String)
  /-- No such session (never existed, expired, or evicted). -/
  | gone
  /-- The session failed. -/
  | failed (msg : String)
  deriving Inhabited

/-- `[u32 opsBytes][ops][strs]` from one flush (the same bytes as `Buf.encode`). -/
def encodeFlush (ops strs : ByteArray) : ByteArray :=
  pushU32 (ByteArray.emptyWithCapacity (4 + ops.size + strs.size)) ops.size.toUInt32 ++ ops ++ strs

/-- A buffer holding one `log` command: what error responses carry, so the runtime (which applies
any body it gets) logs the reason instead of failing to decode it. -/
def logBuffer (msg : String) : ByteArray := (({} : Buf).logCmd msg).encode

namespace Reply

def status : Reply → Nat
  | .update _ => 200 | .bad _ => 400 | .conflict _ => 409 | .gone => 410 | .failed _ => 500

def toRes (r : Reply) (session : String) : Res :=
  let body := match r with
    | .update b => b
    | .bad m => logBuffer s!"LeanUI server: bad request: {m}"
    | .conflict m => logBuffer s!"LeanUI server: {m}"
    | .gone => logBuffer s!"LeanUI server: session {session} has expired; reload the page to start a new one"
    | .failed m => logBuffer s!"LeanUI server: session failed: {m}"
  { status := r.status, body,
    headers := #[("content-type", "application/octet-stream"), ("cache-control", "no-store")] }

end Reply

/-! ## Actors -/

/-- A request and where its reply goes. -/
structure Envelope where
  msg : Remote.Msg
  reply : IO.Promise Reply

/-- A running session: its inbox and its thread. -/
structure Actor where
  inbox : Std.CloseableChannel Envelope
  /-- Resolves when the actor has stopped. -/
  done : Task (Except IO.Error Unit)

/-- What happened to the flushes of one request. -/
private def takeFlush (out : IO.Ref (Array ByteArray)) : IO Reply := do
  let bufs ← out.modifyGet fun a => (a, #[])
  match bufs with
  | #[] => return .update .empty
  | #[b] => return .update b
  | _ => return .failed s!"internal: {bufs.size} flushes for one request"

/-- The actor's body. Runs on its own thread and owns the program: the instance and the output
buffer are created here, so they stay single-threaded (see the module docs). -/
def actorMain {Model Msg : Type} (p : Program Model Msg) (flags selector : String)
    (inbox : Std.CloseableChannel Envelope) : IO Unit := do
  let out ← IO.mkRef (#[] : Array ByteArray)
  let host : Host := { flush := fun ops strs => out.modify (·.push (encodeFlush ops strs)) }
  -- the page already shows the view of `init flags`; hydration claims it
  let inst ← start p host flags selector (hydrate := true)
  let mut hydrated := false
  try
    for env in inbox.sync do
      let reply ← match env.msg with
        | .hydrate =>
          if hydrated then pure (.conflict "this session is already hydrated")
          else do hydrated := true; takeFlush out
        | .event slot payload =>
          if !hydrated then pure (.conflict "event before hydration")
          else do inst.event slot payload; takeFlush out
        | .callback cb ok payload =>
          if !hydrated then pure (.conflict "callback before hydration")
          else do inst.callback cb ok payload; takeFlush out
      env.reply.resolve reply
  finally
    -- stop accepting, and answer whatever is still queued
    discard <| (inbox.close).toBaseIO
    let mut more := true
    while more do
      match ← inbox.tryRecv with
      | some env => env.reply.resolve .gone
      | none => more := false

namespace Actor

/-- Start a session actor on a dedicated thread. -/
def spawn {Model Msg : Type} (p : Program Model Msg) (flags selector : String) : BaseIO Actor := do
  let inbox ← Std.CloseableChannel.new
  let done ← IO.asTask (prio := .dedicated) (actorMain p flags selector inbox)
  return { inbox, done }

/-- Send a message; the task resolves with the reply (`gone` if the actor has stopped). -/
def ask (a : Actor) (m : Remote.Msg) : BaseIO (Task Reply) := do
  let reply ← IO.Promise.new
  if ← a.inbox.trySend { msg := m, reply } then
    return reply.result?.map (·.getD .gone)
  else return .pure .gone

/-- Stop accepting requests; queued ones are still answered, then the thread ends. -/
def stop (a : Actor) : BaseIO Unit := discard <| (a.inbox.close).toBaseIO

def finished (a : Actor) : BaseIO Bool := return (← IO.getTaskState a.done) == .finished

end Actor

/-! ## The session table -/

structure SessionConfig where
  /-- Live sessions (threads) at most; the least recently used is evicted beyond. -/
  maxLive : Nat := 512
  /-- Reserved (not yet started) sessions at most. -/
  maxPending : Nat := 4096
  /-- A live session expires after this long without a request. -/
  idleMs : Nat := 30 * 60 * 1000
  /-- A reserved session that never hydrates expires after this long. -/
  pendingMs : Nat := 5 * 60 * 1000
  /-- How often the reaper looks for expired sessions. -/
  sweepMs : Nat := 5000
  /-- A request whose session has not answered after this long gets `500` (the program is
  stuck, e.g. an `update` that loops), so connections do not pile up; `0` waits forever. -/
  replyTimeoutMs : Nat := 30000
  /-- The container every session's program is mounted in. -/
  selector : String := "#app"
  deriving Inhabited

structure Entry where
  app : String
  /-- Starts the actor (called by the first request). -/
  spawn : BaseIO Actor
  actor : Option Actor := none
  created : Nat
  /-- `IO.monoMsNow` of the last request (expiry). A ref, so a request does not copy the table. -/
  lastSeen : IO.Ref Nat
  /-- The table's logical clock at the last request (least-recently-used order; unlike
  milliseconds it never ties). -/
  lastUse : IO.Ref Nat

structure Table where
  map : Std.HashMap String Entry := {}
  live : Nat := 0
  pending : Nat := 0
  /-- Ticks once per reservation and per request. -/
  clock : Nat := 0

structure SessionStats where
  reserved : Nat := 0
  spawned : Nat := 0
  expired : Nat := 0
  evicted : Nat := 0
  requests : Nat := 0
  gone : Nat := 0
  deriving Inhabited, Repr

structure Sessions where
  cfg : SessionConfig
  table : Std.Mutex Table
  stats : Std.Mutex SessionStats

namespace Sessions

def new (cfg : SessionConfig := {}) : BaseIO Sessions := do
  return { cfg, table := ← Std.Mutex.new {}, stats := ← Std.Mutex.new {} }

private def bump (s : Sessions) (f : SessionStats → SessionStats) : BaseIO Unit :=
  s.stats.atomically (modify f)

/-- An unguessable session id (128 random bits, hex). The id is the session's only credential. -/
def freshId : IO String := return Url.hex (← IO.getRandomBytes 16)

/-- The least recently used entry among those satisfying `pred`. -/
private def lru (t : Table) (pred : String → Entry → Bool) : BaseIO (Option String) := do
  let mut best : Option (String × Nat) := none
  for (id, e) in t.map do
    if pred id e then
      let seen ← e.lastUse.get
      match best with
      | some (_, b) => if seen < b then best := some (id, seen)
      | none => best := some (id, seen)
  return best.map (·.1)

private def removeEntry (t : Table) (id : String) : Table :=
  match t.map.get? id with
  | some e => { t with map := t.map.erase id,
                       live := if e.actor.isSome then t.live - 1 else t.live,
                       pending := if e.actor.isSome then t.pending else t.pending - 1 }
  | none => t

/-- Reserve a session that will run `p` with `flags`; returns its id. No thread is started until
the first request. -/
def reserve {Model Msg : Type} (s : Sessions) (app : String) (p : Program Model Msg) (flags : String) : IO String := do
  let id ← freshId
  let now ← IO.monoMsNow
  let lastSeen ← IO.mkRef now
  let lastUse ← IO.mkRef 0
  let entry : Entry := { app, spawn := Actor.spawn p flags s.cfg.selector, created := now, lastSeen, lastUse }
  let evicted ← s.table.atomically do
    let t ← get
    lastUse.set t.clock
    let t := { t with clock := t.clock + 1 }
    let victim ← if t.pending ≥ s.cfg.maxPending then lru t (fun _ e => e.actor.isNone) else pure none
    let t := match victim with | some v => removeEntry t v | none => t
    set { t with map := t.map.insert id entry, pending := t.pending + 1 }
    return victim.isSome
  s.bump fun st => { st with reserved := st.reserved + 1, evicted := st.evicted + (if evicted then 1 else 0) }
  return id

/-- Look up a session for a request, starting its actor on first use. -/
private def actorFor (s : Sessions) (id : String) : IO (Option Actor) := do
  let now ← IO.monoMsNow
  let (found, victims, spawned) ← s.table.atomically do
    let t ← get
    match t.map.get? id with
    | none => return (none, #[], false)
    | some e =>
      e.lastSeen.set now
      e.lastUse.set t.clock
      let t := { t with clock := t.clock + 1 }
      match e.actor with
      | some a => set t; return (some a, #[], false)
      | none =>
        let a ← e.spawn
        let mut t := { t with map := t.map.insert id { e with actor := some a },
                              live := t.live + 1, pending := t.pending - 1 }
        let mut victims := #[]
        while t.live > s.cfg.maxLive do
          match ← lru t (fun k x => x.actor.isSome && k != id) with
          | some v =>
            if let some ve := t.map.get? v then if let some va := ve.actor then victims := victims.push va
            t := removeEntry t v
          | none => break
        set t
        return (some a, victims, true)
  for v in victims do v.stop
  s.bump fun st => { st with requests := st.requests + 1, spawned := st.spawned + (if spawned then 1 else 0),
                             evicted := st.evicted + victims.size, gone := st.gone + (if found.isNone then 1 else 0) }
  return found

/-- Forward one request to its session. -/
def ask (s : Sessions) (id : String) (m : Remote.Msg) : IO (Task Reply) := do
  match ← s.actorFor id with
  | none => return .pure .gone
  | some a => a.ask m

/-- Expire sessions idle for longer than their limit at time `now` (milliseconds of
`IO.monoMsNow`); also drops sessions whose actor has stopped. Returns how many were removed. -/
def sweep (s : Sessions) (now : Nat) : IO Nat := do
  let dead ← s.table.atomically do
    let t ← get
    let mut dead : Array (String × Option Actor) := #[]
    for (id, e) in t.map do
      let seen ← e.lastSeen.get
      let limit := if e.actor.isSome then s.cfg.idleMs else s.cfg.pendingMs
      let stopped ← match e.actor with | some a => a.finished | none => pure false
      if now > seen + limit || stopped then dead := dead.push (id, e.actor)
    set (dead.foldl (fun t (id, _) => removeEntry t id) t)
    return dead
  for (_, a) in dead do if let some a := a then a.stop
  s.bump fun st => { st with expired := st.expired + dead.size }
  return dead.size

/-- Stop every session (server shutdown). -/
def closeAll (s : Sessions) : IO Unit := do
  let all ← s.table.atomically do
    let t ← get
    set ({} : Table)
    return t.map.toArray
  for (_, e) in all do if let some a := e.actor then a.stop

/-- Expire sessions in the background every `sweepMs`. Returns the action that stops it. -/
def startReaper (s : Sessions) : IO (IO Unit) := do
  let stop ← IO.mkRef false
  let _ ← IO.asTask (prio := .dedicated) do
    let mut waited := 0
    while !(← stop.get) do
      IO.sleep 100
      waited := waited + 100
      if waited ≥ s.cfg.sweepMs then
        waited := 0
        discard <| s.sweep (← IO.monoMsNow)
  return stop.set true

/-- Counts for monitoring: live and reserved sessions, and totals since start. -/
def counts (s : Sessions) : IO (Nat × Nat × SessionStats) := do
  let (live, pending) ← s.table.atomically do let t ← get; return (t.live, t.pending)
  return (live, pending, ← s.stats.atomically get)

/-- The counts as JSON. -/
def statsJson (s : Sessions) : IO String := do
  let (live, pending, st) ← s.counts
  return s!"\{\"live\":{live},\"pending\":{pending},\"reserved\":{st.reserved},\"spawned\":{st.spawned}," ++
    s!"\"expired\":{st.expired},\"evicted\":{st.evicted},\"requests\":{st.requests},\"gone\":{st.gone}}"

/-- Wait for a reply, at most `ms` milliseconds (`0`: no limit). The timer is a libuv timer, not a
thread, and is stopped as soon as the reply arrives. -/
def awaitReply (t : Task Reply) (ms : Nat) : Std.Async.Async Reply := do
  if ms == 0 then return ← Std.Async.await t
  let sl ← Std.Async.Sleep.mk (Std.Time.Millisecond.Offset.ofNat ms)
  let r ← Std.Async.EAsync.race (Std.Async.await t)
    (do sl.wait; return .failed s!"the session did not answer within {ms} ms")
  sl.stop
  return r

/-- The remote protocol endpoint: `POST <endpoint>/<session>`. Each response carries a
`Server-Timing` entry with the time spent in the session (`actor;dur=<ms>`). -/
def route (s : Sessions) (endpoint : String := "/leanui") : Route :=
  Route.param ["POST"] endpoint fun req sid => do
    let some body := req.bodyText? | return (Reply.bad "the body is not UTF-8").toRes sid
    match Remote.parse body with
    | .error e => return (Reply.bad e).toRes sid
    | .ok m =>
      let t0 ← IO.monoNanosNow
      let reply ← awaitReply (← s.ask sid m) s.cfg.replyTimeoutMs
      let dt := (← IO.monoNanosNow) - t0
      let ms := s!"{dt / 1000000}.{toString (1000 + (dt / 1000) % 1000) |>.drop 1}"
      return (reply.toRes sid).withHeader "server-timing" s!"actor;dur={ms}"

/-- `GET path`: the counts as JSON (opt-in: mount it only where monitoring should see it). -/
def statsRoute (s : Sessions) (path : String) : Route :=
  Route.get path fun _ => do return (Res.json (← s.statsJson)).withHeader "cache-control" "no-store"

end Sessions
end LeanUI.Server
