module
public import LeanUI.Html
public import LeanUI.Effect
/-!
# URLs and typed routes

* `Url`: parsing (scheme, host, port, path segments, query parameters, fragment) with
  percent-decoding, printing with percent-encoding, and RFC 3986 reference resolution
  (`Url.resolve`).
* `Route α`: a bidirectional route: the same value parses a URL into an `α` and prints an `α`
  back into a URL, so links can never drift from the parser. Segments compose with `</>`
  (literal segments are plain strings, unit captures drop out of the result type, so
  `"users" </> Route.nat </> "posts" </> Route.str : Route (Nat × String)`), query parameters
  with `<?>`, alternatives with `Route.oneOf`, constructors with `Route.to`.
* `Router α`: a route plus where it lives: under a base path (`/app/users/3`) or in the
  fragment (hash routing: `#/active`, which works on any static server).
* `link`: an `<a href data-link>`; the browser runtime turns clicks on it into `Sub.urlChanges`
  messages without a page load. `Router.navigate` pushes a URL from `update`.

```
inductive Page | home | user (id : Nat) (tab : Option String) | search (q : Option String)

def pages : Route Page := Route.oneOf [
  Route.top |>.to (fun _ => .home) (fun | .home => some () | _ => none),
  ("users" </> Route.nat <?> Route.param "tab") |>.to (fun (id, tab) => .user id tab)
    (fun | .user id tab => some (id, tab) | _ => none),
  ("search" </> Route.param "q") |>.to .search (fun | .search q => some q | _ => none)]

def router : Router Page := { route := pages, base := #["app"] }
-- router.parse "/app/users/3?tab=posts" = some (.user 3 (some "posts"))
-- router.href (.user 3 none)           = "/app/users/3"
```

The round-trip law (`parse (href p) = some p`) holds by construction for the built-in
combinators; `Route.to f g` needs `g (f a) = some a` and `g b = some a → f a = b`, which is what
the `fun | .ctor x => some x | _ => none` pattern gives. `Router.check` tests it for a list of
values.
-/
public section
namespace LeanUI

/-! ## Percent-encoding -/

namespace Url

@[inline] def isAlnum (b : UInt8) : Bool := (b ≥ 48 && b ≤ 57) || (b ≥ 65 && b ≤ 90) || (b ≥ 97 && b ≤ 122)
/-- RFC 3986 unreserved: `A-Z a-z 0-9 - . _ ~`. -/
@[inline] def isUnreserved (b : UInt8) : Bool := isAlnum b || b == 45 || b == 46 || b == 95 || b == 126
@[inline] def inSet (set : String) (b : UInt8) : Bool := set.any (·.toNat == b.toNat)

/-- What `encodeURIComponent` leaves alone. -/
def componentSafe (b : UInt8) : Bool := isUnreserved b || inSet "!*'()" b
/-- Path segments keep the sub-delimiters, `:` and `@` (RFC 3986 `pchar`). -/
def segmentSafe (b : UInt8) : Bool := isUnreserved b || inSet "!$&'()*+,;=:@" b
/-- Query keys and values: `&`, `=`, `+` and `#` are encoded, `/`, `?`, `:` and `@` are not. -/
def querySafe (b : UInt8) : Bool := isUnreserved b || inSet "!$'()*,;:@/?" b
/-- Fragments keep everything RFC 3986 allows there. -/
def fragmentSafe (b : UInt8) : Bool := isUnreserved b || inSet "!$&'()*+,;=:@/?" b

def hexUpper (n : Nat) : Char := if n < 10 then Char.ofNat (48 + n) else Char.ofNat (55 + n)

/-- Percent-encode the UTF-8 bytes of `s` that `safe` rejects (`%XX`, upper-case hex). -/
def percentEncode (s : String) (safe : UInt8 → Bool := componentSafe) : String :=
  s.toUTF8.foldl (init := "") fun acc b =>
    if safe b then acc.push (Char.ofNat b.toNat)
    else (acc.push '%').push (hexUpper (b / 16).toNat) |>.push (hexUpper (b % 16).toNat)

/-- `encodeURIComponent`. -/
def encodeComponent (s : String) : String := percentEncode s componentSafe

@[inline] def hexVal? (b : UInt8) : Option UInt8 :=
  if b ≥ 48 && b ≤ 57 then some (b - 48) else if b ≥ 65 && b ≤ 70 then some (b - 55)
  else if b ≥ 97 && b ≤ 102 then some (b - 87) else none

/-- Decode UTF-8, replacing each malformed sequence with U+FFFD. -/
def utf8Lossy (bs : ByteArray) : String := Id.run do
  if let some s := String.fromUTF8? bs then return s
  let mut out := ""
  let mut i := 0
  while i < bs.size do
    let b := bs[i]!
    let len := if b < 0x80 then 1 else if b ≥ 0xC2 && b < 0xE0 then 2 else if b ≥ 0xE0 && b < 0xF0 then 3
      else if b ≥ 0xF0 && b < 0xF5 then 4 else 0
    match (if len == 0 then none else String.fromUTF8? (bs.extract i (i + len))) with
    | some ch => out := out ++ ch; i := i + len
    | none => out := out.push '\uFFFD'; i := i + 1
  return out

/-- Decode `%XX` escapes (and `+` as a space when `plusIsSpace`, as in query strings). A `%`
not followed by two hex digits stays as it is; bytes that are not UTF-8 become U+FFFD. -/
def percentDecode (s : String) (plusIsSpace := false) : String := Id.run do
  let bs := s.toUTF8
  if !(s.any (· == '%') || (plusIsSpace && s.any (· == '+'))) then return s
  let mut out := ByteArray.emptyWithCapacity bs.size
  let mut i := 0
  while i < bs.size do
    let b := bs[i]!
    if b == 37 && i + 2 < bs.size then
      match hexVal? (bs[i + 1]?.getD 0), hexVal? (bs[i + 2]?.getD 0) with
      | some h, some l => out := out.push (h * 16 + l); i := i + 3
      | _, _ => out := out.push b; i := i + 1
    else if b == 43 && plusIsSpace then out := out.push 32; i := i + 1
    else out := out.push b; i := i + 1
  return utf8Lossy out

end Url

/-! ## URLs -/

/-- A parsed URL. Path segments, query keys and values and the fragment are decoded. A relative
reference (`/users/3?tab=posts`, what `location.pathname + search + hash` gives) has no scheme
and no host. -/
structure Url where
  scheme : Option String := none
  host : Option String := none
  port : Option Nat := none
  /-- Decoded path segments: `/a/b%20c/` is `#["a", "b c"]` (a trailing slash is dropped). -/
  path : Array String := #[]
  /-- Decoded `key=value` pairs, in order; `?flag` is `("flag", "")`. -/
  query : Array (String × String) := #[]
  fragment : Option String := none
  deriving BEq, Inhabited, Repr

namespace Url

/-- Split at the first occurrence of byte `sep`. -/
def splitFirst (s : String) (sep : Char) : String × Option String :=
  match s.splitOn (String.singleton sep) with
  | [] => (s, none)
  | [a] => (a, none)
  | a :: rest => (a, some ((String.singleton sep).intercalate rest))

/-- `scheme:` prefix, if `s` starts with one (RFC 3986: a letter, then letters, digits, `+-.`). -/
def schemeOf? (s : String) : Option String := Id.run do
  let bs := s.toUTF8
  if bs.size == 0 || !((bs[0]! ≥ 65 && bs[0]! ≤ 90) || (bs[0]! ≥ 97 && bs[0]! ≤ 122)) then return none
  for i in [1:bs.size] do
    let b := bs[i]!
    if b == 58 then return some (String.fromUTF8! (bs.extract 0 i))
    if !(isAlnum b || b == 43 || b == 45 || b == 46) then return none
  return none

/-- Path segments of a raw path, decoded. -/
def pathSegments (raw : String) : Array String :=
  let raw := if raw.startsWith "/" then (raw.drop 1).toString else raw
  if raw.isEmpty then #[] else
  let segs := (raw.splitOn "/").toArray
  let segs := if segs.back? == some "" then segs.pop else segs
  segs.map (percentDecode ·)

/-- Query pairs of a raw query string (without the `?`), decoded. -/
def queryPairs (raw : String) : Array (String × String) :=
  (raw.splitOn "&").toArray.filterMap fun part =>
    if part.isEmpty then none else
    match splitFirst part '=' with
    | (k, v) => some (percentDecode k (plusIsSpace := true), percentDecode (v.getD "") (plusIsSpace := true))

/-- Parse an absolute URL (`https://host:8080/a?b#c`), a network-path reference (`//host/a`) or
a relative one (`/a?b#c`, `a/b`). -/
def parse (s : String) : Url := Id.run do
  let (beforeHash, frag) := splitFirst s '#'
  let (beforeQuery, q) := splitFirst beforeHash '?'
  let mut rest := beforeQuery
  let mut scheme := none
  let mut host := none
  let mut port := none
  if let some sc := schemeOf? rest then
    scheme := some sc.toLower
    rest := (rest.drop (sc.length + 1)).toString
  if rest.startsWith "//" then
    let afterSlashes := (rest.drop 2).toString
    let (authority, path) := match splitFirst afterSlashes '/' with
      | (a, some p) => (a, "/" ++ p)
      | (a, none) => (a, "")
    -- drop user info
    let hostPort := match authority.splitOn "@" with
      | [] => authority
      | parts => parts.getLast!
    -- `[::1]:8080` keeps its brackets
    let (h, p) :=
      if hostPort.startsWith "[" then
        match splitFirst hostPort ']' with
        | (a, some r) => (a ++ "]", if r.startsWith ":" then some (r.drop 1).toString else none)
        | (a, none) => (a, none)
      else match splitFirst hostPort ':' with
        | (a, r) => (a, r)
    host := some h.toLower
    port := p.bind String.toNat?
    rest := path
  return { scheme, host, port, path := pathSegments rest, query := (q.map queryPairs).getD #[],
           fragment := frag.map (percentDecode ·) }

/-- The path, query and fragment as a string: `/a/b?x=1#top`. -/
def pathString (u : Url) : String :=
  let path := "/" ++ "/".intercalate (u.path.toList.map (percentEncode · segmentSafe))
  let query := if u.query.isEmpty then "" else
    "?" ++ "&".intercalate (u.query.toList.map fun (k, v) =>
      -- `?flag` for an empty value (but `?=` for an empty key and value, which must not vanish)
      if v.isEmpty && !k.isEmpty then percentEncode k querySafe else percentEncode k querySafe ++ "=" ++ percentEncode v querySafe)
  let frag := match u.fragment with | some f => "#" ++ percentEncode f fragmentSafe | none => ""
  path ++ query ++ frag

/-- The URL as a string; `parse (toString u) == u` for every `u` whose last path segment is
non-empty (an empty last segment would read back as a trailing slash). -/
protected def toString (u : Url) : String :=
  let auth := match u.host with
    | some h => "//" ++ h ++ (match u.port with | some p => ":" ++ toString p | none => "")
    | none => ""
  let sch := match u.scheme with | some s => s ++ ":" | none => ""
  sch ++ auth ++ u.pathString

instance : ToString Url := ⟨Url.toString⟩

/-- The first value of query parameter `k`. -/
def param? (u : Url) (k : String) : Option String := (u.query.find? (·.1 == k)).map (·.2)
/-- Every value of query parameter `k`. -/
def params (u : Url) (k : String) : Array String := u.query.filterMap fun (a, b) => if a == k then some b else none
/-- Set query parameter `k` (replacing every previous value). -/
def setParam (u : Url) (k v : String) : Url := { u with query := (u.query.filter (·.1 != k)).push (k, v) }
def removeParam (u : Url) (k : String) : Url := { u with query := u.query.filter (·.1 != k) }

/-- The fragment of `s` read as a URL of its own, for hash routing: `/app#/users/3?tab=a`
gives path `#["users", "3"]` and query `tab=a`. The raw fragment is split before decoding, so an
encoded `%3F` stays part of a segment. -/
def parseHash (s : String) : Url :=
  match splitFirst s '#' with
  | (_, some frag) => { parse (if frag.startsWith "/" then frag else "/" ++ frag) with fragment := none }
  | (_, none) => {}

/-! ### Reference resolution (RFC 3986, section 5.2) -/

/-- Remove `.` and `..` segments (RFC 3986, section 5.2.4). -/
partial def removeDotSegments (input : String) : String :=
  let rec go (inp : String) (out : Array String) : String :=
    if inp.isEmpty then String.join out.toList
    else if inp.startsWith "../" then go (inp.drop 3).toString out
    else if inp.startsWith "./" then go (inp.drop 2).toString out
    else if inp.startsWith "/./" then go (inp.drop 2).toString out
    else if inp == "/." then go "/" out
    else if inp.startsWith "/../" then go (inp.drop 3).toString out.pop
    else if inp == "/.." then go "/" out.pop
    else if inp == "." || inp == ".." then go "" out
    else
      -- move the first segment (with its leading "/", if any) to the output
      let start := if inp.startsWith "/" then 1 else 0
      let afterStart := (inp.drop start).toString
      let segEnd := match afterStart.splitOn "/" with | s :: _ => s.length | [] => afterStart.length
      let seg := (inp.take (start + segEnd)).toString
      go (inp.drop (start + segEnd)).toString (out.push seg)
  go input #[]

/-- The components of a URI reference as RFC 3986 splits them (raw, not decoded). -/
structure Ref where
  scheme : Option String
  authority : Option String
  path : String
  query : Option String
  fragment : Option String

def Ref.parse (s : String) : Ref := Id.run do
  let (beforeHash, fragment) := splitFirst s '#'
  let (rest, query) := splitFirst beforeHash '?'
  let mut rest := rest
  let mut scheme := none
  if let some sc := schemeOf? rest then
    scheme := some sc
    rest := (rest.drop (sc.length + 1)).toString
  let mut authority := none
  if rest.startsWith "//" then
    let after := (rest.drop 2).toString
    match splitFirst after '/' with
    | (a, some p) => authority := some a; rest := "/" ++ p
    | (a, none) => authority := some a; rest := ""
  return { scheme, authority, path := rest, query, fragment }

def Ref.toString (r : Ref) : String :=
  (match r.scheme with | some s => s ++ ":" | none => "") ++
  (match r.authority with | some a => "//" ++ a | none => "") ++ r.path ++
  (match r.query with | some q => "?" ++ q | none => "") ++
  (match r.fragment with | some f => "#" ++ f | none => "")

/-- Resolve reference `ref` against `base` (RFC 3986, section 5.2.2), as a browser resolves an
`href`: `resolve "http://a/b/c/d;p?q" "../g" = "http://a/b/g"`. -/
def resolve (base ref : String) : String :=
  let b := Ref.parse base
  let r := Ref.parse ref
  let merge (bp rp : String) : String :=
    if b.authority.isSome && bp.isEmpty then "/" ++ rp
    else match (bp.splitOn "/").dropLast with
      | [] => rp
      | dirs => "/".intercalate dirs ++ "/" ++ rp
  let t : Ref :=
    if r.scheme.isSome then { r with path := removeDotSegments r.path }
    else if r.authority.isSome then { r with scheme := b.scheme, path := removeDotSegments r.path }
    else if r.path.isEmpty then
      { r with scheme := b.scheme, authority := b.authority, path := b.path, query := r.query <|> b.query }
    else if r.path.startsWith "/" then
      { r with scheme := b.scheme, authority := b.authority, path := removeDotSegments r.path }
    else
      { r with scheme := b.scheme, authority := b.authority, path := removeDotSegments (merge b.path r.path) }
  t.toString

end Url

/-! ## Routes -/

/-- A bidirectional route: `parse` reads path segments (and looks at the query) and returns
every way to match with the segments left over; `print` writes segments and query pairs, or
fails for values this route does not cover. -/
structure Route (α : Type) where
  parse : List String → Array (String × String) → List (α × List String)
  print : α → Option (Array String × Array (String × String))

namespace Route

variable {α β γ : Type}

/-- Matches without consuming anything (the root `/` when used alone). -/
def top : Route Unit := ⟨fun segs _ => [((), segs)], fun _ => some (#[], #[])⟩

/-- The literal segment `s`. String literals coerce to this in `</>`. -/
def lit (s : String) : Route Unit where
  parse | t :: r, _ => if t == s then [((), r)] else [] | [], _ => []
  print _ := some (#[s], #[])

/-- One segment through a codec. Law: `decode (encode a) = some a`. -/
def seg (decode : String → Option α) (encode : α → Option String) : Route α where
  parse
    | t :: r, _ => match decode t with | some a => [(a, r)] | none => []
    | [], _ => []
  print a := (encode a).map fun s => (#[s], #[])

/-- A canonical natural number: digits, no sign, no leading zeros (so printing is the inverse). -/
def natOf? (s : String) : Option Nat :=
  let bs := s.toUTF8
  if bs.size == 0 || (bs.size > 1 && bs[0]! == 48) || !s.all (fun c => c ≥ '0' && c ≤ '9') then none
  else s.toNat?

def intOf? (s : String) : Option Int :=
  if s.startsWith "-" then (natOf? (s.drop 1).toString).bind fun n => if n == 0 then none else some (-(n : Int))
  else (natOf? s).map fun n => (n : Int)

/-- Any non-empty segment (an empty one cannot round-trip: it would print as a trailing slash). -/
def str : Route String := seg (fun s => if s.isEmpty then none else some s) (fun s => if s.isEmpty then none else some s)
def nat : Route Nat := seg natOf? (fun n => some (toString n))
def int : Route Int := seg intOf? (fun n => some (toString n))

/-- Every remaining segment (`/files/*path`). Prints only when the last segment is non-empty. -/
def rest : Route (List String) where
  parse segs _ := [(segs, [])]
  print xs := if xs.getLast? == some "" then none else some (xs.toArray, #[])

/-- Query parameter `k`, if present. Does not consume segments. -/
def param (k : String) : Route (Option String) where
  parse segs q := [((q.find? (·.1 == k)).map (·.2), segs)]
  print | some v => some (#[], #[(k, v)]) | none => some (#[], #[])

/-- Query parameter `k` through a codec; a value that does not decode reads as `none`. -/
def paramAs (k : String) (decode : String → Option α) (encode : α → String) : Route (Option α) where
  parse segs q := [((q.find? (·.1 == k)).bind (decode ·.2), segs)]
  print | some v => some (#[], #[(k, encode v)]) | none => some (#[], #[])

def paramNat (k : String) : Route (Option Nat) := paramAs k natOf? toString

/-- Every value of a repeated query parameter (`?tag=a&tag=b`). -/
def params (k : String) : Route (Array String) where
  parse segs q := [(q.filterMap (fun (a, b) => if a == k then some b else none), segs)]
  print vs := some (#[], vs.map (k, ·))

/-- `true` when query parameter `k` is present (`?debug`). -/
def flag (k : String) : Route Bool where
  parse segs q := [(q.any (·.1 == k), segs)]
  print b := some (#[], if b then #[(k, "")] else #[])

/-- A partial isomorphism: `f` builds a `β`, `g` takes it apart (`none` for values of `β` this
route does not print, e.g. other constructors). -/
def to (r : Route α) (f : α → β) (g : β → Option α) : Route β where
  parse segs q := (r.parse segs q).map fun (a, rest) => (f a, rest)
  print b := g b >>= r.print

/-- Parse with every alternative (in order); print with the first that accepts the value.
An alternative whose `g` always says `none` is a parse-only alias. -/
def oneOf (rs : List (Route α)) : Route α where
  parse segs q := rs.flatMap (·.parse segs q)
  print a := rs.findSome? (·.print a)

/-- Combine two captures, dropping `Unit`s: `Unit ⊗ β = β`, `α ⊗ Unit = α`, else `α × β`. -/
class Join (α β : Type) (γ : outParam Type) where
  join : α → β → γ
  split : γ → α × β

instance (priority := high) instJoinUnitLeft : Join Unit β β := ⟨fun _ b => b, fun b => ((), b)⟩
instance (priority := mid) instJoinUnitRight : Join α Unit α := ⟨fun a _ => a, fun a => (a, ())⟩
instance (priority := low) instJoinProd : Join α β (α × β) := ⟨Prod.mk, id⟩

/-- `a` then `b`. -/
def seq [Join α β γ] (a : Route α) (b : Route β) : Route γ where
  parse segs q := (a.parse segs q).flatMap fun (x, r) => (b.parse r q).map fun (y, r') => (Join.join x y, r')
  print g :=
    let (x, y) := Join.split g
    match a.print x, b.print y with
    | some (s1, q1), some (s2, q2) => some (s1 ++ s2, q1 ++ q2)
    | _, _ => none

/-- What `</>` accepts: routes, and strings as literal segments. -/
class ToRoute (x : Type) (α : outParam Type) where
  toRoute : x → Route α

instance : ToRoute (Route α) α := ⟨id⟩
instance : ToRoute String Unit := ⟨lit⟩

/-- `a </> b`, with literal strings allowed on either side. -/
def join' {x y : Type} [ToRoute x α] [ToRoute y β] [Join α β γ] (a : x) (b : y) : Route γ :=
  seq (ToRoute.toRoute a) (ToRoute.toRoute b)

/-- Every complete match of `segs` (no segments left over). -/
def run (r : Route α) (segs : List String) (q : Array (String × String)) : List α :=
  (r.parse segs q).filterMap fun (a, rest) => if rest.isEmpty then some a else none

end Route

/-- Path composition: `"users" </> Route.nat </> "posts"`. -/
infixr:60 " </> " => Route.join'
/-- Query composition (the same operation; reads as Elm's `<?>`): `"search" <?> Route.param "q"`. -/
infixr:60 " <?> " => Route.join'

/-! ## Routers -/

/-- A route and where it lives in the URL. -/
structure Router (α : Type) where
  route : Route α
  /-- The path the app is served under, as segments: `#["app"]` for `/app/...`. -/
  base : Array String := #[]
  /-- Hash routing: the route is the fragment (`/index.html#/users/3`). -/
  hash : Bool := false

namespace Router

variable {α Msg : Type}

/-- The base path from a string: `"/plain/effects/"` is `#["plain", "effects"]`. -/
def baseOf (s : String) : Array String := Url.pathSegments s

def withBase (r : Router α) (base : String) : Router α := { r with base := baseOf base }

/-- The route of a parsed URL: under `base` in path mode, in the fragment in hash mode. -/
def parseUrl (r : Router α) (u : Url) : Option α :=
  let segs := u.path.toList
  if r.base.toList.isPrefixOf segs then (r.route.run (segs.drop r.base.size) u.query).head?
  else none

/-- Parse a URL string, e.g. what `Sub.urlChanges` reports (`pathname + search + hash`). In hash
mode a URL without a fragment is the root (`#/`). -/
def parse (r : Router α) (s : String) : Option α :=
  if r.hash then let u := Url.parseHash s; (r.route.run u.path.toList u.query).head?
  else r.parseUrl (Url.parse s)

/-- The URL of `a`, if the route prints it: `/base/users/3?tab=a`, or `#/users/3` in hash
mode. -/
def url? (r : Router α) (a : α) : Option String :=
  (r.route.print a).map fun (segs, query) =>
    if r.hash then "#" ++ ({ path := segs, query } : Url).pathString
    else
      let p := ({ path := r.base ++ segs, query } : Url).pathString
      -- the root of an app under a base path is that directory: `/app/`, not `/app`
      if segs.isEmpty && !r.base.isEmpty then
        let (path, q) := Url.splitFirst p '?'
        path ++ "/" ++ (q.map ("?" ++ ·)).getD ""
      else p

/-- `url?`, or the base path for values the route cannot print. -/
def href (r : Router α) (a : α) : String :=
  (r.url? a).getD (if r.hash then "#/" else if r.base.isEmpty then "/" else ({ path := r.base } : Url).pathString ++ "/")

/-- A link to `a`. -/
def link (r : Router α) (a : α) (attrs : Array (Attr Msg) := #[]) (kids : Array (Html Msg) := #[]) : Html Msg :=
  .elem .html "a" (#[.attr "href" (r.href a), .attr "data-link" ""] ++ attrs) kids

/-- Go to `a` from `update`: push its URL and send `k a` (pushing a URL does not report it to
`Sub.urlChanges`, which only sees back/forward and link clicks). -/
def navigate (r : Router α) (a : α) (k : α → Msg) : Cmd Msg := .batch #[.pushUrl (r.href a), .send (k a)]

/-- Like `navigate`, replacing the current history entry. -/
def redirect (r : Router α) (a : α) (k : α → Msg) : Cmd Msg := .batch #[.replaceUrl (r.href a), .send (k a)]

/-- URL changes (back/forward, link clicks), parsed. -/
def changes (r : Router α) (k : Option α → Msg) : Sub Msg := .urlChanges fun u => k (r.parse u)

/-- Check the round-trip law on sample values: each printable value must parse back to itself. -/
def check [BEq α] [Repr α] (r : Router α) (samples : List α) : Except String Unit :=
  samples.forM fun a => do
    let some u := r.url? a | return
    match r.parse u with
    | some b => unless a == b do throw s!"{reprStr a} prints as {u}, which parses as {reprStr b}"
    | none => throw s!"{reprStr a} prints as {u}, which does not parse"

end Router

/-- A link the runtime handles in-page: a plain click becomes a `Sub.urlChanges` message
instead of a page load (modified clicks still open new tabs). -/
def link {Msg : Type} (href : String) (attrs : Array (Attr Msg) := #[]) (kids : Array (Html Msg) := #[]) : Html Msg :=
  .elem .html "a" (#[.attr "href" href, .attr "data-link" ""] ++ attrs) kids

end LeanUI
