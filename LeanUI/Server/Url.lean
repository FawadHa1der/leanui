module
/-!
# Request targets: paths, queries and percent-encoding

The server never trusts a request path: `Url.segments` decodes it (so `%2e%2e` is seen as `..`),
splits it *after* decoding (so an encoded `%2F` cannot smuggle a separator past the check), and
refuses `..`, NUL, backslashes and drive letters outright instead of trying to normalise them.
Everything here is pure, so `tests/Server.lean` checks it case by case.
-/
public section
namespace LeanUI.Server.Url

/-- The value of an ASCII hex digit. -/
def hexVal (b : UInt8) : Option UInt8 :=
  if b ≥ 48 && b ≤ 57 then some (b - 48)
  else if b ≥ 65 && b ≤ 70 then some (b - 55)
  else if b ≥ 97 && b ≤ 102 then some (b - 87)
  else none

/-- Lower-case hex of a byte array (session ids, ETags). -/
def hex (bs : ByteArray) : String :=
  let digit (n : UInt8) : Char := if n < 10 then Char.ofNat (48 + n.toNat) else Char.ofNat (87 + n.toNat)
  bs.foldl (init := "") fun s b => (s.push (digit (b >>> 4))).push (digit (b &&& 15))

/-- Percent-decode one component. `plus` turns `+` into a space (query strings only). Fails on
a malformed escape or on bytes that are not UTF-8. -/
def decode (s : String) (plus := false) : Option String := Id.run do
  let bs := s.toUTF8
  let mut out := ByteArray.emptyWithCapacity bs.size
  let mut i := 0
  while i < bs.size do
    let b := bs[i]!
    if b == 37 then -- '%'
      if i + 2 ≥ bs.size then return none
      match hexVal bs[i+1]!, hexVal bs[i+2]! with
      | some hi, some lo => out := out.push (hi * 16 + lo); i := i + 3
      | _, _ => return none
    else
      out := out.push (if plus && b == 43 then 32 else b); i := i + 1
  return String.fromUTF8? out

/-- Characters that never need escaping in a path segment or query component (RFC 3986
unreserved). -/
private def unreserved (b : UInt8) : Bool :=
  (b ≥ 48 && b ≤ 57) || (b ≥ 65 && b ≤ 90) || (b ≥ 97 && b ≤ 122) || b == 45 || b == 46 || b == 95 || b == 126

/-- Percent-encode a component (UTF-8 bytes; everything but unreserved characters). -/
def encode (s : String) : String :=
  let digit (n : UInt8) : Char := if n < 10 then Char.ofNat (48 + n.toNat) else Char.ofNat (55 + n.toNat)
  s.toUTF8.foldl (init := "") fun acc b =>
    if unreserved b then acc.push (Char.ofNat b.toNat) else ((acc.push '%').push (digit (b >>> 4))).push (digit (b &&& 15))

/-- Split a request target into its path and its query string (without `?`); a fragment, which a
browser never sends but a hand-written client might, is dropped. -/
def splitTarget (target : String) : String × String :=
  let noFrag := (target.splitOn "#").headD ""
  match noFrag.splitOn "?" with
  | [] => ("/", "")
  | [p] => (p, "")
  | p :: rest => (p, "?".intercalate rest)

/-- `a=1&b=x+y&flag` as decoded pairs (`flag` has the value `""`). Malformed pairs are skipped. -/
def parseQuery (q : String) : Array (String × String) :=
  (q.splitOn "&").foldl (init := #[]) fun acc part =>
    if part.isEmpty then acc
    else
      let (k, v) := match part.splitOn "=" with
        | [] => ("", "")
        | [k] => (k, "")
        | k :: rest => (k, "=".intercalate rest)
      match decode k (plus := true), decode v (plus := true) with
      | some k, some v => acc.push (k, v)
      | _, _ => acc

/-- Encode pairs as a query string (without `?`). -/
def formatQuery (kv : Array (String × String)) : String :=
  "&".intercalate (kv.toList.map fun (k, v) => encode k ++ "=" ++ encode v)

/-- Why a path was refused. -/
inductive Refusal where
  | badEncoding
  | traversal
  | badChar
  deriving BEq, Repr

/-- The decoded, normalised segments of a raw (still percent-encoded) path: empty segments and
`.` are dropped; `..`, NUL, `\` and `:` (Windows drive letters and alternate streams) are
refused, never resolved. -/
def segments (rawPath : String) : Except Refusal (Array String) := do
  let mut out := #[]
  for raw in rawPath.splitOn "/" do
    let some seg := decode raw | throw .badEncoding
    -- split again after decoding: an encoded `/` is a separator, not part of a name
    for s in seg.splitOn "/" do
      if s.isEmpty || s == "." then continue
      if s == ".." then throw .traversal
      if s.any (fun c => c == '\x00' || c == '\\' || c == ':') then throw .badChar
      out := out.push s
  return out

/-- The decoded path for routing: `/` followed by the decoded segments. Never fails: paths that
`segments` refuses route as given (so a handler can still answer 404 or 400 for them). -/
def routePath (rawPath : String) : String :=
  match segments rawPath with
  | .ok segs => "/" ++ "/".intercalate segs.toList ++ (if rawPath.endsWith "/" && !segs.isEmpty then "/" else "")
  | .error _ => rawPath

end LeanUI.Server.Url
