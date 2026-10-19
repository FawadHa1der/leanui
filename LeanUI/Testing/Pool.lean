module
public import LeanUI.Testing.Gen
/-!
# Views whose rows repeat a few shapes (template cloning tests)

`LeanUI.Diff` creates repeated subtrees by cloning templates (`TEMPLATE`, `CLONE`), which random
views from `Testing.Gen` rarely exercise: their subtrees seldom share a shape. Here every view
holds four lists (a table body, a flow container, an SVG element and a MathML element) whose
rows come from a small pool of row shapes, so shapes repeat constantly: the second row of a shape
becomes a template and later ones are clones. Rows carry random texts (empty ones included),
property values, attribute values and listeners; a few attributes switch a row between shapes.
The pool also has the cases the clone path must get right: per-row attribute values (re-set on a
clone), elements whose attribute values are part of the shape (form controls, images, custom
elements), properties on leaf inputs and attributes around them, adjacent and empty texts, a void
element whose view names children, duplicate attributes and listeners, keyed children inside a
row, SVG and MathML, a lazy row around a templatable body, and shapes that must not be templated
(a lazy node inside, a property on an element with children, too few or too many nodes).

A session is a sequence of views; each step inserts, deletes, moves or replaces rows, refills
some (new texts, properties and listeners, possibly another shape), switches a list between keyed
and positional, or applies a random `Edit` inside one row. Every view is valid HTML when
`flowOnly` (no table, SVG or MathML), so those sessions can start from server-rendered HTML.
-/
public section
namespace LeanUI.Testing.Pool

/-- A text: usually a word, sometimes empty. -/
def word : G String := do
  if ← chance 12 then return ""
  pick #["a", "row", "hello world", "é", "😀", "x y", "<b>", "1", "&amp;", "pretty red table", "𝔸", "\"q\""]

def on (ev : String) : G TAttr := do return .on (← genListener (some ev))

/-- Ten nodes, like js-framework-benchmark's row; `class=danger` on a selected row is another shape. -/
def benchRow : G T := do
  let tr : Array TAttr := if ← chance 15 then #[.attr "class" "danger"] else #[]
  return .elem .html "tr" tr #[
    .elem .html "td" #[.attr "class" "col-md-1"] #[.text (← word)],
    .elem .html "td" #[.attr "class" "col-md-4"] #[.elem .html "a" #[.attr "class" "lbl", ← on "click"] #[.text (← word)]],
    .elem .html "td" #[.attr "class" "col-md-1"] #[.elem .html "a" #[.attr "class" "remove", ← on "click"] #[
      .elem .html "span" #[.attr "class" "remove glyphicon glyphicon-remove", .attr "aria-hidden" "true"] #[]]],
    .elem .html "td" #[.attr "class" "col-md-6"] #[]]

def shortRow : G T := do
  return .elem .html "tr" #[] #[.elem .html "td" #[] #[.text (← word)], .elem .html "td" #[] #[.text (← word)]]

/-- A TodoMVC item: properties on leaf inputs (`checked`, `value`, an expando number). -/
def todoRow : G T := do
  let done ← chance 30
  let q : Int := (← below 9 : Nat) - 4
  return .elem .html "article" #[.attr "class" (if done then "completed" else "")] #[
    .elem .html "div" #[.attr "class" "view"] #[
      .elem .html "input" #[.attr "class" "toggle", .attr "type" "checkbox", .prop "checked" (.bool done), ← on "change"] #[],
      .elem .html "label" #[← on "dblclick"] #[.text (← word)],
      .elem .html "button" #[.attr "class" "destroy", ← on "click"] #[]],
    .elem .html "input" #[.attr "class" "edit", .prop "value" (.str (← word)), .prop "num" (.num q)] #[]]

/-- Empty and adjacent texts. -/
def textsRow : G T := do
  return .elem .html "span" #[] #[.text (← word), .text (← word), .elem .html "b" #[] #[.text (← word)], .text (← word), .text ""]

/-- A void element whose view names children (they are never created), and a property before an
attribute (attributes after a property are re-sent on a clone). -/
def voidRow : G T := do
  return .elem .html "div" #[.attr "data-x" (← pick #["1", "2"])] #[
    .elem .html "input" #[.prop "value" (.str (← word)), .attr "name" "n", ← on "input"] #[.text "x", .elem .html "b" #[] #[]],
    .elem .html "br" #[] #[], .text (← word), .elem .html "i" #[] #[.text (← word)]]

/-- Not templatable: a property on an element with children. -/
def propRow : G T := do
  return .elem .html "section" #[.prop "foo" (.str (← word))] #[
    .elem .html "b" #[] #[.text (← word)], .elem .html "i" #[] #[.text (← word)], .text (← word)]

/-- Repeated attribute names and events (the last one wins). -/
def dupRow : G T := do
  let l ← genListener (some "click")
  return .elem .html "div" #[.attr "class" "a", .on l, .attr "title" (← pick #["t", "u"]), .attr "class" "b",
      .on (← genListener (some "click"))] #[
    .elem .html "span" #[] #[.text (← word)], .elem .html "span" #[.attr "class" "x"] #[.text (← word)]]

/-- Keyed children inside a row (keys are not part of a shape). -/
def keyedInside : G T := do
  return .elem .html "div" #[.attr "class" "k"] #[
    .elem .html "span" #[.key s!"a{← below 3}"] #[.text (← word)],
    .elem .html "span" #[.key "b"] #[.text (← word)], .elem .html "em" #[.key "c"] #[.text (← word)]]

/-- Not templatable: a lazy node inside. -/
def lazyInside : G T := do
  return .elem .html "div" #[] #[.lazy none (.elem .html "span" #[] #[.text (← word)]), .text (← word),
    .elem .html "b" #[] #[.text (← word)]]

/-- Three nodes: too small to template. -/
def tinyRow : G T := do return .elem .html "b" #[] #[.elem .html "i" #[] #[.text (← word)]]

/-- `1 + 2n` nodes: templated for n = 20, too big for n = 40. -/
def wideRow : G T := do
  let n ← pick #[20, 40]
  let mut kids := #[]
  for _ in [0:n] do kids := kids.push (.elem .html "i" #[] #[.text (← word)])
  return .elem .html "div" #[.attr "class" "wide"] kids

/-- Per-row attribute values (an id, a link, a style): one shape, whose values a clone re-sets
where they differ from the template's. -/
def uidRow : G T := do
  let id := toString (← below 100000)
  let title ← word
  let style ← pick #["", "width: 10%", "color: red"]
  return .elem .html "tr" #[.attr "data-id" id] #[
    .elem .html "td" #[.attr "class" "id"] #[.text id],
    .elem .html "td" #[] #[.elem .html "a" #[.attr "href" s!"#/item/{id}", .attr "title" title, ← on "click"] #[.text (← word)]],
    .elem .html "td" #[.attr "style" style] #[]]

/-- Elements whose attribute values are part of the shape (form controls, an image, a custom
element) next to one whose values are re-set on a clone. -/
def formRow : G T := do
  let ty ← pick #["text", "checkbox"]
  let v ← pick #["a", "b"]
  let alt ← pick #["", "pic"]
  return .elem .html "div" #[.attr "class" "f"] #[
    .elem .html "input" #[.attr "type" ty, .attr "value" v] #[],
    .elem .html "img" #[.attr "alt" alt, .attr "width" "1"] #[],
    .elem .html "x-tag" #[.attr "data-v" v] #[.text (← word)],
    .elem .html "label" #[.attr "for" (← word)] #[.text (← word)]]

/-- Attributes around properties: a property first or second (where the first property comes is
part of the shape), an attribute after a property (re-sent on a clone). The properties are
expandos and the attribute after `value` is another one: the DOM model reflects no property onto
an attribute and has no dirty flags (an empty `value` property is skipped on a fresh input, so a
later `value` attribute shows), so those cases (`hidden`, `title`, `value` then `value`) are in
the browser scenarios (`Scenario.all`) instead. -/
def interleaveRow : G T := do
  let propFirst ← chance 50
  let p : TAttr := .prop "foo" (.str (← word))
  let cls : TAttr := .attr "class" (← word)
  let span := if propFirst then #[p, cls] else #[cls, p]
  return .elem .html "p" #[] #[
    .elem .html "span" span #[],
    .elem .html "input" #[.attr "class" "e", .prop "value" (.str (← word)), .attr "placeholder" (← word)] #[],
    .elem .html "b" #[.prop "num" (.num ((← below 3 : Nat) : Int))] #[],
    .text (← word)]

def svgRow : G T := do
  return .elem .svg "g" #[.attr "class" (← pick #["a", "b"])] #[
    .elem .svg "rect" #[.attr "fill" "red"] #[], .elem .svg "circle" #[.attr "r" "3", ← on "click"] #[],
    .elem .svg "text" #[] #[.text (← word)]]

def mathRow : G T := do
  return .elem .mathml "mrow" #[] #[.elem .mathml "mi" #[] #[.text (← word)], .elem .mathml "mo" #[] #[.text "+"],
    .elem .mathml "mn" #[] #[.text (← word)]]

def flowRow : G T := do
  let r ← below 100
  let t ← if r < 20 then todoRow else if r < 30 then textsRow else if r < 40 then voidRow
    else if r < 46 then propRow else if r < 55 then dupRow else if r < 64 then keyedInside
    else if r < 70 then lazyInside else if r < 76 then tinyRow else if r < 82 then wideRow
    else if r < 91 then formRow else interleaveRow
  -- a lazy row whose body is templatable (like the benchmark's lazy rows)
  if ← chance 10 then return .lazy none t else return t

/-- A new row for list `k`: 0 table body, 1 flow, 2 SVG, 3 MathML. -/
def row (k : Nat) : G T :=
  match k with
  | 0 => do
    let r ← below 100
    if r < 60 then benchRow else if r < 85 then uidRow else shortRow
  | 1 => flowRow
  | 2 => svgRow
  | _ => mathRow

structure Model where
  lists : Array (Array T) := #[#[], #[], #[], #[]]
  keyed : Array Bool := #[false, false, false, false]
  flowOnly : Bool := false

def Model.view (m : Model) : T :=
  if m.flowOnly then .elem .html "div" #[.attr "id" "root"] #[.elem .html "div" #[.attr "class" "list"] m.lists[1]!]
  else .elem .html "div" #[.attr "id" "root"] #[
    .elem .html "table" #[] #[.elem .html "tbody" #[] m.lists[0]!],
    .elem .html "div" #[.attr "class" "list"] m.lists[1]!,
    .elem .svg "svg" #[] m.lists[2]!,
    .elem .mathml "math" #[] m.lists[3]!]

/-- A fresh row for list `k`, keyed when the list is. -/
def fresh (m : Model) (k : Nat) : G T := do
  let r ← row k
  if m.keyed[k]! then return r.withKey (some (← freshKey)) else return r

def freshRows (m : Model) (k n : Nat) : G (Array T) := do
  let mut out := #[]
  for _ in [0:n] do out := out.push (← fresh m k)
  return out

/-- How many rows a list gets at once: mostly a few, sometimes many. -/
def count : G Nat := do
  let r ← below 100
  if r < 50 then between 1 4 else if r < 85 then between 5 15 else between 16 40

/-- One step of a session. -/
def step (m : Model) : G Model := do
  let k ← if m.flowOnly then pure 1 else below 4
  let rows := m.lists[k]!
  let r ← below 100
  let rows ← if r < 20 then do
      let pos ← below (rows.size + 1)
      let add ← freshRows m k (← count)
      pure (rows.extract 0 pos ++ add ++ rows.extract pos rows.size)
    else if r < 30 then do
      if rows.isEmpty then pure rows else
        let a ← below rows.size; let n ← between 1 (min 6 (rows.size - a))
        pure (rows.extract 0 a ++ rows.extract (a + n) rows.size)
    else if r < 38 then do
      if rows.size < 2 then pure rows else
        let i ← below rows.size; let x := rows[i]!; let rest := rows.eraseIdxIfInBounds i
        pure (rest.insertIdxIfInBounds (← below (rest.size + 1)) x)
    else if r < 41 then pure rows.reverse
    else if r < 49 then do freshRows m k (← count)
    else if r < 52 then pure #[]
    else if r < 68 then do
      -- refill some rows: new content, maybe another shape of the same list, same key
      let mut out := rows
      for _ in [0:(← between 1 4)] do
        if !out.isEmpty then
          let i ← below out.size
          let nr ← row k
          out := out.set! i (nr.withKey out[i]!.keyOld)
      pure out
    else if r < 84 then do
      -- a random edit inside one row
      if rows.isEmpty then pure rows else
        let i ← below rows.size
        let e ← genEdit {} rows[i]!
        pure (rows.set! i (e.apply rows[i]!))
    else if r < 90 then do
      if rows.size < 2 then pure rows else
        let i ← below rows.size; let j ← below rows.size
        pure (rows.swapIfInBounds i j)
    else if r < 95 then do
      if rows.isEmpty then pure rows else
        let i ← below rows.size
        pure (rows.modify i fun t => match t with | .lazy _ b => b | b => .lazy none b)
    else pure rows
  -- switch a list between keyed and positional now and then
  let (rows, keyed) ← if ← chance 6 then do
      if m.keyed[k]! then pure (rows.map (·.withKey none), false)
      else
        let mut out := #[]
        for t in rows do out := out.push (t.withKey (some (← freshKey)))
        pure (out, true)
    else pure (rows, m.keyed[k]!)
  return { m with lists := m.lists.set! k rows, keyed := m.keyed.set! k keyed }

/-- The views of a session: an initial view, then `steps` more. -/
def session (steps : Nat) (flowOnly := false) : G (Array T) := do
  let mut m : Model := { flowOnly }
  for k in [0:4] do
    let keyed ← chance 50
    m := { m with keyed := m.keyed.set! k keyed }
    m := { m with lists := m.lists.set! k (← freshRows m k (← count)) }
  let mut out := #[m.view]
  for _ in [0:steps] do
    m ← step m
    out := out.push m.view
  return out

/-! ## Scenarios for real browsers

Views whose clones a browser could tell apart from mounts where the DOM model cannot: properties
that reflect onto attributes (or skip an assignment because the value is already there), form
controls' values, checkedness and dirty flags, attribute order, scripts, and the per-row
attribute values a clone re-sets. In each, the first row is mounted, the second becomes the
template and later ones are clones. `leanui-props --only corpus` writes the engine's buffers for
them with templates and without; `tests/browser/templates.mjs` applies both in Chromium and
Firefox and compares the DOM. The `templates` suite runs them natively too. -/

namespace Scenario

def E (tag : String) (attrs : Array TAttr) (kids : Array T) : T := .elem .html tag attrs kids
def ES (tag : String) (attrs : Array TAttr) (kids : Array T) : T := .elem .svg tag attrs kids
def X (s : String) : T := .text s
def S (s : String) : TProp := .str s
def on (ev : String) (id : Nat) : TAttr := .on { event := ev, id }

/-- A row: the special leaf, then filler (6 nodes). -/
def row (special : T) (t : String := "x") : T :=
  E "div" #[.attr "class" "row"] #[special, E "span" #[] #[X t], E "b" #[] #[X "y"]]
def root (rows : Array T) : T := E "div" #[.attr "id" "root"] rows
/-- A row of three same-tag filler elements around a text (keyed or not). -/
def krow (k : String) (keyed := true) : T :=
  E "div" ((if keyed then #[TAttr.key k] else #[]) ++ #[.attr "class" "row", on "click" 1])
    #[E "span" #[] #[X k], E "b" #[] #[X "y"], E "i" #[] #[]]

def all : Array (String × Array T) := #[
  ("defaultValue after value",
    let sp (d : String) := E "input" #[.prop "value" (S "a"), .prop "defaultValue" (S d)] #[]
    #[root #[row (sp "a"), row (sp "a"), row (sp "b")]]),
  ("value attribute after the value property",
    let sp (a : String) := E "input" #[.prop "value" (S "a"), .attr "value" a] #[]
    #[root #[row (sp "a"), row (sp "a"), row (sp "a")], root #[row (sp "a"), row (sp "a"), row (sp "z")]]),
  ("className set to empty",
    let sp (c : String) := E "span" #[.prop "className" (S c)] #[]
    #[root #[row (sp "x"), row (sp "x"), row (sp "")]]),
  ("id set to empty",
    let sp (c : String) := E "span" #[.prop "id" (S c)] #[]
    #[root #[row (sp "x"), row (sp "y"), row (sp "")]]),
  ("boolean reflection and attribute order",
    let sp (b : Bool) := E "span" #[.prop "hidden" (.bool b), .attr "class" "c"] #[]
    #[root #[row (sp false), row (sp false), row (sp true)]]),
  ("checkbox value property \"on\"",
    let sp (v : String) := E "input" #[.attr "type" "checkbox", .prop "value" (S v)] #[]
    #[root #[row (sp "x"), row (sp "x"), row (sp "on")]]),
  ("style property set to empty",
    let sp (v : String) := E "span" #[.prop "style" (S v)] #[]
    #[root #[row (sp "color: red"), row (sp "color: red"), row (sp "")]]),
  ("option value property",
    let o (v : String) := E "option" #[.attr "label" "L", .prop "value" (S v)] #[]
    let sel (v : String) := E "select" #[] #[o "x", o v, o "", E "option" #[] #[]]
    #[root #[sel "x", sel "x", sel "y"]]),
  ("two checked radios in a row",
    let r (b : Bool) := E "input" #[.attr "type" "radio", .attr "name" "g", .prop "checked" (.bool b)] #[]
    let rr (a b : Bool) := E "div" #[] #[r a, r b, E "span" #[] #[X "s"]]
    #[root #[rr false false, rr false false, rr true true]]),
  ("options selected by property",
    let o (l : String) (b : Bool) := E "option" #[.attr "label" l, .prop "selected" (.bool b)] #[]
    let sel (a b c : Bool) := E "select" #[] #[o "a" a, o "b" b, o "c" c]
    #[root #[sel false true false, sel false true false, sel true false false, sel false false true, sel false false false],
      root #[sel false true false, sel false true false, sel true false false, sel false false true, sel false true false]]),
  ("textarea as the template root",
    let ta (a : String) := E "textarea" #[] #[X a, X "-", X "c"]
    #[root #[ta "a", ta "a", ta "Q"], root #[ta "a", ta "a", ta "R"]]),
  ("number property, attribute after it",
    let sp (q : Int) := E "span" #[.prop "tabIndex" (.num q), .attr "class" "k"] #[]
    #[root #[row (sp 12), row (sp 12), row (sp (-4))]]),
  ("SVG with odd and repeated attributes",
    let r (t : String) := ES "g" #[.attr "data-x" "a\"b<c>&", .attr "class" "p", .attr "class" "q"]
      #[ES "text" #[.attr "x" "1"] #[X t], ES "rect" #[] #[], X ""]
    #[root #[r "1", r "2", r "3"]]),
  ("repeated listeners and a key",
    let r (t : String) := E "div" #[.key t, on "click" 1, on "input" 2, on "click" 3]
      #[E "span" #[on "click" 4] #[X t], E "b" #[] #[X t], X t]
    #[root #[r "1", r "2", r "3"], root #[r "1", r "2", r "3", r "4"]]),
  ("checked attribute, then the checked property",
    let sp (b : Bool) := E "input" #[.attr "type" "checkbox", .attr "checked" "", .prop "checked" (.bool b)] #[]
    #[root #[row (sp true), row (sp true), row (sp false)]]),
  ("value property, then the type attribute",
    let sp (v : String) := E "input" #[.prop "value" (S v), .attr "type" "checkbox"] #[]
    #[root #[row (sp "a"), row (sp "a"), row (sp "on")]]),
  ("keyed insert and reverse",
    #[root #[krow "a", krow "b", krow "c"], root #[krow "a", krow "n1", krow "n2", krow "b", krow "n3", krow "c"],
      root #[krow "c", krow "n3", krow "b", krow "n2", krow "n1", krow "a", krow "z"]]),
  ("rows replaced by another tag",
    let r (t k : String) := E t #[.attr "class" "row"] #[E "span" #[] #[X k], E "b" #[] #[X "y"], E "i" #[] #[]]
    #[root #[r "div" "1", r "div" "2", r "div" "3"], root #[r "section" "1", r "section" "2", r "section" "3", r "section" "4"]]),
  ("lazy rows",
    let r (k : String) : T := .lazy none (krow k false)
    #[root #[r "1", r "2", r "3"], root #[r "1", r "2", r "3", r "4", r "5"]]),
  ("handles reused after FREE",
    let r (k : String) := krow k false
    #[root #[r "1", r "2", r "3", r "4"], root #[r "1"], root #[r "1", r "5", r "6", r "7", r "8", r "9"]]),
  ("scripts inside rows",
    let r (k : String) := E "div" #[] #[E "script" #[] #[X "window.__runs=(window.__runs||0)+1"], E "span" #[] #[X k], E "b" #[] #[]]
    #[root #[r "1", r "2", r "3", r "4"]]),
  ("a select with a selected attribute",
    let sel (k : String) := E "select" #[] #[E "option" #[] #[X "a"], E "option" #[.attr "selected" ""] #[X k], E "option" #[] #[X "c"]]
    #[root #[sel "1", sel "2", sel "3"]]),
  ("a textarea value property",
    let r (v : String) := E "div" #[] #[E "textarea" #[.prop "value" (S v)] #[], E "span" #[] #[X v], E "b" #[] #[]]
    #[root #[r "a", r "a", r "", r "q"], root #[r "a", r "a", r "", r "q2"]]),
  ("innerHTML and textContent on leaves",
    let r (a b : String) := E "div" #[] #[E "span" #[.prop "innerHTML" (S a)] #[], E "p" #[.prop "textContent" (S b)] #[], E "b" #[] #[X b]]
    #[root #[r "<i>x</i><i>y</i>" "t", r "<i>x</i>" "u", r "<em>z</em>" "", r "" "v"],
      root #[r "<i>x</i><i>y</i>" "t", r "<i>q</i>" "u", r "<em>z</em>" "w", r "<s>1</s>" "v"]]),
  ("TodoMVC rows",
    let r (done : Bool) (t : String) := E "li" #[] #[
      E "input" #[.attr "class" "toggle", .attr "type" "checkbox", .prop "checked" (.bool done)] #[],
      E "label" #[] #[X t], E "input" #[.attr "class" "edit", .prop "value" (S t)] #[]]
    #[root #[r false "a", r true "b", r false "", r true "d"], root #[r true "a", r true "b2", r false "c", r false "d"]]),
  ("per-row attribute values",
    let r (i : Nat) := E "div" #[.attr "data-id" (toString i), .attr "class" (if i % 3 == 0 then "x" else "")]
      #[E "a" #[.attr "href" s!"#/{i}", on "click" 1] #[X s!"item {i}"], E "span" #[.attr "title" s!"t{i}"] #[], E "b" #[] #[X ""]]
    #[root #[r 1, r 2, r 3, r 4], root #[r 1, r 5, r 6, r 7, r 8], root #[r 8, r 7, r 9, r 1]]),
  ("attribute values around a property",
    let sp (c t : String) (b : Bool) := E "span" #[.attr "class" c, .prop "hidden" (.bool b), .attr "title" t] #[]
    #[root #[row (sp "a" "t" false), row (sp "a" "t" false), row (sp "b" "u" true), row (sp "" "" false)]]),
  ("a range input's value before its max, an image, a custom element",
    let r (v : String) := E "div" #[] #[E "input" #[.attr "type" "range", .attr "value" v, .attr "max" "200"] #[],
      E "img" #[.attr "alt" v, .attr "width" "1"] #[], E "x-item" #[.attr "data-v" v] #[X v]]
    #[root #[r "50", r "50", r "150", r "150", r "150", r "50"]]),
  ("inputs with per-row attributes",
    let r (v : String) (c : Bool) := E "div" #[] #[
      E "input" #[.attr "type" "email", .attr "value" s!" {v} , b ", .attr "multiple" ""] #[],
      E "input" #[.attr "type" "number", .attr "value" v] #[],
      E "input" #[.attr "type" "checkbox", .attr "value" v, .attr (if c then "checked" else "data-c") ""] #[],
      E "input" #[.attr "value" v, .attr "type" "date"] #[]]
    #[root #[r "a" true, r "a" true, r "2" true, r "2020-01-02" true, r "x" false, r "3.5" false]]),
  ("two radios with checked attributes in a row",
    let r (n : String) := E "input" #[.attr "type" "radio", .attr "name" n, .attr "checked" ""] #[]
    let rr (n : String) := E "div" #[] #[r n, r n, E "span" #[] #[X n]]
    #[root #[rr "g1", rr "g2", rr "g3", rr "g3"]]),
  ("a multiple select with two selected options",
    let o (l : String) (b : Bool) := E "option" (if b then #[.attr "selected" ""] else #[]) #[X l]
    let sel (a b c : Bool) := E "select" #[.attr "multiple" ""] #[o "a" a, o "b" b, o "c" c]
    #[root #[sel true true false, sel true true false, sel true true false, sel false true true]]),
  ("repeated attribute names with other values",
    let r (a b : String) := E "div" #[.attr "class" a, .attr "title" "t", .attr "class" b] #[E "span" #[] #[X a], E "i" #[] #[], X b]
    #[root #[r "a" "b", r "a" "b", r "a" "c", r "x" "b", r "a" "b"]])
]

end Scenario

end LeanUI.Testing.Pool
