module
public import LeanUI
public import LeanUI.Router
public import LeanUI.Json
public import Counter
public import TodoMVC
meta import LeanUI.Json.Derive
meta import LeanUI.Syntax
/-!
# The LeanUI site

A real multi-page app, and the page LeanUI presents itself with: a home page, the examples, and
the benchmark results. It is one `Program`, served by a native Lean server
(`examples/SiteServer.lean`) that renders every page to HTML first and then lets the browser's
wasm build hydrate it, or, where WebAssembly Memory64 is missing (Safari), drives it from the
server.

What it exercises:

* **routing** on real paths (`/`, `/examples`, `/benchmarks`) with `data-link` links,
  back/forward, the page title, and a server that renders whichever page the URL names;
* **components**: the counter and TodoMVC are whole programs embedded with `Html.map`,
  `Cmd.map` and `Sub.map`. TodoMVC keeps its own fragment routing (`/examples#/active`) next to
  the site's path routing: each subscribes to URL changes, and one browser listener serves both;
* **data**: the benchmarks page fetches `/data/benchmarks.json`, decodes it with derived
  `FromJson`, and draws an SVG chart (templates set SVG namespaces by themselves);
* **templates** throughout.
-/
@[expose] public section
open LeanUI Attr
namespace Site

/-! ## Data -/

structure Op where
  name : String
  desc : String
  /-- CPU time per operation, LeanUI and the vanilla reference (Chromium, traced). -/
  leanui : Float
  vanilla : Float
  deriving ToJson, FromJson, Inhabited

structure Ratios where
  browser : String
  /-- LeanUI ÷ vanilla per operation, in `ops` order. -/
  ratios : Array Float
  deriving ToJson, FromJson

structure Results where
  machine : String
  chromium : String
  ops : Array Op
  release : Array Ratios := #[]
  /-- Native Lean cost of the same operations (update, view, diff, encode), ms. -/
  native : Array Float := #[]
  deriving ToJson, FromJson

/-! ## Pages -/

inductive Page | home | examples | benchmarks | notFound
  deriving BEq, Repr, Inhabited

def Page.title : Page → String
  | .home => "LeanUI" | .examples => "Examples" | .benchmarks => "Benchmarks" | .notFound => "Not found"

def pages : Route Page := Route.oneOf [
  Route.top |>.to (fun _ => .home) (fun | .home => some () | _ => none),
  Route.lit "examples" |>.to (fun _ => .examples) (fun | .examples => some () | _ => none),
  Route.lit "benchmarks" |>.to (fun _ => .benchmarks) (fun | .benchmarks => some () | _ => none)]

def router : Router Page := { route := pages }

/-! ## Model -/

inductive Load (α : Type) where
  | idle | loading | ok (a : α) | failed (why : String)

structure Model where
  page : Page
  counter : Int := 0
  todo : TodoMVC.Model
  results : Load Results := .idle

inductive Msg where
  | urlChanged (url : String)
  | counter (m : Counter.Msg)
  | todo (m : TodoMVC.Msg)
  | got (r : Response)

def dataUrl := "/data/benchmarks.json"

/-- Arrive on a page: set the title, and load the results the first time they are shown. -/
def arrive (m : Model) (p : Page) : Model × Cmd Msg :=
  let title : Cmd Msg := .title (if p == .home then "LeanUI: web UIs in Lean 4" else s!"{p.title} · LeanUI")
  match p, m.results with
  | .benchmarks, .idle => ({ m with page := p, results := .loading }, .batch #[title, .fetch { url := dataUrl } .got])
  | _, _ => ({ m with page := p }, if p == m.page then .none else title)

def update (msg : Msg) (m : Model) : Model × Cmd Msg :=
  match msg with
  | .urlChanged url => arrive m ((router.parse url).getD .notFound)
  | .counter cm => let (n, c) := Counter.update cm m.counter; ({ m with counter := n }, c.map .counter)
  | .todo tm => let (t, c) := TodoMVC.update tm m.todo; ({ m with todo := t }, c.map .todo)
  | .got r =>
    let results := if !r.ok then .failed s!"HTTP {r.status}" else
      match Json.decode Results r.body with
      | .ok d => .ok d
      | .error e => .failed e
    ({ m with results }, .none)

/-- Flags: the page's URL (path and fragment). -/
def init (url : String) : Model × Cmd Msg :=
  let (todo, tc) := TodoMVC.init url
  let page := (router.parse url).getD .notFound
  let m : Model := { page, todo }
  -- the server renders the page as it is before any data arrives: "loading" for the results
  let (m, c) := if page == .benchmarks then ({ m with results := .loading }, Cmd.fetch { url := dataUrl } Msg.got) else (m, .none)
  -- no focus on arrival: the TodoMVC example should not steal the page's focus
  let tc := match tc with
    | .batch cs => Cmd.batch (cs.filter fun (c : Cmd TodoMVC.Msg) => match c with | .focus _ => false | _ => true)
    | c => c
  (m, .batch #[c, tc.map .todo])

/-- The site follows the URL's path, the embedded TodoMVC its fragment: two subscriptions to URL
changes, served by one browser listener. -/
def subscriptions (m : Model) : LeanUI.Sub Msg :=
  .batch #[.urlChanges .urlChanged, (TodoMVC.subscriptions m.todo).map .todo]

/-! ## View -/

/-- The source repository (an ordinary link: it leaves the site). -/
def sourceUrl := "https://github.com/FawadHa1der/leanui"

def navLink (current p : Page) (label : String) : Html Msg :=
  router.link p #[cls (if current == p then "active" else "")] #[text label]

def header (m : Model) : Html Msg :=
  <header class="site-header">
    <a class="brand" href="/" data-link="">Lean<b>UI</b></a>
    <nav>
      {navLink m.page .home "Home"}
      {navLink m.page .examples "Examples"}
      {navLink m.page .benchmarks "Benchmarks"}
      <a href="/editor/">Photo editor</a>
      <a href={sourceUrl}>GitHub</a>
    </nav>
  </header>

def counterSource : String :=
"def view (n : Int) : Html Msg :=
  <main class=\"counter\">
    <h1>LeanUI counter</h1>
    <p>
      <button id=\"dec\" onClick={.dec}>−</button>
      <output id=\"value\" class={if n < 0 then \"neg\" else \"pos\"}>{n}</output>
      <button id=\"inc\" onClick={.inc}>+</button>
    </p>
    <p>
      <input id=\"box\" type=\"number\" value={toString n} onInput={fun s => .set (s.toInt?.getD n)} />
      <button id=\"reset\" onClick={.reset}>reset</button>
    </p>
  </main>"

def feature (title body : String) : Html Msg :=
  <div class="feature"><h3>{title}</h3><p>{body}</p></div>

def home (m : Model) : Html Msg :=
  <main class="home">
    <section class="hero">
      <h1>Web UIs, written in Lean 4.</h1>
      <p class="lead">
        A model, an update function and a view: plain Lean values, type-checked like the rest of
        your code. LeanUI compiles them to WebAssembly (wasm64), drives the DOM with a compact
        command buffer, and renders the same program on a Lean server.
      </p>
      <p class="cta">
        {router.link .examples #[cls "button primary"] #[text "See the examples"]}
        {router.link .benchmarks #[cls "button"] #[text "How fast is it?"]}
      </p>
    </section>
    <section class="try">
      <div class="code"><pre><code>{counterSource}</code></pre></div>
      <div class="live">
        <p class="caption">That is the view of <code>examples/Counter.lean</code>, running here:</p>
        {(Counter.view m.counter).map Msg.counter}
      </div>
    </section>
    <section class="features">
      {feature "Pure and typed" "Views are values of type Html Msg. Templates are checked by Lean's elaborator and expand to the constructors you would write by hand, so they cost nothing at run time."}
      {feature "Fast where it counts" "A keyed, exact-lazy diff that recognises unchanged subtrees without allocating; about 1.3× the CPU time of hand-written JavaScript on the standard benchmark."}
      {feature "Proved, then tested" "The keyed reconciliation planner is proved correct and optimal in Lean; property tests and browser fuzzing check the rest against a reference model."}
      {feature "Everywhere" "This page was rendered to HTML by a Lean server, then hydrated by wasm. Browsers without Memory64 get the same app driven from the server."}
    </section>
  </main>

def examples (m : Model) : Html Msg :=
  <main class="examples">
    <h1>Examples</h1>
    <section class="example">
      <h2>Counter</h2>
      <p>A program of four lines of logic, embedded here as a component with <code>Html.map</code>.</p>
      {(Counter.view m.counter).map Msg.counter}
    </section>
    <section class="example">
      <h2>TodoMVC</h2>
      <p>
        The whole TodoMVC specification: editing, filters in the URL fragment, the list kept in
        {" "}<code>localStorage</code> as JSON. Its model logic is proved to keep the list's keys
        unique under every message.
      </p>
      <div class="todo-demo">{(TodoMVC.view m.todo).map Msg.todo}</div>
    </section>
  </main>

/-- A non-negative number with `digits` decimals. -/
def fmt (x : Float) (digits : Nat := 2) : String :=
  let k := 10 ^ digits
  let n := (x * k.toFloat).round.toUInt64.toNat
  let frac := toString (n % k)
  if digits == 0 then toString n else s!"{n / k}." ++ "".pushn '0' (digits - frac.length) ++ frac

/-- Horizontal bars: LeanUI and vanilla per operation, on a log-free linear scale per row (each
row scaled to its own maximum, so small and large operations are both readable). -/
def chart (ops : Array Op) : Html Msg :=
  let rowH := 34
  let h := ops.size * rowH + 10;
  <svg class="chart" viewBox={s!"0 0 720 {h}"} role="img" aria-label="LeanUI and vanilla JavaScript, CPU time per operation">
    {...ops.mapIdx fun i o =>
      let y := i * rowH + 6
      let mx := max o.leanui o.vanilla
      let wl := if mx > 0 then 380 * o.leanui / mx else 0
      let wv := if mx > 0 then 380 * o.vanilla / mx else 0;
      <g>
        <text x="0" y={y + 17} class="label">{o.desc}</text>
        <rect x="230" y={y} width={fmt wl 1} height="13" rx="2" class="bar-leanui" />
        <rect x="230" y={y + 14} width={fmt wv 1} height="13" rx="2" class="bar-vanilla" />
        <text x={fmt (236 + wl) 1} y={y + 11} class="value">{fmt o.leanui ++ " ms"}</text>
        <text x={fmt (236 + wv) 1} y={y + 25} class="value muted">{fmt o.vanilla ++ " ms"}</text>
      </g>}
  </svg>

def resultsView (r : Results) : Html Msg :=
  <div>
    <p>
      CPU time per operation (script and the rendering work it causes), median of fresh page
      loads, in {r.chromium} on {r.machine}. Both implementations build identical tables.
    </p>
    <p class="legend"><span class="swatch leanui" /> LeanUI <span class="swatch vanilla" /> vanilla JavaScript</p>
    {chart r.ops}
    <table class="ratios">
      <thead>
        <tr>
          <th>operation</th>
          <th>Lean (native)</th>
          {...r.release.map fun b => <th>{b.browser}</th>}
        </tr>
      </thead>
      <tbody>
        {...r.ops.mapIdx fun i o =>
          <tr>
            <td>{o.desc}</td>
            <td>{(r.native[i]?.map fun x => fmt x ++ " ms").getD "–"}</td>
            {...r.release.map fun b => <td>{(b.ratios[i]?.map fun x => fmt x ++ "×").getD "–"}</td>}
          </tr>}
      </tbody>
    </table>
    <p class="note">
      Release-browser columns: LeanUI ÷ vanilla (script and layout). "Lean (native)" is the Lean
      side alone, compiled natively: update, view, diff and command encoding, without the DOM.
    </p>
  </div>

def benchmarks (m : Model) : Html Msg :=
  <main class="benchmarks">
    <h1>Benchmarks</h1>
    <p>
      The js-framework-benchmark keyed operations, against hand-written vanilla JavaScript with the
      same markup, stylesheet and data.
    </p>
    <p>
      <a href="/race/">The race</a> runs this benchmark and a Game of Life side by side in your
      browser, timed live: vanilla JavaScript, LeanUI compiled to wasm64, and LeanUI interpreted by
      lean-vir. It checks that all three end in the same state.
    </p>
    {match m.results with
      | .ok r => resultsView r
      | .failed why => <p class="error">Could not load the results: {why}</p>
      | _ => <p class="loading">Loading the results…</p>}
  </main>

def notFound : Html Msg :=
  <main class="not-found"><h1>Not found</h1><p>{router.link .home #[] #[text "Back to the home page"]}</p></main>

def view (m : Model) : Html Msg :=
  <div class="site">
    {header m}
    {match m.page with
      | .home => home m
      | .examples => examples m
      | .benchmarks => benchmarks m
      | .notFound => notFound}
    <footer class="site-footer">
      <p>LeanUI: Lean 4.34, single-threaded wasm64. This page is a LeanUI program;
        its source is <a href={sourceUrl}>on GitHub</a> (MIT).</p>
    </footer>
  </div>

def program : Program Model Msg := { init, update, view, subscriptions }

end Site
