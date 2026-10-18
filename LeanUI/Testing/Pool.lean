module
public import LeanUI.Testing.Gen
/-!
# Views whose rows repeat a few shapes (template cloning tests)

`LeanUI.Diff` creates repeated subtrees by cloning templates (`TEMPLATE`, `CLONE`), which random
views from `Testing.Gen` rarely exercise: their subtrees seldom share a shape. Here every view
holds four lists (a table body, a flow container, an SVG element and a MathML element) whose
rows come from a small pool of row shapes, so shapes repeat constantly: the second row of a shape
becomes a template and later ones are clones. Rows carry random texts (empty ones included),
property values and listeners; a few attribute values switch a row between shapes. The pool also
has the cases the clone path must get right: properties on leaf inputs, adjacent and empty texts,
a void element whose view names children, duplicate attributes and listeners, keyed children
inside a row, SVG and MathML, a lazy row around a templatable body, and shapes that must not be
templated (a lazy node inside, a property on an element with children, too few or too many
nodes).

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

def svgRow : G T := do
  return .elem .svg "g" #[.attr "class" (← pick #["a", "b"])] #[
    .elem .svg "rect" #[.attr "fill" "red"] #[], .elem .svg "circle" #[.attr "r" "3", ← on "click"] #[],
    .elem .svg "text" #[] #[.text (← word)]]

def mathRow : G T := do
  return .elem .mathml "mrow" #[] #[.elem .mathml "mi" #[] #[.text (← word)], .elem .mathml "mo" #[] #[.text "+"],
    .elem .mathml "mn" #[] #[.text (← word)]]

def flowRow : G T := do
  let r ← below 100
  let t ← if r < 25 then todoRow else if r < 37 then textsRow else if r < 49 then voidRow
    else if r < 57 then propRow else if r < 67 then dupRow else if r < 77 then keyedInside
    else if r < 84 then lazyInside else if r < 92 then tinyRow else wideRow
  -- a lazy row whose body is templatable (like the benchmark's lazy rows)
  if ← chance 10 then return .lazy none t else return t

/-- A new row for list `k`: 0 table body, 1 flow, 2 SVG, 3 MathML. -/
def row (k : Nat) : G T :=
  match k with
  | 0 => do if ← chance 85 then benchRow else shortRow
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

end LeanUI.Testing.Pool
