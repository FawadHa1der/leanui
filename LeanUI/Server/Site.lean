module
public import LeanUI.Server.Page
public import LeanUI.Server.Session
/-!
# Serving a program

`Server.program` mounts a `Program` at a URL and serves it every way LeanUI can run it, from the
same view function:

| path (below the mount point) | page |
|---|---|
| `/` | `auto`: wasm when the browser has Memory64, the server otherwise (`?mode=` overrides) |
| `/wasm` | server-rendered, then hydrated by the app's wasm build |
| `/server` | server-rendered, then driven by a native session |
| `/ssr` | server-rendered only, no script |

Every page starts as the view of `init flags` rendered by `Html.render`, so it is complete before
any script runs; the wasm or the session then adopts those nodes (hydration) instead of
rebuilding them. Both compute `init flags` again, which is deterministic (`init` is pure), so the
client state matches the HTML exactly.
-/
public section
namespace LeanUI.Server

/-- How a page is brought to life. -/
inductive Mode where
  | auto | wasm | server | ssr
  deriving BEq, Repr, Inhabited

def Mode.ofString? : String → Option Mode
  | "auto" => some .auto | "wasm" => some .wasm | "server" => some .server | "ssr" => some .ssr
  | _ => none

def Mode.name : Mode → String
  | .auto => "auto" | .wasm => "wasm" | .server => "server" | .ssr => "ssr"

/-- How to serve a program. -/
structure Site where
  title : String := "LeanUI"
  /-- URL of the directory holding the app's wasm build (`app.js`, `app.wasm`), with a trailing
  slash, e.g. `/assets/counter/`. Without one, `wasm` pages are unavailable and `auto` pages are
  server-driven. -/
  assets : Option String := none
  /-- URL of `runtime/leanui.js`. -/
  runtime : String := "/leanui.js"
  /-- Where the session endpoint (`Sessions.route`) is mounted. -/
  endpoint : String := "/leanui"
  /-- Raw HTML for `<head>`, before and after the container. -/
  head : String := ""
  header : String := ""
  footer : String := ""
  container : String := "app"
  /-- The program's flags for a request (the same string reaches `init` on the server and in the
  wasm). -/
  flags : Req → String := fun _ => ""
  /-- What `/` serves. -/
  defaultMode : Mode := .auto

namespace Site

/-- The page for `mode`, reserving a session when the page may need one. -/
def page {Model Msg : Type} (site : Site) (name : String) (p : Program Model Msg) (sessions : Sessions)
    (mode : Mode) (req : Req) : IO Res := do
  let flags := site.flags req
  let t0 ← IO.monoNanosNow
  let body := (p.view (p.init flags).1).render
  let t1 ← IO.monoNanosNow
  let glue := site.assets.map (· ++ "app.js")
  let boot ← match mode, glue with
    | .ssr, _ => pure Boot.none
    | .wasm, some g => pure (Boot.wasm g flags)
    | .wasm, none => return Res.notFound s!"{name} has no wasm build"
    | .server, _ => do let sid ← sessions.reserve name p flags; pure (Boot.server site.endpoint sid)
    | .auto, some g => do let sid ← sessions.reserve name p flags; pure (Boot.auto g flags site.endpoint sid)
    | .auto, none => do let sid ← sessions.reserve name p flags; pure (Boot.server site.endpoint sid)
  let pg : Page := { title := site.title, head := site.head, header := site.header, footer := site.footer,
                     container := site.container, body, runtime := site.runtime, boot }
  -- a page that names a session must never be cached: the id would be shared
  let cache := match boot with | .server .. | .auto .. => "no-store" | _ => "no-cache"
  let us := (t1 - t0) / 1000
  return (Res.html pg.render).withHeader "cache-control" cache
    |>.withHeader "server-timing" s!"ssr;dur={us / 1000}.{toString (1000 + us % 1000) |>.drop 1}"

end Site

/-- Serve `p` below the current mount point (see the module docs for the paths). -/
def program {Model Msg : Type} (name : String) (p : Program Model Msg) (site : Site) (sessions : Sessions) : Route :=
  ⟨fun req => do
    if !req.isRead then return none
    let mode? : Option Mode := match req.rest with
      | #[] => some ((req.param? "mode" >>= Mode.ofString?).getD site.defaultMode)
      | #[m] => Mode.ofString? m
      | _ => none
    match mode? with
    | some mode => return some (← site.page name p sessions mode req)
    | none => return none⟩

end LeanUI.Server
