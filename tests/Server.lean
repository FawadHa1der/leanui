module
public import LeanUI.Server
public import LeanUI.Server.Testing
public import LeanUI.Server.Cli
public import LeanUI.Server.Demo
public import LeanUI.Testing.Harness
/-!
# Native tests for the server lane

Everything below runs without a network: routes are called with hand-made requests, the
server-driven pages are driven by `LeanUI.Server.Testing.Client` (SSR → claim → `h`/`e`/`c` →
`Testing.Dom`), and the `Std.Http` adapter is exercised over `Std.Http`'s in-memory mock
transport. The last section measures the session-actor design against a shared-table design.

    .lake/build/bin/leanui-server-tests [--bench]
-/
public section
open LeanUI LeanUI.Server LeanUI.Server.Testing Attr

/-! ## Helpers -/

def expect (ok : Bool) (what : String) : IO Unit :=
  unless ok do throw (IO.userError s!"FAILED: {what}")

def expectEq [BEq α] [Repr α] (got want : α) (what : String) : IO Unit :=
  unless got == want do throw (IO.userError s!"FAILED: {what}\n  got:  {repr got}\n  want: {repr want}")

def run (route : Route) (req : Req) : IO Res := (route.handle req).block

def contains (s pat : String) : Bool := (s.splitOn pat).length > 1

structure Rng where
  s : UInt64
def Rng.next (r : Rng) : Rng × Nat :=
  let s := r.s * 6364136223846793005 + 1442695040888963407; (⟨s⟩, (s >>> 33).toNat)
def Rng.below (r : Rng) (n : Nat) : Rng × Nat := let (r, x) := r.next; (r, if n == 0 then 0 else x % n)
def Rng.pick [Inhabited α] (r : Rng) (xs : Array α) : Rng × α := let (r, i) := r.below xs.size; (r, xs[i]!)

/-! ## URLs -/

def testUrl : IO Unit := do
  expectEq (Url.decode "a%20b%2Fc") (some "a b/c") "decode"
  expectEq (Url.decode "%E2%9C%93") (some "✓") "decode utf-8"
  expectEq (Url.decode "bad%2") none "truncated escape"
  expectEq (Url.decode "bad%zz") none "bad hex"
  expectEq (Url.decode "%ff") none "not utf-8"
  expectEq (Url.decode "a+b" (plus := true)) (some "a b") "plus in queries"
  expectEq (Url.decode "a+b") (some "a+b") "plus in paths"
  expectEq (Url.encode "a b/ü") "a%20b%2F%C3%BC" "encode"
  expectEq (Url.decode (Url.encode "x y&z=✓😀")) (some "x y&z=✓😀") "encode/decode round trip"
  expectEq (Url.splitTarget "/a/b?x=1&y=2#frag") ("/a/b", "x=1&y=2") "split target"
  expectEq (Url.parseQuery "x=1&y=a+b&flag&z=%3D&=&bad=%zz") #[("x", "1"), ("y", "a b"), ("flag", ""), ("z", "="), ("", "")] "query"
  let ok (p : String) (segs : Array String) : IO Unit := do
    match Url.segments p with
    | .ok s => expectEq s segs s!"segments {p}"
    | .error e => throw (IO.userError s!"FAILED: segments {p}: {repr e}")
  let refused (p : String) (why : Url.Refusal) : IO Unit := do
    match Url.segments p with
    | .ok s => throw (IO.userError s!"FAILED: {p} should be refused, got {s}")
    | .error e => expect (e == why) s!"{p}: {repr e} instead of {repr why}"
  ok "/" #[]
  ok "/a//b/./c/" #["a", "b", "c"]
  ok "/dist/app%20name.wasm" #["dist", "app name.wasm"]
  ok "/a%2Fb" #["a", "b"]
  refused "/../etc/passwd" .traversal
  refused "/a/%2e%2e/%2e%2e/etc" .traversal
  refused "/a/%2E%2E" .traversal
  refused "/a/..%2F..%2Fx" .traversal
  refused "/a%5c..%5cb" .badChar
  refused "/C:/windows" .badChar
  refused "/a%00b" .badChar
  refused "/%zz" .badEncoding
  let r := Req.get "/counter/server/?mode=wasm&x=%20y"
  expectEq r.path "/counter/server/" "Req.path"
  expectEq (r.param? "mode") (some "wasm") "Req.param?"
  expectEq (r.param? "x") (some " y") "Req.param? decoded"
  let r := { r with consumed := 1 }
  expectEq r.path "/server/" "path below a mount point"
  expectEq r.base "/counter" "base"
  IO.println "  urls, queries, traversal refusals: ok"

def testMime : IO Unit := do
  for (f, t) in [("app.wasm", "application/wasm"), ("APP.WASM", "application/wasm"),
                 ("leanui.js", "text/javascript; charset=utf-8"), ("x.mjs", "text/javascript; charset=utf-8"),
                 ("index.html", "text/html; charset=utf-8"), ("s.css", "text/css; charset=utf-8"),
                 ("a.json", "application/json"), ("i.svg", "image/svg+xml"), ("f.woff2", "font/woff2"),
                 ("noext", "application/octet-stream"), ("x.unknown", "application/octet-stream"),
                 ("dir.v2/file", "application/octet-stream")] do
    expectEq (Mime.ofPath f) t s!"mime {f}"
  expect (Mime.compressible "application/wasm") "wasm compresses"
  expect (!Mime.compressible "image/png") "png does not"
  IO.println "  media types: ok"

/-! ## The remote protocol -/

def testRemoteParse : IO Unit := do
  let ok (body : String) (m : Remote.Msg) : IO Unit := do
    match Remote.parse body with
    | .ok got => expectEq got m s!"parse {body.quote}"; expectEq (Remote.parse got.body |>.toOption) (some m) s!"round trip {body.quote}"
    | .error e => throw (IO.userError s!"FAILED: parse {body.quote}: {e}")
  ok "h" .hydrate
  ok "e\n7\n" (.event 7 "")
  ok "e\n7\nhello" (.event 7 "hello")
  ok "e\n12\nname=a\nnote=multi\nline" (.event 12 "name=a\nnote=multi\nline")
  ok "c\n3\n1\n200\n{\"a\":1}" (.callback 3 true "200\n{\"a\":1}")
  ok "c\n3\n0\n" (.callback 3 false "")
  ok "e\n4294967295\nx" (.event 4294967295 "x")
  for bad in ["", "x", "e", "e\nseven\n", "e\n4294967296\n", "e\n-1\n", "c\n1\n2\nx", "c\nz\n1\n", "H", "h\nx"] do
    expect (Remote.parse bad |>.toOption |>.isNone) s!"{bad.quote} must be refused"
  IO.println "  remote protocol bodies (h, e, c): ok"

/-! ## Pages and the hydration contract -/

def testJson : IO Unit := do
  expectEq (jsonString "a\"b\\c\n") "\"a\\\"b\\\\c\\n\"" "json escapes"
  let s := jsonString "</script><!-- \u2028 & >"
  expect (!contains s "</" && !contains s "<!--" && !contains s "\u2028") s!"script-safe json: {s}"
  expectEq (jsonField (jsonObject [("k", jsonString "x\u003cy\n\"z")]) "k") (some "x<y\n\"z") "jsonField reads jsonString back"
  IO.println "  script-safe JSON: ok"

/-- A view generator for the SSR ⇄ hydration contract: adjacent and empty texts, characters that
need escaping, astral characters (two UTF-16 units), void elements and properties. -/
partial def genView (r : Rng) (depth : Nat) : Rng × Html Unit := Id.run do
  let texts := #["", "a", "x<y", "&amp;", "\"q\" 'q'", "é", "😀 smile", " ", "a  b", "<!--", "-->", "|", "t",
    "\n", "\nlead", "a\r\nb", "\r"]
  let attrs : Array (Attr Unit) := #[cls "c\"1", cls "other", .attr "title" "<&>", .attr "data-x" "😀", .attr "data-e" "",
    id "n1", .attr "aria-label" "a&b\r\nc", .prop "hidden" (.bool false)]
  let mut r := r
  let (r1, kind) := r.below 10; r := r1
  if depth == 0 || kind < 3 then
    let (r2, t) := r.pick texts; r := r2
    return (r, text t)
  if kind == 3 then
    let (r2, v) := r.pick texts; r := r2
    return (r, el "input" #[value v, .prop "checked" (.bool (v.length % 2 == 0))] #[])
  if kind == 4 then return (r, el "br" #[] #[])
  let (r2, tag) := r.pick #["div", "span", "b", "em", "section", "ul", "li", "pre", "textarea"]; r := r2
  let (r3, na) := r.below 3; r := r3
  let mut as : Array (Attr Unit) := #[]
  for _ in [0:na] do
    let (r4, a) := r.pick attrs; r := r4
    as := as.push a
  -- a textarea's content is text (RCDATA): one non-empty text at most, no markers possible
  if tag == "textarea" then
    let (r5, t) := r.pick texts; r := r5
    return (r, el tag as (if t.isEmpty then #[] else #[text t]))
  let (r5, nk) := r.below 5; r := r5
  let mut kids := #[]
  for _ in [0:nk] do
    let (r6, k) := genView r (depth - 1); r := r6
    kids := kids.push k
  return (r, el tag as kids)

/-- Server-render `v`, parse the HTML, claim it as the runtime does, apply the hydration buffer
of `mount` (hydrating), and compare with the view. -/
def hydrateNatively (v : Html Unit) : IO Unit := do
  let html := v.render
  let nodes ← match parseHtml html with
    | .ok n => pure n
    | .error e => throw (IO.userError s!"FAILED: parse {html}: {e}")
  let (d, claimed) := claim nodes
  expectEq claimed.toNat (countNodes v) s!"claimed nodes of {html}"
  let p : Program Unit Unit := { init := fun _ => ((), .none), update := fun _ m => (m, .none), view := fun _ => v }
  let st := initState p "" "#app" true
  let d := { d with roots := #[("#app", 1)] }.apply st.diff.buf.ops st.diff.buf.strs
  expect d.errors.isEmpty s!"protocol errors {d.errors}"
  expectEq d.effects #[s!"hydrate #app 1 {claimed}"] "one hydrate command"
  expectEq (liveCanon d 1) (viewCanon v) s!"hydrated DOM of {html}"

def testHydrationContract (iters : Nat) : IO Unit := do
  let mut r : Rng := ⟨2026⟩
  for _ in [0:iters] do
    let (r', v) := genView r 4; r := r'
    -- a view's root is an element (texts at the top cannot be claimed by selector)
    hydrateNatively (el "div" #[] #[v])
  -- the cases that need markers, spelled out
  hydrateNatively (el "p" #[] #[text "a", text "", text "", text "b", el "br" #[] #[], text "", text "c"])
  hydrateNatively (el "p" #[] #[text ""])
  hydrateNatively (el "p" #[] #[])
  -- regressions (LeanUI.Render): the parser drops a newline after <pre>/<textarea>, normalises
  -- carriage returns, and keeps the first of duplicate attributes
  hydrateNatively (el "pre" #[] #[text "\n"])
  hydrateNatively (el "pre" #[] #[text "\n\nindented\n"])
  hydrateNatively (el "textarea" #[] #[text "\nfirst line"])
  hydrateNatively (el "p" #[.attr "title" "a\r\nb"] #[text "c\rd\r\n"])
  hydrateNatively (el "div" #[cls "a", id "x", cls "b"] #[])
  IO.println s!"  SSR ⇄ hydration contract, {iters} random views (parse, claim, hydrate, compare): ok"

def testPage : IO Unit := do
  let v : Html Unit := el "main" #[] #[text "a", text "b"]
  let body := v.render
  for boot in [Boot.none, .wasm "/a/app.js" "fl\"ags</script>", .server "/leanui" "abc", .auto "/a/app.js" "" "/leanui" "abc"] do
    let page := ({ body, boot, title := "T <&>" } : Page).render
    let nodes ← match parseHtml page with
      | .ok n => pure n
      | .error e => throw (IO.userError s!"FAILED: page does not parse: {e}")
    let some (.elem _ _ kids) := byId nodes "app" | throw (IO.userError "FAILED: no #app")
    -- the container holds exactly the view: hydration counts every node
    let (_, n) := claim kids
    expectEq n.toNat (countNodes v) s!"container of a {boot.mode} page"
    expect (contains page s!"<div id=\"app\">{body}</div>") "no whitespace around the view"
    match boot with
    | .none => expect (!contains page "<script") "an ssr page has no script"
    | _ =>
      let some cfg := byId nodes "leanui-boot" | throw (IO.userError "FAILED: no boot json")
      expectEq (jsonField cfg.textContent "mode") (some boot.mode) "boot mode"
      if let .wasm _ f := boot then
        expectEq (jsonField cfg.textContent "flags") (some f) "flags survive the page"
        expect (contains page "rel=\"preload\" href=\"/a/app.js\" as=\"script\"") "glue preload"
  IO.println "  page template (4 boot modes): ok"

/-! ## Static files -/

def testStatic : IO Unit := do
  let dir ← IO.FS.createTempDir
  try
    IO.FS.writeFile (dir / "index.html") "<p>root</p>"
    IO.FS.writeBinFile (dir / "app.wasm") (ByteArray.mk #[0, 97, 115, 109, 1, 0, 0, 0])
    IO.FS.writeFile (dir / "app.js") "console.log(1)"
    IO.FS.writeFile (dir / "app.js.br") "BROTLI"
    IO.FS.writeFile (dir / "app.js.gz") "GZIP"
    IO.FS.writeFile (dir / ".secret") "s3cret"
    IO.FS.createDirAll (dir / "sub")
    IO.FS.writeFile (dir / "sub" / "index.html") "<p>sub</p>"
    IO.FS.writeFile (dir / "sub" / "a b.txt") "spaced"
    IO.FS.createDirAll (dir / "empty")
    IO.FS.createDirAll (dir / ".well-known")
    IO.FS.writeFile (dir / ".well-known" / "x.json") "{}"
    let outside ← IO.FS.createTempDir
    IO.FS.writeFile (outside / "leak.txt") "leaked"
    let ln ← IO.Process.output { cmd := "ln", args := #["-s", outside.toString, (dir / "link").toString] }
    expect (ln.exitCode == 0) "ln -s"
    let st : Static := { root := dir }
    let r := Route.under "/s" st.route
    let get (t : String) (hs : Array (String × String) := #[]) := run r (Req.get t hs)
    let res ← get "/s/app.wasm"
    expectEq res.status 200 "wasm 200"
    expectEq (res.header? "content-type") (some "application/wasm") "wasm type"
    expectEq res.body.size 8 "wasm body"
    expectEq (res.header? "cache-control") (some "no-cache") "revalidate policy"
    expectEq (res.header? "x-content-type-options") (some "nosniff") "nosniff"
    expect (res.header? "cross-origin-opener-policy" |>.isNone) "no COOP by default"
    let some tag := res.header? "etag" | throw (IO.userError "FAILED: no etag")
    let res ← get "/s/app.wasm" #[("If-None-Match", tag)]
    expectEq res.status 304 "304 on matching etag"
    expectEq res.body.size 0 "304 has no body"
    let res ← get "/s/app.wasm" #[("If-None-Match", "W/\"other\", " ++ tag)]
    expectEq res.status 304 "304 on a list of etags"
    let res ← run r (Req.ofTarget "HEAD" "/s/app.wasm")
    expectEq res.status 200 "HEAD"
    expectEq (res.header? "content-type") (some "application/wasm") "HEAD type"
    let res ← get "/s/"
    expectEq (res.status, res.bodyText) (200, "<p>root</p>") "index at the root"
    let res ← get "/s/sub"
    expectEq (res.status, res.header? "location") (301, some "/s/sub/") "directory redirect"
    let res ← get "/s/sub?x=1"
    expectEq (res.header? "location") (some "/s/sub/?x=1") "redirect keeps the query"
    let res ← get "/s/sub/"
    expectEq res.bodyText "<p>sub</p>" "index of a directory"
    let res ← get "/s/sub/a%20b.txt"
    expectEq (res.status, res.bodyText) (200, "spaced") "percent-decoded file name"
    for t in ["/s/.secret", "/s/sub/../.secret", "/s/%2e%2e/x", "/s/empty/", "/s/missing.js", "/s/link/leak.txt"] do
      let res ← get t
      expect (res.status == 404 || res.status == 400) s!"{t} must not be served (got {res.status} {res.bodyText})"
    let res ← get "/s/.well-known/x.json"
    expectEq res.status 200 ".well-known is served"
    -- precompressed siblings
    let res ← get "/s/app.js" #[("Accept-Encoding", "gzip, deflate, br")]
    expectEq (res.header? "content-encoding", res.bodyText) (some "br", "BROTLI") "brotli sibling"
    expectEq (res.header? "content-type") (some "text/javascript; charset=utf-8") "type of the original"
    expectEq (res.header? "vary") (some "accept-encoding") "vary"
    let res ← get "/s/app.js" #[("Accept-Encoding", "gzip")]
    expectEq (res.header? "content-encoding", res.bodyText) (some "gzip", "GZIP") "gzip sibling"
    let res ← get "/s/app.js" #[("Accept-Encoding", "br;q=0, gzip")]
    expectEq (res.header? "content-encoding") (some "gzip") "q=0 refuses a coding"
    let res ← get "/s/app.js"
    expectEq (res.header? "content-encoding", res.bodyText) (none, "console.log(1)") "identity"
    -- options
    let iso := Route.under "/s" { st with isolate := true, cache := .immutable }.route
    let res ← run iso (Req.get "/s/app.wasm")
    expectEq (res.header? "cross-origin-opener-policy", res.header? "cross-origin-embedder-policy")
      (some "same-origin", some "require-corp") "isolation headers"
    expectEq (res.header? "cache-control") (some "public, max-age=31536000, immutable") "immutable"
    let res ← run iso (Req.get "/s/")
    expectEq (res.header? "cache-control") (some "no-cache") "html revalidates even when assets are immutable"
    let spa := Route.under "/s" { st with spa := true }.route
    expectEq (← run spa (Req.get "/s/todos/active")).bodyText "<p>root</p>" "spa fallback"
    expectEq (← run spa (Req.get "/s/missing.js")).status 404 "no spa fallback for files"
    let lst := Route.under "/s" { st with listing := true }.route
    let res ← run lst (Req.get "/s/empty/")
    expect (res.status == 200 && contains res.bodyText "<h1>/s/empty/</h1>") "listing"
    let res ← run (Route.under "/s" { st with confine := false }.route) (Req.get "/s/link/leak.txt")
    expectEq res.bodyText "leaked" "confine := false follows symlinks"
    let res ← run (Static.file "/leanui.js" (dir / "app.js")) (Req.get "/leanui.js")
    expectEq res.bodyText "console.log(1)" "single file route"
    IO.FS.removeDirAll outside
  finally
    IO.FS.removeDirAll dir
  IO.println "  static files (types, index, redirects, ETag/304, HEAD, br/gz, COOP, SPA, symlink confinement): ok"

/-! ## Server-driven sessions through the demo site -/

/-- The demo site with fresh sessions, closed afterwards even if the test fails: a session is a
thread blocked on its inbox, and a Lean process does not exit while dedicated threads run. -/
def withSite (cfg : SessionConfig := {}) (f : Sessions → Route → IO α) : IO α := do
  let sessions ← Sessions.new cfg
  try f sessions (Demo.routes {} sessions "runtime/leanui.js" false)
  finally sessions.closeAll

def testCounterSession : IO Unit := withSite {} fun _ site => do
  let c ← Client.open site "/counter/server"
  c.check (Counter.view 0) "hydrated"
  for i in [1:4] do
    expectEq (← c.click "id" "inc") 200 "click"
    c.check (Counter.view i) s!"after {i} inc"
  discard <| c.fire (← c.find "id" "box") "input" "-7"
  c.check (Counter.view (-7)) "after input"
  expectEq (← c.text "id" "value") "<output class=\"neg\" id=\"value\">-7</output>" "class follows the model"
  discard <| c.click "id" "reset"
  c.check (Counter.view 0) "after reset"
  expect ((← c.effects).contains "op43 reset") "reset logs through the browser"
  discard <| c.click "id" "dec"
  c.check (Counter.view (-1)) "after dec"
  -- the auto page reserves a session too (used when the browser lacks Memory64)
  let c2 ← Client.open site "/counter"
  c2.check (Counter.view 0) "auto page, server fallback"
  discard <| c2.click "id" "inc"
  c2.check (Counter.view 1) "the second session is independent"
  c.check (Counter.view (-1)) "the first is unchanged"
  -- the response names the time spent in the session
  let res ← run site (Req.post s!"/leanui/{c.session}" "e\n999\n")
  expectEq res.status 200 "an unknown slot is ignored"
  expect ((res.header? "server-timing").any (·.startsWith "actor;dur=")) "server-timing"
  expectEq res.body.size 0 "nothing changed"
  IO.println "  server-driven counter (SSR, claim, h, e: clicks, input, effects): ok"

def testTickerSession : IO Unit := withSite {} fun _ site => do
  let c ← Client.open site "/ticker/server?from=5"
  let view := Demo.Ticker.view
  let m : Demo.Ticker.Model := { ticks := 5 }
  c.check (view m) "flags reach init"
  discard <| c.click "id" "toggle"
  let m := { m with running := true }
  c.check (view m) "running"
  let some sub := (← c.effects).findSome? fun e =>
      match e.splitOn " " with | ["interval", s, "100"] => s.toNat? | _ => none
    | throw (IO.userError s!"FAILED: no interval in {← c.effects}")
  for i in [1:4] do
    expectEq (← c.send (.callback sub.toUInt32 true "")) 200 "tick"
    c.check (view { m with ticks := 5 + i }) s!"tick {i}"
  let m := { m with ticks := 8 }
  discard <| c.click "id" "toggle"
  let m := { m with running := false }
  c.check (view m) "stopped"
  expect ((← c.effects).contains s!"op35 {sub}") "the interval is cleared"
  discard <| c.click "id" "fetch"
  let some cb := (← c.effects).findSome? fun e =>
      if e.startsWith "fetch cb=" then (((e.drop 9).toString.splitOn " ").headD "").toNat? else none
    | throw (IO.userError "FAILED: no fetch")
  expect ((← c.effects).any (contains · "/api/hello?n=8")) "fetch url"
  -- the browser would perform the fetch; answer it from the route itself
  let api ← run site (Req.get "/api/hello?n=8")
  expectEq (← c.send (.callback cb.toUInt32 true s!"200\n{api.bodyText}")) 200 "fetch result"
  c.check (view { m with reply := api.bodyText }) "fetched"
  discard <| c.click "id" "bump"
  expect ((← c.effects).contains "op44 ticker 108") "title effect"
  IO.println "  server-driven ticker (c: subscriptions, fetch results; title effect; flags): ok"

def testContractSession : IO Unit := withSite {} fun _ site => do
  let c ← Client.open site "/contract/server"
  c.check (Demo.Contract.view 0) "hydrated"
  discard <| c.click "id" "go"
  c.check (Demo.Contract.view 1) "updated through the claimed handles"
  IO.println "  server-driven SSR contract page (pre/textarea newlines, CR, duplicates): ok"

def testProtocolErrors : IO Unit := withSite {} fun _ site => do
  let post (sid body : String) := run site (Req.post s!"/leanui/{sid}" body)
  let page ← run site (Req.get "/counter/server")
  expectEq (page.header? "cache-control") (some "no-store") "session pages are never cached"
  let some sid := jsonField page.bodyText "session" | throw (IO.userError "FAILED: no session")
  expectEq sid.length 32 "128-bit ids"
  let logged (r : Res) (needle : String) : Bool :=
    match decodeUpdate r.body with
    | some (ops, strs) => (({} : LeanUI.Testing.Dom).apply ops strs).effects.any (contains · needle)
    | none => false
  let res ← post sid "e\n1\n"
  expectEq res.status 409 "event before hydration"
  expect (logged res "before hydration") "the error body is a log command"
  expectEq (← post sid "h").status 200 "hydrate"
  expectEq (← post sid "h").status 409 "second hydrate"
  let res ← post sid "x\n1"
  expectEq res.status 400 "malformed body"
  expect (logged res "not a LeanUI request") "400 body"
  let res ← run site (Req.ofTarget "POST" s!"/leanui/{sid}" #[] (ByteArray.mk #[0xff, 0xfe]))
  expectEq res.status 400 "non-UTF-8 body"
  let res ← post "0123456789abcdef0123456789abcdef" "h"
  expectEq res.status 410 "unknown session"
  expect (logged res "expired") "410 body"
  expectEq (← run site (Req.get s!"/leanui/{sid}")).status 404 "GET on the endpoint"
  expectEq (← post sid "e\n1\n").status 200 "the session still works"
  IO.println "  protocol errors (400, 409, 410, error bodies are log buffers): ok"

def testLifecycle : IO Unit := withSite { maxLive := 2, maxPending := 3, idleMs := 1000, pendingMs := 500 } fun s site => do
  let sid (r : Res) : IO String := do
    let some x := jsonField r.bodyText "session" | throw (IO.userError "FAILED: no session")
    return x
  -- reservations are lazy: no thread until the first request
  let ids ← (List.range 3).mapM fun _ => do sid (← run site (Req.get "/counter/server"))
  let (live, pending, st) ← s.counts
  expectEq (live, pending, st.reserved, st.spawned) (0, 3, 3, 0) "three reserved, none started"
  -- a fourth reservation evicts the oldest reservation
  let d ← sid (← run site (Req.get "/counter/server"))
  let (live, pending, st) ← s.counts
  expectEq (live, pending, st.evicted) (0, 3, 1) "pending cap"
  expectEq (← run site (Req.post s!"/leanui/{ids[0]!}" "h")).status 410 "the evicted reservation is gone"
  -- start three: the least recently used live one is evicted at the cap of two
  for i in [ids[1]!, ids[2]!, d] do
    expectEq (← run site (Req.post s!"/leanui/{i}" "h")).status 200 s!"hydrate {i}"
  let (live, pending, st) ← s.counts
  expectEq (live, pending, st.spawned) (2, 0, 3) "live cap"
  expectEq (← run site (Req.post s!"/leanui/{ids[1]!}" "e\n2\n")).status 410 "LRU live session evicted"
  expectEq (← run site (Req.post s!"/leanui/{d}" "e\n2\n")).status 200 "the newest survives"
  -- expiry, with a clock in the future
  let now ← IO.monoMsNow
  expectEq (← s.sweep now) 0 "nothing idle yet"
  let e ← sid (← run site (Req.get "/counter/server"))
  expectEq (← s.sweep (now + 700)) 1 "the reservation expires first (pendingMs)"
  expectEq (← run site (Req.post s!"/leanui/{e}" "h")).status 410 "expired reservation"
  expectEq (← s.sweep (now + 5000)) 2 "idle live sessions expire (idleMs)"
  let (live, pending, _) ← s.counts
  expectEq (live, pending) (0, 0) "all gone"
  expectEq (← run site (Req.post s!"/leanui/{d}" "e\n2\n")).status 410 "expired live session"
  -- the reaper runs in the background and stops on request
  withSite { sweepMs := 100, pendingMs := 50 } fun s2 site2 => do
  discard <| run site2 (Req.get "/counter/server")
  let stop ← s2.startReaper
  IO.sleep 400
  stop
  let (_, pending, st) ← s2.counts
  expectEq (pending, st.expired) (0, 1) "the reaper expired the reservation"
  -- closeAll stops every actor
  let c ← Client.open site2 "/counter/server"
  s2.closeAll
  expectEq (← c.click "id" "inc") 410 "closed"
  IO.println "  session lifecycle (lazy start, caps with LRU eviction, expiry, reaper, closeAll): ok"

/-- A pure busy loop (an `update` that takes far too long). -/
def spin : Nat → UInt64 → UInt64
  | 0, a => a
  | n + 1, a => spin n (a * 6364136223846793005 + 1442695040888963407)

/-- A session that does not answer in time gets `500` (from the reaper's watchdog) instead of
holding the connection; so do the requests queued behind it; then the session is gone. -/
def testReplyTimeout : IO Unit := do
  let sessions ← Sessions.new { replyTimeoutMs := 150, sweepMs := 100 }
  let stopReaper ← sessions.startReaper
  try
    let slow : Program UInt64 Unit := {
      init := fun _ => (0, .none), update := fun _ m => (spin 800000000 m, .none)
      view := fun m => el "p" #[onClick ()] #[text (toString (m % 10))] }
    let site := Route.under "/slow" (program "slow" slow {} sessions) ++ sessions.route "/leanui"
    let c ← Client.open site "/slow/server"
    let slot := ((← c.dom.get).get (← c.root)).listeners[0]!.2.1
    let t0 ← IO.monoMsNow
    let first ← IO.asTask (Client.request site (Req.post s!"/leanui/{c.session}" s!"e\n{slot}\n"))
    IO.sleep 20
    let queued ← Client.request site (Req.post s!"/leanui/{c.session}" s!"e\n{slot}\n")
    let first ← IO.ofExcept (← IO.wait first)
    let dt := (← IO.monoMsNow) - t0
    expectEq (first.status, queued.status) (500, 500) "a stuck session and the request queued behind it answer 500"
    expect (dt < 1500) s!"answered by the watchdog ({dt} ms)"
    expectEq (← c.fire (← c.root) "click") 410 "then the session is gone"
  finally
    stopReaper
    sessions.closeAll
  IO.println "  stuck sessions (the reaper's watchdog answers 500 after replyTimeoutMs, no timer per request): ok"

/-- Many sessions driven at once, each from its own task, plus one session hammered by several
tasks: actors keep every session's state separate and its requests serialised. -/
def testConcurrency : IO Unit := withSite {} fun _ site => do
  let clients ← (List.range 24).toArray.mapM fun _ => Client.open site "/counter/server"
  let tasks ← clients.mapIdxM fun i c => IO.asTask do
    for _ in [0:i + 5] do discard <| c.click "id" "inc"
    for _ in [0:i % 3] do discard <| c.click "id" "dec"
  for t in tasks do discard <| IO.ofExcept (← IO.wait t)
  let mut i := 0
  for c in clients do
    c.check (Counter.view ((i + 5 : Nat) - (i % 3 : Nat) : Int)) s!"session {i}"
    i := i + 1
  -- one session, several senders: increments commute, so the count is exact
  let c ← Client.open site "/counter/server"
  let inc ← c.find "id" "inc"
  let slot := ((← c.dom.get).get inc).listeners.find? (·.1 == "click") |>.map (·.2.1) |>.getD 0
  let hammer ← (List.range 8).toArray.mapM fun _ => IO.asTask do
    for _ in [0:50] do
      let r ← run site (Req.post s!"/leanui/{c.session}" s!"e\n{slot}\n")
      unless r.status == 200 do throw (IO.userError s!"status {r.status}")
  for t in hammer do discard <| IO.ofExcept (← IO.wait t)
  discard <| c.click "id" "inc"
  expectEq (← c.text "id" "value") "<output class=\"pos\" id=\"value\">401</output>" "8 × 50 concurrent increments + 1"
  IO.println "  concurrency (24 sessions in parallel; 400 requests from 8 tasks to one session): ok"

/-! ## The `Std.Http` adapter, over the in-memory transport -/

/-- Send raw HTTP/1.1 bytes through `Std.Http`'s connection loop with our handler. -/
def rawHttp (route : Route) (raw : String) (cfg : Config := {}) : IO ByteArray := Std.Async.Async.block do
  let (client, server) ← Std.Http.Internal.Mock.new
  client.send raw.toUTF8
  client.getSendChan.close
  Std.Http.Server.serveConnection server ({ route, cfg := { cfg with log := false } } : LeanUI.Server.Handler) cfg.http |>.run
  return (← client.recv?).getD .empty

/-- Split a raw response into its head (text) and body. -/
def splitResponse (b : ByteArray) : String × ByteArray := Id.run do
  let mut i := 0
  while i + 3 < b.size do
    if b[i]! == 13 && b[i+1]! == 10 && b[i+2]! == 13 && b[i+3]! == 10 then
      return (String.fromUTF8! (b.extract 0 i), b.extract (i + 4) b.size)
    i := i + 1
  return (String.fromUTF8? b |>.getD "", .empty)

def testHttpAdapter : IO Unit := withSite {} fun _ site => do
  let (head, body) := splitResponse (← rawHttp site "GET /counter/server?x=1 HTTP/1.1\r\nHost: t\r\n\r\n")
  expect (head.startsWith "HTTP/1.1 200") s!"page status: {head}"
  expect (contains head "Content-Type: text/html; charset=utf-8") "page type"
  expect (contains head "Cache-Control: no-store") "page cache"
  let page := String.fromUTF8! body
  let some sid := jsonField page "session" | throw (IO.userError "FAILED: no session over HTTP")
  expect (contains page "<output id=\"value\" class=\"pos\">0</output>") "SSR over HTTP"
  let (head, body) := splitResponse (← rawHttp site s!"POST /leanui/{sid} HTTP/1.1\r\nHost: t\r\nContent-Type: text/plain\r\nContent-Length: 1\r\n\r\nh")
  expect (head.startsWith "HTTP/1.1 200") s!"hydrate status: {head}"
  expect (contains head "Server-Timing: actor;dur=") "server-timing over HTTP"
  let some (ops, strs) := decodeUpdate body | throw (IO.userError "FAILED: hydrate body")
  let d := ({} : LeanUI.Testing.Dom).apply ops strs
  expect (d.effects.any (·.startsWith "hydrate #app 1 ")) "hydrate command over HTTP"
  -- keep-alive: two requests on one connection, the second an event
  let ev := "e\n2\n"
  let both ← rawHttp site (s!"POST /leanui/{sid} HTTP/1.1\r\nHost: t\r\nContent-Length: {ev.utf8ByteSize}\r\n\r\n{ev}" ++
    "GET /api/hello?n=3 HTTP/1.1\r\nHost: t\r\n\r\n")
  let txt := String.fromUTF8? both |>.getD (String.fromUTF8! (both.extract (both.size - 40) both.size))
  expectEq ((String.ofList (both.toList.map fun b => Char.ofNat b.toNat)).splitOn "HTTP/1.1 200").length 3 "two responses on one connection"
  expect (contains txt "{\"hello\":\"from Lean\",\"n\":\"3\"}") "second response"
  let (head, body) := splitResponse (← rawHttp site "HEAD /leanui.js HTTP/1.1\r\nHost: t\r\n\r\n")
  expect (head.startsWith "HTTP/1.1 200" && contains head "Content-Type: text/javascript") s!"HEAD: {head}"
  expect (body.size == 0) "HEAD has no body"
  expect (contains head "Content-Length: ") "HEAD keeps the length"
  let (head, _) := splitResponse (← rawHttp site "GET /nope HTTP/1.1\r\nHost: t\r\n\r\n")
  expect (head.startsWith "HTTP/1.1 404") "404"
  let (head, _) := splitResponse (← rawHttp site "GET /a/%2e%2e/b HTTP/1.1\r\nHost: t\r\n\r\n")
  expect (head.startsWith "HTTP/1.1 400") s!"refused path: {head}"
  let big := String.ofList (List.replicate 3000 'x')
  let (head, _) := splitResponse (← rawHttp site s!"POST /leanui/{sid} HTTP/1.1\r\nHost: t\r\nContent-Length: 3000\r\n\r\n{big}" { maxBody := 1000 })
  expect (head.startsWith "HTTP/1.1 413") s!"body limit: {head}"
  IO.println "  Std.Http adapter over the mock transport (page, h, keep-alive, HEAD, 400/404/413): ok"

/-! ## The CLI -/

def testCli : IO Unit := do
  match Cli.parseServe ["dist/counter", "--port", "5352", "--coop", "--cache", "3600", "--spa"] with
  | .ok o => expectEq (o.dir.toString, o.port, o.coop, o.cache, o.spa, o.listing) ("dist/counter", 5352, true, .maxAge 3600, true, true) "serve options"
  | .error e => throw (IO.userError s!"FAILED: {e}")
  for bad in [[], ["a", "b"], ["d", "--port", "99999"], ["d", "--cache", "forever"], ["d", "--what"]] do
    expect (Cli.parseServe bad).toOption.isNone s!"serve {bad} must fail"
  expect (Cli.validName "Todo" && Cli.validName "My_App2") "valid names"
  expect (!Cli.validName "todo" && !Cli.validName "" && !Cli.validName "A-B" && !Cli.validName "A.B") "invalid names"
  expectEq (Cli.defaultName "Examples.CounterApp") "examples-counterapp" "build-app.sh's default name"
  let files := Cli.scaffold "Gizmo"
  expectEq (files.map (·.1)) ["Gizmo.lean", "GizmoApp.lean"] "scaffold files"
  for (_, body) in files do expect (body.startsWith "module\npublic import ") "scaffolded files are modules"
  expect (contains (files[1]!.2) "leanui_app Gizmo.program") "entry module"
  expect (contains (files[0]!.2) "s!\" {m.draft.length} characters\"") "interpolation survives the template"
  expectEq (← Cli.findRoot ".") (some ".") "the checkout root"
  IO.println "  cli (serve options, names, scaffold): ok"

/-! ## Measurements: session actors against a shared session table -/

namespace BenchList
structure Model where
  rows : Array Nat
  sel : Nat := 0
inductive Msg | select (k : Nat)
def view (m : Model) : Html Msg :=
  el "ul" #[id "rows"] (m.rows.map fun k =>
    el "li" #[Attr.key (toString k), cls (if k == m.sel then "selected" else "row"), onClick (.select k)] #[
      el "span" #[] #[text s!"row {k}"], text " ", el "b" #[] #[text (toString (k * 7 % 13))]])
def program : Program Model Msg := {
  init := fun flags => ({ rows := Array.range (flags.toNat?.getD 1000) }, .none)
  update := fun | .select k, m => ({ m with sel := k }, .none)
  view }
end BenchList

def nsPerEvent (t0 t1 n : Nat) : Float := (t1 - t0).toFloat / n.toFloat

/-- Microseconds with one decimal, right-aligned in `w` columns. -/
def fmtUs (ns : Float) (w : Nat := 10) : String :=
  let tenths := (ns / 100.0).round.toUInt64.toNat
  let s := s!"{tenths / 10}.{tenths % 10}µs"
  String.ofList (List.replicate (w - min w s.length) ' ') ++ s

/-- One run of `n` events (rows selected in a fixed pseudo-random order) per design; returns
nanoseconds per event for: in-thread (`start` driven directly, no threads: the floor), actor
(the server's design: a dedicated thread owns the state), shared-mt (the state reachable from a
table shared across tasks, stepped on the calling thread: the multi-threaded-object cost alone),
shared-tasks (the same, each request on a fresh task, as an HTTP handler would). -/
def benchOnce (rows n : Nat) : IO (Float × Float × Float × Float) := do
  let flags := toString rows
  let p := BenchList.program
  let mut rng : Rng := ⟨77⟩
  let mut slots : Array UInt32 := #[]
  for _ in [0:n] do
    let (r, k) := rng.below rows; rng := r
    slots := slots.push (k + 1).toUInt32
  let sink ← IO.mkRef 0
  let host : Host := { flush := fun ops strs => sink.modify (· + ops.size + strs.size) }
  -- in-thread
  let inst ← start p host flags "#app" false
  let t0 ← IO.monoNanosNow
  for s in slots do inst.event s ""
  let direct := nsPerEvent t0 (← IO.monoNanosNow) n
  -- actor
  let a ← Actor.spawn p flags "#app"
  discard <| IO.wait (← a.ask .hydrate)
  let t0 ← IO.monoNanosNow
  for s in slots do discard <| IO.wait (← a.ask (.event s ""))
  let actor := nsPerEvent t0 (← IO.monoNanosNow) n
  a.stop
  -- shared table, stepped on this thread
  let inst ← start p host flags "#app" false
  let table ← Std.Mutex.new (({} : Std.HashMap String Instance).insert "s" inst)
  -- one task touching the table makes it, and everything reachable from it, multi-threaded
  discard <| IO.wait (← IO.asTask (table.atomically (m := IO) do return (← get).size))
  let step (s : UInt32) : IO Unit := table.atomically (m := IO) do
    if let some i := (← get).get? "s" then i.event s ""
  let t0 ← IO.monoNanosNow
  for s in slots do step s
  let sharedMt := nsPerEvent t0 (← IO.monoNanosNow) n
  -- shared table, a task per request
  let t0 ← IO.monoNanosNow
  for s in slots do discard <| IO.wait (← IO.asTask (step s))
  let sharedTasks := nsPerEvent t0 (← IO.monoNanosNow) n
  return (direct, actor, sharedMt, sharedTasks)

def bench (full : Bool) : IO Unit := do
  IO.println "  session designs, per event (select a row: render, diff, encode):"
  IO.println "     rows   in-thread      actor  shared-mt  shared-tasks   shared-mt vs actor"
  for (rows, n) in (if full then [(100, 2000), (1000, 600), (5000, 150)] else [(1000, 200)]) do
    -- best of three: scheduling noise only ever adds time
    let mut best := (1e18, 1e18, 1e18, 1e18)
    for _ in [0:3] do
      let (a, b, c, d) ← benchOnce rows n
      best := (min best.1 a, min best.2.1 b, min best.2.2.1 c, min best.2.2.2 d)
    let (a, b, c, d) := best
    let pct := ((c / b - 1.0) * 100.0).round.toUInt64.toNat
    let pad (n : Nat) (s : String) := String.ofList (List.replicate (n - min n s.length) ' ') ++ s
    IO.println s!"    {pad 5 (toString rows)} {fmtUs a 11} {fmtUs b 10} {fmtUs c 10} {fmtUs d 13}   +{pct}%"

/-- Model writes: a model holding one big array, an update that writes one element
(`Array.set!`), and a constant (lazy) view, so the time per event is the write itself. In a
single-threaded state the write is in place whatever the size; in a state that is reachable from
a shared table (multi-threaded) the array is never exclusive, so every write copies all of it. -/
def benchModelWrites : IO Unit := do
  let mk (n : Nat) : Program (Array Nat) Nat := {
    init := fun _ => (Array.replicate n 0, .none)
    update := fun i a => (a.set! (i % a.size) i, .none)
    view := fun _ => lazy 1 fun _ => el "p" #[onClick 1] #[text "constant"] }
  IO.println "  model writes (one Array.set! per event, constant view), per event:"
  IO.println "     elements   in-thread      actor   shared-mt"
  for n in [1000, 100000, 1000000] do
    let k := if n ≥ 1000000 then 30 else 200
    let sink ← IO.mkRef 0
    let host : Host := { flush := fun ops _ => sink.modify (· + ops.size) }
    let inst ← start (mk n) host "" "#app" false
    let t0 ← IO.monoNanosNow
    for _ in [0:k] do inst.event 1 ""
    let direct := nsPerEvent t0 (← IO.monoNanosNow) k
    let a ← Actor.spawn (mk n) "" "#app"
    discard <| IO.wait (← a.ask .hydrate)
    let t0 ← IO.monoNanosNow
    for _ in [0:k] do discard <| IO.wait (← a.ask (.event 1 ""))
    let actor := nsPerEvent t0 (← IO.monoNanosNow) k
    a.stop
    let inst ← start (mk n) host "" "#app" false
    let table ← Std.Mutex.new (({} : Std.HashMap String Instance).insert "s" inst)
    discard <| IO.wait (← IO.asTask (table.atomically (m := IO) do return (← get).size))
    let t0 ← IO.monoNanosNow
    for _ in [0:k] do table.atomically (m := IO) do if let some i := (← get).get? "s" then i.event 1 ""
    let shared := nsPerEvent t0 (← IO.monoNanosNow) k
    let pad (w : Nat) (s : String) := String.ofList (List.replicate (w - min w s.length) ' ') ++ s
    IO.println s!"    {pad 9 (toString n)} {fmtUs direct 11} {fmtUs actor 10} {fmtUs shared 11}"

def main (args : List String) : IO UInt32 := do
  IO.println "leanui server tests"
  try
    testUrl
    testMime
    testRemoteParse
    testJson
    testPage
    testHydrationContract 600
    testStatic
    testCounterSession
    testTickerSession
    testContractSession
    testProtocolErrors
    testLifecycle
    testConcurrency
    testReplyTimeout
    testHttpAdapter
    testCli
    bench (args.contains "--bench")
    benchModelWrites
  catch e =>
    IO.eprintln s!"{e}"
    -- exit at once: a failed test may leave threads behind that would keep the process alive
    IO.Process.exit 1
  IO.println "all passed"
  return 0
