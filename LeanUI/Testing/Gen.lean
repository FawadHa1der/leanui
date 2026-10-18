module
public import LeanUI.Testing.Tree
/-!
# Random views and random edits

Deterministic generators (SplitMix64) for first-order views (`T`) and for edit sequences that
mutate them. Generation is context-aware so that, by default, every tree is also a valid HTML
document fragment (no children under void elements, `li` only under `ul`, SVG and MathML only
under their roots): that is what makes the server-rendering round trip exact. `Config.hazards`
turns those rules off on purpose, and `dupAttrPct` / `dupOnPct` add duplicate attributes and
listeners (chaos mode).
-/
public section
namespace LeanUI.Testing

/-- SplitMix64. -/
structure Rng where
  s : UInt64
  deriving Inhabited, Repr

def Rng.next (r : Rng) : Rng × UInt64 :=
  let s := r.s + 0x9E3779B97F4A7C15
  let z := (s ^^^ (s >>> 30)) * 0xBF58476D1CE4E5B9
  let z := (z ^^^ (z >>> 27)) * 0x94D049BB133111EB
  (⟨s⟩, z ^^^ (z >>> 31))

/-- A seed derived from a base seed and a case number (independent streams per case). -/
def Rng.ofCase (seed : UInt64) (i : Nat) : Rng := ⟨(Rng.next ⟨seed ^^^ (i.toUInt64 * 0xD1B54A32D192ED03)⟩).2⟩

structure GenState where
  rng : Rng
  /-- Nodes still allowed in the tree being generated. -/
  budget : Nat := 0
  /-- Fresh listener ids (each new handler gets a new message identity). -/
  nextId : Nat := 1
  /-- Fresh keys. -/
  nextKey : Nat := 0
  deriving Inhabited

abbrev G := StateM GenState

def rand : G UInt64 := modifyGet fun s => let (r, x) := s.rng.next; (x, { s with rng := r })
def below (n : Nat) : G Nat := do if n == 0 then return 0 else return ((← rand).toNat % n)
/-- True with probability `pct` percent. -/
def chance (pct : Nat) : G Bool := do return (← below 100) < pct
def pick {α : Type} [Inhabited α] (xs : Array α) : G α := do return xs[← below xs.size]!
def between (lo hi : Nat) : G Nat := do return lo + (← below (hi - lo + 1))
def freshId : G Nat := modifyGet fun s => (s.nextId, { s with nextId := s.nextId + 1 })
def freshKey : G String := modifyGet fun s => (s!"n{s.nextKey}", { s with nextKey := s.nextKey + 1 })

def G.run' {α : Type} (g : G α) (r : Rng) : α × Rng := let (a, s) := g.run { rng := r }; (a, s.rng)

structure Config where
  maxDepth : Nat := 5
  maxKids : Nat := 8
  /-- Upper bound on nodes per generated tree. -/
  budget : Nat := 160
  textPct : Nat := 30
  emptyTextPct : Nat := 10
  keyedPct : Nat := 45
  /-- Of keyed lists: one duplicate key (the diff must fall back to positional). -/
  dupKeyPct : Nat := 8
  /-- Of keyed lists: one child without a key. -/
  mixedKeyPct : Nat := 5
  lazyPct : Nat := 12
  pinnedPct : Nat := 10
  svgPct : Nat := 6
  mathPct : Nat := 3
  listenerPct : Nat := 35
  propPct : Nat := 20
  /-- Chaos: an element repeats an attribute or property name. -/
  dupAttrPct : Nat := 0
  /-- Chaos: an element has two listeners for one event. -/
  dupOnPct : Nat := 0
  /-- Allow constructs whose server rendering the HTML parser does not round-trip. -/
  hazards : Bool := false
  deriving Inhabited, Repr

/-- Duplicate attributes and listeners on top of the default mix. -/
def Config.chaos (c : Config := {}) : Config := { c with dupAttrPct := 12, dupOnPct := 12 }

/-- Where a node sits, which decides which tags may appear. -/
inductive Ctx where
  | flow | list | svg | math
  /-- Inside a MathML token element (`mi`, `mo`, `mn`): text only, since the HTML parser parses
  element children of these as HTML. -/
  | mtext
  deriving BEq, Inhabited, Repr

def flowTags : Array String := #["div", "span", "section", "b", "i", "em", "label", "article", "ul"]
def voidTags : Array String := #["input", "br", "img", "hr"]
def svgTags : Array String := #["g", "rect", "circle", "path", "text", "line"]
def mathTags : Array String := #["mi", "mn", "mo", "mrow"]
/-- Tags that break the HTML round trip (hazard mode only). -/
def hazardTags : Array String := #["p", "pre", "textarea", "li", "a", "button", "table", "title", "script"]

def textPieces : Array String :=
  #["a", "hello", "x y", " ", "row", "<b>", "&amp;", "\"q\"", "'", "é", "日本語", "😀", "a\tb", "-->",
    "<!--", "&lt;", "1", "\n", "Ω≈", "]]>", "\\", "{}", "%20", "𝔸"]

def attrNamesHtml : Array String := #["class", "id", "title", "data-x", "data-y", "aria-label", "href", "style", "alt", "name", "role"]
def attrNamesSvg : Array String := #["class", "fill", "stroke", "d", "cx", "r", "id", "data-x"]
def valuePieces : Array String := #["", "a", "b c", "x\"y", "<&>", "é", "😀", "1", "on", "long-value-0123456789", "'s'", "=", "\n"]
/-- Real DOM properties of `input` that do not reflect to attributes. -/
def inputProps : Array String := #["value", "checked", "indeterminate"]
/-- Expando properties (plain JavaScript properties on any element). -/
def expandoProps : Array String := #["foo", "num"]

def keyPool : Array String := #["k0", "k1", "k2", "k3", "k4", "k5", "k6", "k7", "k8", "k9", "ключ", "🔑", "a b", ""]

def genString (pieces : Array String) (maxPieces : Nat) : G String := do
  let n ← below (maxPieces + 1)
  let mut s := ""
  for _ in [0:n] do s := s ++ (← pick pieces)
  return s

def genText (cfg : Config) : G String := do
  if ← chance cfg.emptyTextPct then return ""
  let s ← genString textPieces 3
  let s := if s.isEmpty then "t" else s
  if cfg.hazards && (← chance 4) then return s ++ "\r\n" ++ s
  return s

def events : Array (String × Payload) :=
  #[("click", .none), ("dblclick", .none), ("input", .value), ("change", .checked), ("keydown", .key),
    ("submit", .formData), ("focusout", .none), ("mouseenter", .none)]

def genListener (ev? : Option String := none) : G TListener := do
  let (ev, pl) ← match ev? with
    | some e => pure (e, ((events.find? (·.1 == e)).map (·.2)).getD .none)
    | none => pick events
  let id ← freshId
  -- a few listeners extract a different part of the event than usual
  let pl ← do if ← chance 10 then pick #[Payload.none, .value, .checked, .key, .formData] else pure pl
  return { event := ev, payload := pl, id, filter := ev == "keydown" && (← chance 70),
           prevent := ev == "submit" || (← chance 10), stop := ← chance 10 }

def genProp (tag : String) : G (String × TProp) := do
  let name ← if tag == "input" && (← chance 70) then pick inputProps else pick expandoProps
  let v ← match name with
    | "checked" | "indeterminate" => do pure (TProp.bool (← chance 50))
    | "num" => do pure (TProp.num ((← below 41 : Nat) - 20 : Int))
    | _ => do
      -- browsers strip line breaks from `input.value`, so keep prop strings on one line
      pure (TProp.str ((← genString (valuePieces.filter (· != "\n")) 2)))
  return (name, v)

def genAttrs (cfg : Config) (ctx : Ctx) (tag : String) : G (Array TAttr) := do
  let names := if ctx == .svg then attrNamesSvg else attrNamesHtml
  let n ← below 4
  let mut as : Array TAttr := #[]
  let mut used : Array String := #[]
  for _ in [0:n] do
    let nm ← pick names
    if used.contains nm then continue
    used := used.push nm
    as := as.push (.attr nm (← genString valuePieces 2))
  if ctx != .svg && ctx != .math && (← chance cfg.propPct) then
    let (nm, v) ← genProp tag
    as := as.push (.prop nm v)
  if ← chance cfg.listenerPct then
    as := as.push (.on (← genListener))
    if ← chance 25 then
      let l ← genListener
      if !(as.any fun | .on m => m.event == l.event | _ => false) then as := as.push (.on l)
  -- chaos: repeat a name with a different value or handler
  if ← chance cfg.dupAttrPct then
    let nm ← pick names
    as := as.push (.attr nm (← genString valuePieces 1)) |>.push (.attr nm (← genString valuePieces 2))
  if ← chance cfg.dupOnPct then
    let l ← genListener
    as := as.push (.on l) |>.push (.on (← genListener (some l.event)))
  -- shuffle so attributes, properties and listeners interleave
  let mut out := as
  for i in [0:out.size] do
    out := out.swapIfInBounds i (i + (← below (out.size - i)))
  return out

def takeBudget : G Bool := modifyGet fun s => if s.budget == 0 then (false, s) else (true, { s with budget := s.budget - 1 })

/-- Fan-out: mostly small, sometimes the maximum. -/
def genFanout (cfg : Config) : G Nat := do
  let r ← below 100
  if r < 15 then return 0
  if r < 60 then return (← between 1 3)
  if r < 90 then return (← between 1 cfg.maxKids)
  return cfg.maxKids

def childCtx (ctx : Ctx) (tag : String) : Ctx :=
  match ctx with
  | .flow => if tag == "ul" then .list else if tag == "svg" then .svg else if tag == "math" then .math else .flow
  | .list => .flow
  | .math => if tag == "mrow" then .math else .mtext
  | c => c

/-- Make a child list keyed (unique keys), possibly with one duplicate or one missing key. -/
def keyKids (cfg : Config) (kids : Array T) : G (Array T) := do
  if kids.isEmpty then return kids
  -- unique keys: a random selection from the pool, or fresh ones when the pool is too small
  let mut pool := keyPool
  for i in [0:pool.size] do pool := pool.swapIfInBounds i (i + (← below (pool.size - i)))
  let mut out := #[]
  for h : i in [0:kids.size] do
    let k ← if i < pool.size then pure pool[i]! else freshKey
    out := out.push (kids[i].withKey (some k))
  if out.size ≥ 2 && (← chance cfg.dupKeyPct) then
    let i ← below out.size; let j ← below out.size
    if i != j then out := out.modify i (·.withKey (out[j]!.keyOld))
  if ← chance cfg.mixedKeyPct then
    out := out.modify (← below out.size) (·.withKey none)
  return out

mutual

partial def genElem (cfg : Config) (ctx : Ctx) (depth : Nat) : G T := do
  match ctx with
  | .list =>
    if cfg.hazards && (← chance 10) then genLeafOrElem cfg .flow depth
    else
      let attrs ← genAttrs cfg .flow "li"
      return .elem .html "li" attrs (← genKids cfg .flow (depth + 1))
  | .svg =>
    let tag ← pick svgTags
    let attrs ← genAttrs cfg .svg tag
    return .elem .svg tag attrs (← genKids cfg .svg (depth + 1))
  | .math =>
    let tag ← pick mathTags
    return .elem .mathml tag (← genAttrs cfg .math tag) (← genKids cfg (childCtx .math tag) (depth + 1))
  | .mtext => return .text (← genText cfg)
  | .flow =>
    if ← chance cfg.svgPct then
      return .elem .svg "svg" (← genAttrs cfg .svg "svg") (← genKids cfg .svg (depth + 1))
    if ← chance cfg.mathPct then
      return .elem .mathml "math" #[] (← genKids cfg .math (depth + 1))
    if ← chance 12 then
      let tag ← pick voidTags
      let kids ← if cfg.hazards && (← chance 30) then genKids cfg .flow (depth + 1) else pure #[]
      return .elem .html tag (← genAttrs cfg .flow tag) kids
    let tag ← if cfg.hazards && (← chance 25) then pick hazardTags else pick flowTags
    let attrs ← genAttrs cfg .flow tag
    return .elem .html tag attrs (← genKids cfg (childCtx .flow tag) (depth + 1))

partial def genLeafOrElem (cfg : Config) (ctx : Ctx) (depth : Nat) : G T := do
  let ok ← takeBudget
  let t ← if !ok || depth ≥ cfg.maxDepth || ctx == .mtext || (ctx != .list && (← chance cfg.textPct)) then
      if ctx == .list then pure (.elem .html "li" #[] #[]) else pure (.text (← genText cfg))
    else genElem cfg ctx depth
  if ← chance cfg.lazyPct then
    let pin ← if ← chance cfg.pinnedPct then pure (some (← rand)) else pure none
    let t := if ← chance 15 then T.lazy none t else t
    return .lazy pin t
  return t

partial def genKids (cfg : Config) (ctx : Ctx) (depth : Nat) : G (Array T) := do
  if depth ≥ cfg.maxDepth then return #[]
  let n ← genFanout cfg
  let mut kids := #[]
  for _ in [0:n] do kids := kids.push (← genLeafOrElem cfg ctx depth)
  if kids.size ≥ 1 && ctx != .mtext && (← chance cfg.keyedPct) then
    -- a keyed list holds elements only (texts have no key)
    let ns : Ns := if ctx == .svg then .svg else if ctx == .math then .mathml else .html
    let wrapTag := if ctx == .svg then "g" else if ctx == .math then "mrow" else "span"
    let kids' := kids.map fun k => match k.force with | .text s => T.elem ns wrapTag #[] #[.text s] | _ => k
    keyKids cfg kids'
  else return kids

end

/-- A random view: a root element whose subtree has at most `cfg.budget` nodes. -/
def genTree (cfg : Config := {}) : G T := do
  modify fun s => { s with budget := cfg.budget }
  let attrs ← genAttrs cfg .flow "div"
  return .elem .html "div" attrs (← genKids cfg .flow 1)

/-! ## Edit sites and random edits -/

structure Site where
  path : Array Nat
  ctx : Ctx
  node : T
  deriving Inhabited

/-- Every node with the path that reaches it and the context it sits in. A lazy node and its body
share a path (lazy wrappers are transparent to paths). -/
partial def sites (t : T) (ctx : Ctx := .flow) (path : Array Nat := #[]) : Array Site :=
  let here : Site := { path, ctx, node := t }
  match t with
  | .lazy _ b => #[here] ++ sites b ctx path
  | .elem _ tag _ kids =>
    let cc := childCtx ctx tag
    kids.foldl (init := (#[here], 0)) (fun (acc, i) k => (acc ++ sites k cc (path.push i), i + 1)) |>.1
  | .text _ => #[here]

/-- Is a child list keyed, judging by its first child? Inserting there keeps it keyed. -/
def keyedList (kids : Array T) : Bool := kids.size > 0 && kids.all (·.keyOld.isSome)

def genSub (cfg : Config) (ctx : Ctx) (keyed : Bool) : G T := do
  modify fun s => { s with budget := min cfg.budget 12 }
  let t ← genLeafOrElem { cfg with maxDepth := 3 } ctx 1
  if keyed then
    let ns : Ns := if ctx == .svg then .svg else if ctx == .math then .mathml else .html
    let wrapTag := if ctx == .svg then "g" else if ctx == .math then "mrow" else "span"
    let t := match t.force with | .text s => T.elem ns wrapTag #[] #[.text s] | _ => t
    let k ← if ← chance 8 then pick keyPool else freshKey
    return t.withKey (some k)
  return t

def tagsFor (cfg : Config) (ctx : Ctx) (hasKids : Bool) : Array String :=
  match ctx with
  | .svg => svgTags
  | .math => if hasKids then #["mrow"] else mathTags
  | .mtext => mathTags
  | .list => #["li"]
  | .flow => (if hasKids then flowTags.filter (· != "ul") else flowTags.filter (· != "ul") ++ voidTags) ++
      (if cfg.hazards then hazardTags else #[])

/-- One random edit of `t`, aimed at an existing node. -/
def genEdit (cfg : Config) (t : T) : G Edit := do
  let ss := sites t
  let s ← pick ss
  let p := s.path
  match s.node with
  | .text _ =>
    let r ← below 10
    if r < 6 then return .setText p (← genText cfg)
    if r < 8 then return .replace p (← genSub cfg s.ctx false)
    return .wrapLazy p
  | .lazy pin _ =>
    let r ← below 10
    if r < 3 then return .unwrapLazy p
    if r < 6 then return (if pin.isSome then .unpin p else .pin p)
    -- edit inside the lazy body (deps follow unless pinned)
    let inner := ss.filter fun x => x.path.size > p.size && x.path.extract 0 p.size == p
    if inner.isEmpty then return .wrapLazy p
    let x ← pick inner
    return .setText x.path (← genText cfg)
  | .elem ns tag attrs kids =>
    let cc := childCtx s.ctx tag
    let r ← below 100
    if r < 14 && !isVoid tag then return .insert p (← below (kids.size + 1)) (← genSub cfg cc (keyedList kids))
    if r < 22 && !kids.isEmpty then return .delete p (← below kids.size)
    if r < 28 && kids.size ≥ 2 then return .move p (← below kids.size) (← below kids.size)
    if r < 32 && kids.size ≥ 2 then return .swap p (← below kids.size) (← below kids.size)
    if r < 34 && kids.size ≥ 2 then return .reverse p
    if r < 36 && kids.size ≥ 2 then return .rotate p (← between 1 kids.size)
    if r < 44 then
      let names := if s.ctx == .svg then attrNamesSvg else attrNamesHtml
      return .setAttr p (← pick names) (← genString valuePieces 2)
    if r < 48 then
      match attrs.findSome? (fun | .attr n _ => some n | _ => none) with
      | some n => return .delAttr p n
      | none => return .setAttr p "class" "c"
    if r < 53 && ns == .html then let (n, v) ← genProp tag; return .setProp p n v
    if r < 55 then
      match attrs.findSome? (fun | .prop n _ => some n | _ => none) with
      | some n => return .delProp p n
      | none => return .rotateAttrs p 1
    if r < 63 then
      -- usually a new handler for an event the element already has
      let ev? ← match attrs.findSome? (fun | .on l => some l.event | _ => none) with
        | some e => do if ← chance 60 then pure (some e) else pure none
        | none => pure none
      return .setOn p (← genListener ev?)
    if r < 66 then
      match attrs.findSome? (fun | .on l => some l.event | _ => none) with
      | some e => return .delOn p e
      | none => return .setOn p (← genListener)
    if r < 70 then return .retag p (← pick (tagsFor cfg s.ctx !kids.isEmpty))
    if r < 71 && s.ctx == .flow && (← chance 50) then return .renamespace p (if ns == .html then .svg else .html)
    if r < 75 && !kids.isEmpty then return .keyAll p (← pick #["k", "q", "n"])
    if r < 78 && !kids.isEmpty then return .unkeyAll p
    if r < 84 && !kids.isEmpty then
      let k ← if ← chance 50 then pick keyPool else freshKey
      return .setKey p (← below kids.size) (if ← chance 15 then none else some k)
    if r < 87 then return .rotateAttrs p (← between 1 4)
    if r < 90 && !p.isEmpty then return .replace p (← genSub cfg s.ctx false)
    if r < 93 then return .wrapLazy p
    if r < 97 && (cfg.dupAttrPct > 0 || cfg.dupOnPct > 0) then
      if ← chance 50 then
        match attrs.findSome? (fun | .attr n _ => some n | _ => none) with
        | some n => return .addAttr p (.attr n (← genString valuePieces 2))
        | none => return .addAttr p (.attr "class" "dup")
      else
        match attrs.findSome? (fun | .on l => some l.event | _ => none) with
        | some e => return .addAttr p (.on (← genListener (some e)))
        | none => return .addAttr p (.on (← genListener))
    return .setAttr p "data-x" (← genString valuePieces 1)

/-- `n` edits, each aimed at the tree the previous ones produced. -/
def genEdits (cfg : Config) (t : T) (n : Nat) : G (Array Edit) := do
  let mut cur := t
  let mut out := #[]
  for _ in [0:n] do
    let e ← genEdit cfg cur
    out := out.push e
    cur := e.apply cur
  return out

/-! ## Rows (scale tests) -/

/-- A keyed row like js-framework-benchmark's: `li` with a key, a class, a click listener, a label
and a nested element. -/
def row (id : Nat) (label : String) (selected : Bool := false) : T :=
  .elem .html "li" #[.key s!"r{id}", .attr "class" (if selected then "danger" else "row"),
    .on { event := "click", id := id }] #[.text label, .elem .html "b" #[] #[.text (toString id)]]

def rows (ids : Array Nat) (labelOf : Nat → String := fun i => s!"row {i}") : T :=
  .elem .html "ul" #[.attr "id" "rows"] (ids.map fun i => row i (labelOf i))

/-- The same rows, each wrapped in a lazy node whose deps are its content hash. -/
def lazyRows (ids : Array Nat) (labelOf : Nat → String := fun i => s!"row {i}") : T :=
  .elem .html "ul" #[.attr "id" "rows"] (ids.map fun i => .lazy none (row i (labelOf i)))

def shuffleArr {α : Type} (xs : Array α) : G (Array α) := do
  let mut a := xs
  for i in [0:a.size] do a := a.swapIfInBounds i (i + (← below (a.size - i)))
  return a

end LeanUI.Testing
