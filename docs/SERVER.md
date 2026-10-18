# The LeanUI server

`LeanUI.Server` runs LeanUI programs on a native Lean server (`Std.Http`, Lean 4.34). One
`Program` (pure `init`, `update`, `view`) is served three ways from the same code:

- **server-rendered, then hydrated by its wasm build**: the page is complete HTML before any
  script runs; the app's wasm64 module then *adopts* those nodes instead of recreating them;
- **server-rendered, then server-driven**: for browsers without WebAssembly Memory64, the page is a
  thin client and a native *session* on the server runs the program;
- **server-rendered only**: no script at all.

`LeanUI.boot` picks the first when the browser has Memory64 and the second otherwise. The
library also serves static files, and the `leanui` command builds, scaffolds and serves apps.

```
 GET /counter/server ─▶ Site.page ─▶ view (init flags) ─▶ Html.render ─▶ <div id="app">…</div>
                                       └─ Sessions.reserve (an id, no thread yet)
 browser: LeanUI.connect ─▶ POST /leanui/<id> "h" ─▶ Sessions.route ─▶ Mailbox ─▶ actor thread
                                                                        │ LeanUI.start (hydrate)
          applies Buf.encode ◀──────────────── 200 [u32 opsBytes][ops][strs] ◀┘ Instance.event
 click:   POST "e\n<slot>\n<payload>" ─▶ … same actor, same Instance … ─▶ the diff, as bytes
```

## Contents

| Module | What it does |
|---|---|
| `LeanUI.Server.Http` | `Req`, `Res`, `Route` and its combinators (transport-independent) |
| `LeanUI.Server.Url` | path/query decoding, percent-encoding, traversal refusal |
| `LeanUI.Server.Mime` | media types (`application/wasm` among them) |
| `LeanUI.Server.Static` | static files: index, redirects, ETag/304, HEAD, cache policies, br/gz, COOP/COEP |
| `LeanUI.Server.Page` | the HTML document around a rendered view, and the boot script |
| `LeanUI.Server.Session` | the remote protocol, session actors, the session table |
| `LeanUI.Server.Site` | `program`: serve a `Program` at a URL in every mode |
| `LeanUI.Server.Run` | the `Std.Http` adapter, `serve`, clean shutdown on signals |
| `LeanUI.Server.Testing` | a native browser stand-in for server-driven pages (not in the umbrella) |
| `LeanUI.Server.Cli` | the `leanui` command (`cli/Main.lean` calls it) |
| `LeanUI.Server.Demo` | the site of `leanui-demo-server` (`examples/ServerDemo.lean`) |

`import LeanUI.Server` brings in everything an app needs (not `Testing`, `Cli` or `Demo`). Server
modules are native only: `tools/build-app.sh` leaves every `*/Server*` path out of wasm builds.

## Quick start

```sh
lake build                                   # ~/.elan/toolchains/leanprover--lean4---v4.34.0/bin/lake
.lake/build/bin/leanui build CounterApp counter --compress   # dist/counter/: app.js, app.wasm, leanui.js (+ .br/.gz)
.lake/build/bin/leanui-demo-server --port 5340               # http://127.0.0.1:5340/
```

The demo serves `/counter` (auto), `/counter/wasm`, `/counter/server`, `/counter/ssr`, a
server-driven `/ticker/server` (an interval subscription, an HTTP effect, a title effect, flags
from `?from=N`) and `/contract/server` (markup the HTML parser rewrites; see the SSR contract
below). Without `dist/counter` it still runs: wasm pages answer 404 and `/counter` is
server-driven.

## Serving a program

```lean
import LeanUI.Server
open LeanUI LeanUI.Server

def main : IO Unit := do
  let sessions ← Sessions.new {}                  -- SessionConfig: caps, timeouts
  let stopReaper ← sessions.startReaper          -- expiry and the stuck-session watchdog
  let site : Site := { title := "Counter", assets := some "/assets/counter/",
                       flags := fun req => (req.param? "start").getD "" }
  serve { port := 8080 } (Route.first [
      Static.file "/leanui.js" "dist/counter/leanui.js",
      Route.under "/assets/counter" (Static.route { root := "dist/counter" }),
      Route.under "/counter" (program "counter" Counter.program site sessions),
      sessions.route "/leanui"])
    (onShutdown := do stopReaper; sessions.closeAll)
```

`program name p site sessions` answers, below its mount point:

| path | page | needs |
|---|---|---|
| `/` | `site.defaultMode` (`auto`), or `?mode=wasm\|server\|ssr\|auto` | |
| `/wasm` | server-rendered, hydrated by `<assets>app.js` | `site.assets` |
| `/server` | server-rendered, driven by a session | `sessions.route` mounted at `site.endpoint` |
| `/ssr` | server-rendered only | |
| `/auto` | `LeanUI.boot`: wasm with Memory64, else the session (falls back to the session if the wasm fails to start) | both |

Every page is the view of `init flags` rendered by `Html.render`; the wasm and the session compute
`init flags` again (it is pure), so the client starts from exactly the state the HTML shows.
`site.flags` maps the request to the flags string; the same string reaches the wasm through the
page. Pages that name a session are sent `Cache-Control: no-store` (a cached page would share its
session id); each carries `Server-Timing: ssr;dur=<ms>`.

### The page

`Page.render` writes `<div id="app">` + the rendered view + `</div>` with nothing in between
(hydration counts every node, whitespace included), then the boot parameters as JSON in
`<script id="leanui-boot" type="application/json">`, the runtime, and one fixed boot script. A
wasm page preloads `app.js`. After boot, `window.__leanui` is the runtime and
`<html data-leanui="wasm|server|failed">` says which transport runs. JSON is escaped so it is
safe inside `<script>` (`<`, `>`, `&`, U+2028/9 as `\uXXXX`).

## Server-driven sessions

### Protocol (`docs/DESIGN.md` §2)

`POST <endpoint>/<session>` with a text body:

| body | meaning |
|---|---|
| `h` | hydrate: claim the server-rendered nodes, attach listeners, run `init`'s commands |
| `e\n<slot>\n<payload>` | an event on listener slot `slot`; the payload may contain newlines |
| `c\n<cb>\n<0\|1>\n<payload>` | an effect finished (`fetch`, timer, storage, frame) or a subscription fired |

The response is `Buf.encode` of the update (`[u32 opsBytes][ops][strs]`, empty if nothing
changed) with `Server-Timing: actor;dur=<ms>`. Errors use HTTP statuses **and** carry a valid
buffer holding one `log` command with the reason, because the runtime applies any body it gets:

| status | when |
|---|---|
| 400 | malformed body (not UTF-8, unknown kind, bad slot or callback id) |
| 409 | out of order: an event before `h`, a second `h` |
| 410 | unknown, expired or evicted session (the browser logs "reload the page") |
| 500 | the session is stuck (see the watchdog) |

### Sessions are actors

A session runs on its own dedicated thread (`IO.asTask (prio := .dedicated)`), which creates the
running program (`LeanUI.start host flags selector (hydrate := true)`) and then serves the requests
that arrive in its mailbox, replying through an `IO.Promise`. The HTTP handler only forwards and
awaits the promise (no thread is blocked for it). Requests to one session are serialised by its
mailbox; sessions run in parallel.

Two Lean runtime properties shaped this design; both were measured (Apple M4 Max, 14 cores).

**Multi-threaded objects are never updated in place.** Everything reachable from a value that
crosses threads (a task closure, a shared `IO.Ref` or `Mutex`) is marked multi-threaded, and a
multi-threaded object is never "exclusive", so the first write to each array or buffer in it copies
the whole thing. If sessions lived in a table that handler tasks step directly, each event's
state would be marked again on every update. `tests/Server.lean` measures both designs:

| per event | in-thread | actor | shared table, same thread | shared table, task per request |
|---|---|---|---|---|
| 1000-row list: select a row (render, diff, encode) | 929 µs | 933 µs | 1040 µs (+11%) | 1138 µs |
| model with 1000 elements, one `Array.set!` | 0.3 µs | 8.0 µs | 1.9 µs | |
| 100 000 elements | 0.2 µs | 9.6 µs | 211 µs | |
| 1 000 000 elements | 9.4 µs | 11.6 µs | 1499 µs | |

The actor's cost is a fixed thread hop (8 to 10 µs, the mailbox round trip). The shared design
costs a fraction of every render, and grows with the model: a one-element write to a million-entry
model copies 8 MB, 130× slower than the actor.

**`IO.wait` wakes every waiter.** A thread blocked in `IO.wait` (`Task.get`) waits on the task
manager's single condition variable, which is notified on *every* task completion in the process.
With session threads blocked on `Std.CloseableChannel` receives, every idle session was woken by
every task the HTTP server finished: a trivial request took 0.30 ms with no sessions, 0.89 ms with
8 idle ones, 2.0 ms with 40 and 3.7 ms with 168. So a `Mailbox` is a queue with its *own*
condition variable (`Std.Mutex` + `Std.Condvar`); with it, 168 idle sessions leave the request at
0.37 ms.

### Lifecycle

- **Reserve** (`Sessions.reserve`, called by `program` when it renders a page that may need a
  session): an id of 128 random bits and a closure; no thread. Pages whose browser runs the wasm
  never start one.
- **Start**: the first request spawns the actor.
- **Expire**: the reaper (`startReaper`, every `sweepMs`) removes live sessions idle for
  `idleMs` and reservations unused for `pendingMs`.
- **Evict**: at `maxLive` live sessions (threads) the least recently used is stopped; at
  `maxPending` reservations, the oldest reservation is dropped. Recency is a logical clock, so ties
  cannot occur.
- **Watchdog**: a session busy with one request for more than `replyTimeoutMs` (an `update` that
  loops) is removed by the next sweep; its request and those queued behind it get `500`. This costs
  nothing per request (the actor records when it started its current request). The thread itself
  cannot be cancelled and ends when the update returns.
- **Shutdown**: `closeAll` stops every actor. A Lean process does not exit while dedicated
  threads run (`lean_finalize_task_manager` waits for them), so a server must close its sessions;
  `serve`'s `onShutdown` (run on `SIGINT`/`SIGTERM`) is the place.

| `SessionConfig` | default |
|---|---|
| `maxLive` | 512 |
| `maxPending` | 4096 |
| `idleMs` | 30 min |
| `pendingMs` | 5 min |
| `sweepMs` | 5 s |
| `replyTimeoutMs` | 30 s (`0`: off) |
| `selector` | `#app` |

`sessions.statsRoute "/leanui/stats"` serves the counts as JSON (live, pending, reserved,
spawned, expired, evicted, requests, gone); mount it only where monitoring should see it.

### Security

The session id is the session's only credential: 128 bits from `IO.getRandomBytes`, never in a
cacheable response. Without the id a cross-site page cannot drive a session, so no CSRF token is
needed. Request bodies are capped (`Config.maxBody`, 1 MiB; larger ones get 413). Run behind a
TLS-terminating proxy in production; the server binds `127.0.0.1` unless told otherwise.

## Static files

`Static.route { root := dir }` serves a directory:

- media types from the extension (`application/wasm`, `text/javascript; charset=utf-8`, …),
  `X-Content-Type-Options: nosniff`;
- `index.html` for directories; a directory URL without its trailing slash is redirected (301) to
  it, keeping the query, so relative URLs inside the page resolve; optional listings;
- `HEAD` (the transport sends the headers and `Content-Length`, no body);
- weak ETags from size and modification time, `If-None-Match` → 304;
- `Cache-Control`: `.noStore`, `.revalidate` (`no-cache` + ETag, the default), `.maxAge s`,
  `.immutable` (for content-hashed names); HTML has its own policy (`htmlCache`, revalidate);
- precompressed siblings: `f.br` or `f.gz` is sent for `f` when it exists and the client accepts
  it (`Content-Encoding`, `Vary: accept-encoding`);
- `isolate := true` adds `Cross-Origin-Opener-Policy: same-origin` and
  `Cross-Origin-Embedder-Policy: require-corp`. Off by default: LeanUI's wasm is single-threaded
  and needs no `SharedArrayBuffer`, and isolation would stop the page from embedding cross-origin
  resources that do not opt in;
- `spa := true`: unknown extension-less paths get the root `index.html` (client-side routes);
- never outside the root: the path is decoded segment by segment and `..`, NUL, `\` and `:` are
  refused (400), not resolved (`%2e%2e` and `..%2f` included); dotfiles are hidden
  (`.well-known` excepted); with `confine` (default) the real path must stay below the root's, so a
  symlink cannot lead out.

`Static.file "/leanui.js" path` serves one file at one URL.

## Routes

```lean
structure Req  -- method, target, decoded segments, query, lower-case headers, body
structure Res  -- status, headers, body; Res.html / text / json / bytes / redirect / notFound
structure Route where run : Req → Async (Option Res)   -- none: not mine, try the next
```

`Route.first [..]` and `a ++ b` try routes in order; `Route.get path f`, `Route.post`,
`Route.on methods path f` match one path below the mount point; `Route.under "/prefix" r` mounts
`r` (it sees `req.path` below the prefix and `req.base` for absolute URLs); `Route.param methods
pre f` passes one more segment (a session id); `Route.handle` turns a route into a complete
handler (404, 400 for refused paths, 500 for exceptions, logged). Handlers run in `Std.Async`, so
they can await tasks without blocking a thread.

`serve cfg route (onShutdown)` binds (`Config.host`, `port`; `0` picks a port, `boundPort` reports
it), logs one line per request (`log`, `logSessions`), and stops on `SIGINT`/`SIGTERM`.

## The `leanui` command

```
leanui serve <dir> [--port N] [--host H] [--coop] [--cache no-store|revalidate|immutable|<s>] [--spa] [--no-listing] [--quiet]
leanui build <EntryModule> [name] [--debug] [--compress]
                                              # tools/build-app.sh; finds the wasm64 archives
                                              # ($LEANUI_TOOLCHAIN, <root>/.toolchain, or the main
                                              # checkout's when run from a git worktree); checks Docker;
                                              # --compress writes .br/.gz siblings (Node's zlib), else
                                              # removes stale ones
leanui new <Name> [--dir DIR]                 # DIR/<Name>.lean (program) + DIR/<Name>App.lean (wasm entry)
leanui help | version
```

`leanui new` refuses to overwrite and prints the `lakefile.toml` roots to add; the scaffold
compiles as is.

## The SSR contract

Hydration walks the *parsed* DOM in pre-order and must meet exactly the nodes `mount` allocates.
The HTML parser rewrites some markup, so `Html.render` compensates where it can:

- adjacent texts get `<!--|-->` between them and an empty text is `<!--t-->` (the parser would
  merge or drop them);
- a carriage return is written `&#13;` (the parser turns `\r` and `\r\n` into `\n`);
- of duplicate attributes only the last is written (the parser keeps the first, mounting keeps
  the last, and hydration does not resend attributes);
- a text starting with a newline inside `<pre>`, `<textarea>` or `<listing>` gets one more newline
  (the parser drops one after the start tag; a text of just `"\n"` would vanish).

Views that are served server-rendered must also avoid what the parser *restructures*, which a
renderer cannot undo: `<tr>` directly in `<table>` (the parser inserts `<tbody>`), block elements
inside `<p>` (`<p><div>` closes the paragraph), nested `<a>`, `<form>` in `<form>`, element children
or several texts in `<textarea>` or `<title>` (their content is text, and the markers would be
text too), and texts in `<script>`/`<style>` that need escaping (their content is not decoded).
Verified in Chromium 151 and Firefox 153.

`tests/Server.lean` checks the contract as a property: random views (adjacent and empty texts,
characters that need escaping, astral characters, carriage returns, `pre`/`textarea` newlines,
duplicate attributes, void elements, properties) are rendered, parsed by
`LeanUI.Server.Testing.parseHtml` (which applies the parser's rewrites above), claimed as the
runtime claims them, given the hydration buffer of `mount`, and compared with the view.

## Testing

Native (`.lake/build/bin/leanui-server-tests [--bench]`, about 4 s):

- URL decoding and traversal refusal, media types, protocol bodies, script-safe JSON, the page
  template in its four boot modes;
- the SSR ⇄ hydration property (600 random views) and its regressions;
- static files: types, index, redirects, ETag/304, HEAD, br/gz, COOP/COEP, SPA, listings,
  dotfiles, symlink confinement;
- server-driven pages through `LeanUI.Server.Testing.Client`, which plays the browser against the
  real demo routes: GET the page, parse it, claim the container's nodes, `h`, then clicks, input,
  interval callbacks, fetch results and title effects, each response applied to
  `LeanUI.Testing.Dom` and compared with the view (no leaked handles);
- protocol errors (400/409/410 with log bodies), lifecycle (lazy start, both caps, expiry, the
  reaper, `closeAll`), the watchdog, 24 sessions in parallel and 400 concurrent requests to one;
- the `Std.Http` adapter over `Std.Http`'s in-memory mock transport (page, `h`, keep-alive,
  HEAD, 400/404/413);
- the CLI's options and scaffold; the measurements above.

Browser (`node tests/browser/server.mjs [chromium|firefox|all]`, under the host browser lock,
ports 5351-5352; needs `dist/counter`): starts `leanui-demo-server` and `leanui serve --coop`
itself and stops them with `SIGTERM` (checking they exit cleanly), then in Chromium and Firefox:

- server-driven counter: an expando put on the server-rendered `#value` (with the session's
  first reply held back) survives, the node list is identical, clicks and input work;
- SSR + wasm hydration: the same with the wasm loader held back; events work after hydration;
  each asset is fetched once; the page reserved no session;
- `/counter` boots wasm, and is server-driven when Memory64 is hidden from the feature test;
- the ticker: interval callbacks, a fetch result, `document.title`;
- the contract page hydrates exactly and updates through the claimed text nodes;
- pages without JavaScript; MIME types, HEAD, ETag/304, COOP/COEP, traversal refused (raw
  `%2e%2e` bytes);
- 32 concurrent sessions × 100 events over HTTP;
- precompressed siblings: `br` and `gzip` decode to the same bytes, and the browsers fetch the
  wasm compressed;
- no page errors and no wasm MIME fallback warnings.

### Measured on localhost (M4 Max)

| | Chromium 151 | Firefox 153 |
|---|---|---|
| server-driven round trip, click → DOM updated (200 clicks) | median 1.2 to 1.5 ms, p95 1.4 to 2.0 ms | median 2 ms, p95 2 to 3 ms (1 ms timer resolution) |
| of which in the session (`Server-Timing`) | 0.02 to 0.03 ms | 0.02 to 0.05 ms |
| wasm boot + hydration of the counter | 38 to 51 ms | 51 to 62 ms |
| `app.wasm` on the wire with `--compress` (both send `br` to `127.0.0.1`) | 150 KB of 1034 KB | 150 KB of 1034 KB |

Over HTTP with keep-alive: about 0.3 ms per request for a static file or a small route (curl), 0.5
to 0.7 ms per session event (ApacheBench, one connection, 1500 to 2200 events/s). `Std.Http` in Lean
4.34 tops out near 2000 to 3000 requests/s on this machine whatever the concurrency (the bare
research prototype server: 3200/s sequential, 2500/s at 32 connections); 32 concurrent sessions
over HTTP reach about 1500 events/s.
