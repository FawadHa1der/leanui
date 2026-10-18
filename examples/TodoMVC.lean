module
public import LeanUI
public import LeanUI.Router
public import LeanUI.Json
meta import LeanUI.Json.Derive
/-!
# TodoMVC

The [TodoMVC](https://todomvc.com) app, to its specification: add, edit (double-click; Enter or
blur saves, Escape cancels, an empty title deletes), toggle, toggle all, delete, clear completed,
an item counter, the All / Active / Completed filters in the URL fragment (`#/active`, so it works
on any static server and survives a reload), and the list kept in `localStorage` as JSON.

The model logic is the pure function `step`, separate from the effects (`effects`), so that
properties of the app can be proved about it: `examples/TodoMVCProofs.lean` shows that every
message keeps todo ids unique (the keyed list's keys) and below `nextId`, and the effect of the
bulk operations. Rows are keyed and lazy: each is rendered and diffed only when its own todo, or
whether it is being edited, changes.

The page (`examples/todomvc.html`) passes the URL as flags, so the first render already shows the
filter it names.
-/
@[expose] public section
open LeanUI Attr
namespace TodoMVC

/-! ## Model -/

structure Todo where
  id : Nat
  title : String
  completed : Bool
  deriving BEq, Repr, Inhabited

/-- What is stored: ids are per session, so only titles and states are kept. -/
structure Stored where
  title : String
  completed : Bool := false
  deriving ToJson, FromJson

inductive Filter | all | active | completed
  deriving BEq, Repr, Inhabited

structure Model where
  todos : Array Todo := #[]
  nextId : Nat := 1
  /-- The new-todo field. -/
  field : String := ""
  /-- The todo being edited, and its draft title. -/
  editing : Option Nat := none
  draft : String := ""
  filter : Filter := .all

inductive Msg where
  | field (s : String)
  | newKey (key : String)
  | toggle (id : Nat) (done : Bool)
  | toggleAll (done : Bool)
  | destroy (id : Nat)
  | edit (id : Nat)
  | draft (s : String)
  | editKey (key : String)
  | commit
  | clearCompleted
  | urlChanged (url : String)
  | loaded (json : Option String)

def storageKey := "todos-leanui"

/-! ## Routes: the filter lives in the fragment -/

def filters : Route Filter := Route.oneOf [
  Route.top |>.to (fun _ => .all) (fun | .all => some () | _ => none),
  Route.lit "active" |>.to (fun _ => .active) (fun | .active => some () | _ => none),
  Route.lit "completed" |>.to (fun _ => .completed) (fun | .completed => some () | _ => none)]

def router : Router Filter := { route := filters, hash := true }

/-! ## The model logic (pure) -/

/-- Apply `f` to the todo with id `i`. -/
def modify (i : Nat) (f : Todo → Todo) (ts : Array Todo) : Array Todo :=
  ts.map fun t => if t.id == i then f t else t

def remove (i : Nat) (ts : Array Todo) : Array Todo := ts.filter (·.id != i)

/-- Number todos `k, k+1, …`. -/
def renumberFrom (k : Nat) : List Todo → List Todo
  | [] => []
  | t :: ts => { t with id := k } :: renumberFrom (k + 1) ts

/-- Number todos `1 … n` (used for todos read back from storage). -/
def renumber (ts : Array Todo) : Array Todo := (renumberFrom 1 ts.toList).toArray

def addTodo (m : Model) : Model :=
  let title := m.field.trimAscii.toString
  if title.isEmpty then { m with field := "" }
  else { m with todos := m.todos.push { id := m.nextId, title, completed := false }, nextId := m.nextId + 1, field := "" }

/-- Leave editing, saving the draft (an empty draft deletes the todo). -/
def commitEdit (m : Model) : Model :=
  match m.editing with
  | none => m
  | some i =>
    let title := m.draft.trimAscii.toString
    let todos := if title.isEmpty then remove i m.todos else modify i (fun t => { t with title }) m.todos
    { m with todos, editing := none, draft := "" }

def decodeStored (json : Option String) : Array Todo :=
  match json.map (Json.decode (Array Stored)) with
  | some (.ok xs) => xs.map fun s => { id := 0, title := s.title, completed := s.completed }
  | _ => #[]

/-- Todos read back from storage come first; everything is renumbered. -/
def load (json : Option String) (m : Model) : Model :=
  let todos := renumber (decodeStored json ++ m.todos)
  { m with todos, nextId := todos.size + 1, editing := none, draft := "" }

def step : Msg → Model → Model
  | .field s, m => { m with field := s }
  | .newKey k, m => if k == "Enter" then addTodo m else m
  | .toggle i b, m => { m with todos := modify i (fun t => { t with completed := b }) m.todos }
  | .toggleAll b, m => { m with todos := m.todos.map fun t => { t with completed := b } }
  | .destroy i, m => { m with todos := remove i m.todos, editing := if m.editing == some i then none else m.editing }
  | .edit i, m => match m.todos.find? (·.id == i) with
    | some t => { m with editing := some i, draft := t.title }
    | none => m
  | .draft s, m => { m with draft := s }
  | .editKey k, m =>
    if k == "Enter" then commitEdit m
    else if k == "Escape" then { m with editing := none, draft := "" }
    else m
  | .commit, m => commitEdit m
  | .clearCompleted, m => { m with todos := m.todos.filter (!·.completed) }
  | .urlChanged url, m => { m with filter := (router.parse url).getD .all }
  | .loaded json, m => load json m

/-! ## Effects -/

def save (m : Model) : Cmd Msg :=
  .storageSet storageKey (Json.encode (m.todos.map fun t => ({ title := t.title, completed := t.completed } : Stored)))

/-- What a message makes the runtime do besides re-rendering: store the list when it changed,
focus the editor when editing starts. -/
def effects (msg : Msg) (before after : Model) : Cmd Msg :=
  let stored := if before.todos == after.todos then .none else save after
  match msg with
  | .edit _ => if after.editing.isSome then .batch #[stored, .focus ".todo-list li.editing .edit"] else stored
  | _ => stored

def update (msg : Msg) (m : Model) : Model × Cmd Msg :=
  let m' := step msg m
  (m', effects msg m m')

/-- Flags: the page's URL, so the first render shows the filter in its fragment. -/
def init (url : String) : Model × Cmd Msg :=
  ({ filter := (router.parse url).getD .all }, .batch #[.storageGet storageKey .loaded, .focus ".new-todo"])

def subscriptions (_ : Model) : LeanUI.Sub Msg := .urlChanges .urlChanged

/-! ## View -/

def visible (f : Filter) (t : Todo) : Bool :=
  match f with
  | .all => true
  | .active => !t.completed
  | .completed => t.completed

def checkbox (cl : String) (on : Bool) (k : Bool → Msg) (extra : Array (Attr Msg) := #[]) : Html Msg :=
  el "input" (#[cls cl, Attr.attr "type" "checkbox", checked on, onCheck k] ++ extra) #[]

def viewTodo (t : Todo) (draft : Option String) : Html Msg :=
  el "li" #[classes [("completed", t.completed), ("editing", draft.isSome)]] (#[
    el "div" #[cls "view"] #[
      checkbox "toggle" t.completed (.toggle t.id),
      el "label" #[onDblClick (.edit t.id)] #[text t.title],
      el "button" #[cls "destroy", onClick (.destroy t.id)] #[]]] ++
    match draft with
    | some d => #[el "input" #[cls "edit", value d, onInput .draft, onKeyDown (fun k => some (.editKey k)), onBlur .commit] #[]]
    | none => #[])

def filterLink (current f : Filter) (label : String) : Html Msg :=
  el "li" #[] #[router.link f #[cls (if current == f then "selected" else "")] #[text label]]

def view (m : Model) : Html Msg :=
  let active := (m.todos.filter (!·.completed)).size
  let completed := m.todos.size - active
  let rows := m.todos.filter (visible m.filter) |>.map fun t =>
    let draft := if m.editing == some t.id then some m.draft else none
    keyed (toString t.id) (lazy (t.id, t.title, t.completed, draft) fun _ => viewTodo t draft)
  el "div" #[] #[
    el "section" #[cls "todoapp"] (#[
      el "header" #[cls "header"] #[
        el "h1" #[] #[text "todos"],
        el "input" #[cls "new-todo", Attr.attr "placeholder" "What needs to be done?", Attr.attr "autofocus" "",
          value m.field, onInput .field, onKeyDown (fun k => if k == "Enter" then some (.newKey k) else none)] #[]]] ++
      if m.todos.isEmpty then #[] else #[
        el "section" #[cls "main"] #[
          checkbox "toggle-all" (active == 0) .toggleAll #[id "toggle-all"],
          el "label" #[Attr.attr "for" "toggle-all"] #[text "Mark all as complete"],
          el "ul" #[cls "todo-list"] rows],
        el "footer" #[cls "footer"] (#[
          el "span" #[cls "todo-count"] #[el "strong" #[] #[text (toString active)], text (if active == 1 then " item left" else " items left")],
          el "ul" #[cls "filters"] #[filterLink m.filter .all "All", filterLink m.filter .active "Active", filterLink m.filter .completed "Completed"]] ++
          if completed > 0 then #[el "button" #[cls "clear-completed", onClick .clearCompleted] #[text "Clear completed"]] else #[])]),
    el "footer" #[cls "info"] #[
      el "p" #[] #[text "Double-click to edit a todo"],
      el "p" #[] #[text "Written in Lean 4 with LeanUI"],
      el "p" #[] #[text "Part of ", el "a" #[Attr.attr "href" "https://todomvc.com"] #[text "TodoMVC"]]]]

def program : Program Model Msg := { init, update, view, subscriptions }

end TodoMVC
