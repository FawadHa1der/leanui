module
/-!
# The view language

A LeanUI view is a pure value of type `Html Msg`: a tree of elements and text whose event
listeners produce messages of type `Msg`. Views are rebuilt on every update; the runtime diffs
the new tree against the mounted one and sends the browser only the changes.

Nothing here touches the DOM, so the same view renders in the browser (wasm64), on a native Lean
server (`LeanUI.Render`), and in native tests.
-/
public section
namespace LeanUI

/-- XML namespace of an element. MathML and SVG elements must be created with their namespace. -/
inductive Ns where
  | html | svg | mathml
  deriving BEq, Inhabited, Repr

def Ns.code : Ns → UInt32
  | .html => 0 | .svg => 1 | .mathml => 2

/-- A value assigned to a DOM *property* (as opposed to an attribute): `input.value`,
`input.checked`, `option.selected`, `video.currentTime`. -/
inductive PropValue where
  | str (s : String)
  | bool (b : Bool)
  | num (x : Float)
  deriving Inhabited

def PropValue.beq : PropValue → PropValue → Bool
  | .str a, .str b => a == b
  | .bool a, .bool b => a == b
  | .num a, .num b => a == b
  | _, _ => false

instance : BEq PropValue := ⟨PropValue.beq⟩

/-- Which part of a DOM event the browser hands to Lean. The browser extracts it, so a handler
never needs to call back into JavaScript to read the event. -/
inductive Payload where
  /-- Nothing: the handler is a plain message. -/
  | none
  /-- `event.target.value` (inputs, textareas, selects). -/
  | value
  /-- `event.target.checked` as `"true"`/`"false"`. -/
  | checked
  /-- `KeyboardEvent.key`, e.g. `"Enter"`, `"Escape"`, `"a"`. -/
  | key
  /-- The form's fields as `name=value` lines (for `submit`). -/
  | formData
  deriving BEq, Inhabited, Repr

def Payload.code : Payload → UInt32
  | .none => 0 | .value => 1 | .checked => 2 | .key => 3 | .formData => 4

/-- How an event becomes a message. `decode` returns `none` to ignore the event (for example a
`keydown` that is not Enter). -/
structure Handler (Msg : Type) where
  payload : Payload := .none
  decode : String → Option Msg
  preventDefault : Bool := false
  stopPropagation : Bool := false

instance : Inhabited (Handler Msg) := ⟨{ decode := fun _ => none }⟩

def Handler.flags (h : Handler Msg) : UInt32 :=
  (if h.preventDefault then 1 else 0) ||| (if h.stopPropagation then 2 else 0)

def Handler.map (f : α → β) (h : Handler α) : Handler β :=
  { h with decode := fun s => (h.decode s).map f }

/-- One attribute of an element. -/
inductive Attr (Msg : Type) where
  /-- An HTML attribute (`setAttribute`). -/
  | attr (name value : String)
  /-- A DOM property (`element[name] = value`), used for live form state. -/
  | prop (name : String) (value : PropValue)
  /-- An event listener (delegated: one real listener per event type on the root). -/
  | on (event : String) (handler : Handler Msg)
  /-- The reconciliation key among siblings. Not rendered. -/
  | key (k : String)

instance : Inhabited (Attr Msg) := ⟨.key ""⟩

def Attr.map (f : α → β) : Attr α → Attr β
  | .attr n v => .attr n v
  | .prop n v => .prop n v
  | .on e h => .on e (h.map f)
  | .key k => .key k

/-- What a `lazy` subtree depends on. Dependencies are compared exactly (structurally, strings
by pointer first), never by hash, so reusing a subtree is never a guess. `ToDep` builds one from
ordinary values. -/
inductive Dep where
  | unit
  | bool (b : Bool)
  | nat (n : Nat)
  | int (i : Int)
  | u64 (n : UInt64)
  | str (s : String)
  | opt (d : Option Dep)
  | pair (a b : Dep)
  | list (ds : List Dep)
  deriving BEq, Inhabited, Repr

instance : OfNat Dep n := ⟨.nat n⟩

/-- Values a lazy subtree can depend on. -/
class ToDep (α : Type) where
  toDep : α → Dep

export ToDep (toDep)

instance : ToDep Dep := ⟨id⟩
instance : ToDep Unit := ⟨fun _ => .unit⟩
instance : ToDep Bool := ⟨.bool⟩
instance : ToDep Nat := ⟨.nat⟩
instance : ToDep Int := ⟨.int⟩
instance : ToDep UInt64 := ⟨.u64⟩
instance : ToDep UInt32 := ⟨fun n => .u64 n.toUInt64⟩
instance : ToDep Char := ⟨fun c => .nat c.toNat⟩
instance : ToDep String := ⟨.str⟩
instance [ToDep α] : ToDep (Option α) := ⟨fun o => .opt (o.map toDep)⟩
instance [ToDep α] [ToDep β] : ToDep (α × β) := ⟨fun (a, b) => .pair (toDep a) (toDep b)⟩
instance [ToDep α] : ToDep (List α) := ⟨fun xs => .list (xs.map toDep)⟩
instance [ToDep α] : ToDep (Array α) := ⟨fun xs => .list (xs.toList.map toDep)⟩

/-- A view. -/
inductive Html (Msg : Type) where
  | text (s : String)
  | elem (ns : Ns) (tag : String) (attrs : Array (Attr Msg)) (kids : Array (Html Msg))
  /-- A subtree rendered only when needed: while `deps` equals the mounted subtree's, both its
  rendering and its diff are skipped, handlers included. So `render` must be determined by
  `deps`, including the messages its handlers send. `key` is its reconciliation key among
  siblings, since that cannot be read off the subtree without rendering it. -/
  | lazy (key : Option String) (deps : Dep) (render : Unit → Html Msg)

instance : Inhabited (Html Msg) := ⟨.text ""⟩

/-- Elements that have no closing tag and no children (`LeanUI.Render` writes none). -/
def voidElements : List String :=
  ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]

/-- Is `tag` one of `voidElements`? Dispatches on the length first, so the common tags cost a
comparison or two. -/
def isVoid (tag : String) : Bool :=
  match tag.utf8ByteSize with
  | 2 => tag == "br" || tag == "hr"
  | 3 => tag == "col" || tag == "img" || tag == "wbr"
  | 4 => tag == "area" || tag == "base" || tag == "link" || tag == "meta"
  | 5 => tag == "embed" || tag == "input" || tag == "track"
  | 6 => tag == "source"
  | _ => false

/-- The children an element really gets: none for a void element, whatever the view says, so the
browser DOM, server rendering and hydration agree. -/
@[inline] def effectiveKids (tag : String) (kids : Array α) : Array α :=
  if kids.isEmpty then kids else if isVoid tag then #[] else kids

namespace Html

/-- The reconciliation key of a node, if it has one. -/
def key? : Html Msg → Option String
  | .elem _ _ attrs _ => attrs.findSome? fun | .key k => some k | _ => none
  | .lazy k _ _ => k
  | _ => none

/-- Change the message type of a view, for composing components. -/
partial def map (f : α → β) : Html α → Html β
  | .text s => .text s
  | .elem ns tag attrs kids => .elem ns tag (attrs.map (Attr.map f)) (kids.map (map f))
  | .lazy k deps r => .lazy k deps fun _ => map f (r ())

/-- Force `lazy` nodes (used where a concrete tree is needed, e.g. server rendering). -/
partial def force : Html Msg → Html Msg
  | .lazy _ _ r => force (r ())
  | h => h

end Html

/-! ## Smart constructors (the non-macro API) -/

@[inline] def text (s : String) : Html Msg := .text s
@[inline] def el (tag : String) (attrs : Array (Attr Msg) := #[]) (kids : Array (Html Msg) := #[]) : Html Msg :=
  .elem .html tag attrs kids
@[inline] def svg (tag : String) (attrs : Array (Attr Msg) := #[]) (kids : Array (Html Msg) := #[]) : Html Msg :=
  .elem .svg tag attrs kids
@[inline] def mathml (tag : String) (attrs : Array (Attr Msg) := #[]) (kids : Array (Html Msg) := #[]) : Html Msg :=
  .elem .mathml tag attrs kids
/-- A lazy subtree: `render` runs, and is diffed, only when `deps` differs from last time. -/
@[inline] def lazy [ToDep α] (deps : α) (render : Unit → Html Msg) : Html Msg :=
  .lazy none (toDep deps) render
/-- `memo a f` shows `f a`, recomputing it only when `a` changes. -/
@[inline] def memo [ToDep α] (a : α) (f : α → Html Msg) : Html Msg :=
  .lazy none (toDep a) fun _ => f a
/-- Give a node a reconciliation key among its siblings (lazy nodes included; text cannot be
keyed). -/
def keyed (k : String) : Html Msg → Html Msg
  | .elem ns tag attrs kids => .elem ns tag (#[.key k] ++ attrs.filter fun | .key _ => false | _ => true) kids
  | .lazy _ d r => .lazy (some k) d r
  | h => h

namespace Attr
@[inline] def cls (c : String) : Attr Msg := .attr "class" c
@[inline] def id (i : String) : Attr Msg := .attr "id" i
/-- `class` from a list of (name, enabled) pairs. -/
def classes (cs : List (String × Bool)) : Attr Msg :=
  .attr "class" (" ".intercalate (cs.filterMap fun (c, b) => if b then some c else none))
@[inline] def value (v : String) : Attr Msg := .prop "value" (.str v)
@[inline] def checked (b : Bool) : Attr Msg := .prop "checked" (.bool b)
@[inline] def onClick (m : Msg) : Attr Msg := .on "click" { decode := fun _ => some m }
@[inline] def onDblClick (m : Msg) : Attr Msg := .on "dblclick" { decode := fun _ => some m }
@[inline] def onInput (f : String → Msg) : Attr Msg := .on "input" { payload := .value, decode := fun s => some (f s) }
@[inline] def onChange (f : String → Msg) : Attr Msg := .on "change" { payload := .value, decode := fun s => some (f s) }
@[inline] def onCheck (f : Bool → Msg) : Attr Msg := .on "change" { payload := .checked, decode := fun s => some (f (s == "true")) }
@[inline] def onBlur (m : Msg) : Attr Msg := .on "focusout" { decode := fun _ => some m }
/-- `keydown`, mapping `KeyboardEvent.key` to a message or ignoring it. -/
@[inline] def onKeyDown (f : String → Option Msg) : Attr Msg := .on "keydown" { payload := .key, decode := f }
/-- `submit` with the form's `name=value` lines; the default navigation is prevented. -/
@[inline] def onSubmit (f : String → Msg) : Attr Msg :=
  .on "submit" { payload := .formData, decode := fun s => some (f s), preventDefault := true }
end Attr

end LeanUI
