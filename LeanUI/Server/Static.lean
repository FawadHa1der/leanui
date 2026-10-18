module
public import LeanUI.Server.Http
public import LeanUI.Server.Mime
public import LeanUI.Render
/-!
# Static files

`Static.route` serves a directory: the right `Content-Type` (including `application/wasm`),
`index.html` for directories (a directory URL without its trailing slash is redirected to it, so
relative links inside the page resolve), `HEAD`, weak ETags with `304 Not Modified`, a choice of
`Cache-Control` policies, precompressed `.br`/`.gz` siblings when the client accepts them, and
optional cross-origin isolation headers.

Requests never leave the root: the path is decoded and checked segment by segment (`..` is
refused, never resolved; see `Url.segments`), dotfiles are hidden unless enabled, and with
`confine` (the default) the resolved file's real path must stay below the root's, so a symlink
cannot point outside it either.

Cross-origin isolation (`COOP`/`COEP`) is **off** by default: LeanUI's wasm is single-threaded and
needs no `SharedArrayBuffer`, and isolation would stop the page from embedding cross-origin
resources that do not opt in.
-/
public section
namespace LeanUI.Server

/-- How long browsers may reuse a response without asking again. -/
inductive Cache where
  /-- `no-store`: never reuse (development: always the latest build). -/
  | noStore
  /-- `no-cache` with an ETag: reuse after a cheap `304` revalidation (the default). -/
  | revalidate
  /-- `public, max-age=<seconds>` with an ETag. -/
  | maxAge (seconds : Nat)
  /-- A year, `immutable`: for content-hashed file names only. -/
  | immutable
  deriving BEq, Repr, Inhabited

def Cache.header : Cache → String
  | .noStore => "no-store"
  | .revalidate => "no-cache"
  | .maxAge s => s!"public, max-age={s}"
  | .immutable => "public, max-age=31536000, immutable"

/-- The headers that make a page cross-origin isolated (needed only by multi-threaded wasm). -/
def isolationHeaders : Array (String × String) :=
  #[("cross-origin-opener-policy", "same-origin"), ("cross-origin-embedder-policy", "require-corp")]

structure Static where
  root : System.FilePath
  cache : Cache := .revalidate
  /-- HTML is the entry point that names every other file, so it revalidates by default even
  when the rest of the directory is cached for longer. -/
  htmlCache : Cache := .revalidate
  /-- Send `COOP`/`COEP` (cross-origin isolation). -/
  isolate : Bool := false
  index : String := "index.html"
  /-- Serve files and directories whose name starts with `.` (`.well-known` is always served). -/
  dotfiles : Bool := false
  /-- The resolved real path must stay below the root's real path (no symlink escapes). -/
  confine : Bool := true
  /-- List directories that have no index file. -/
  listing : Bool := false
  /-- Serve `f.br` / `f.gz` instead of `f` when they exist and the client accepts them. -/
  precompressed : Bool := true
  /-- Single-page apps: an unknown path without a file extension gets the root `index.html`
  (so client-side routes survive a reload). -/
  spa : Bool := false
  /-- Extra headers on every response. -/
  headers : Array (String × String) := #[]
  deriving Inhabited

namespace Static

/-- A weak validator from size and modification time. -/
def etag (m : IO.FS.Metadata) (variant : String := "") : String :=
  let t := m.modified
  s!"W/\"{m.byteSize}-{t.sec}-{t.nsec}{variant}\""

/-- Does an `If-None-Match` header match `tag`? (Weak comparison, as RFC 9110 requires for GET.) -/
def tagMatches (ifNoneMatch tag : String) : Bool :=
  let strip (s : String) : String := (if s.startsWith "W/" then (s.drop 2).toString else s)
  ifNoneMatch.trimAscii.toString == "*" || (ifNoneMatch.splitOn ",").any fun t => strip t.trimAscii.toString == strip tag

/-- The client's accepted content codings (`br`, `gzip`), ignoring q-values of 0. -/
def accepts (r : Req) (coding : String) : Bool :=
  match r.header? "accept-encoding" with
  | none => false
  | some v => (v.splitOn ",").any fun part =>
    let fields := (part.splitOn ";").map (·.trimAscii.toString)
    fields.head? == some coding && !fields.any (· == "q=0")

private def isHidden (seg : String) : Bool := seg.startsWith "." && seg != ".well-known"

/-- Common headers for a file response. -/
private def baseHeaders (s : Static) (ctype : String) : Array (String × String) :=
  #[("content-type", ctype), ("x-content-type-options", "nosniff")] ++
    (if s.isolate then isolationHeaders else #[]) ++ s.headers.map fun (k, v) => (k.toLower, v)

/-- Is `file` inside `root` once symlinks are resolved? -/
def confined (root file : System.FilePath) : IO Bool := do
  let r := (← IO.FS.realPath root).toString
  let f := (← IO.FS.realPath file).toString
  return f == r || f.startsWith (if r.endsWith "/" then r else r ++ "/")

/-- Serve one file that is known to exist. `name` picks the media type. -/
def serveFile (s : Static) (req : Req) (file : System.FilePath) (name : String) : IO Res := do
  let ctype := Mime.ofPath name
  let cache := if ctype.startsWith "text/html" then s.htmlCache else s.cache
  -- pick a precompressed sibling if the client takes it
  let mut path := file
  let mut coding := ""
  if s.precompressed && Mime.compressible ctype then
    for (c, ext) in [("br", "br"), ("gzip", "gz")] do
      if coding.isEmpty && accepts req c then
        let alt : System.FilePath := file.toString ++ "." ++ ext
        if ← alt.pathExists then path := alt; coding := c
  let md ← path.metadata
  let tag := etag md (if coding.isEmpty then "" else "-" ++ coding)
  let mut hs := baseHeaders s ctype |>.push ("etag", tag) |>.push ("cache-control", cache.header)
  if s.precompressed && Mime.compressible ctype then hs := hs.push ("vary", "accept-encoding")
  if !coding.isEmpty then hs := hs.push ("content-encoding", coding)
  if let some inm := req.header? "if-none-match" then
    if cache != .noStore && tagMatches inm tag then
      return { status := 304, headers := hs.filter (·.1 != "content-type") }
  return { status := 200, headers := hs, body := ← IO.FS.readBinFile path }

/-- An HTML listing of a directory. -/
def listingPage (s : Static) (req : Req) (dir : System.FilePath) : IO Res := do
  let entries ← dir.readDir
  let mut names := #[]
  for e in entries do
    if !s.dotfiles && isHidden e.fileName then continue
    let isDir ← e.path.isDir
    names := names.push (e.fileName ++ (if isDir then "/" else ""))
  let sorted := names.qsort (· < ·)
  let here := req.base ++ req.path
  let items := sorted.toList.map fun n =>
    let href := Url.encode (n.dropEndWhile (· == '/')).toString ++ (if n.endsWith "/" then "/" else "")
    s!"<li><a href=\"{escapeHtml true "" href}\">{escapeHtml false "" n}</a></li>"
  let up := if req.rest.isEmpty then "" else "<li><a href=\"../\">../</a></li>"
  let page := s!"<!doctype html><html><head><meta charset=\"utf-8\"><title>{escapeHtml false "" here}</title>" ++
    "<style>body{font:15px/1.5 system-ui,sans-serif;margin:2rem auto;max-width:48rem;padding:0 1rem}" ++
    "a{text-decoration:none}a:hover{text-decoration:underline}li{list-style:none}</style></head>" ++
    s!"<body><h1>{escapeHtml false "" here}</h1><ul>{up}{String.join items}</ul></body></html>"
  return { Res.html page with headers := baseHeaders s "text/html; charset=utf-8" |>.push ("cache-control", "no-cache") }

/-- Resolve the request below the root and answer it, or decline (`none`) when there is no such
file, so a later route can try. -/
def serve (s : Static) (req : Req) : IO (Option Res) := do
  if !req.isRead then return none
  let segs := req.rest
  if !s.dotfiles && segs.any isHidden then return none
  let target := segs.foldl (· / ·) s.root
  if ← target.isDir then
    if s.confine && !(← confined s.root target) then return none
    -- `/dir` → `/dir/`, and the mount point itself (`/assets` → `/assets/`), so relative URLs in
    -- the index resolve inside the directory
    if !req.trailingSlash && (!segs.isEmpty || req.consumed > 0) then
      let here := req.base ++ req.path
      let q := req.rawQuery
      return some (Res.redirect ((if here.endsWith "/" then here else here ++ "/") ++ (if q.isEmpty then "" else "?" ++ q)) 301)
    let idx := target / s.index
    if ← idx.pathExists then return some (← serveFile s req idx s.index)
    if s.listing then return some (← listingPage s req target)
    return none
  if ← target.pathExists then
    if s.confine && !(← confined s.root target) then return none
    return some (← serveFile s req target (segs.back?.getD ""))
  -- single-page app fallback: extension-less paths get the root index
  if s.spa && !segs.isEmpty && Mime.extension (segs.back?.getD "") == "" then
    let idx := s.root / s.index
    if ← idx.pathExists then return some (← serveFile s req idx s.index)
  return none

/-- The directory as a route. -/
def route (s : Static) : Route := ⟨fun req => s.serve req⟩

end Static

/-- One file at one exact path (e.g. the runtime at `/leanui.js`). -/
def Static.file (urlPath : String) (file : System.FilePath) (cache : Cache := .revalidate) : Route :=
  Route.get urlPath fun req => do
    if ← file.pathExists then Static.serveFile { root := file.parent.getD ".", cache, htmlCache := cache } req file file.toString
    else pure (Res.notFound s!"{file} is missing")

end LeanUI.Server
