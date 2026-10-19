module
public import LeanUI.Html
/-!
# First-order views for property tests

A `T` is a view with no closures: every listener is a `TListener` (an event, what the browser
extracts, and a message id), every lazy node says whether its `deps` are honest (a hash of its
body) or pinned to a fixed value. Because a `T` is plain data it can be generated, edited,
hashed, compared, shrunk and printed as Lean code; `T.toHtml` turns it into the `Html String`
the engine runs, with lazy thunks that count how often the diff forces them.

Messages are strings: a listener with id `n` on event `e` turns a payload `p` into `"n|e|p"`, so
a test can tell exactly which listener (and which version of it) a slot routes to.
-/
public section
namespace LeanUI.Testing

/-- A property value. Numbers are quarters (`n / 4`), so they print and compare exactly. -/
inductive TProp where
  | str (s : String)
  | bool (b : Bool)
  | num (q : Int)
  deriving BEq, Repr, Inhabited

def TProp.toProp : TProp → PropValue
  | .str s => .str s
  | .bool b => .bool b
  | .num q => .num (Float.ofInt q / 4)

/-- How the DOM model and the browser store a property value (as a string). -/
def TProp.shown : TProp → String
  | .str s => s
  | .bool b => if b then "true" else "false"
  | .num q => toString (Float.ofInt q / 4)

structure TListener where
  event : String
  payload : Payload := .none
  /-- Message identity; a fresh id means a new handler. -/
  id : Nat
  /-- Ignore every payload except `"Enter"` (like a keydown handler). -/
  filter : Bool := false
  prevent : Bool := false
  stop : Bool := false
  deriving BEq, Repr, Inhabited

def TListener.flags (l : TListener) : UInt32 :=
  (if l.prevent then 1 else 0) ||| (if l.stop then 2 else 0)

/-- The message this listener's handler produces for a payload. -/
def TListener.decode (l : TListener) (p : String) : Option String :=
  if l.filter && p != "Enter" then none else some s!"{l.id}|{l.event}|{p}"

def TListener.toHandler (l : TListener) : Handler String :=
  { payload := l.payload, decode := l.decode, preventDefault := l.prevent, stopPropagation := l.stop }

inductive TAttr where
  | attr (name value : String)
  | prop (name : String) (v : TProp)
  | on (l : TListener)
  | key (k : String)
  deriving BEq, Repr, Inhabited

def TAttr.toAttr : TAttr → Attr String
  | .attr n v => .attr n v
  | .prop n v => .prop n v.toProp
  | .on l => .on l.event l.toHandler
  | .key k => .key k

/-- A first-order view. `lazy none body` has honest deps (`body.hash`); `lazy (some d) body`
keeps `d` whatever the body becomes (a *stale probe*: the diff must not look inside). -/
inductive T where
  | text (s : String)
  | elem (ns : Ns) (tag : String) (attrs : Array TAttr) (kids : Array T)
  | lazy (pin : Option UInt64) (body : T)
  deriving Repr, Inhabited

namespace T

partial def beq : T → T → Bool
  | .text a, .text b => a == b
  | .elem n t as ks, .elem n' t' as' ks' =>
    n == n' && t == t' && as == as' && ks.size == ks'.size &&
      (ks.zip ks').all fun (a, b) => beq a b
  | .lazy p b, .lazy p' b' => p == p' && beq b b'
  | _, _ => false

instance : BEq T := ⟨beq⟩

private def hs (h : UInt64) (s : String) : UInt64 := mixHash h (hash s)

def TProp.hash' : TProp → UInt64
  | .str s => mixHash 11 (hash s)
  | .bool b => if b then 12 else 13
  | .num q => mixHash 14 (hash q)

def attrHash (h : UInt64) : TAttr → UInt64
  | .attr n v => hs (hs (mixHash h 21) n) v
  | .prop n v => mixHash (hs (mixHash h 22) n) (TProp.hash' v)
  | .on l => mixHash (hs (mixHash h 23) l.event)
      (mixHash (hash l.id) (mixHash l.payload.code.toUInt64 (mixHash l.flags.toUInt64 (if l.filter then 1 else 0))))
  | .key k => hs (mixHash h 24) k

/-- A structural hash: the honest `deps` of a lazy node. -/
partial def hash : T → UInt64
  | .text s => hs 1 s
  | .elem ns tag attrs kids =>
    let h := attrs.foldl attrHash (hs (mixHash 2 ns.code.toUInt64) tag)
    kids.foldl (fun h k => mixHash h k.hash) (mixHash h kids.size.toUInt64)
  | .lazy pin body => mixHash (mixHash 3 (pin.getD 0)) body.hash

/-- The `deps` a lazy node carries. -/
def deps (pin : Option UInt64) (body : T) : UInt64 := pin.getD body.hash

partial def size : T → Nat
  | .text _ => 1
  | .elem _ _ _ kids => kids.foldl (fun n k => n + k.size) 1
  | .lazy _ b => b.size

/-- DOM nodes the view produces (lazy wrappers are not nodes). -/
abbrev nodes := size

partial def lazies : T → Nat
  | .text _ => 0
  | .elem _ _ _ kids => kids.foldl (fun n k => n + k.lazies) 0
  | .lazy _ b => 1 + b.lazies

partial def depth : T → Nat
  | .text _ => 1
  | .elem _ _ _ kids => 1 + kids.foldl (fun n k => max n k.depth) 0
  | .lazy _ b => b.depth

/-- Look through lazy wrappers. -/
partial def force : T → T
  | .lazy _ b => force b
  | t => t

def keyOf (attrs : Array TAttr) : Option String := attrs.findSome? fun | .key k => some k | _ => none

/-- The key `Html.key?` reports for this view: lazy nodes have none. -/
def keyNew : T → Option String
  | .elem _ _ attrs _ => keyOf attrs
  | _ => none

/-- The key `Node.key?` reports for this view once mounted. A lazy node carries its own key
(`Html.lazy`'s first field, `keyed k`), never its body's; the generated lazy nodes have none. -/
def keyOld : T → Option String
  | .elem _ _ attrs _ => keyOf attrs
  | _ => none

end T

/-! ## Effective attributes (what the DOM shows: the last attribute of a name wins) -/

def setKV' (xs : Array (String × String)) (k v : String) : Array (String × String) :=
  match xs.findIdx? (·.1 == k) with
  | some i => xs.set! i (k, v)
  | none => xs.push (k, v)

/-- Attributes after duplicates are resolved (last wins), in first-occurrence order. -/
def effAttrs (as : Array TAttr) : Array (String × String) :=
  as.foldl (fun acc a => match a with | .attr n v => setKV' acc n v | _ => acc) #[]

def effProps (as : Array TAttr) : Array (String × TProp) :=
  as.foldl (init := #[]) fun acc a => match a with
    | .prop n v => match acc.findIdx? (·.1 == n) with
      | some i => acc.set! i (n, v)
      | none => acc.push (n, v)
    | _ => acc

/-- One listener per event: the last one declared. -/
def effListeners (as : Array TAttr) : Array TListener :=
  as.foldl (init := #[]) fun acc a => match a with
    | .on l => match acc.findIdx? (·.event == l.event) with
      | some i => acc.set! i l
      | none => acc.push l
    | _ => acc

/-! ## Strict canonical form

Unlike `Testing.canonHtml`, this keeps namespaces, separates adjacent texts, and lists listeners
(event, payload code, flags). Strings are length-prefixed (`len:chars`, length in code points),
so the format is unambiguous and easy to reproduce in JavaScript. -/

def lp (s : String) : String := s!"{s.length}:{s}"

def sortByName {α : Type} (xs : Array (String × α)) : Array (String × α) := xs.qsort (fun a b => a.1 < b.1)

def canonElem (ns : UInt32) (tag : String) (attrs : Array (String × String)) (props : Array (String × String))
    (ls : Array (String × String)) (kids : String) : String :=
  let a := String.join ((sortByName attrs).toList.map fun (n, v) => s!" @{n}={lp v}")
  let p := String.join ((sortByName props).toList.map fun (n, v) => s!" .{n}={lp v}")
  let l := String.join ((sortByName ls).toList.map fun (e, x) => s!" !{e}/{x}")
  s!"<{ns}:{tag}{a}{p}{l}>{kids}</>"

/-- Strict canonical form of a (forced) view. -/
partial def T.canon : T → String
  | .text s => "#" ++ lp s
  | .lazy _ b => b.canon
  | .elem ns tag attrs kids =>
    canonElem ns.code tag (effAttrs attrs) ((effProps attrs).map fun (n, v) => (n, v.shown))
      ((effListeners attrs).map fun l => (l.event, s!"{l.payload.code}/{l.flags}"))
      (String.join (kids.toList.map T.canon))

/-! ## Turning a `T` into a runnable view -/

private unsafe def tickImpl {α : Type} [Inhabited α] (c : IO.Ref Nat) (_ : Unit) (x : Unit → α) : α :=
  unsafeBaseIO (do c.modify (· + 1); pure (x ()))

/-- `x ()`, counting the call in `c`. Takes the thunk's unit argument so the compiler cannot
hoist the call out of the thunk. -/
@[implemented_by tickImpl] opaque tick {α : Type} [Inhabited α] (c : IO.Ref Nat) (u : Unit) (x : Unit → α) : α

/-- The view the engine runs. Every forced lazy thunk increments `c`. -/
partial def T.toHtml (c : IO.Ref Nat) : T → Html String
  | .text s => .text s
  | .elem ns tag attrs kids => .elem ns tag (attrs.map TAttr.toAttr) (kids.map (T.toHtml c))
  | .lazy pin body => .lazy none (.u64 (T.deps pin body)) fun u => tick c u fun _ => body.toHtml c

/-- The view without render counting. -/
partial def T.toHtml' : T → Html String
  | .text s => .text s
  | .elem ns tag attrs kids => .elem ns tag (attrs.map TAttr.toAttr) (kids.map T.toHtml')
  | .lazy pin body => .lazy none (.u64 (T.deps pin body)) fun _ => body.toHtml'

/-! ## Printing as Lean code (for minimized repros) -/

def TProp.toLean : TProp → String
  | .str s => s!"(.str {s.quote})"
  | .bool b => s!"(.bool {b})"
  | .num q => s!"(.num ({Float.ofInt q / 4}))"

def payloadLean : Payload → String
  | .none => ".none" | .value => ".value" | .checked => ".checked" | .key => ".key" | .formData => ".formData"
  | .files => ".files" | .pointer => ".pointer"

def TListener.toLean (l : TListener) : String :=
  let body := s!"some (\"{l.id}|{l.event}|\" ++ p)"
  let dec := if l.filter then s!"fun p => if p == \"Enter\" then {body} else none" else s!"fun p => {body}"
  let extra := (if l.prevent then ", preventDefault := true" else "") ++ (if l.stop then ", stopPropagation := true" else "")
  s!".on {l.event.quote} \{ payload := {payloadLean l.payload}, decode := {dec}{extra} }"

def TAttr.toLean : TAttr → String
  | .attr n v => s!".attr {n.quote} {v.quote}"
  | .prop n v => s!".prop {n.quote} {v.toLean}"
  | .on l => l.toLean
  | .key k => s!".key {k.quote}"

/-- The view as Lean source using the public `Html` API. -/
partial def T.toLean (indent : Nat := 0) : T → String
  | .text s => s!"text {s.quote}"
  | .lazy pin body => s!"lazy {T.deps pin body} fun _ => {body.toLean indent}"
  | .elem ns tag attrs kids =>
    let ctor := match ns with | .html => "el" | .svg => "svg" | .mathml => "mathml"
    let as := ", ".intercalate (attrs.toList.map TAttr.toLean)
    let pad := String.ofList (List.replicate (indent + 2) ' ')
    let ks := if kids.isEmpty then "#[]"
      else "#[\n" ++ ",\n".intercalate (kids.toList.map fun k => pad ++ k.toLean (indent + 2)) ++ "]"
    s!"{ctor} {tag.quote} #[{as}] {ks}"

/-! ## Edits

An edit names its target by a path of child indices, each taken modulo the number of children
at that level (a path that runs out of children stops early), so every edit applies to every
tree. That is what lets the shrinker delete edits freely. Lazy wrappers are transparent to
paths. -/

inductive Edit where
  | insert (path : Array Nat) (pos : Nat) (sub : T)
  | delete (path : Array Nat) (pos : Nat)
  | move (path : Array Nat) (src dst : Nat)
  | swap (path : Array Nat) (i j : Nat)
  | reverse (path : Array Nat)
  | rotate (path : Array Nat) (by_ : Nat)
  | replace (path : Array Nat) (sub : T)
  | setAttr (path : Array Nat) (name value : String)
  | delAttr (path : Array Nat) (name : String)
  | setProp (path : Array Nat) (name : String) (v : TProp)
  | delProp (path : Array Nat) (name : String)
  | setOn (path : Array Nat) (l : TListener)
  | delOn (path : Array Nat) (event : String)
  | setText (path : Array Nat) (s : String)
  | retag (path : Array Nat) (tag : String)
  | renamespace (path : Array Nat) (ns : Ns)
  /-- Give every child a key `pfx ++ index` (positional → keyed). -/
  | keyAll (path : Array Nat) (pfx : String)
  /-- Remove every child's key (keyed → positional). -/
  | unkeyAll (path : Array Nat)
  /-- Set (or clear) one child's key; can create a duplicate or a mixed list. -/
  | setKey (path : Array Nat) (pos : Nat) (k : Option String)
  | wrapLazy (path : Array Nat)
  | unwrapLazy (path : Array Nat)
  /-- Freeze a lazy node's deps at their current value: later edits inside it are stale. -/
  | pin (path : Array Nat)
  | unpin (path : Array Nat)
  /-- Rotate an element's attribute list (same attributes, new order: the general attr path). -/
  | rotateAttrs (path : Array Nat) (by_ : Nat)
  /-- Append an attribute as is, even if one of the same name exists (duplicates: chaos mode). -/
  | addAttr (path : Array Nat) (a : TAttr)
  deriving Repr, Inhabited

namespace Edit

def path : Edit → Array Nat
  | .insert p .. | .delete p .. | .move p .. | .swap p .. | .reverse p | .rotate p .. | .replace p ..
  | .setAttr p .. | .delAttr p .. | .setProp p .. | .delProp p .. | .setOn p .. | .delOn p ..
  | .setText p .. | .retag p .. | .renamespace p .. | .keyAll p .. | .unkeyAll p | .setKey p ..
  | .wrapLazy p | .unwrapLazy p | .pin p | .unpin p | .rotateAttrs p .. | .addAttr p .. => p

def name : Edit → String
  | .insert .. => "insert" | .delete .. => "delete" | .move .. => "move" | .swap .. => "swap"
  | .reverse .. => "reverse" | .rotate .. => "rotate" | .replace .. => "replace" | .setAttr .. => "setAttr"
  | .delAttr .. => "delAttr" | .setProp .. => "setProp" | .delProp .. => "delProp" | .setOn .. => "setOn"
  | .delOn .. => "delOn" | .setText .. => "setText" | .retag .. => "retag" | .renamespace .. => "renamespace"
  | .keyAll .. => "keyAll" | .unkeyAll .. => "unkeyAll" | .setKey .. => "setKey" | .wrapLazy .. => "wrapLazy"
  | .unwrapLazy .. => "unwrapLazy" | .pin .. => "pin" | .unpin .. => "unpin" | .rotateAttrs .. => "rotateAttrs"
  | .addAttr .. => "addAttr"

end Edit

/-- Apply `f` to the node at `path` (outermost node there, lazy wrappers included). -/
partial def T.modifyAt (f : T → T) : T → List Nat → T
  | t, [] => f t
  | .lazy pin b, path => .lazy pin (b.modifyAt f path)
  | .elem ns tag attrs kids, i :: rest =>
    if kids.isEmpty then f (.elem ns tag attrs kids)
    else
      let j := i % kids.size
      .elem ns tag attrs (kids.modify j fun k => k.modifyAt f rest)
  | t, _ => f t

/-- Apply `f` to the first element under any lazy wrappers. -/
partial def T.onElem (f : Ns → String → Array TAttr → Array T → T) : T → T
  | .lazy pin b => .lazy pin (b.onElem f)
  | .elem ns tag attrs kids => f ns tag attrs kids
  | t => t

def rotateArr {α : Type} (xs : Array α) (k : Nat) : Array α :=
  if xs.isEmpty then xs else
    let k := k % xs.size
    xs.extract k xs.size ++ xs.extract 0 k

def setAttrIn (as : Array TAttr) (n v : String) : Array TAttr :=
  match as.findIdx? (fun | .attr m _ => m == n | _ => false) with
  | some i => as.set! i (.attr n v)
  | none => as.push (.attr n v)

def setPropIn (as : Array TAttr) (n : String) (v : TProp) : Array TAttr :=
  match as.findIdx? (fun | .prop m _ => m == n | _ => false) with
  | some i => as.set! i (.prop n v)
  | none => as.push (.prop n v)

def setOnIn (as : Array TAttr) (l : TListener) : Array TAttr :=
  match as.findIdx? (fun | .on m => m.event == l.event | _ => false) with
  | some i => as.set! i (.on l)
  | none => as.push (.on l)

def stripKey (as : Array TAttr) : Array TAttr := as.filter fun | .key _ => false | _ => true

/-- Set or clear the key of a node (through lazy wrappers); texts are unchanged. -/
def T.withKey (k : Option String) (t : T) : T :=
  t.onElem fun ns tag attrs kids =>
    let as := stripKey attrs
    .elem ns tag (match k with | some k => #[.key k] ++ as | none => as) kids

/-- Is `tag` a void element (`LeanUI.voidElements`, no children allowed)? -/
def isVoid (tag : String) : Bool :=
  ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"].contains tag

def Edit.apply (t : T) (e : Edit) : T :=
  let at_ (f : T → T) := t.modifyAt f e.path.toList
  let kidsOf (g : Array T → Array T) := at_ fun n => n.onElem fun ns tag attrs kids => .elem ns tag attrs (g kids)
  match e with
  | .insert _ pos sub => at_ fun n => n.onElem fun ns tag attrs kids =>
      if isVoid tag then .elem ns tag attrs kids
      else .elem ns tag attrs (kids.insertIdxIfInBounds (pos % (kids.size + 1)) sub)
  | .delete _ pos => kidsOf fun kids => if kids.isEmpty then kids else kids.eraseIdxIfInBounds (pos % kids.size)
  | .move _ s d => kidsOf fun kids =>
      if kids.isEmpty then kids else
        let s := s % kids.size; let x := kids[s]!; let rest := kids.eraseIdxIfInBounds s
        rest.insertIdxIfInBounds (d % (rest.size + 1)) x
  | .swap _ i j => kidsOf fun kids => if kids.isEmpty then kids else kids.swapIfInBounds (i % kids.size) (j % kids.size)
  | .reverse _ => kidsOf Array.reverse
  | .rotate _ k => kidsOf fun kids => rotateArr kids k
  | .replace _ sub => at_ fun _ => sub
  | .setAttr _ n v => at_ fun x => x.onElem fun ns tag attrs kids => .elem ns tag (setAttrIn attrs n v) kids
  | .delAttr _ n => at_ fun x => x.onElem fun ns tag attrs kids =>
      .elem ns tag (attrs.filter fun | .attr m _ => m != n | _ => true) kids
  | .setProp _ n v => at_ fun x => x.onElem fun ns tag attrs kids => .elem ns tag (setPropIn attrs n v) kids
  | .delProp _ n => at_ fun x => x.onElem fun ns tag attrs kids =>
      .elem ns tag (attrs.filter fun | .prop m _ => m != n | _ => true) kids
  | .setOn _ l => at_ fun x => x.onElem fun ns tag attrs kids => .elem ns tag (setOnIn attrs l) kids
  | .delOn _ ev => at_ fun x => x.onElem fun ns tag attrs kids =>
      .elem ns tag (attrs.filter fun | .on l => l.event != ev | _ => true) kids
  | .setText _ s => at_ fun x => match x with | .text _ => .text s | y => y
  | .retag _ tg => at_ fun x => x.onElem fun ns tag attrs kids =>
      if isVoid tg && !kids.isEmpty then .elem ns tag attrs kids else .elem ns tg attrs kids
  | .renamespace _ ns' => at_ fun x => x.onElem fun _ tag attrs kids => .elem ns' tag attrs kids
  | .keyAll _ pfx => kidsOf fun kids => kids.mapIdx fun i k => k.withKey (some s!"{pfx}{i}")
  | .unkeyAll _ => kidsOf fun kids => kids.map (·.withKey none)
  | .setKey _ pos k => kidsOf fun kids => if kids.isEmpty then kids else kids.modify (pos % kids.size) (·.withKey k)
  | .wrapLazy _ => at_ fun x => .lazy none x
  | .unwrapLazy _ => at_ fun x => match x with | .lazy _ b => b | y => y
  | .pin _ => at_ fun x => match x with | .lazy pn b => .lazy (some (T.deps pn b)) b | y => y
  | .unpin _ => at_ fun x => match x with | .lazy _ b => .lazy none b | y => y
  | .rotateAttrs _ k => at_ fun x => x.onElem fun ns tag attrs kids => .elem ns tag (rotateArr attrs k) kids
  | .addAttr _ a => at_ fun x => x.onElem fun ns tag attrs kids => .elem ns tag (attrs.push a) kids

def Edit.toLean (e : Edit) : String := (repr e).pretty 120

end LeanUI.Testing
