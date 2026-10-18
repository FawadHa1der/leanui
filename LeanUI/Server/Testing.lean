module
public import LeanUI.Server.Site
public import LeanUI.Testing.Dom
/-!
# Testing server-driven apps natively

`Client` plays the browser against a `Route`, without a socket: it requests a page, parses the
server-rendered HTML, **claims** the container's nodes in pre-order exactly as
`runtime/leanui.js` hydrates them (skipping `<!--|-->`, turning `<!--t-->` into an empty text),
then speaks the remote protocol (`h`, `e`, `c` bodies) and applies every response to the
`LeanUI.Testing.Dom` model. So a test covers the whole server-driven path: SSR, the hydration
contract, the session actor, the protocol and the diff.

`parseHtml` reads the HTML that LeanUI pages are made of (elements, attributes, text with
character references, comments, raw-text `script`/`style`, void elements, a doctype).
-/
public section
namespace LeanUI.Server.Testing
open LeanUI.Testing

/-- A parsed HTML node. -/
inductive PNode where
  | elem (tag : String) (attrs : Array (String × String)) (kids : Array PNode)
  | text (s : String)
  | comment (s : String)
  deriving Inhabited, Repr

/-! ## Parsing -/

private def isSpace (c : Char) : Bool := c == ' ' || c == '\n' || c == '\t' || c == '\r' || c == '\x0c'

/-- Decode character references (`&amp;`, `&#60;`, `&#x3c;`, a few named ones). -/
def decodeEntities (s : String) : String := Id.run do
  if !s.contains '&' then return s
  let cs := s.toList.toArray
  let mut out := ""
  let mut i := 0
  while i < cs.size do
    if cs[i]! == '&' then
      let mut j := i + 1
      while j < cs.size && j < i + 12 && cs[j]! != ';' do j := j + 1
      if j < cs.size && cs[j]! == ';' then
        let name := String.ofList (cs.extract (i + 1) j).toList
        let ch : Option Char :=
          if name.startsWith "#x" || name.startsWith "#X" then
            ((name.drop 2).toString.foldl (fun acc c => acc.bind fun n =>
              if c.isDigit then some (n * 16 + (c.toNat - 48))
              else if 'a' ≤ c && c ≤ 'f' then some (n * 16 + (c.toNat - 87))
              else if 'A' ≤ c && c ≤ 'F' then some (n * 16 + (c.toNat - 55)) else none) (some 0)).map Char.ofNat
          else if name.startsWith "#" then ((name.drop 1).toString.toNat?).map Char.ofNat
          else match name with
            | "amp" => some '&' | "lt" => some '<' | "gt" => some '>' | "quot" => some '"'
            | "apos" => some '\'' | "nbsp" => some ' ' | _ => none
        match ch with
        | some c => out := out.push c; i := j + 1
        | none => out := out.push '&'; i := i + 1
      else out := out.push '&'; i := i + 1
    else out := out.push cs[i]!; i := i + 1
  return out

/-- Add an attribute unless one with that name exists: the HTML parser keeps the *first* of
duplicate attributes. -/
private def addAttr (as : Array (String × String)) (k v : String) : Array (String × String) :=
  if as.any (·.1 == k) then as else as.push (k, v)

private def rawText : List String := ["script", "style", "textarea", "title"]

/-- Parse an HTML document or fragment. Applies the HTML parser's rules that make a page differ
from the markup it was given, because hydration meets the *parsed* nodes: newlines are normalised
(`\r\n` and `\r` become `\n`; `&#13;` still yields `\r`), a newline right after `<pre>`,
`<listing>` or `<textarea>` is dropped, and of duplicate attributes the first is kept. -/
partial def parseHtml (src : String) : Except String (Array PNode) := do
  let src := (src.replace "\r\n" "\n").replace "\r" "\n"
  let cs := src.toList.toArray
  let n := cs.size
  let at? (i : Nat) (lit : String) : Bool :=
    let l := lit.toList.toArray
    i + l.size ≤ n && (List.range l.size).all fun k => (cs[i + k]!).toLower == l[k]!
  let find (i : Nat) (lit : String) : Option Nat := Id.run do
    let mut j := i
    while j < n do
      if at? j lit then return some j
      j := j + 1
    return none
  let str (a b : Nat) : String := String.ofList (cs.extract a b).toList
  -- stack of open elements: (tag, attrs, kids); the bottom entry collects the top level
  let mut stack : Array (String × Array (String × String) × Array PNode) := #[("", #[], #[])]
  let push (st : Array (String × Array (String × String) × Array PNode)) (node : PNode) :=
    let (t, a, k) := st.back!
    st.pop.push (t, a, k.push node)
  let mut i := 0
  let mut textStart := 0
  while i < n do
    if cs[i]! != '<' then i := i + 1; continue
    if textStart < i then stack := push stack (.text (decodeEntities (str textStart i)))
    if at? i "<!--" then
      let some e := find (i + 4) "-->" | throw "unterminated comment"
      stack := push stack (.comment (str (i + 4) e)); i := e + 3; textStart := i; continue
    if at? i "<!" || at? i "<?" then
      let some e := find i ">" | throw "unterminated declaration"
      i := e + 1; textStart := i; continue
    if at? i "</" then
      let some e := find i ">" | throw "unterminated end tag"
      let tag := (str (i + 2) e).trimAscii.toString.toLower
      -- close up to the matching element
      let some depth := (List.range stack.size).reverse.find? fun d => d > 0 && (stack[d]!).1 == tag
        | throw s!"</{tag}> closes nothing"
      while stack.size > depth do
        let (t, a, k) := stack.back!
        stack := push stack.pop (.elem t a k)
      i := e + 1; textStart := i; continue
    -- a start tag
    let mut j := i + 1
    while j < n && !isSpace cs[j]! && cs[j]! != '>' && cs[j]! != '/' do j := j + 1
    let tag := (str (i + 1) j).toLower
    if tag.isEmpty then throw s!"bad tag at {i}"
    let mut attrs : Array (String × String) := #[]
    let mut selfClose := false
    let mut done := false
    while !done do
      while j < n && isSpace cs[j]! do j := j + 1
      if j ≥ n then throw s!"unterminated <{tag}>"
      if cs[j]! == '>' then j := j + 1; done := true
      else if cs[j]! == '/' && j + 1 < n && cs[j + 1]! == '>' then j := j + 2; selfClose := true; done := true
      else
        let a := j
        while j < n && !isSpace cs[j]! && cs[j]! != '=' && cs[j]! != '>' && !(cs[j]! == '/' && j + 1 < n && cs[j+1]! == '>') do j := j + 1
        let name := (str a j).toLower
        while j < n && isSpace cs[j]! do j := j + 1
        if j < n && cs[j]! == '=' then
          j := j + 1
          while j < n && isSpace cs[j]! do j := j + 1
          if j < n && (cs[j]! == '"' || cs[j]! == '\'') then
            let q := cs[j]!
            let b := j + 1
            j := b
            while j < n && cs[j]! != q do j := j + 1
            attrs := addAttr attrs name (decodeEntities (str b j)); j := j + 1
          else
            let b := j
            while j < n && !isSpace cs[j]! && cs[j]! != '>' do j := j + 1
            attrs := addAttr attrs name (decodeEntities (str b j))
        else attrs := addAttr attrs name ""
    i := j
    if selfClose || voidElements.contains tag then
      stack := push stack (.elem tag attrs #[])
    else if rawText.contains tag then
      let some e := find i ("</" ++ tag) | throw s!"unterminated <{tag}>"
      let body := str i e
      let body := if tag == "textarea" && body.startsWith "\n" then (body.drop 1).toString else body
      let kids : Array PNode := if body.isEmpty then #[] else #[.text (if tag == "script" || tag == "style" then body else decodeEntities body)]
      stack := push stack (.elem tag attrs kids)
      let some e2 := find e ">" | throw s!"unterminated </{tag}"
      i := e2 + 1
    else
      stack := stack.push (tag, attrs, #[])
      if (tag == "pre" || tag == "listing") && i < n && cs[i]! == '\n' then i := i + 1
    textStart := i
  if textStart < n then stack := push stack (.text (decodeEntities (str textStart n)))
  while stack.size > 1 do
    let (t, a, k) := stack.back!
    stack := push stack.pop (.elem t a k)
  return (stack[0]!).2.2

/-- The first element (depth-first) satisfying `p`. -/
partial def PNode.findElem (p : String → Array (String × String) → Bool) : PNode → Option PNode
  | e@(.elem t a k) => if p t a then some e else k.findSome? (PNode.findElem p)
  | _ => none

def findElem (nodes : Array PNode) (p : String → Array (String × String) → Bool) : Option PNode :=
  nodes.findSome? (PNode.findElem p)

def byId (nodes : Array PNode) (id : String) : Option PNode :=
  findElem nodes fun _ a => a.any (· == ("id", id))

partial def PNode.textContent : PNode → String
  | .text s => s
  | .elem _ _ k => String.join (k.toList.map PNode.textContent)
  | .comment _ => ""

/-! ## Claiming server-rendered nodes, as the browser runtime hydrates -/

/-- Put the nodes of a container into a `Dom`, allocating handles from `first` in pre-order and
skipping the markers `Html.render` writes, exactly as `runtime/leanui.js` does. Returns the DOM
and the number of handles claimed. -/
partial def claim (kids : Array PNode) (first : UInt32 := 1) (d : Dom := {}) : Dom × UInt32 :=
  let rec go (parent : Option UInt32) (kids : Array PNode) (st : Dom × UInt32) : Dom × UInt32 :=
    kids.foldl (init := st) fun (d, h) k =>
      let link (d : Dom) : Dom := match parent with
        | some p => d.put p { d.get p with kids := (d.get p).kids.push h }
        | none => d
      match k with
      | .comment "t" => (link (d.put h { isText := true, text := "", parent }), h + 1)
      | .comment _ => (d, h)
      | .text s => (link (d.put h { isText := true, text := s, parent }), h + 1)
      | .elem tag attrs ks =>
        let d := link (d.put h { tag, attrs, parent })
        go (some h) ks (d, h + 1)
  let (d, h) := go none kids (d, first)
  (d, h - first)

/-- The live state of a subtree: attributes and properties merged (a property wins over the
attribute of the same name, as it does for the page the user sees), sorted; listeners omitted. -/
partial def liveCanon (d : Dom) (h : UInt32) : String :=
  let nd := d.get h
  if nd.isText then nd.text
  else
    let kv := nd.props.foldl (fun acc (k, v) => Dom.setKV acc k v) nd.attrs
    let kv := kv.qsort (fun a b => a.1 < b.1)
    "<" ++ nd.tag ++ String.join (kv.toList.map fun (k, v) => s!" {k}={repr v}") ++ ">" ++
      String.join (nd.kids.toList.map (liveCanon d)) ++ "</" ++ nd.tag ++ ">"

/-- The state a view describes, in `liveCanon`'s format. -/
partial def viewCanon {Msg : Type} : Html Msg → String
  | .text s => s
  | .lazy _ _ r => viewCanon (r ())
  | .elem _ tag attrs kids =>
    let kv : Array (String × String) := attrs.filterMap fun
      | .attr k v => some (k, v)
      | .prop k (.str v) => some (k, v)
      | .prop k (.bool b) => some (k, if b then "true" else "false")
      | .prop k (.num x) => some (k, toString x)
      | _ => none
    let kv := (kv.foldl (fun acc (k, v) => Dom.setKV acc k v) #[]).qsort (fun a b => a.1 < b.1)
    "<" ++ tag ++ String.join (kv.toList.map fun (k, v) => s!" {k}={repr v}") ++ ">" ++
      String.join ((effectiveKids tag kids).toList.map viewCanon) ++ "</" ++ tag ++ ">"

/-- Split an encoded update (`[u32 opsBytes][ops][strs]`) into its parts. -/
def decodeUpdate (b : ByteArray) : Option (ByteArray × ByteArray) :=
  if b.size == 0 then some (.empty, .empty)
  else if b.size < 4 then none
  else
    let n := b[0]!.toNat ||| (b[1]!.toNat <<< 8) ||| (b[2]!.toNat <<< 16) ||| (b[3]!.toNat <<< 24)
    if 4 + n > b.size || n % 4 != 0 then none
    else some (b.extract 4 (4 + n), b.extract (4 + n) b.size)

/-- A small JSON string-field reader (enough for the boot parameters). -/
def jsonField (json key : String) : Option String := Id.run do
  let pat := "\"" ++ key ++ "\":\""
  match json.splitOn pat with
  | _ :: rest :: _ =>
    let cs := rest.toList.toArray
    let mut out := ""
    let mut i := 0
    while i < cs.size do
      let c := cs[i]!
      if c == '"' then return some out
      if c == '\\' && i + 1 < cs.size then
        let e := cs[i + 1]!
        if e == 'u' && i + 5 < cs.size then
          let hex := String.ofList (cs.extract (i + 2) (i + 6)).toList
          let v := hex.foldl (fun n c => n * 16 + (if c.isDigit then c.toNat - 48 else (c.toLower.toNat - 87))) 0
          out := out.push (Char.ofNat v); i := i + 6
        else
          out := out.push (match e with | 'n' => '\n' | 't' => '\t' | 'r' => '\r' | c => c); i := i + 2
      else out := out.push c; i := i + 1
    return none
  | _ => return none

/-! ## The client -/

/-- A browser stand-in driving one server-driven page through a `Route`. -/
structure Client where
  route : Route
  page : String
  endpoint : String
  session : String
  selector : String
  dom : IO.Ref Dom
  /-- Handles claimed from the server-rendered HTML. -/
  claimed : UInt32
  /-- Wall time of each protocol round trip, in nanoseconds. -/
  timings : IO.Ref (Array Nat)

namespace Client

/-- Run a request through the route. -/
def request (route : Route) (req : Req) : IO Res := (route.handle req).block

/-- Apply a response body to the DOM, as the runtime does with any body it receives. -/
def applyBody (c : Client) (body : ByteArray) : IO Unit := do
  match decodeUpdate body with
  | some (ops, strs) => if ops.size > 0 then c.dom.modify (·.apply ops strs)
  | none => throw (IO.userError s!"the response is not an encoded update ({body.size} bytes)")

/-- Send one protocol message; returns the HTTP status. -/
def send (c : Client) (m : Remote.Msg) : IO Nat := do
  let t0 ← IO.monoNanosNow
  let res ← request c.route (Req.post s!"{c.endpoint}/{c.session}" m.body)
  c.timings.modify (·.push ((← IO.monoNanosNow) - t0))
  c.applyBody res.body
  return res.status

/-- Load a page (it must name a session) and hydrate it. -/
def «open» (route : Route) (url : String) : IO Client := do
  let res ← request route (Req.get url)
  unless res.status == 200 do throw (IO.userError s!"GET {url}: {res.status} {res.bodyText}")
  let page := res.bodyText
  let nodes ← match parseHtml page with
    | .ok n => pure n
    | .error e => throw (IO.userError s!"GET {url}: cannot parse the page: {e}")
  let some cfg := byId nodes "leanui-boot" | throw (IO.userError s!"GET {url}: no boot parameters")
  let json := cfg.textContent
  let some session := jsonField json "session" | throw (IO.userError s!"GET {url}: no session in {json}")
  let endpoint := (jsonField json "endpoint").getD "/leanui"
  let selector := (jsonField json "selector").getD "#app"
  let some (.elem _ _ kids) := byId nodes (selector.drop 1).toString
    | throw (IO.userError s!"GET {url}: no container {selector}")
  let (d, claimed) := claim kids
  let dom ← IO.mkRef { d with roots := #[(selector, 1)] }
  let c : Client := { route, page, endpoint, session, selector, dom, claimed, timings := ← IO.mkRef #[] }
  let st ← c.send .hydrate
  unless st == 200 do throw (IO.userError s!"hydrate: {st}")
  -- the runtime checks the claim count against the server's; so do we
  let d ← c.dom.get
  let want := s!"hydrate {selector} 1 {claimed}"
  unless d.effects.contains want do
    throw (IO.userError s!"hydration mismatch: claimed {claimed} nodes, server says {d.effects.filter (·.startsWith "hydrate")}")
  return c

def root (c : Client) : IO UInt32 := do
  let some h := (← c.dom.get).rootOf c.selector | throw (IO.userError "nothing mounted")
  return h

/-- The first node whose attribute `name` is `value`. -/
def find (c : Client) (name value : String) : IO UInt32 := do
  let d ← c.dom.get
  match (d.reachable (← c.root)).find? fun h => (d.get h).attrs.any (· == (name, value)) with
  | some h => return h
  | none => throw (IO.userError s!"no node with {name}={value}")

/-- Fire `event` on a node, bubbling to the first ancestor with a listener, as the runtime's
delegated listener does; returns the HTTP status. -/
partial def fire (c : Client) (h : UInt32) (event : String) (payload := "") : IO Nat := do
  let d ← c.dom.get
  match (d.get h).listeners.find? (·.1 == event) with
  | some (_, slot, _, _) => c.send (.event slot payload)
  | none => match (d.get h).parent with
    | some p => c.fire p event payload
    | none => throw (IO.userError s!"no {event} listener on node {h} or its ancestors")

def click (c : Client) (name value : String) : IO Nat := do c.fire (← c.find name value) "click"

def effects (c : Client) : IO (Array String) := return (← c.dom.get).effects

def text (c : Client) (name value : String) : IO String := do
  let d ← c.dom.get
  return liveCanon d (← c.find name value)

/-- The page must show `view`, the protocol must have been followed, and no handle may leak. -/
def check {Msg : Type} (c : Client) (view : Html Msg) (what : String) : IO Unit := do
  let d ← c.dom.get
  let r ← c.root
  unless d.errors.isEmpty do throw (IO.userError s!"{what}: protocol errors {d.errors}")
  let got := liveCanon d r
  let want := viewCanon view
  unless got == want do throw (IO.userError s!"{what}: DOM differs\n got: {got.take 500}\nwant: {want.take 500}")
  let live := (d.reachable r).size
  unless live == d.nodes.size do
    throw (IO.userError s!"{what}: {d.nodes.size - live} leaked handles ({d.nodes.size} known, {live} attached)")

end Client
end LeanUI.Server.Testing
