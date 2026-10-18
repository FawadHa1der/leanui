module
public import Std.Async
public import LeanUI.Server.Url
/-!
# Requests, responses and routes

LeanUI's handlers see a `Req` (decoded path segments, parsed query, lower-case header names, the
whole body) and produce a `Res`. Neither depends on the transport: `LeanUI.Server.Run` adapts them
to `Std.Http`, and the native tests call routes directly with hand-made requests, so every
handler, the static file server and the session protocol are tested without a socket.

A `Route` answers a request or declines it (`none`), so routes compose by trying them in order
(`Route.first`, `++`). `Route.under "/counter"` mounts a route below a prefix: the route sees the
rest of the path and can rebuild absolute URLs from `Req.base`.
-/
public section
namespace LeanUI.Server
open Std.Async

/-- An HTTP request, transport-independent. -/
structure Req where
  method : String := "GET"
  /-- The request target as sent: raw (percent-encoded) path and query. -/
  target : String := "/"
  /-- The raw path. -/
  rawPath : String := "/"
  /-- The decoded path segments, or why the path was refused (`..`, bad encoding). -/
  segments : Except Url.Refusal (Array String) := .ok #[]
  /-- How many leading segments enclosing `Route.under`s consumed. -/
  consumed : Nat := 0
  /-- Did the raw path end with `/` (directories redirect to it)? -/
  trailingSlash : Bool := false
  query : Array (String × String) := #[]
  /-- Header names are lower case. -/
  headers : Array (String × String) := #[]
  body : ByteArray := .empty
  /-- The peer, when the transport knows it. -/
  remote : String := ""

instance : Inhabited Req := ⟨{}⟩

namespace Req

/-- A request from a method and a raw target, as a client would send it. -/
def ofTarget (method target : String) (headers : Array (String × String) := #[])
    (body : ByteArray := .empty) : Req :=
  let (raw, q) := Url.splitTarget target
  { method, target, rawPath := raw, segments := Url.segments raw,
    trailingSlash := raw.endsWith "/" && raw != "/", query := Url.parseQuery q,
    headers := headers.map fun (k, v) => (k.toLower, v), body }

/-- `GET target` (tests and examples). -/
def get (target : String) (headers : Array (String × String) := #[]) : Req := ofTarget "GET" target headers

/-- `POST target` with a text body. -/
def post (target : String) (body : String) (headers : Array (String × String) := #[]) : Req :=
  ofTarget "POST" target headers body.toUTF8

/-- The segments below the current mount point (empty if the path was refused). -/
def rest (r : Req) : Array String :=
  match r.segments with
  | .ok s => s.extract r.consumed s.size
  | .error _ => #[]

/-- The path below the mount point, decoded: `/`, `/server`, `/a/b/`. -/
def path (r : Req) : String :=
  let rs := r.rest
  "/" ++ "/".intercalate rs.toList ++ (if r.trailingSlash && !rs.isEmpty then "/" else "")

/-- The mount point (`""` at the top level, else e.g. `/counter`), for building absolute URLs. -/
def base (r : Req) : String :=
  match r.segments with
  | .ok s => String.join ((s.extract 0 r.consumed).toList.map fun seg => "/" ++ Url.encode seg)
  | .error _ => ""

/-- The raw query string (`a=1&b=2`), for redirects that must keep it. -/
def rawQuery (r : Req) : String := (Url.splitTarget r.target).2

def header? (r : Req) (name : String) : Option String :=
  let n := name.toLower
  (r.headers.find? (·.1 == n)).map (·.2)

def param? (r : Req) (name : String) : Option String := (r.query.find? (·.1 == name)).map (·.2)

def bodyText? (r : Req) : Option String := String.fromUTF8? r.body

/-- `GET` or `HEAD` (a `HEAD` is answered like a `GET`; the transport drops the body). -/
def isRead (r : Req) : Bool := r.method == "GET" || r.method == "HEAD"

end Req

/-- An HTTP response, transport-independent. -/
structure Res where
  status : Nat := 200
  /-- Header names are lower case. -/
  headers : Array (String × String) := #[]
  body : ByteArray := .empty

instance : Inhabited Res := ⟨{}⟩

namespace Res

/-- Set a header, replacing any with the same (case-insensitive) name. -/
def withHeader (r : Res) (name value : String) : Res :=
  let n := name.toLower
  { r with headers := (r.headers.filter (·.1 != n)).push (n, value) }

def header? (r : Res) (name : String) : Option String :=
  let n := name.toLower
  (r.headers.find? (·.1 == n)).map (·.2)

def withStatus (r : Res) (s : Nat) : Res := { r with status := s }

def bytes (ctype : String) (b : ByteArray) (status : Nat := 200) : Res :=
  { status, headers := #[("content-type", ctype)], body := b }
def html (s : String) (status : Nat := 200) : Res := bytes "text/html; charset=utf-8" s.toUTF8 status
def text (s : String) (status : Nat := 200) : Res := bytes "text/plain; charset=utf-8" s.toUTF8 status
def json (s : String) (status : Nat := 200) : Res := bytes "application/json" s.toUTF8 status

def notFound (msg : String := "not found") : Res := text msg 404
def badRequest (msg : String := "bad request") : Res := text msg 400

/-- A redirect (`302 Found` unless told otherwise; `301` for permanent ones). -/
def redirect (location : String) (status : Nat := 302) : Res :=
  (text s!"see {location}" status).withHeader "location" location

def bodyText (r : Res) : String := String.fromUTF8? r.body |>.getD ""

end Res

/-- A route answers a request, or declines it with `none` so the next route can try. -/
structure Route where
  run : Req → Async (Option Res)

instance : Inhabited Route := ⟨⟨fun _ => pure none⟩⟩

namespace Route

/-- Declines everything. -/
def empty : Route := ⟨fun _ => pure none⟩

/-- Try `a`, then `b`. -/
def orElse (a b : Route) : Route := ⟨fun r => do
  match ← a.run r with
  | some res => pure (some res)
  | none => b.run r⟩

instance : Append Route := ⟨orElse⟩

/-- The first route that answers. -/
def first (rs : List Route) : Route := rs.foldr orElse empty

/-- Answer every request (typically the last route: a custom 404). -/
def always (f : Req → Async Res) : Route := ⟨fun r => some <$> f r⟩

/-- Answer requests with one of `methods` whose path below the mount point is exactly `path`
(`"/"` matches the mount point itself, with or without a trailing slash). -/
def on (methods : List String) (path : String) (f : Req → Async Res) : Route := ⟨fun r => do
  let want := (path.splitOn "/").filter (!·.isEmpty)
  if methods.contains r.method && r.rest.toList == want then some <$> f r else pure none⟩

/-- `GET` (and `HEAD`) of exactly `path`. -/
def get (path : String) (f : Req → Async Res) : Route := on ["GET", "HEAD"] path f
/-- `POST` to exactly `path`. -/
def post (path : String) (f : Req → Async Res) : Route := on ["POST"] path f

/-- A route over the requests whose path starts with the segments of `pre`; it sees the rest of
the path (`Req.path`) and the prefix as `Req.base`. -/
def under (pre : String) (r : Route) : Route := ⟨fun req => do
  let want := (pre.splitOn "/").filter (!·.isEmpty) |>.toArray
  let rs := req.rest
  if want.size ≤ rs.size && rs.extract 0 want.size == want then
    r.run { req with consumed := req.consumed + want.size }
  else pure none⟩

/-- Requests with exactly one more segment below `pre`, passed to `f` (e.g. a session id). -/
def param (methods : List String) (pre : String) (f : Req → String → Async Res) : Route :=
  under pre ⟨fun r => do
    match r.rest with
    | #[x] => if methods.contains r.method then some <$> f r x else pure none
    | _ => pure none⟩

/-- Run a route as a complete handler: `404` if nothing answers, `400` for a refused path, and a
`500` (logged to stderr) if the handler throws. -/
def handle (route : Route) (req : Req) : Async Res := do
  if let .error why := req.segments then
    return Res.badRequest s!"bad path ({repr why})"
  try
    match ← route.run req with
    | some res => pure res
    | none => pure (Res.notFound s!"not found: {req.rawPath}")
  catch e =>
    IO.eprintln s!"[leanui] {req.method} {req.target}: {e}"
    pure (Res.text "internal server error" 500)

end Route
end LeanUI.Server
