module
public import LeanUI.Render
public import LeanUI.Testing.Spec
/-!
# Server rendering: a parser for `Html.render` output, and hydration in the DOM model

`parse` reads the HTML `LeanUI.Render` writes the way a browser's HTML parser would, for the
constructs Render can produce: tags, quoted attributes, text, comments, void elements and
character references. It also models the parser rules that make a naive round trip lossy:

* input preprocessing: `\r\n` and `\r` become `\n` (also inside attribute values);
* tag and attribute names are ASCII-lowercased;
* a repeated attribute keeps its *first* value (the DOM's `setAttribute` keeps the last);
* a line feed right after `<pre>`, `<listing>` or `<textarea>` is dropped;
* `textarea` and `title` are RCDATA (comments inside are text), `script`, `style` and
  friends are raw text (no character references either).

Tree-construction rules that move nodes (a `<p>` closed by a block, nested `<a>`, `<li>`
outside a list, table foster parenting, breaking out of SVG) are not modeled; `hazards` lints
a view for them instead, so the property is: *a view with no hazard round-trips exactly.*

`claims` walks the parsed nodes the way `runtime/leanui.js` hydrates (pre-order, `<!--t-->`
becomes an empty text, other comments are skipped), and `hydrateDom` builds the DOM model the
browser would hold, with handles 1..N in pre-order.
-/
public section
namespace LeanUI.Testing.Ssr

inductive PNode where
  | elem (tag : String) (attrs : Array (String × String)) (kids : Array PNode)
  | text (s : String)
  | comment (s : String)
  deriving Inhabited, Repr

def rawTextTags : List String := ["script", "style", "xmp", "iframe", "noembed", "noframes"]
/-- MathML text integration points: their element children are parsed as HTML. -/
def mathTextPoints : List String := ["mi", "mo", "mn", "ms", "mtext"]
def rcdataTags : List String := ["textarea", "title"]
def lfDroppingTags : List String := ["pre", "listing", "textarea"]

private def lower (s : String) : String := s.map Char.toLower

/-- `\r\n` and lone `\r` become `\n` (HTML input stream preprocessing). -/
def normalizeNewlines (b : ByteArray) : ByteArray := Id.run do
  let mut out := ByteArray.emptyWithCapacity b.size
  let mut i := 0
  while i < b.size do
    let c := b[i]!
    if c == 13 then
      out := out.push 10
      if i + 1 < b.size && b[i + 1]! == 10 then i := i + 1
    else out := out.push c
    i := i + 1
  return out

/-- Decode the character references Render writes (and numeric ones); anything else is kept. -/
def decodeEntities (s : String) : String := Id.run do
  if !s.contains '&' then return s
  let cs := s.toList.toArray
  let mut out := ""
  let mut i := 0
  while i < cs.size do
    let c := cs[i]!
    if c != '&' then out := out.push c; i := i + 1; continue
    -- find the terminating ';' within a short window
    let mut j := i + 1
    while j < cs.size && j < i + 12 && cs[j]! != ';' && cs[j]! != '&' do j := j + 1
    if j < cs.size && cs[j]! == ';' then
      let name := String.ofList (cs.extract (i + 1) j).toList
      let rep : Option String :=
        if name == "amp" then some "&" else if name == "lt" then some "<" else if name == "gt" then some ">"
        else if name == "quot" then some "\"" else if name == "apos" then some "'"
        else if name.startsWith "#x" || name.startsWith "#X" then
          ((name.drop 2).toString.foldl (fun acc ch => acc.bind fun n =>
              if ch.isDigit then some (n * 16 + (ch.toNat - '0'.toNat))
              else if 'a' ≤ ch.toLower && ch.toLower ≤ 'f' then some (n * 16 + (ch.toLower.toNat - 'a'.toNat + 10))
              else none) (some 0)).map fun n => String.singleton (Char.ofNat n)
        else if name.startsWith "#" then ((name.drop 1).toString.toNat?).map fun n => String.singleton (Char.ofNat n)
        else none
      match rep with
      | some r => out := out ++ r; i := j + 1
      | none => out := out.push c; i := i + 1
    else out := out.push c; i := i + 1
  return out

private def isNameByte (c : UInt8) : Bool :=
  (c ≥ 97 && c ≤ 122) || (c ≥ 65 && c ≤ 90) || (c ≥ 48 && c ≤ 57) || c == 45 || c == 95 || c == 58 || c == 46

private def str (b : ByteArray) (i j : Nat) : String := String.fromUTF8! (b.extract i j)

private def startsAt (b : ByteArray) (i : Nat) (pat : String) : Bool := Id.run do
  let p := pat.toUTF8
  if i + p.size > b.size then return false
  for k in [0:p.size] do
    if b[i + k]! != p[k]! then return false
  return true

/-- Position of `</tag` (ASCII case-insensitive) at or after `i`. -/
private def findEndTag (b : ByteArray) (i : Nat) (tag : String) : Option Nat := Id.run do
  let p := ("</" ++ tag).toUTF8
  let mut k := i
  while k + p.size ≤ b.size do
    let mut ok := true
    for m in [0:p.size] do
      let c := b[k + m]!
      let c := if c ≥ 65 && c ≤ 90 then c + 32 else c
      if c != p[m]! then ok := false; break
    if ok then return some k
    k := k + 1
  return none

structure Open where
  tag : String
  attrs : Array (String × String)
  kids : Array PNode
  deriving Inhabited

private def pushKid (stack : Array Open) (n : PNode) : Array Open :=
  stack.modify (stack.size - 1) fun o =>
    match n, o.kids.back? with
    | .text t, some (.text s) => { o with kids := o.kids.pop.push (.text (s ++ t)) }
    | _, _ => { o with kids := o.kids.push n }

/-- Parse Render's output (the container's inner HTML) into its top-level nodes. -/
def parse (html : String) : Except String (Array PNode) := do
  let b := normalizeNewlines html.toUTF8
  let mut stack : Array Open := #[{ tag := "#container", attrs := #[], kids := #[] }]
  let mut i := 0
  -- set after a start tag whose first line feed the parser drops
  let mut dropLF := false
  while i < b.size do
    if dropLF then
      dropLF := false
      if b[i]! == 10 then i := i + 1; continue
    if b[i]! != 60 then
      let mut j := i
      while j < b.size && b[j]! != 60 do j := j + 1
      stack := pushKid stack (.text (decodeEntities (str b i j)))
      i := j
      continue
    if startsAt b i "<!--" then
      let mut j := i + 4
      while j + 2 < b.size && !(b[j]! == 45 && b[j + 1]! == 45 && b[j + 2]! == 62) do j := j + 1
      if j + 2 ≥ b.size then throw s!"unterminated comment at byte {i}"
      stack := pushKid stack (.comment (str b (i + 4) j))
      i := j + 3
      continue
    if i + 1 < b.size && b[i + 1]! == 47 then
      let mut j := i + 2
      while j < b.size && isNameByte b[j]! do j := j + 1
      let tag := lower (str b (i + 2) j)
      if j ≥ b.size || b[j]! != 62 then throw s!"malformed end tag at byte {i}"
      if stack.size ≤ 1 then throw s!"end tag </{tag}> with nothing open at byte {i}"
      let top := stack.back!
      if top.tag != tag then throw s!"end tag </{tag}> closes <{top.tag}> at byte {i}"
      stack := pushKid stack.pop (.elem top.tag top.attrs top.kids)
      i := j + 1
      continue
    -- start tag
    let mut j := i + 1
    while j < b.size && isNameByte b[j]! do j := j + 1
    if j == i + 1 then throw s!"malformed tag at byte {i}"
    let tag := lower (str b (i + 1) j)
    let mut attrs : Array (String × String) := #[]
    let mut done := false
    while !done do
      while j < b.size && (b[j]! == 32 || b[j]! == 10 || b[j]! == 9) do j := j + 1
      if j ≥ b.size then throw s!"unterminated tag <{tag}> at byte {i}"
      if b[j]! == 62 then j := j + 1; done := true; continue
      if b[j]! == 47 && j + 1 < b.size && b[j + 1]! == 62 then j := j + 2; done := true; continue
      let k := j
      while j < b.size && b[j]! != 61 && b[j]! != 32 && b[j]! != 62 && b[j]! != 47 && b[j]! != 10 do j := j + 1
      if j == k then throw s!"malformed attribute in <{tag}> at byte {j}"
      let name := lower (str b k j)
      let mut value := ""
      if j < b.size && b[j]! == 61 then
        j := j + 1
        if j < b.size && b[j]! == 34 then
          let v := j + 1
          j := v
          while j < b.size && b[j]! != 34 do j := j + 1
          if j ≥ b.size then throw s!"unterminated attribute value in <{tag}>"
          value := decodeEntities (str b v j)
          j := j + 1
        else
          let v := j
          while j < b.size && b[j]! != 32 && b[j]! != 62 do j := j + 1
          value := decodeEntities (str b v j)
      -- the HTML parser keeps the first of repeated attributes
      if !(attrs.any (·.1 == name)) then attrs := attrs.push (name, value)
    i := j
    if voidElements.contains tag then
      stack := pushKid stack (.elem tag attrs #[])
    else if rawTextTags.contains tag || rcdataTags.contains tag then
      let some e := findEndTag b i tag | throw s!"unterminated <{tag}>"
      let start := if tag == "textarea" && i < b.size && b[i]! == 10 then i + 1 else i
      let raw := str b start e
      let txt := if rcdataTags.contains tag then decodeEntities raw else raw
      stack := pushKid stack (.elem tag attrs (if txt.isEmpty then #[] else #[.text txt]))
      let mut q := e + 2
      while q < b.size && b[q]! != 62 do q := q + 1
      i := q + 1
    else
      stack := stack.push { tag, attrs, kids := #[] }
      if lfDroppingTags.contains tag then dropLF := true
  if stack.size != 1 then throw s!"unclosed <{stack.back!.tag}> at end of input"
  return stack[0]!.kids

/-! ## Hydration -/

/-- One node the hydration walk claims: an element (namespace code by the parser's rules, tag,
attributes) or a text. -/
inductive Claim where
  | elem (ns : UInt32) (tag : String) (attrs : Array (String × String))
  | text (s : String)
  deriving Inhabited, BEq, Repr

/-- The nodes the browser's hydration walk claims, in pre-order, with their parent's index. -/
partial def claims (ns : UInt32 := 0) (parentTag : String := "") (parent : Option Nat := none)
    (acc : Array (Claim × Option Nat)) (nodes : Array PNode) : Array (Claim × Option Nat) :=
  nodes.foldl (init := acc) fun acc n => match n with
    | .comment "t" => acc.push (.text "", parent)
    | .comment _ => acc
    | .text s => acc.push (.text s, parent)
    | .elem tag attrs kids =>
      -- namespaces the way the HTML parser assigns them: HTML integration points (SVG
      -- foreignObject/desc/title) and MathML text integration points (mi, mo, mn, ms, mtext)
      -- parse their element children as HTML
      let integration := (ns == 1 && ["foreignobject", "desc", "title"].contains parentTag) ||
        (ns == 2 && mathTextPoints.contains parentTag && !["mglyph", "malignmark"].contains tag)
      let myNs : UInt32 := if ns == 0 || integration then (if tag == "svg" then 1 else if tag == "math" then 2 else 0)
        else ns
      let me := acc.size
      claims myNs tag (some me) (acc.push (.elem myNs tag attrs, parent)) kids

/-- What `mount` allocates for a view, in pre-order: the same shape as `claims`, with the
attributes the server rendering *should* produce (the DOM's attributes, plus properties
rendered as initial attributes). -/
partial def expectedClaims (t : T) (acc : Array Claim := #[]) (withProps := true) : Array Claim :=
  match t with
  | .lazy _ b => expectedClaims b acc withProps
  | .text s => acc.push (.text s)
  | .elem ns tag attrs kids =>
    let as := effAttrs attrs
    let ps := if !withProps then #[] else (effProps attrs).filterMap fun (n, v) =>
      if as.any (·.1 == n) then none else match v with
        | .str s => some (n, s) | .bool true => some (n, "") | .bool false => none | .num q => some (n, toString (Float.ofInt q / 4))
    let acc := acc.push (.elem ns.code tag (as ++ ps))
    (effectiveKids tag kids).foldl (fun acc k => expectedClaims k acc withProps) acc

def sortAttrs (as : Array (String × String)) : Array (String × String) := as.qsort (fun a b => a.1 < b.1)

def Claim.show : Claim → String
  | .elem ns tag as => s!"<{ns}:{tag} {sortAttrs as}>"
  | .text s => s!"text {s.quote}"

/-- The DOM model a browser holds after loading the server-rendered page and hydrating it:
handles 1..N in pre-order, the root mounted at `sel`. `view` is the view's own attributes in
pre-order (`expectedClaims (withProps := false)`); attributes the page has beyond those came from
properties, and are returned per handle (the engine does not know about them). -/
def hydrateDom (sel : String) (cs : Array (Claim × Option Nat)) (view : Array Claim) :
    Dom × Std.HashMap UInt32 (Array String) := Id.run do
  let mut d : Dom := { roots := #[(sel, 1)] }
  let mut ghosts : Std.HashMap UInt32 (Array String) := {}
  for h : i in [0:cs.size] do
    let (c, p) := cs[i]
    let hdl := (i + 1).toUInt32
    let parent := p.map fun j => (j + 1).toUInt32
    match c with
    | .text s => d := d.put hdl { isText := true, text := s, parent }
    | .elem ns tag as =>
      d := d.put hdl { ns, tag, attrs := as, parent }
      match view[i]? with
      | some (.elem _ _ vas) =>
        let g := as.filterMap fun (n, _) => if vas.any (·.1 == n) then none else some n
        if !g.isEmpty then ghosts := ghosts.insert hdl g
      | _ => pure ()
    if let some ph := parent then
      d := d.put ph { d.get ph with kids := (d.get ph).kids.push hdl }
  return (d, ghosts)

/-! ## The hazard lint -/

/-- Start tags that close an open `<p>` in button scope (HTML tree construction, "in body"). -/
def blockTags : List String :=
  ["address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div", "dl", "fieldset",
   "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr",
   "main", "menu", "nav", "ol", "p", "pre", "search", "section", "summary", "table", "ul", "listing", "xmp",
   "plaintext", "li", "dd", "dt"]

/-- Elements that bound "button scope" (besides foreign content). -/
def buttonScope : List String :=
  ["button", "applet", "caption", "html", "table", "td", "th", "marquee", "object", "template"]

/-- Reasons the HTML parser would not rebuild exactly the nodes `mount` allocates for `t`.
`ancestors` are the tags above, nearest first. -/
partial def hazards (t : T) (ancestors : List (Ns × String) := []) : Array String :=
  match t with
  | .lazy _ b => hazards b ancestors
  | .text _ => #[]
  | .elem ns tag attrs kids => Id.run do
    let mut out := #[]
    let parent := ancestors.head?
    let forced := kids.map T.force
    if tag.any Char.isUpper then out := out.push s!"uppercase in tag <{tag}>"
    let names := (attrs.filterMap fun | .attr n _ => some n | .prop n _ => some n | _ => none)
    for n in names do
      if n.any Char.isUpper then out := out.push s!"uppercase in attribute {n}"
    -- (Render writes repeated attributes once, the last; `\r` as `&#13;`; and protects a leading
    -- line feed in <pre>/<textarea>/<listing>, so none of those is a hazard)
    if ns == .html && isVoid tag && !kids.isEmpty then out := out.push s!"children under void <{tag}>"
    if ns == .html && (rawTextTags.contains tag || rcdataTags.contains tag) then
      if forced.size > 1 || forced.any (fun k => match k with | T.text _ => false | _ => true) then
        out := out.push s!"<{tag}> holds text only (RCDATA/raw text)"
      else
        match forced[0]? with
        | some (T.text s) =>
          if s.isEmpty then out := out.push s!"empty text in <{tag}>"
          else if rawTextTags.contains tag && (s.any fun c => c == '&' || c == '<' || c == '>') then
            out := out.push s!"escaped characters in raw text <{tag}>"
        | _ => pure ()
    -- tree construction
    if ns == .html then
      let inScope (tg : String) (stop : List String) : Bool := Id.run do
        for (n, a) in ancestors do
          if n != .html then return false
          if a == tg then return true
          if stop.contains a then return false
        return false
      -- a block start tag closes any <p> open in button scope, not only a parent <p>
      if blockTags.contains tag && inScope "p" buttonScope then out := out.push s!"<{tag}> inside <p> closes it"
      if tag == "a" && inScope "a" [] then out := out.push "<a> inside <a>"
      if tag == "button" && inScope "button" [] then out := out.push "<button> inside <button>"
      if tag == "li" && inScope "li" ["ul", "ol"] then out := out.push "<li> inside <li>"
      if ["table", "tr", "td", "th", "tbody", "thead", "tfoot", "caption", "col", "colgroup"].contains tag then
        out := out.push s!"table markup <{tag}> (foster parenting, implied tbody)"
      if ["option", "optgroup", "select", "dd", "dt", "rb", "rt", "rp", "h1", "h2", "h3", "h4", "h5", "h6", "form",
          "html", "head", "body", "frameset", "frame", "template", "math", "svg"].contains tag && tag != "math" && tag != "svg" then
        out := out.push s!"<{tag}> has implied end tags or a special insertion mode"
      if parent.any (fun (n, a) => n == .svg && a != "foreignObject") then
        out := out.push s!"HTML <{tag}> inside SVG"
      if parent.any (fun (n, a) => n == .mathml && !mathTextPoints.contains a) then out := out.push s!"HTML <{tag}> inside MathML"
    if ns == .svg && tag != "svg" && !(parent.any fun (n, _) => n == .svg) then
      out := out.push s!"SVG <{tag}> outside <svg>"
    if ns == .svg && tag == "svg" && parent.any (fun (n, _) => n == .svg) then pure ()
    if ns == .mathml && tag != "math" && !(parent.any fun (n, _) => n == .mathml) then
      out := out.push s!"MathML <{tag}> outside <math>"
    if ns != .html && parent.any (fun (n, a) => n == .mathml && mathTextPoints.contains a) &&
        !["mglyph", "malignmark"].contains tag then
      out := out.push s!"<{tag}> inside a MathML text integration point (parsed as HTML)"
    if ns == .svg && ["foreignObject", "desc", "title"].contains tag then out := out.push s!"SVG HTML integration point <{tag}>"
    if (ns == .html && tag == "svg") || (ns == .html && tag == "math") then out := out.push s!"<{tag}> in the HTML namespace"
    if ns == .svg && tag == "svg" && parent.any (fun (n, _) => n == .html) then pure ()
    for k in kids do out := out ++ hazards k ((ns, tag) :: ancestors)
    return out

/-! ## The round-trip property -/

structure Report where
  html : String
  claims : Array (Claim × Option Nat) := #[]
  failures : Array String := #[]

/-- Render `t`, parse it back and compare the hydration walk with what `mount` allocates:
node count (`countNodes`, `mount`), kinds, namespaces, tags, texts, attributes. -/
def roundTrip (t : T) : Report := Id.run do
  let v := t.toHtml'
  let html := v.render
  match parse html with
  | .error e => return { html, failures := #[s!"parse: {e}"] }
  | .ok nodes =>
    let cs := claims 0 "" none #[] nodes
    let want := expectedClaims t
    let mut out := #[]
    let counted := countNodes v
    let allocated := ((mount v).run ({} : DiffState String)).2.nextNode.toNat - 1
    if cs.size != counted then out := out.push s!"hydration walk finds {cs.size} nodes, countNodes says {counted}"
    if allocated != counted then out := out.push s!"mount allocates {allocated} nodes, countNodes says {counted}"
    if want.size != counted then out := out.push s!"the view has {want.size} nodes, countNodes says {counted}"
    for i in [0:min cs.size want.size] do
      let got := cs[i]!.1
      let exp := want[i]!
      let same := match got, exp with
        | .elem n t a, .elem n' t' a' => n == n' && t == t' && sortAttrs a == sortAttrs a'
        | .text a, .text b => a == b
        | _, _ => false
      if !same then
        out := out.push s!"node {i + 1}: parsed {got.show}, mount makes {exp.show}"
        break
    return { html, claims := cs, failures := out }

end LeanUI.Testing.Ssr

namespace LeanUI.Testing.Session

open Ssr in
/-- Start a session the way a server-rendered page does: render `t`, parse it into the DOM model
(the browser's HTML parser), then `App.initState` with hydrate = true and apply its buffer. -/
def hydrate (c : IO.Ref Nat) (t : T) (recording := false) : IO (Session × Array String × Nat) := do
  let rep := roundTrip t
  if !rep.failures.isEmpty then
    return ({ diff := {}, node := default, dom := {}, shadow := {}, eff := t, renders := c }, rep.failures.map ("ssr: " ++ ·), 0)
  let (dom, ghosts) := hydrateDom "#app" rep.claims (expectedClaims t (withProps := false))
  let r0 ← c.get
  let st ← IO.lazyPure fun _ => initState (staticProgram c t) "" "#app" true
  let r1 ← c.get
  let (eff, want) := (mountS t).run 0
  let mut fails := #[]
  let n := rep.claims.size
  -- the buffer starts with the hydrate claim
  match Wire.decode st.diff.buf.ops st.diff.buf.strs with
  | .ok cmds =>
    match cmds[0]?.map (·.op) with
    | some (Wire.WOp.hydrate sel first count) =>
      if sel != "#app" || first != 1 || count.toNat != n then
        fails := fails.push s!"hydrate: claims ({sel}, {first}, {count}), the page has {n} nodes"
    | _ => fails := fails.push "hydrate: the buffer does not start with HYDRATE"
    for c in cmds do
      match c.op with
      | .createElement .. | .createText .. | .appendChild .. | .insertBefore .. | .setAttr .. | .mount .. =>
        fails := fails.push s!"hydrate: {c.op.name} while hydrating (the nodes exist already)"; break
      | _ => pure ()
  | .error e => fails := fails.push s!"hydrate: {e}"
  let s : Session := { diff := st.diff, node := st.tree, dom, shadow := Wire.Shadow.ofDom dom, eff, renders := c, ghosts, recording }
  let s := s.flush "hydrate"
  fails := fails ++ s.check "hydrate"
  -- `initState` forces each lazy thunk twice while hydrating (countNodes, then mount)
  return (s, fails, (r1 - r0) - want)

end LeanUI.Testing.Session

namespace LeanUI.Testing.Ssr

/-- What the browser's parse of `Html.render t` must hold for the round trip to be exact, in
`strictDom` form without listeners or properties: the nodes `mount` creates, with the
attributes the server rendering writes. -/
partial def ssrCanon : T → String
  | .lazy _ b => ssrCanon b
  | .text s => "#" ++ lp s
  | .elem ns tag attrs kids =>
    match expectedClaims (.elem ns tag attrs #[]) with
    | #[.elem _ _ as] => canonElem ns.code tag as #[] #[] (String.join (kids.toList.map ssrCanon))
    | _ => ""

/-- The same form for what this module's parser model makes of `html` (the browser's parse
is compared against both). -/
def modelCanon (html : String) : Option String :=
  match parse html with
  | .error _ => none
  | .ok nodes =>
    let cs := claims 0 "" none #[] nodes
    if cs.isEmpty then none
    else
      let (d, _) := hydrateDom "#app" cs #[]
      some (strictDom d 1)

end LeanUI.Testing.Ssr
