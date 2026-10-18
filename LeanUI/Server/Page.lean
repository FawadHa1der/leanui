module
public import LeanUI.Render
/-!
# Server-rendered pages

A `Page` is the HTML document a LeanUI server sends: the program's view rendered by
`Html.render` inside its container, the browser runtime, and the boot call that brings the page
to life in one of these ways:

* `wasm`: the app's own wasm module **hydrates** the server-rendered nodes (adopts them in
  pre-order instead of recreating them) and runs in the page;
* `server`: the page stays a thin client; `LeanUI.connect` opens the remote protocol and a native
  session on the server runs the program (for browsers without WebAssembly Memory64);
* `auto`: `LeanUI.boot` picks wasm when the browser has Memory64 and the server otherwise;
* `none`: no script at all (the server-rendered HTML is the whole page).

The boot parameters travel as JSON in `<script type="application/json" id="leanui-boot">`, read
by one fixed boot script, so the page varies only in data. Hydration needs the container's
contents to be exactly the rendered view, so nothing (not even whitespace) is written around it.
-/
public section
namespace LeanUI.Server

/-- A JSON (and JavaScript) string literal that is also safe inside `<script>`: `<` is written
as `<` (so `</script>` and `<!--` cannot occur), and the line separators U+2028/U+2029 are
escaped (they end a line in older JavaScript). -/
def jsonString (s : String) : String :=
  let hex4 (n : Nat) : String :=
    let d := fun k => let v := (n >>> (4 * k)) % 16; Char.ofNat (if v < 10 then 48 + v else 87 + v)
    String.ofList [d 3, d 2, d 1, d 0]
  (s.foldl (init := "\"") fun acc c =>
    match c with
    | '"' => acc ++ "\\\""
    | '\\' => acc ++ "\\\\"
    | '\n' => acc ++ "\\n"
    | '\r' => acc ++ "\\r"
    | '\t' => acc ++ "\\t"
    | '<' => acc ++ "\\u003c"
    | '>' => acc ++ "\\u003e"
    | '&' => acc ++ "\\u0026"
    | c => if c.val < 0x20 || c.val == 0x2028 || c.val == 0x2029 then acc ++ "\\u" ++ hex4 c.val.toNat else acc.push c)
    ++ "\""

/-- A JSON object from already-encoded values. -/
def jsonObject (kvs : List (String × String)) : String :=
  "{" ++ ",".intercalate (kvs.map fun (k, v) => jsonString k ++ ":" ++ v) ++ "}"

/-- How the page comes alive. -/
inductive Boot where
  /-- Server-rendered HTML only. -/
  | none
  /-- The app's wasm hydrates the page. `glue` is the URL of its `app.js`. -/
  | wasm (glue flags : String)
  /-- A native session drives the page over the remote protocol. -/
  | server (endpoint session : String)
  /-- `LeanUI.boot`: wasm with Memory64, the session otherwise. -/
  | auto (glue flags endpoint session : String)
  deriving Inhabited, BEq, Repr

def Boot.mode : Boot → String
  | .none => "none" | .wasm .. => "wasm" | .server .. => "server" | .auto .. => "auto"

/-- The boot script: reads the JSON parameters and starts the runtime. Exposes the runtime as
`window.__leanui` and the chosen transport as `<html data-leanui="wasm|server">`, and falls back
to the server when an `auto` page cannot start its wasm. -/
def bootScript : String :=
  "(function(){var c=JSON.parse(document.getElementById('leanui-boot').textContent);" ++
  "function done(rt){window.__leanui=rt;document.documentElement.dataset.leanui=rt.transport&&rt.transport.session?'server':'wasm';return rt;}" ++
  "function fail(e){console.error('LeanUI failed to start:',e);document.documentElement.dataset.leanui='failed';}" ++
  "var o={glue:c.glue,flags:c.flags,selector:c.selector,hydrate:true,endpoint:c.endpoint,session:c.session};" ++
  "if(c.mode==='server'){done(LeanUI.connect(o));}" ++
  "else if(c.mode==='wasm'){LeanUI.start(o).then(done,fail);}" ++
  "else{LeanUI.boot(o).then(done,function(e){if(!LeanUI.supported())throw e;" ++
  "console.warn('LeanUI: wasm did not start, using the server instead',e);return done(LeanUI.connect(o));}).catch(fail);}" ++
  "})();"

/-- An HTML document around a rendered view. -/
structure Page where
  title : String := "LeanUI"
  lang : String := "en"
  /-- Raw HTML for `<head>` (styles, meta tags). -/
  head : String := ""
  /-- Raw HTML before the container, inside `<body>`. -/
  header : String := ""
  /-- The container element's id; the runtime's selector is `#<container>`. -/
  container : String := "app"
  /-- The container's contents: `Html.render` of the view. -/
  body : String := ""
  /-- Raw HTML after the container (and before the scripts). -/
  footer : String := ""
  /-- URL of `runtime/leanui.js`. -/
  runtime : String := "/leanui.js"
  boot : Boot := .none
  deriving Inhabited

namespace Page

def selector (p : Page) : String := "#" ++ p.container

/-- The JSON boot parameters. -/
def bootJson (p : Page) : String :=
  let sel := ("selector", jsonString p.selector)
  jsonObject <| match p.boot with
    | .none => [("mode", jsonString "none"), sel]
    | .wasm g f => [("mode", jsonString "wasm"), sel, ("glue", jsonString g), ("flags", jsonString f)]
    | .server e s => [("mode", jsonString "server"), sel, ("endpoint", jsonString e), ("session", jsonString s)]
    | .auto g f e s => [("mode", jsonString "auto"), sel, ("glue", jsonString g), ("flags", jsonString f),
        ("endpoint", jsonString e), ("session", jsonString s)]

/-- Preload hints: the wasm loader is requested by the runtime only after it has run, so naming
it in `<head>` starts the download while the page is still parsing. -/
def preloads (p : Page) : String :=
  match p.boot with
  | .wasm g _ | .auto g _ _ _ => s!"<link rel=\"preload\" href=\"{escapeHtml true "" g}\" as=\"script\">"
  | _ => ""

/-- The document. -/
def render (p : Page) : String :=
  let esc := escapeHtml true ""
  let scripts := match p.boot with
    | .none => ""
    | _ => s!"<script id=\"leanui-boot\" type=\"application/json\">{p.bootJson}</script>" ++
        s!"<script src=\"{esc p.runtime}\"></script><script>{bootScript}</script>"
  s!"<!doctype html><html lang=\"{esc p.lang}\"><head><meta charset=\"utf-8\">" ++
  "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" ++
  s!"<title>{escapeHtml false "" p.title}</title>{p.preloads}{p.head}</head><body>{p.header}" ++
  -- nothing between the container's tags but the view: hydration counts every node in it
  s!"<div id=\"{esc p.container}\">{p.body}</div>{p.footer}{scripts}</body></html>"

end Page
end LeanUI.Server
