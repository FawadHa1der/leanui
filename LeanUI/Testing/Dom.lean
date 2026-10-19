module
public import Std.Data.HashMap
public import LeanUI.Html
public import LeanUI.Patch
/-!
# A DOM model for native tests

`Dom.apply` executes a command buffer against a pure model of the DOM, exactly as the browser
runtime (`runtime/leanui.js`) does: it decodes the 32-bit words and the UTF-16 string slices,
keeps a node table with parent links, attributes, properties and listeners, and logs effects. It
lets the whole engine (diff, protocol, runtime) be tested without a browser, and it is the
reference the browser runtime is checked against.
-/
public section
namespace LeanUI.Testing

structure DNode where
  isText : Bool := false
  ns : UInt32 := 0
  tag : String := ""
  text : String := ""
  attrs : Array (String × String) := #[]
  props : Array (String × String) := #[]
  kids : Array UInt32 := #[]
  parent : Option UInt32 := none
  /-- event name → (slot, payload code, flags) -/
  listeners : Array (String × UInt32 × UInt32 × UInt32) := #[]
  deriving Inhabited

/-- A template the browser holds (`TEMPLATE`): what `cloneNode(true)` copies, as the model sees
it: namespaces, tags, attributes and texts (no properties, no listeners). -/
inductive Snap where
  | text (s : String)
  | elem (ns : UInt32) (tag : String) (attrs : Array (String × String)) (kids : Array Snap)
  deriving Inhabited

partial def Snap.size : Snap → Nat
  | .text _ => 1
  | .elem _ _ _ kids => kids.foldl (fun n k => n + k.size) 1

structure Dom where
  nodes : Std.HashMap UInt32 DNode := {}
  names : Std.HashMap UInt32 String := {}
  /-- container selector → mounted root handle -/
  roots : Array (String × UInt32) := #[]
  /-- Effect commands, rendered as text, in order. -/
  effects : Array String := #[]
  /-- Protocol violations found while applying (a correct engine produces none). -/
  errors : Array String := #[]
  /-- Templates by id. -/
  templates : Std.HashMap UInt32 Snap := {}
  deriving Inhabited

/-- The string area as UTF-16 code units (what JavaScript slices). -/
def utf16Units (strs : ByteArray) : Array UInt16 := Id.run do
  let s := String.fromUTF8! strs
  let mut out := Array.mkEmpty strs.size
  for c in s.toList do
    let v := c.val
    if v < 0x10000 then out := out.push v.toUInt16
    else
      let w := v - 0x10000
      out := out.push ((0xD800 : UInt32) + (w >>> 10)).toUInt16 |>.push ((0xDC00 : UInt32) + (w &&& 0x3FF)).toUInt16
  return out

def fromUnits (us : Array UInt16) (off len : Nat) : String := Id.run do
  let mut s := ""
  let mut i := off
  while i < off + len do
    let u := us[i]!.toUInt32
    if u >= 0xD800 && u < 0xDC00 && i + 1 < off + len then
      let lo := us[i + 1]!.toUInt32
      s := s.push (Char.ofNat ((((u - 0xD800) <<< 10) ||| (lo - 0xDC00)) + 0x10000).toNat)
      i := i + 2
    else
      s := s.push (Char.ofNat u.toNat); i := i + 1
  return s

namespace Dom

def get (d : Dom) (h : UInt32) : DNode := d.nodes.getD h default
def put (d : Dom) (h : UInt32) (n : DNode) : Dom := { d with nodes := d.nodes.insert h n }
/-- Update a node in place (reading it with `get` and writing it back would share its child
array with the map, so every append would copy it: quadratic on a wide parent). -/
@[inline] def upd (d : Dom) (h : UInt32) (f : DNode → DNode) : Dom :=
  if d.nodes.contains h then { d with nodes := d.nodes.modify h f } else d.put h (f default)
def err (d : Dom) (m : String) : Dom := { d with errors := d.errors.push m }

def detach (d : Dom) (c : UInt32) : Dom :=
  match (d.get c).parent with
  | none => d
  | some p =>
    let d := d.upd p fun pn => { pn with kids := pn.kids.filter (· != c) }
    d.upd c fun n => { n with parent := none }

/-- Is `h` in the document, i.e. does its parent chain end at a mounted root? -/
partial def attached (d : Dom) (h : UInt32) (fuel : Nat := 100000) : Bool :=
  if d.roots.any (·.2 == h) then true
  else match fuel, (d.get h).parent with
    | 0, _ => false
    | _, none => false
    | f + 1, some p => d.attached p f

def setKV (xs : Array (String × String)) (k v : String) : Array (String × String) :=
  if xs.any (·.1 == k) then xs.map fun (a, b) => if a == k then (a, v) else (a, b) else xs.push (k, v)

/-- The handles of a subtree in pre-order. -/
partial def preorderOf (d : Dom) (h : UInt32) (acc : Array UInt32 := #[]) : Array UInt32 :=
  (d.get h).kids.foldl (fun acc k => d.preorderOf k acc) (acc.push h)

/-- What `cloneNode(true)` of `h` copies. -/
partial def snap (d : Dom) (h : UInt32) : Snap :=
  let n := d.get h
  if n.isText then .text n.text else .elem n.ns n.tag n.attrs (n.kids.map d.snap)

/-- Create the nodes of a copy of `t` at the handles `hs[i..]` (pre-order); returns the next index. -/
partial def instantiate (d : Dom) (hs : Array UInt32) (t : Snap) (parent : Option UInt32) (i : Nat) : Dom × Nat :=
  let h := hs[i]!
  match t with
  | .text s => (d.put h { isText := true, text := s, parent }, i + 1)
  | .elem ns tag attrs kids =>
    let (d, j, ks) := kids.foldl (init := (d, i + 1, (#[] : Array UInt32))) fun (d, j, ks) k =>
      let (d, j') := d.instantiate hs k (some h) j
      (d, j', ks.push hs[j]!)
    (d.put h { ns, tag, attrs, kids := ks, parent }, j)

/-- Apply one command buffer. -/
def apply (d : Dom) (ops strs : ByteArray) : Dom := Id.run do
  let us := utf16Units strs
  let word (i : Nat) : UInt32 :=
    ops[i]!.toUInt32 ||| (ops[i+1]!.toUInt32 <<< 8) ||| (ops[i+2]!.toUInt32 <<< 16) ||| (ops[i+3]!.toUInt32 <<< 24)
  let mut d := d
  let mut pc := 0
  let n := ops.size
  let str (i : Nat) : String := fromUnits us (word i).toNat (word (i + 4)).toNat
  while pc < n do
    let op := word pc
    let a := word (pc + 4)
    if op == Op.createElement then
      d := d.put a { ns := word (pc + 8), tag := d.names.getD (word (pc + 12)) "?" }; pc := pc + 16
    else if op == Op.createText then
      d := d.put a { isText := true, text := str (pc + 8) }; pc := pc + 16
    else if op == Op.setAttr then
      let nd := d.get a; d := d.put a { nd with attrs := setKV nd.attrs (d.names.getD (word (pc + 8)) "?") (str (pc + 12)) }; pc := pc + 20
    else if op == Op.removeAttr then
      let nd := d.get a; let k := d.names.getD (word (pc + 8)) "?"; d := d.put a { nd with attrs := nd.attrs.filter (·.1 != k) }; pc := pc + 12
    else if op == Op.setPropStr || op == Op.setPropNum then
      let nd := d.get a; d := d.put a { nd with props := setKV nd.props (d.names.getD (word (pc + 8)) "?") (str (pc + 12)) }; pc := pc + 20
    else if op == Op.setPropBool then
      let nd := d.get a
      d := d.put a { nd with props := setKV nd.props (d.names.getD (word (pc + 8)) "?") (if word (pc + 12) == 1 then "true" else "false") }; pc := pc + 16
    else if op == Op.removeProp then
      let nd := d.get a; let k := d.names.getD (word (pc + 8)) "?"; d := d.put a { nd with props := nd.props.filter (·.1 != k) }; pc := pc + 12
    else if op == Op.setText then
      d := d.put a { d.get a with text := str (pc + 8) }; pc := pc + 16
    else if op == Op.appendChild then
      let c := word (pc + 8)
      d := d.detach c
      d := d.upd a fun n => { n with kids := n.kids.push c }
      d := d.upd c fun n => { n with parent := some a }; pc := pc + 12
    else if op == Op.insertBefore then
      let c := word (pc + 8); let r := word (pc + 12)
      d := d.detach c
      match (d.get a).kids.idxOf? r with
      | some i => d := d.upd a fun pn => { pn with kids := pn.kids.insertIdxIfInBounds i c }
      | none => d := (d.err s!"insertBefore: {r} is not a child of {a}").upd a fun pn => { pn with kids := pn.kids.push c }
      d := d.upd c fun n => { n with parent := some a }; pc := pc + 16
    else if op == Op.remove then
      d := d.detach a; pc := pc + 8
    else if op == Op.replace then
      let nw := word (pc + 8)
      d := d.detach nw
      match (d.get a).parent with
      | some p =>
        let pn := d.get p
        d := d.put p { pn with kids := pn.kids.map fun k => if k == a then nw else k }
        d := d.put nw { d.get nw with parent := some p }
        d := d.put a { d.get a with parent := none }
      | none =>
        -- a mounted root being replaced
        d := { d with roots := d.roots.map fun (sel, r) => if r == a then (sel, nw) else (sel, r) }
      pc := pc + 12
    else if op == Op.free then
      -- freeing a node inside a removed (detached) subtree is fine; freeing one still in the
      -- document is a protocol error
      if d.attached a then d := d.err s!"free: {a} is still in the document"
      d := { d with nodes := d.nodes.erase a }; pc := pc + 8
    else if op == Op.setListener then
      let ev := d.names.getD (word (pc + 8)) "?"
      let nd := d.get a
      let l := (ev, word (pc + 12), word (pc + 16), word (pc + 20))
      d := d.put a { nd with listeners := (nd.listeners.filter (·.1 != ev)).push l }; pc := pc + 24
    else if op == Op.removeListener then
      let ev := d.names.getD (word (pc + 8)) "?"
      let nd := d.get a; d := d.put a { nd with listeners := nd.listeners.filter (·.1 != ev) }; pc := pc + 12
    else if op == Op.intern then
      d := { d with names := d.names.insert a (str (pc + 8)) }; pc := pc + 16
    else if op == Op.mount then
      let sel := str (pc + 4); let h := word (pc + 12)
      d := { d with roots := (d.roots.filter (·.1 != sel)).push (sel, h) }; pc := pc + 16
    else if op == Op.hydrate then
      d := { d with effects := d.effects.push s!"hydrate {str (pc + 4)} {word (pc + 12)} {word (pc + 16)}" }; pc := pc + 20
    else if op == Op.template || op == Op.clone then
      -- variable width: a count, then that many handles
      let base := pc + 8
      let count := (word base).toNat
      let hs := (Array.range count).map fun k => word (base + 4 + 4 * k)
      if op == Op.template then
        let pre := if hs.isEmpty then #[] else d.preorderOf hs[0]!
        if hs.isEmpty || pre != hs then d := d.err s!"template {a}: the handles are not the subtree of {hs[0]?.getD 0} in pre-order"
        else d := { d with templates := d.templates.insert a (d.snap hs[0]!) }
      else
        match d.templates.get? a with
        | none => d := d.err s!"clone: no template {a}"
        | some t =>
          if t.size != count then d := d.err s!"clone: template {a} has {t.size} nodes, not {count}"
          else d := (d.instantiate hs t none 0).1
      pc := base + 4 + 4 * count
    else if op == Op.fetch then
      d := { d with effects := d.effects.push s!"fetch cb={a} {str (pc + 8)} {str (pc + 16)}" }; pc := pc + 40
    else if op == Op.timeout || op == Op.intervalSet then
      d := { d with effects := d.effects.push s!"{if op == Op.timeout then "timeout" else "interval"} {a} {word (pc + 8)}" }; pc := pc + 12
    else if op == Op.intervalClear || op == Op.urlListen || op == Op.frame then
      d := { d with effects := d.effects.push s!"op{op} {a}" }; pc := pc + 8
    else if op == Op.storageSet then
      d := { d with effects := d.effects.push s!"storageSet {str (pc + 4)}={str (pc + 12)}" }; pc := pc + 20
    else if op == Op.storageGet then
      d := { d with effects := d.effects.push s!"storageGet cb={a} {str (pc + 8)}" }; pc := pc + 16
    else if op == Op.storageRemove || op == Op.urlPush || op == Op.urlReplace || op == Op.focus ||
        op == Op.log || op == Op.title || op == Op.blur || op == Op.scrollIntoView then
      d := { d with effects := d.effects.push s!"op{op} {str (pc + 4)}" }; pc := pc + 12
    else if op == Op.putImage then
      let e := s!"putImage {str (pc + 4)} blob={word (pc + 12)} {word (pc + 16)}x{word (pc + 20)} dirty={word (pc + 24)},{word (pc + 28)},{word (pc + 32)},{word (pc + 36)}"
      d := { d with effects := d.effects.push e }; pc := pc + 40
    else if op == Op.download then
      d := { d with effects := d.effects.push s!"download {str (pc + 4)} {str (pc + 12)} blob={word (pc + 20)}" }; pc := pc + 24
    else if op == Op.fileRead || op == Op.imageDecode then
      d := { d with effects := d.effects.push s!"{if op == Op.fileRead then "readFile" else "decodeImage"} cb={a} file={word (pc + 8)}" }; pc := pc + 12
    else if op == Op.keysListen then
      d := { d with effects := d.effects.push s!"op{op} {a}" }; pc := pc + 8
    else
      d := d.err s!"unknown opcode {op} at byte {pc}"; pc := n
  return d

/-- Canonical HTML of a subtree: attributes and properties merged and sorted, listeners
omitted. Comparable with `canonHtml` of the intended view. -/
partial def canon (d : Dom) (h : UInt32) : String :=
  let nd := d.get h
  if nd.isText then nd.text
  else
    let props : Array (String × String) := nd.props.map fun (p : String × String) => ("." ++ p.1, p.2)
    let kv := (nd.attrs ++ props).qsort (fun a b => a.1 < b.1)
    "<" ++ nd.tag ++ String.join (kv.toList.map fun (kv : String × String) => s!" {kv.1}={repr kv.2}") ++ ">" ++
      String.join (nd.kids.toList.map d.canon) ++ "</" ++ nd.tag ++ ">"

def rootOf (d : Dom) (sel : String) : Option UInt32 := (d.roots.find? (·.1 == sel)).map (·.2)

/-- Every node reachable from the mounted roots. -/
partial def reachable (d : Dom) (h : UInt32) : Array UInt32 :=
  (d.get h).kids.foldl (fun acc k => acc ++ d.reachable k) #[h]

end Dom

/-- Canonical HTML of a view (the same format as `Dom.canon`). -/
partial def canonHtml {Msg : Type} : Html Msg → String
  | .text s => s
  | .lazy _ _ r => canonHtml (r ())
  | .elem _ tag attrs kids =>
    let kv : Array (String × String) := attrs.filterMap fun
      | .attr k v => some (k, v)
      | .prop k (.str v) => some ("." ++ k, v)
      | .prop k (.bool b) => some ("." ++ k, if b then "true" else "false")
      | .prop k (.num x) => some ("." ++ k, toString x)
      | _ => none
    -- later attributes with the same name win, as in the DOM
    let kv := kv.foldl (fun acc (k, v) => Dom.setKV acc k v) #[]
    let kv := kv.qsort (fun a b => a.1 < b.1)
    "<" ++ tag ++ String.join (kv.toList.map fun (kv : String × String) => s!" {kv.1}={repr kv.2}") ++ ">" ++
      String.join (kids.toList.map canonHtml) ++ "</" ++ tag ++ ">"

end LeanUI.Testing
