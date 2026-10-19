module
public import LeanUI
public section
open LeanUI Attr

/-!
# The js-framework-benchmark keyed app

The standard benchmark app (github.com/krausest/js-framework-benchmark, "keyed" category): the same
buttons, ids, table structure and class names, so the same operations can be timed. Labels come
from a deterministic 64-bit LCG instead of `Math.random`, so every implementation and every run
builds identical tables.
-/
namespace Bench

structure Row where
  id : Nat
  label : String
  deriving Inhabited

structure Model where
  rows : Array Row := #[]
  nextId : Nat := 1
  selected : Option Nat := none
  seed : UInt64 := 42

inductive Msg
  | run | runLots | add | update | clear | swapRows
  | select (id : Nat) | remove (id : Nat)

def adjectives : Array String := #["pretty", "large", "big", "small", "tall", "short", "long",
  "handsome", "plain", "quaint", "clean", "elegant", "easy", "angry", "crazy", "helpful", "mushy",
  "odd", "unsightly", "adorable", "important", "inexpensive", "cheap", "expensive", "fancy"]
def colours : Array String := #["red", "yellow", "blue", "green", "pink", "brown", "purple",
  "brown", "white", "black", "orange"]
def nouns : Array String := #["table", "chair", "house", "bbq", "desk", "car", "pony", "cookie",
  "sandwich", "burger", "pizza", "mouse", "keyboard"]

@[inline] def lcg (s : UInt64) : UInt64 := s * 6364136223846793005 + 1442695040888963407
@[inline] def pick (s : UInt64) (a : Array String) : String := a[((s >>> 33) % a.size.toUInt64).toNat]!

def build (m : Model) (count : Nat) : Model := Id.run do
  let mut s := m.seed
  let mut rows := m.rows
  let mut id := m.nextId
  for _ in [0:count] do
    let s1 := lcg s; let s2 := lcg s1; let s3 := lcg s2
    rows := rows.push { id, label := pick s1 adjectives ++ " " ++ pick s2 colours ++ " " ++ pick s3 nouns }
    s := s3; id := id + 1
  return { m with rows, nextId := id, seed := s }

def update : Msg → Model → Model × Cmd Msg
  | .run, m => (build { m with rows := #[], selected := none } 1000, .none)
  | .runLots, m => (build { m with rows := #[], selected := none } 10000, .none)
  | .add, m => (build m 1000, .none)
  | .update, m => ({ m with rows := m.rows.mapIdx fun i r => if i % 10 == 0 then { r with label := r.label ++ " !!!" } else r }, .none)
  | .clear, m => ({ m with rows := #[], selected := none }, .none)
  | .swapRows, m =>
    if m.rows.size > 998 then
      let a := m.rows[1]!; let b := m.rows[998]!
      ({ m with rows := (m.rows.set! 1 b).set! 998 a }, .none)
    else (m, .none)
  | .select rid, m => ({ m with selected := some rid }, .none)
  | .remove rid, m => ({ m with rows := m.rows.filter (·.id != rid) }, .none)

def button (bid label : String) (msg : Msg) : Html Msg :=
  el "div" #[cls "col-sm-6 smallpad"] #[
    el "button" #[Attr.attr "type" "button", cls "btn btn-primary btn-block", id bid, onClick msg] #[text label]]

/-- One row. `idText` is the id as text, which the lazy rows already made for the key. -/
def row (sel : Bool) (r : Row) (idText : String := toString r.id) : Html Msg :=
  el "tr" (if sel then #[cls "danger"] else #[]) #[
    el "td" #[cls "col-md-1"] #[text idText],
    el "td" #[cls "col-md-4"] #[el "a" #[cls "lbl", onClick (.select r.id)] #[text r.label]],
    el "td" #[cls "col-md-1"] #[el "a" #[cls "remove", onClick (.remove r.id)] #[
      el "span" #[cls "remove glyphicon glyphicon-remove", Attr.attr "aria-hidden" "true"] #[]]],
    el "td" #[cls "col-md-6"] #[]]

/-- Is row `id` the selected one? (`m.selected == some id` would allocate the `some`.) -/
@[inline] def isSelected (selected : Option Nat) (id : Nat) : Bool :=
  match selected with
  | some s => s == id
  | none => false

/-- The rows, each keyed and lazy: rendered and diffed only when its id (the key), label or
selection changes. -/
def lazyRows (m : Model) : Array (Html Msg) :=
  m.rows.map fun r =>
    let sel := isSelected m.selected r.id
    let k := toString r.id
    keyedLazy k (r.label, sel) fun _ => row sel r k

/-- The same rows rebuilt eagerly on every update (for comparison). -/
def eagerRows (m : Model) : Array (Html Msg) :=
  m.rows.map fun r => keyed (toString r.id) (row (isSelected m.selected r.id) r)

def page (rows : Array (Html Msg)) : Html Msg :=
  el "div" #[cls "container"] #[
    el "div" #[cls "jumbotron"] #[
      el "div" #[cls "row"] #[
        el "div" #[cls "col-md-6"] #[el "h1" #[] #[text "LeanUI (keyed)"]],
        el "div" #[cls "col-md-6"] #[
          el "div" #[cls "row"] #[
            button "run" "Create 1,000 rows" .run,
            button "runlots" "Create 10,000 rows" .runLots,
            button "add" "Append 1,000 rows" .add,
            button "update" "Update every 10th row" .update,
            button "clear" "Clear" .clear,
            button "swaprows" "Swap Rows" .swapRows]]]],
    el "table" #[cls "table table-hover table-striped test-data"] #[
      el "tbody" #[id "tbody"] rows],
    el "span" #[cls "preloadicon glyphicon glyphicon-remove", Attr.attr "aria-hidden" "true"] #[]]

def view (m : Model) : Html Msg := page (lazyRows m)

def program : Program Model Msg := { init := fun _ => ({}, .none), update, view }

/-- The benchmark app without `lazy`: every row is rebuilt and diffed on every update. -/
def programEager : Program Model Msg := { program with view := fun m => page (eagerRows m) }

end Bench
