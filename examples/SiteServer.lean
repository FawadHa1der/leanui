module
public import LeanUI.Server
public import Site
/-!
# `leanui-site`: the LeanUI site, served by Lean

    leanui-site [--port 5360] [--host 127.0.0.1] [--dist dist] [--quiet]

Every page (`/`, `/examples`, `/benchmarks`) is the site program's view for that URL, rendered to
HTML by this server, so it is complete before any script runs. Then the browser brings it to
life: with WebAssembly Memory64, the site's wasm build (`dist/site`, from
`tools/build-app.sh SiteApp site`) hydrates the page; without it (Safari), a native session on
this server runs the program and drives the page. `?mode=wasm|server|ssr|auto` picks a mode.

`/editor/` is the photo editor (`examples/Editor.lean`), a client-side app served as its own page
from `dist/editor` (`tools/build-app.sh EditorApp editor`), so the site's pages do not grow.

`/race/` is the race page, static files from `dist/race` (`bench/race/build.sh`): the same apps in
vanilla JavaScript, in LeanUI compiled to wasm64 and in LeanUI interpreted by lean-vir (`vir/`),
side by side. lean-vir runs only there; the site itself is the wasm64 build.
-/
public section
open LeanUI LeanUI.Server

namespace SiteServer

structure Opts where
  port : UInt16 := 5360
  host : String := "127.0.0.1"
  dist : System.FilePath := "dist"
  quiet : Bool := false

partial def parseArgs : List String → Opts → Except String Opts
  | [], o => .ok o
  | "--port" :: p :: rest, o => match p.toNat? with
    | some n => if n < 65536 then parseArgs rest { o with port := n.toUInt16 } else .error s!"bad port {p}"
    | none => .error s!"bad port {p}"
  | "--host" :: h :: rest, o => parseArgs rest { o with host := h }
  | "--dist" :: d :: rest, o => parseArgs rest { o with dist := d }
  | "--quiet" :: rest, o => parseArgs rest { o with quiet := true }
  | a :: _, _ => .error s!"unknown argument {a}"

def head : String :=
  "<meta name=\"description\" content=\"LeanUI: web user interfaces written in Lean 4, compiled to WebAssembly.\">" ++
  "<link rel=\"stylesheet\" href=\"/site.css\">"

/-- A page of the site: the URL's page, in the requested mode (404 for unknown paths). -/
def pageRoute (sessions : Sessions) (wasm : Bool) : Route := ⟨fun req => do
  if !req.isRead then return none
  let page? := Site.router.parse req.rawPath
  let mode := (req.param? "mode" >>= Mode.ofString?).getD .auto
  let site : Site := {
    title := match page? with
      | some .home | none => "LeanUI: web UIs in Lean 4"
      | some p => s!"{p.title} · LeanUI"
    head, assets := if wasm then some "/assets/site/" else none
    flags := fun r => r.rawPath }
  let res ← site.page "site" Site.program sessions mode req
  return some (if page?.isNone then res.withStatus 404 else res)⟩

def routes (o : Opts) (sessions : Sessions) (wasm : Bool) : Route :=
  let dist := o.dist / "site"
  Route.first [
    Static.file "/leanui.js" (if wasm then dist / "leanui.js" else "runtime/leanui.js"),
    Static.file "/site.css" "examples/site/site.css",
    Static.file "/data/benchmarks.json" "examples/site/benchmarks.json",
    Route.under "/assets/site" (Static.route { root := dist }),
    Route.under "/editor" (Static.route { root := o.dist / "editor" }),
    Route.under "/race" (Static.route { root := o.dist / "race" }),
    sessions.route "/leanui",
    pageRoute sessions wasm]

def main (args : List String) : IO UInt32 := do
  let o ← match parseArgs args {} with
    | .ok o => pure o
    | .error e => IO.eprintln s!"leanui-site: {e}"; return 2
  let wasm ← (o.dist / "site" / "app.wasm").pathExists
  unless wasm do IO.eprintln s!"[site] no wasm build at {o.dist / "site"}: every page is server-driven (run `tools/build-app.sh SiteApp site`)"
  let sessions ← Sessions.new {}
  let stopReaper ← sessions.startReaper
  serve { port := o.port, host := o.host, log := !o.quiet } (routes o sessions wasm)
    (onShutdown := do stopReaper; sessions.closeAll)
  return 0

end SiteServer

def main (args : List String) : IO UInt32 := SiteServer.main args
