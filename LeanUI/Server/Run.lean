module
public import Std.Http
public import Std.Async.Signal
public import LeanUI.Server.Http
/-!
# Running a server on `Std.Http`

The adapter between LeanUI's transport-independent `Req`/`Res` and Lean 4.34's HTTP/1.1 server:
it reads the request body (up to `maxBody`; larger requests get `413`), runs the route, converts
the response, and logs one line per request. `serve` binds, prints the URL, and shuts down
cleanly on `SIGINT`/`SIGTERM` (running `onShutdown` first, which is where sessions are closed:
their threads would otherwise keep the process alive).
-/
public section
namespace LeanUI.Server
open Std.Async

structure Config where
  /-- Address to bind (`127.0.0.1`, `0.0.0.0`, `localhost`). -/
  host : String := "127.0.0.1"
  /-- `0` picks a free port (`listen` reports it). -/
  port : UInt16 := 8080
  /-- Largest request body accepted. -/
  maxBody : Nat := 1 <<< 20
  /-- Log every request (`false`: only errors). -/
  log : Bool := true
  /-- Also log `POST`s to the session endpoint (one per event; off by default). -/
  logSessions : Bool := false
  /-- Prefix of the session endpoint (for `logSessions`). -/
  endpoint : String := "/leanui"
  /-- The `Std.Http` settings. Keep-alive connections serve many events each. -/
  http : Std.Http.Config := { maxRequests := 100000, serverName := some (.mk "LeanUI") }

/-- The bind address. -/
def Config.address (c : Config) : Except String Std.Net.SocketAddress := do
  let h := if c.host == "localhost" then "127.0.0.1" else c.host
  match Std.Net.IPv4Addr.ofString h with
  | some a => return .v4 ⟨a, c.port⟩
  | none =>
    match Std.Net.IPv6Addr.ofString h with
    | some a => return .v6 ⟨a, c.port⟩
    | none => throw s!"not an IP address: {c.host}"

/-- A `Std.Http` request as a `Req` (reads the body). -/
def toReq (r : Std.Http.Request Std.Http.Body.Stream) (maxBody : Nat) : ContextAsync (Except Nat Req) := do
  let target := match r.line.uri with
    | .originForm p q => toString p ++ Std.Http.URI.Query.formatOption q
    | .absoluteForm u => toString u.path ++ Std.Http.URI.Query.formatOption u.query
    | t => toString t
  let target := if target.isEmpty || !target.startsWith "/" then "/" ++ target else target
  let headers := r.line.headers.fold (init := #[]) fun acc n v => acc.push (n.value, v.value)
  let method := toString r.line.method
  let hasBody := !(method == "GET" || method == "HEAD" || method == "OPTIONS")
  let body ← if hasBody then
      try
        let b : ByteArray ← r.body.readAll (maximumSize := some maxBody.toUInt64)
        pure (some b)
      catch _ => pure none
    else pure (some .empty)
  match body with
  | none => return .error 413
  | some body =>
    let remote := match r.extensions.get Std.Http.Server.RemoteAddr with
      | some a => toString a.addr
      | none => ""
    return .ok { Req.ofTarget method target headers body with remote }

/-- A `Res` as a `Std.Http` response. Invalid header names or values are dropped (and logged). -/
def toResponse (res : Res) : Async (Std.Http.Response Std.Http.Body.Full) := do
  let status := (Std.Http.Status.ofCode none res.status.toUInt16).getD .internalServerError
  let mut b := Std.Http.Response.withStatus status
  for (k, v) in res.headers do
    match b.header? k v with
    | some b' => b := b'
    | none => IO.eprintln s!"[leanui] dropped invalid header {k.quote}: {v.quote}"
  b.fromBytes res.body

def fmtBytes (n : Nat) : String :=
  if n < 10000 then s!"{n}B" else if n < 10000000 then s!"{n / 1000}kB" else s!"{n / 1000000}MB"

def fmtMs (ns : Nat) : String :=
  let us := ns / 1000
  s!"{us / 1000}.{toString (1000 + us % 1000) |>.drop 1}ms"

/-- The `Std.Http` handler for a route. -/
structure Handler where
  route : Route
  cfg : Config

instance : Std.Http.Server.Handler Handler where
  ResponseBody := Std.Http.Body.Full
  onRequest h r := do
    let t0 ← IO.monoNanosNow
    let res ← match ← toReq r h.cfg.maxBody with
      | .error code => pure (Res.text "request body too large" code)
      | .ok req => do
        let res ← (h.route.handle req : Async Res)
        if h.cfg.log && (h.cfg.logSessions || !(req.method == "POST" && req.path.startsWith h.cfg.endpoint)) then
          let dt := (← IO.monoNanosNow) - t0
          IO.println s!"[leanui] {req.method} {req.target} {res.status} {fmtMs dt} {fmtBytes res.body.size}"
        pure res
    toResponse res
  onFailure _ e := IO.eprintln s!"[leanui] connection error: {e}"

/-- Bind and start serving `route`; returns the running server (its `localAddr` has the actual
port when `cfg.port` is `0`). -/
def listen (cfg : Config) (route : Route) : Async Std.Http.Server := do
  match cfg.address with
  | .error e => throw (IO.userError e)
  | .ok addr => Std.Http.Server.serve addr { route, cfg : Handler } cfg.http

/-- The port a running server is bound to. -/
def boundPort (s : Std.Http.Server) : Option UInt16 :=
  s.localAddr.map fun
    | .v4 a => a.port
    | .v6 a => a.port

/-- Serve `route` until `SIGINT` or `SIGTERM`; then run `onShutdown` (close sessions, stop
background tasks) and stop accepting connections. -/
def serve (cfg : Config) (route : Route) (onShutdown : IO Unit := pure ()) (banner := true) : IO Unit := Async.block do
  let srv ← listen cfg route
  let port := (boundPort srv).getD cfg.port
  if banner then IO.println s!"[leanui] listening on http://{cfg.host}:{port}/"
  let stopOn (sig : Signal) (name : String) : Async Unit := do
    let w ← Signal.Waiter.mk sig false
    let t ← w.wait
    background do
      let _ ← await t
      IO.println s!"[leanui] {name}: shutting down"
      onShutdown
      srv.shutdown
  stopOn .sigint "SIGINT"
  stopOn .sigterm "SIGTERM"
  srv.waitShutdown

end LeanUI.Server
