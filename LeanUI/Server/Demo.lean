module
public import LeanUI.Server
public import Counter
/-!
# The demo site

Everything `leanui-demo-server` (`examples/ServerDemo.lean`) serves, as a library so the native
tests (`tests/Server.lean`) drive the very same routes without a socket:

* `/counter` lets `LeanUI.boot` choose: the app's wasm when the browser has WebAssembly
  Memory64, the server otherwise;
* `/counter/wasm` is server-rendered, then hydrated by the wasm build in `<dist>/counter`;
* `/counter/server` is server-rendered, then driven by a native session;
* `/counter/ssr` is the server-rendered HTML alone;
* `/ticker/server` is a second, server-only program with a subscription (`Sub.every`), an HTTP
  effect (`Cmd.fetch` of `/api/hello`), a title effect and flags (`?from=N`): the callback half
  of the remote protocol;
* `/leanui.js` (the runtime), `/assets/counter/*` (the wasm build), `/api/hello`,
  `/leanui/stats` (session counts) and the session endpoint `POST /leanui/<session>`.

This module depends on the `Counter` example; nothing in the server library imports it.
-/
public section
namespace LeanUI.Server.Demo
open LeanUI LeanUI.Server Attr

namespace Ticker

structure Model where
  ticks : Nat
  running : Bool := false
  reply : String := "(nothing fetched yet)"
  deriving Inhabited

inductive Msg where
  | tick | toggle | fetch | got (r : Response) | bump (n : Nat)

def init (flags : String) : Model × Cmd Msg := ({ ticks := flags.toNat?.getD 0 }, .none)

def update : Msg → Model → Model × Cmd Msg
  | .tick, m => ({ m with ticks := m.ticks + 1 }, .none)
  | .toggle, m => ({ m with running := !m.running }, .none)
  | .fetch, m => (m, .fetch { url := s!"/api/hello?n={m.ticks}" } .got)
  | .got r, m => ({ m with reply := if r.ok then r.body else s!"failed ({r.status})" }, .none)
  | .bump n, m => ({ m with ticks := m.ticks + n }, .title s!"ticker {m.ticks + n}")

def view (m : Model) : Html Msg :=
  el "main" #[cls "ticker"] #[
    el "h1" #[] #[text "LeanUI ticker"],
    el "p" #[] #[
      text "ticks: ", el "output" #[id "ticks"] #[text (toString m.ticks)]],
    el "p" #[] #[
      el "button" #[id "toggle", onClick .toggle] #[text (if m.running then "stop" else "start")],
      el "button" #[id "fetch", onClick .fetch] #[text "fetch /api/hello"],
      el "button" #[id "bump", onClick (.bump 100)] #[text "+100"]],
    el "p" #[] #[text "server says: ", el "output" #[id "reply"] #[text m.reply]]]

def subscriptions (m : Model) : LeanUI.Sub Msg := if m.running then .every 100 .tick else .none

def program : Program Model Msg := { init, update, view, subscriptions }

end Ticker

namespace Contract

inductive Msg | go

/-- Markup the HTML parser rewrites (a newline after `<pre>`/`<textarea>`, carriage returns,
duplicate attributes, adjacent and empty texts, astral characters): the server renders it, the
browser parses it, and the session must still claim exactly the nodes it mounted. Clicking `go`
then updates texts through the claimed handles. -/
def view (n : Nat) : Html Msg :=
  el "main" #[id "contract"] #[
    el "pre" #[id "pre"] #[text s!"\n{n}\n"],
    el "p" #[id "texts"] #[text "a", text "", text "b", text (toString n)],
    el "p" #[id "crlf", .attr "title" "x\r\ny"] #[text "c\r\nd"],
    el "p" #[id "dup", cls "first", cls "last"] #[text "😀 & <tags>"],
    el "textarea" #[id "ta"] #[text "\nline"],
    el "button" #[id "go", onClick .go] #[text "go"]]

def program : Program Nat Msg := { init := fun _ => (0, .none), update := fun _ n => (n + 1, .none), view }

end Contract

def style : String :=
  "<style>:root{color-scheme:light dark;font:16px/1.5 system-ui,sans-serif}" ++
  "body{max-width:44rem;margin:2rem auto;padding:0 1rem}button{font:inherit;margin:0 .25rem;padding:.2rem .8rem}" ++
  "output{display:inline-block;min-width:3ch;text-align:center;font-weight:600}.neg{color:#c33}" ++
  "nav a{margin-right:1rem}code{font-size:.9em}table{border-collapse:collapse}td,th{padding:.2rem .6rem;text-align:left}</style>"

def nav : String :=
  "<nav><a href=\"/\">home</a><a href=\"/counter\">auto</a><a href=\"/counter/wasm\">wasm</a>" ++
  "<a href=\"/counter/server\">server</a><a href=\"/counter/ssr\">ssr</a><a href=\"/ticker/server\">ticker</a></nav>"

def landing (wasm : Bool) : String :=
  "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" ++
  "<title>LeanUI demo server</title>" ++ style ++ "</head><body>" ++ nav ++
  "<h1>LeanUI, served by Lean</h1>" ++
  "<p>This page comes from a native Lean server (<code>Std.Http</code>). The same <code>Counter</code> program " ++
  "(pure Lean: <code>init</code>, <code>update</code>, <code>view</code>) is served four ways:</p><table>" ++
  "<tr><th><a href=\"/counter\">/counter</a></th><td><code>LeanUI.boot</code> picks: wasm with Memory64, the server otherwise</td></tr>" ++
  "<tr><th><a href=\"/counter/wasm\">/counter/wasm</a></th><td>server-rendered, hydrated by the app's wasm64 build</td></tr>" ++
  "<tr><th><a href=\"/counter/server\">/counter/server</a></th><td>server-rendered, driven by a native Lean session</td></tr>" ++
  "<tr><th><a href=\"/counter/ssr\">/counter/ssr</a></th><td>server-rendered HTML only</td></tr>" ++
  "<tr><th><a href=\"/ticker/server?from=5\">/ticker/server</a></th><td>timers and HTTP effects in a server-driven session</td></tr>" ++
  "<tr><th><a href=\"/contract/server\">/contract/server</a></th><td>markup the HTML parser rewrites, hydrated anyway</td></tr></table>" ++
  (if wasm then "" else "<p><strong>No wasm build found</strong>: run <code>leanui build CounterApp counter</code>; until then wasm pages answer 404 and <code>/counter</code> is server-driven.</p>") ++
  "<p>This browser: <strong id=\"m64\">checking…</strong></p>" ++
  "<script src=\"/leanui.js\"></script><script>document.getElementById('m64').textContent=" ++
  "LeanUI.supported()?'has WebAssembly Memory64: /counter runs in wasm':'has no Memory64: /counter is server-driven';</script>" ++
  "</body></html>"

structure Opts where
  port : UInt16 := 5340
  host : String := "127.0.0.1"
  dist : System.FilePath := "dist"
  runtime : Option System.FilePath := none
  quiet : Bool := false

partial def parseArgs : List String → Opts → Except String Opts
  | [], o => .ok o
  | "--port" :: p :: rest, o => match p.toNat? with
    | some n => if n < 65536 then parseArgs rest { o with port := n.toUInt16 } else .error s!"bad port {p}"
    | none => .error s!"bad port {p}"
  | "--host" :: h :: rest, o => parseArgs rest { o with host := h }
  | "--dist" :: d :: rest, o => parseArgs rest { o with dist := d }
  | "--runtime" :: f :: rest, o => parseArgs rest { o with runtime := some f }
  | "--quiet" :: rest, o => parseArgs rest { o with quiet := true }
  | a :: _, _ => .error s!"unknown argument {a}"

/-- The whole site. -/
def routes (o : Opts) (sessions : Sessions) (runtime : System.FilePath) (wasm : Bool) : Route :=
  let page (title : String) : Site := {
    title, head := style, header := nav, assets := if wasm then some "/assets/counter/" else none }
  Route.first [
    Route.get "/" fun _ => return Res.html (landing wasm) |>.withHeader "cache-control" "no-cache",
    Static.file "/leanui.js" runtime,
    Route.under "/assets/counter" (Static.route { root := o.dist / "counter" }),
    Route.under "/counter" (program "counter" Counter.program (page "LeanUI counter") sessions),
    Route.get "/ticker" fun _ => return Res.redirect "/ticker/server",
    Route.under "/ticker" (program "ticker" Ticker.program
      { page "LeanUI ticker" with assets := none, flags := fun r => (r.param? "from").getD "0" } sessions),
    Route.under "/contract" (program "contract" Contract.program { page "SSR contract" with assets := none } sessions),
    Route.get "/api/hello" fun req =>
      return Res.json s!"\{\"hello\":\"from Lean\",\"n\":{jsonString ((req.param? "n").getD "")}}",
    sessions.statsRoute "/leanui/stats",
    sessions.route "/leanui"]



/-- Run the demo server (`leanui-demo-server [--port 5340] [--host H] [--dist dist] [--runtime F] [--quiet]`). -/
def main (args : List String) : IO UInt32 := do
  let o ← match parseArgs args {} with
    | .ok o => pure o
    | .error e => IO.eprintln s!"leanui-demo-server: {e}"; return 2
  let runtime ← match o.runtime with
    | some f => pure f
    | none => do
      -- the runtime next to the wasm build matches it; the repository copy otherwise
      let inDist := o.dist / "counter" / "leanui.js"
      pure (if ← inDist.pathExists then inDist else "runtime/leanui.js")
  let wasm ← (o.dist / "counter" / "app.wasm").pathExists
  unless wasm do IO.eprintln s!"[demo] no wasm build at {o.dist / "counter"}: wasm pages are off (run `leanui build CounterApp counter`)"
  let sessions ← Sessions.new {}
  let stopReaper ← sessions.startReaper
  IO.println s!"[demo] runtime {runtime}, wasm {if wasm then "on" else "off"}"
  serve { port := o.port, host := o.host, log := !o.quiet } (routes o sessions runtime wasm)
    (onShutdown := do stopReaper; sessions.closeAll)
  return 0

end LeanUI.Server.Demo
