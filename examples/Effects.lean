module
public import LeanUI
public import LeanUI.Router
public import LeanUI.Json
meta import LeanUI.Json.Derive
/-!
# Effects lab

One page that exercises every `Cmd` and `Sub` the runtime has, with `LeanUI.Json` and
`LeanUI.Router` doing real work:

* **Router**: path routing under the page's base path (`/users/42?tab=posts`, `/search?q=`,
  `/files/*path`, a not-found page), driven by `data-link` clicks, `pushUrl`, `replaceUrl` and
  back/forward (`Sub.urlChanges`); a second router reads a filter from the fragment
  (`#/active`, hash routing); every page change sets the document title.
* **Fetch**: a JSON catalog decoded with derived `FromJson`, a 404, a file that is not JSON
  (the parse error names line and column) and one with the wrong shape (the decode error names
  the path).
* **Timers**: `Cmd.after`, and two `Sub.every` intervals switched on and off independently.
* **Storage**: a note saved, read back and removed; a visit counter kept as JSON across reloads.
* **DOM**: `focus`, `blur`, `scrollIntoView`; `log`; a `nextFrame` animation loop.
* **JSON lab**: parse what is typed, print it compact and pretty (optionally through doubles,
  which reproduces `JSON.stringify(JSON.parse(input))` exactly).

The page passes `{"base": ..., "url": ...}` as flags (`examples/effects-assets/index.html`).
-/
public section
open LeanUI Attr

namespace Effects

/-! ## Data -/

structure Flags where
  base : String := "/"
  url : String := "/"
  deriving FromJson

structure Planet where
  name : String
  symbol : String
  moons : Nat
  radiusKm : Float
  rings : Bool
  /-- Year of discovery; absent for the planets known since antiquity. -/
  discovered? : Option Nat
  deriving ToJson, FromJson

structure Catalog where
  title : String
  planets : Array Planet
  deriving ToJson, FromJson

/-- What `localStorage` keeps between visits. -/
structure Saved where
  visits : Nat := 0
  lastPage : String := ""
  deriving ToJson, FromJson

def savedKey := "leanui.effects.saved"
def noteKey := "leanui.effects.note"

/-! ## Routes -/

inductive Page where
  | home
  | about
  | user (id : Nat) (tab : Option String)
  | search (q : Option String)
  | files (path : List String)
  | notFound
  deriving BEq, Repr, Inhabited

def pages : Route Page := Route.oneOf [
  Route.top |>.to (fun _ => .home) (fun | .home => some () | _ => none),
  -- the page is first loaded as .../index.html: a parse-only alias of the root
  Route.lit "index.html" |>.to (fun _ => .home) (fun _ => none),
  Route.lit "about" |>.to (fun _ => .about) (fun | .about => some () | _ => none),
  ("users" </> Route.nat <?> Route.param "tab") |>.to (fun (uid, tab) => .user uid tab)
    (fun | .user uid tab => some (uid, tab) | _ => none),
  ("search" <?> Route.param "q") |>.to .search (fun | .search q => some q | _ => none),
  ("files" </> Route.rest) |>.to .files (fun | .files p => some p | _ => none)]

inductive Filter | all | active | done
  deriving BEq, Repr, Inhabited

def filters : Route Filter := Route.oneOf [
  Route.top |>.to (fun _ => .all) (fun | .all => some () | _ => none),
  Route.lit "active" |>.to (fun _ => .active) (fun | .active => some () | _ => none),
  Route.lit "done" |>.to (fun _ => .done) (fun | .done => some () | _ => none)]

def Page.title : Page → String
  | .home => "Home" | .about => "About" | .user uid _ => s!"User {uid}"
  | .search q => s!"Search {(q.getD "").quote}" | .files p => s!"Files /{"/".intercalate p}"
  | .notFound => "Not found"

def Page.describe : Page → String
  | .home => "home" | .about => "about"
  | .user uid tab => s!"user {uid}" ++ (match tab with | some t => s!" · tab {t}" | none => "")
  | .search q => s!"search {(q.getD "").quote}"
  | .files p => s!"files {p}"
  | .notFound => "not found"

def Filter.name : Filter → String
  | .all => "all" | .active => "active" | .done => "done"

/-! ## Model -/

inductive Load (α : Type) where
  | idle
  | loading
  | done (status : Nat) (value : α)
  | failed (status : Nat) (error : String)

instance : Inhabited (Load α) := ⟨.idle⟩

/-- The files the fetch section loads, relative to the base path. -/
def sources : Array String := #["data.json", "missing.json", "broken.json", "shape.json"]

structure Model where
  router : Router Page
  hashRouter : Router Filter
  base : String
  url : String
  page : Page
  filter : Filter
  loads : Array (Load Catalog) := sources.map fun _ => .idle
  afterPending : Nat := 0
  afterFired : Nat := 0
  fast : Bool := false
  fastTicks : Nat := 0
  slow : Bool := false
  slowTicks : Nat := 0
  draft : String := ""
  note : Option (Option String) := none
  saved : Option Saved := none
  logs : Nat := 0
  frames : Nat := 0
  frameTarget : Nat := 0
  frameFirst : Float := 0
  frameLast : Float := 0
  monotonic : Bool := true
  jsonIn : String := ""
  doubles : Bool := false

inductive Msg where
  | urlChanged (url : String)
  | navigate (p : Page)
  | redirect (p : Page)
  | goto (p : Page)
  | fetch (i : Nat)
  | fetched (i : Nat) (r : Response)
  | startAfter
  | afterFired
  | setFast (on : Bool)
  | setSlow (on : Bool)
  | fastTick
  | slowTick
  | draft (s : String)
  | saveNote
  | loadNote
  | gotNote (v : Option String)
  | removeNote
  | gotSaved (v : Option String)
  | focusName
  | nameKey (k : String)
  | scrollBottom
  | log
  | animate
  | frame (t : Float)
  | jsonIn (s : String)
  | doubles (on : Bool)

/-! ## Update -/

def fmtFloat (f : Float) : String := (JsonNumber.ofFloat? f).map toString |>.getD (toString f)

def decodeCatalog (r : Response) : Load Catalog :=
  if !r.ok then .failed r.status (if r.status == 0 then "network error" else s!"HTTP {r.status}")
  else match Json.decode Catalog r.body with
    | .ok c => .done r.status c
    | .error e => .failed r.status e

/-- Set the route from a URL, and the document title when it changes. -/
def route (m : Model) (url : String) : Model × Cmd Msg :=
  let page := (m.router.parse url).getD .notFound
  let filter := (m.hashRouter.parse url).getD .all
  let cmd : Cmd Msg := if page.title == m.page.title then .none else .title s!"{page.title} · LeanUI effects"
  ({ m with url, page, filter }, cmd)

def update (msg : Msg) (m : Model) : Model × Cmd Msg :=
  match msg with
  | .urlChanged url => route m url
  | .navigate p => (m, m.router.navigate p .goto)
  | .redirect p => (m, m.router.redirect p .goto)
  | .goto p =>
    let m' := { m with page := p, filter := .all, url := m.router.href p }
    (m', if p.title == m.page.title then .none else .title s!"{p.title} · LeanUI effects")
  | .fetch i =>
    ({ m with loads := m.loads.set! i .loading },
     .fetch { url := m.base ++ sources[i]!, headers := #[("Accept", "application/json")] } (.fetched i))
  | .fetched i r => ({ m with loads := m.loads.set! i (decodeCatalog r) }, .none)
  | .startAfter => ({ m with afterPending := m.afterPending + 1 }, .after 300 .afterFired)
  | .afterFired => ({ m with afterPending := m.afterPending - 1, afterFired := m.afterFired + 1 }, .none)
  | .setFast b => ({ m with fast := b }, .none)
  | .setSlow b => ({ m with slow := b }, .none)
  | .fastTick => ({ m with fastTicks := m.fastTicks + 1 }, .none)
  | .slowTick => ({ m with slowTicks := m.slowTicks + 1 }, .none)
  | .draft s => ({ m with draft := s }, .none)
  | .saveNote => (m, .batch #[.storageSet noteKey m.draft, .log s!"saved note {m.draft.quote}"])
  | .loadNote => (m, .storageGet noteKey .gotNote)
  | .gotNote v => ({ m with note := some v }, .none)
  | .removeNote => ({ m with note := some none }, .storageRemove noteKey)
  | .gotSaved v =>
    -- count this visit and write the record back
    let old : Saved := (v.bind fun s => (Json.decode Saved s).toOption).getD {}
    let now : Saved := { visits := old.visits + 1, lastPage := m.page.describe }
    ({ m with saved := some now }, .storageSet savedKey (Json.encode now))
  | .focusName => (m, .focus "#name")
  | .nameKey k => if k == "Escape" then (m, .blur "#name") else (m, .none)
  | .scrollBottom => (m, .scrollIntoView "#bottom")
  | .log => ({ m with logs := m.logs + 1 }, .log s!"LeanUI log #{m.logs + 1}")
  | .animate => ({ m with frames := 0, frameTarget := 30, monotonic := true }, .nextFrame .frame)
  | .frame t =>
    let n := m.frames + 1
    let m := { m with frames := n, frameFirst := if n == 1 then t else m.frameFirst, frameLast := t,
                      monotonic := m.monotonic && (n == 1 || t ≥ m.frameLast) }
    (m, if n < m.frameTarget then .nextFrame .frame else .none)
  | .jsonIn s => ({ m with jsonIn := s }, .none)
  | .doubles b => ({ m with doubles := b }, .none)

def init (flagsStr : String) : Model × Cmd Msg :=
  let flags : Flags := (Json.decode Flags flagsStr).toOption.getD {}
  let router : Router Page := { route := pages, base := Router.baseOf flags.base }
  let m : Model := { router, hashRouter := { route := filters, hash := true }, base := flags.base,
                     url := flags.url, page := .notFound, filter := .all }
  let (m, title) := route m flags.url
  (m, .batch #[title, .storageGet savedKey .gotSaved, .log "effects: started"])

def subscriptions (m : Model) : LeanUI.Sub Msg :=
  .batch #[.urlChanges .urlChanged,
           if m.fast then .every 100 .fastTick else .none,
           if m.slow then .every 300 .slowTick else .none]

/-! ## View -/

def section_ (title : String) (ident : String) (kids : Array (Html Msg)) : Html Msg :=
  el "section" #[id ident] (#[el "h2" #[] #[text title]] ++ kids)

def button (ident label : String) (m : Msg) : Html Msg :=
  el "button" #[id ident, onClick m] #[text label]

def toggle (ident label : String) (on : Bool) (f : Bool → Msg) : Html Msg :=
  el "label" #[] #[el "input" #[id ident, Attr.attr "type" "checkbox", checked on, onCheck f] #[], text label]

def stat (ident : String) (v : String) : Html Msg := el "output" #[id ident] #[text v]

def viewRouter (m : Model) : Html Msg :=
  let r := m.router
  let navLink (ident : String) (p : Page) (label : String) : Html Msg :=
    r.link p #[id ident, cls (if p == m.page then "active" else "")] #[text label]
  section_ "Router" "router" #[
    el "nav" #[] #[
      navLink "nav-home" .home "home",
      navLink "nav-about" .about "about",
      navLink "nav-user" (.user 42 none) "user 42",
      navLink "nav-user-posts" (.user 42 (some "posts")) "user 42 · posts",
      navLink "nav-search" (.search (some "lean ui & wasm")) "search",
      navLink "nav-files" (.files ["docs", "read me.txt"]) "files",
      link (r.href .home ++ "no/such/page") #[id "nav-broken"] #[text "broken link"]],
    el "p" #[] #[text "page: ", stat "route" m.page.describe, text " · filter: ", stat "filter" m.filter.name],
    el "p" #[] #[text "url: ", el "code" #[id "url"] #[text m.url]],
    el "p" #[cls "row"] #[
      -- `Router.navigate`/`redirect`: push (replace) the route's URL and send `goto`
      button "go-user7" "pushUrl → user 7" (.navigate (.user 7 none)),
      button "replace" "replaceUrl → user 7 · settings" (.redirect (.user 7 (some "settings")))],
    el "p" #[cls "row"] #[
      text "hash filter: ",
      el "a" #[id "f-all", Attr.attr "href" "#/"] #[text "all"],
      el "a" #[id "f-active", Attr.attr "href" "#/active"] #[text "active"],
      link (m.hashRouter.href .done) #[id "f-done"] #[text "done (data-link)"]]]

def viewPlanets (c : Catalog) : Html Msg :=
  el "table" #[id "planets"] #[
    el "caption" #[] #[text c.title],
    el "thead" #[] #[el "tr" #[] (#["planet", "", "moons", "radius km", "rings", "discovered"].map fun h => el "th" #[] #[text h])],
    el "tbody" #[] (c.planets.map fun p => el "tr" #[Attr.key p.name] #[
      el "td" #[] #[text p.name], el "td" #[] #[text p.symbol], el "td" #[] #[text (toString p.moons)],
      el "td" #[] #[text (fmtFloat p.radiusKm)], el "td" #[] #[text (if p.rings then "yes" else "no")],
      el "td" #[] #[text (match p.discovered? with | some y => toString y | none => "antiquity")]])]

def loadStatus : Load Catalog → String
  | .idle => "idle"
  | .loading => "loading…"
  | .done st c => s!"{st} · {c.planets.size} planets"
  | .failed st e => s!"{st} · {e}"

def viewFetch (m : Model) : Html Msg :=
  section_ "Fetch" "fetch" (
    (sources.mapIdx fun i src => el "p" #[cls "row"] #[
      button s!"fetch-{i}" s!"GET {src}" (.fetch i), stat s!"status-{i}" (loadStatus m.loads[i]!)]) ++
    (match m.loads[0]! with | .done _ c => #[viewPlanets c] | _ => #[]))

def viewTimers (m : Model) : Html Msg :=
  section_ "Timers" "timers" #[
    el "p" #[cls "row"] #[button "after" "after 300 ms" .startAfter,
      stat "after-status" s!"pending {m.afterPending} · fired {m.afterFired}"],
    el "p" #[cls "row"] #[toggle "fast" "every 100 ms" m.fast .setFast, stat "fast-ticks" (toString m.fastTicks)],
    el "p" #[cls "row"] #[toggle "slow" "every 300 ms" m.slow .setSlow, stat "slow-ticks" (toString m.slowTicks)]]

def viewStorage (m : Model) : Html Msg :=
  section_ "Storage" "storage" #[
    el "p" #[cls "row"] #[
      el "input" #[id "note", Attr.attr "placeholder" "a note", value m.draft, onInput .draft] #[],
      button "save-note" "save" .saveNote, button "load-note" "load" .loadNote, button "remove-note" "remove" .removeNote],
    el "p" #[] #[text "stored note: ", stat "note-value" (match m.note with
      | none => "(not read yet)" | some none => "(none)" | some (some v) => v.quote)],
    el "p" #[] #[text "visits: ", stat "visits" (match m.saved with
      | some s => s!"{s.visits}" | none => "…")]]

def viewDom (m : Model) : Html Msg :=
  let pct := if m.frameTarget == 0 then 0 else m.frames * 100 / m.frameTarget
  section_ "DOM, log and frames" "dom" #[
    el "p" #[cls "row"] #[
      el "input" #[id "name", Attr.attr "placeholder" "Escape blurs me",
        onKeyDown fun k => if k == "Escape" then some (.nameKey k) else none] #[],
      button "focus-name" "focus" .focusName, button "scroll-bottom" "scroll to the bottom" .scrollBottom],
    el "p" #[cls "row"] #[button "log" "console.log" .log, stat "log-count" (toString m.logs)],
    el "p" #[cls "row"] #[button "animate" "30 frames" .animate,
      el "progress" #[id "frame-bar", Attr.attr "max" "100", Attr.prop "value" (.num pct.toFloat)] #[],
      stat "frames" (if m.frameTarget == 0 then "idle"
        else s!"{m.frames}/{m.frameTarget} · {fmtFloat (m.frameLast - m.frameFirst)} ms · " ++
          (if m.monotonic then "monotonic" else "NOT monotonic"))]]

def viaDoubles (j : Json) : Json :=
  j.mapNumbers fun n => match JsonNumber.ofFloat? n.toFloat with | some d => .num d | none => .null

def viewJson (m : Model) : Html Msg :=
  let result := if m.jsonIn.isEmpty then none else some (Json.parseE m.jsonIn)
  section_ "JSON lab" "json" #[
    el "textarea" #[id "json-in", Attr.attr "rows" "5", Attr.attr "placeholder" "type JSON", value m.jsonIn, onInput .jsonIn] #[],
    toggle "json-doubles" "through doubles (like JSON.parse)" m.doubles .doubles,
    match result with
    | none => stat "json-error" ""
    | some (.error e) => stat "json-error" (toString e)
    | some (.ok j) =>
      let j := if m.doubles then viaDoubles j else j
      el "div" #[] #[stat "json-error" "", el "pre" #[id "json-compact"] #[text j.compress],
        el "pre" #[id "json-pretty"] #[text j.pretty]]]

def view (m : Model) : Html Msg :=
  el "main" #[cls "effects"] #[
    el "h1" #[] #[text "LeanUI effects lab"],
    viewRouter m, viewFetch m, viewTimers m, viewStorage m, viewDom m, viewJson m,
    el "div" #[cls "spacer", Attr.attr "style" "height: 1600px"] #[],
    el "p" #[id "bottom"] #[text "the bottom"]]

def program : Program Model Msg := { init, update, view, subscriptions }

end Effects
