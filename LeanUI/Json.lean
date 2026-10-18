module
public import Std.Data.HashMap
/-!
# JSON on `Init` only

A complete JSON library for apps that must not link the Lean compiler (`Lean.Data.Json` lives
under `Lean.*`, and a runtime `Lean` import links about 104 MB of compiler into the binary).

* `Json`: the value type. Objects keep their keys in insertion order, as JavaScript does; a
  duplicate key keeps its first position and its last value (JavaScript's `JSON.parse` rule).
* `JsonNumber`: numbers are exact decimals `mantissa × 10^exponent`, so `12345678901234567890`
  and `0.1` survive a round trip unchanged. `toFloat` rounds correctly (the nearest double, ties
  to even, as browsers do); `ofFloat?` gives the shortest decimal that reads back as the same
  double, and the printer uses ECMAScript's `Number::toString` layout. So `Json.compress` of a
  value built from doubles prints byte-for-byte what `JSON.stringify` prints.
* `Json.parse`: RFC 8259, strict (no comments, trailing commas, leading zeros, `NaN`, BOM or raw
  control characters in strings), every escape including `\uXXXX` surrogate pairs, nesting
  bounded by `maxDepth` (no stack overflow on hostile input), and errors with line and column.
* `Json.compress` (what `JSON.stringify(v)` prints) and `Json.pretty` (what
  `JSON.stringify(v, null, 2)` prints).
* `ToJson` / `FromJson` with instances for the basic types, field helpers for writing instances
  by hand, and decoding errors that say where they happened (`$.users[3].name: expected a
  string, got 42`). `LeanUI.Json.Derive` (compile time only, reached through `meta import`)
  derives both classes for structures and inductive types.
-/
public section
namespace LeanUI

/-! ## Numbers -/

/-- A JSON number, exactly: `mantissa × 10 ^ exponent`. Values built by this module are
normalized (the mantissa has no trailing decimal zeros and zero is `⟨0, 0⟩`), so structural
equality is numeric equality. -/
structure JsonNumber where
  mantissa : Int
  exponent : Int
  deriving BEq, Inhabited, Repr, Hashable

namespace JsonNumber

/-- Number of decimal digits (1 for 0). -/
def numDigits (n : Nat) : Nat := (Nat.repr n).length

/-- `m × 10^e` with trailing zeros moved from the mantissa into the exponent. -/
partial def normalize (m : Int) (e : Int) : JsonNumber :=
  if m == 0 then ⟨0, 0⟩ else if m % 10 == 0 then normalize (m / 10) (e + 1) else ⟨m, e⟩

def zero : JsonNumber := ⟨0, 0⟩
def ofNat (n : Nat) : JsonNumber := normalize n 0
def ofInt (n : Int) : JsonNumber := normalize n 0
/-- `m × 10^e`, negated if `neg`. -/
def ofScientific (m : Nat) (neg : Bool) (e : Int) : JsonNumber := normalize (if neg then -(m : Int) else m) e

instance : OfNat JsonNumber n := ⟨ofNat n⟩
instance : Neg JsonNumber := ⟨fun x => ⟨-x.mantissa, x.exponent⟩⟩

/-- Integers whose decimal exponent is larger than this are not expanded (`1e100000000` would
otherwise allocate a hundred-million-digit number). -/
def maxExpand : Nat := 4096

def isInteger (x : JsonNumber) : Bool := x.exponent ≥ 0

/-- The value as an integer, if it is one (and not absurdly large). -/
def toInt? (x : JsonNumber) : Option Int :=
  if x.exponent < 0 then none
  else if x.exponent.toNat + numDigits x.mantissa.natAbs > maxExpand then none
  else some (x.mantissa * (10 : Int) ^ x.exponent.toNat)

def toNat? (x : JsonNumber) : Option Nat :=
  match x.toInt? with
  | some i => if i ≥ 0 then some i.toNat else none
  | none => none

/-- The double nearest to `num / den` (both positive), ties to even: the conversion browsers
use. Exact big-integer arithmetic, so there is no double rounding. -/
def ratToFloat (num den : Nat) : Float :=
  let a : Int := num.log2
  let b : Int := den.log2
  -- floor(log2 (num / den)) is a - b or a - b - 1
  let k := a - b
  let geK : Bool := if k ≥ 0 then num ≥ den <<< k.toNat else num <<< k.natAbs ≥ den
  let e := if geK then k else k - 1
  -- the weight of the last mantissa bit: 2^(e-52) for normal numbers, 2^-1074 below them
  let lsb := max (e - 52) (-1074)
  let (n, d) := if lsb ≤ 0 then (num <<< lsb.natAbs, den) else (num, den <<< lsb.toNat)
  let q := n / d
  let r := n % d
  let q := if 2 * r > d || (2 * r == d && q % 2 == 1) then q + 1 else q
  let (q, lsb) := if q == 2 ^ 53 then (2 ^ 52, lsb + 1) else (q, lsb)
  if q ≥ 2 ^ 52 then
    let biased := lsb + 1075
    if biased ≥ 2047 then Float.ofBits 0x7FF0000000000000
    else Float.ofBits ((biased.toNat <<< 52) ||| (q - 2 ^ 52)).toUInt64
  else Float.ofBits q.toUInt64

/-- The nearest double (correctly rounded; overflow gives ±∞, underflow ±0). -/
def toFloat (x : JsonNumber) : Float :=
  if x.mantissa == 0 then 0 else
  let m := x.mantissa.natAbs
  let mag : Int := numDigits m + x.exponent
  let f :=
    -- |x| < 10^mag and |x| ≥ 10^(mag-1)
    if mag ≥ 310 then Float.ofBits 0x7FF0000000000000
    else if mag ≤ -324 then 0
    else if x.exponent ≥ 0 then ratToFloat (m * 10 ^ x.exponent.toNat) 1
    else ratToFloat m (10 ^ x.exponent.natAbs)
  if x.mantissa < 0 then -f else f

/-- `x / 10^e` for `x = m × 2^e2`, as a numerator and denominator. -/
def scaled (m : Nat) (e2 : Int) (e : Int) : Nat × Nat :=
  let (n, d) := if e2 ≥ 0 then (m <<< e2.toNat, 1) else (m, 1 <<< e2.natAbs)
  if e ≥ 0 then (n, (d * 5 ^ e.toNat) <<< e.toNat) else ((n * 5 ^ e.natAbs) <<< e.natAbs, d)

/-- The shortest decimal that reads back as exactly `f`, and of those the closest to `f` (ties
to even): the digits ECMAScript's `Number::toString` specifies, so V8 and SpiderMonkey print the
same. `none` for NaN and the infinities, which JSON cannot represent. -/
def ofFloat? (f : Float) : Option JsonNumber :=
  if f.isNaN || f.isInf then none
  else if f == 0 then some zero
  else
    let bits := f.toBits
    let neg := bits >>> 63 == 1
    let target := if neg then -f else f
    let be := ((bits >>> 52) &&& 0x7FF).toNat
    let frac := (bits &&& 0xFFFFFFFFFFFFF).toNat
    -- |f| = m2 × 2^e2 exactly
    let (m2, e2) : Nat × Int := if be == 0 then (frac, -1074) else (frac + 2 ^ 52, (be : Int) - 1075)
    -- the decimal exponent k: 10^k ≤ |f| < 10^(k+1); estimated from the binary one, then fixed
    let atLeast (k : Int) : Bool := let (n, d) := scaled m2 e2 k; n ≥ d
    let est : Int := (Float.floor ((Float.ofInt (e2 + m2.log2)) * 0.30102999566398119)).toInt64.toInt
    let k := Id.run do
      let mut k := est
      while !atLeast k do k := k - 1
      while atLeast (k + 1) do k := k + 1
      return k
    let reads (q : Nat) (e : Int) : Bool := (normalize q e).toFloat == target
    -- With p significant digits the decimals nearest to f are f rounded down and up; p digits
    -- suffice when one of them reads back as f. (The rounding interval around f is convex but
    -- not symmetric at powers of two, so both sides are tried.) Sufficiency is monotone in p,
    -- because a p-digit decimal is also a (p+1)-digit one, so the least p is a binary search.
    let pick (p : Nat) : Option (Nat × Int) :=
      let e := k + 1 - p
      let (n, d) := scaled m2 e2 e
      let lo := n / d
      let r := n % d
      if r == 0 then some (lo, e) else
      match reads lo e, reads (lo + 1) e with
      | true, true => some (if 2 * r < d || (2 * r == d && lo % 2 == 0) then lo else lo + 1, e)
      | true, false => some (lo, e)
      | false, true => some (lo + 1, e)
      | false, false => none
    let p := Id.run do
      let mut lo := 1
      let mut hi := 17
      while lo < hi do
        let mid := (lo + hi) / 2
        if (pick mid).isSome then hi := mid else lo := mid + 1
      return lo
    let (q, e) := (pick p).getD (m2, e2)  -- 17 digits always suffice
    some (normalize (if neg then -(q : Int) else q) e)

/-- ECMAScript's `Number::toString` layout: plain digits for magnitudes in `[1e-6, 1e21)`,
otherwise `d.ddde±x`. -/
protected def toString (x : JsonNumber) : String :=
  if x.mantissa == 0 then "0" else
  let s := Nat.repr x.mantissa.natAbs
  let k : Int := s.length
  let n : Int := k + x.exponent
  let body :=
    if k ≤ n && n ≤ 21 then s.pushn '0' (n - k).toNat
    else if 0 < n && n ≤ 21 then (s.take n.toNat).toString ++ "." ++ (s.drop n.toNat).toString
    else if -6 < n && n ≤ 0 then ("0.".pushn '0' n.natAbs) ++ s
    else
      let e := n - 1
      let mant := if k == 1 then s else (s.take 1).toString ++ "." ++ (s.drop 1).toString
      mant ++ "e" ++ (if e < 0 then "-" else "+") ++ Nat.repr e.natAbs
  if x.mantissa < 0 then "-" ++ body else body

instance : ToString JsonNumber := ⟨JsonNumber.toString⟩

/-- Numeric order. -/
def lt (a b : JsonNumber) : Bool :=
  -- compare a.m × 10^a.e with b.m × 10^b.e by aligning exponents (bounded: far-apart
  -- magnitudes are decided by sign and digit count first)
  if a.mantissa.sign != b.mantissa.sign then a.mantissa.sign < b.mantissa.sign
  else if a.mantissa == 0 then false
  else
    let ma : Int := numDigits a.mantissa.natAbs + a.exponent
    let mb : Int := numDigits b.mantissa.natAbs + b.exponent
    let pos := a.mantissa > 0
    if ma != mb then (if pos then ma < mb else ma > mb)
    else
      let e := min a.exponent b.exponent
      a.mantissa * (10 : Int) ^ (a.exponent - e).toNat < b.mantissa * (10 : Int) ^ (b.exponent - e).toNat

instance : LT JsonNumber := ⟨fun a b => a.lt b = true⟩
instance (a b : JsonNumber) : Decidable (a < b) := inferInstanceAs (Decidable (a.lt b = true))

end JsonNumber

/-! ## Values -/

/-- A JSON value. -/
inductive Json where
  | null
  | bool (b : Bool)
  | num (n : JsonNumber)
  | str (s : String)
  | arr (elems : Array Json)
  /-- Keys in insertion order, without duplicates (use `Json.mkObj`/`setObjVal` to keep that). -/
  | obj (fields : Array (String × Json))

namespace Json

instance : Inhabited Json := ⟨.null⟩

/-- Structural equality; object fields compare as maps (order does not matter). -/
protected partial def beq : Json → Json → Bool
  | .null, .null => true
  | .bool a, .bool b => a == b
  | .num a, .num b => a == b
  | .str a, .str b => a == b
  | .arr a, .arr b => a.size == b.size && (a.zip b).all fun (x, y) => Json.beq x y
  | .obj a, .obj b =>
    a.size == b.size && a.all fun (k, v) =>
      match b.find? (·.1 == k) with
      | some (_, w) => Json.beq v w
      | none => false
  | _, _ => false

instance : BEq Json := ⟨Json.beq⟩

instance : OfNat Json n := ⟨.num (JsonNumber.ofNat n)⟩
instance : Coe String Json := ⟨.str⟩
instance : Coe Bool Json := ⟨.bool⟩
instance : Coe JsonNumber Json := ⟨.num⟩

/-- `"null"`, `"boolean"`, `"number"`, `"string"`, `"array"` or `"object"`. -/
def kind : Json → String
  | .null => "null" | .bool _ => "boolean" | .num _ => "number" | .str _ => "string"
  | .arr _ => "array" | .obj _ => "object"

/-! ### Objects and arrays -/

/-- An object from fields; a repeated key keeps its first position and its last value. -/
def mkObj (fields : List (String × Json)) : Json :=
  .obj <| fields.foldl (init := #[]) fun acc (k, v) =>
    match acc.findIdx? (·.1 == k) with
    | some i => acc.set! i (k, v)
    | none => acc.push (k, v)

/-- The value of field `k`, if this is an object that has it. -/
def find? (j : Json) (k : String) : Option Json :=
  match j with
  | .obj fs => (fs.find? (·.1 == k)).map (·.2)
  | _ => none

/-- Element `i`, if this is an array long enough. -/
def at? (j : Json) (i : Nat) : Option Json :=
  match j with
  | .arr xs => xs[i]?
  | _ => none

/-- `j["name"]?` reads an object field and `j[3]?` an array element. -/
instance : GetElem? Json String Json (fun _ _ => False) where
  getElem _ _ h := h.elim
  getElem? j k := j.find? k

instance : GetElem? Json Nat Json (fun _ _ => False) where
  getElem _ _ h := h.elim
  getElem? j i := j.at? i

/-- Set field `k` (replacing it in place, or appending it). A non-object becomes an object. -/
def setObjVal (j : Json) (k : String) (v : Json) : Json :=
  match j with
  | .obj fs =>
    match fs.findIdx? (·.1 == k) with
    | some i => .obj (fs.set! i (k, v))
    | none => .obj (fs.push (k, v))
  | _ => .obj #[(k, v)]

def eraseObjVal (j : Json) (k : String) : Json :=
  match j with
  | .obj fs => .obj (fs.filter (·.1 != k))
  | j => j

/-- Fields of `b` override those of `a` (shallow). -/
def mergeObj (a b : Json) : Json :=
  match a, b with
  | .obj _, .obj fs => fs.foldl (fun acc (k, v) => acc.setObjVal k v) a
  | _, b => b

/-- Fields for `mkObj` from an optional value: `[]` when it is `none`. -/
def opt (k : String) (v : Option Json) : List (String × Json) :=
  match v with
  | some v => [(k, v)]
  | none => []

/-- Apply `f` to every number (for example, to round-trip a document through doubles). -/
partial def mapNumbers (f : JsonNumber → Json) : Json → Json
  | .num n => f n
  | .arr xs => .arr (xs.map (mapNumbers f))
  | .obj fs => .obj (fs.map fun (k, v) => (k, mapNumbers f v))
  | j => j

/-! ## Printing -/

def hexDigit (n : Nat) : Char :=
  if n < 10 then Char.ofNat (48 + n) else Char.ofNat (87 + n)

def pushU4 (acc : String) (u : Nat) : String :=
  acc ++ "\\u" |>.push (hexDigit (u / 4096 % 16)) |>.push (hexDigit (u / 256 % 16))
    |>.push (hexDigit (u / 16 % 16)) |>.push (hexDigit (u % 16))

/-- Append `s` as a JSON string literal. Escapes exactly what `JSON.stringify` escapes (`"`,
`\`, control characters); with `ascii`, also every non-ASCII character (as `\uXXXX`, with
surrogate pairs above U+FFFF). -/
def escapeInto (acc : String) (s : String) (ascii := false) : String :=
  let acc := s.foldl (init := acc.push '"') fun acc c =>
    let v := c.toNat
    if c == '"' then acc ++ "\\\""
    else if c == '\\' then acc ++ "\\\\"
    else if v < 0x20 then
      if c == '\n' then acc ++ "\\n" else if c == '\r' then acc ++ "\\r"
      else if c == '\t' then acc ++ "\\t" else if v == 8 then acc ++ "\\b"
      else if v == 12 then acc ++ "\\f" else pushU4 acc v
    else if ascii && v > 0x7E then
      if v < 0x10000 then pushU4 acc v
      else let w := v - 0x10000; pushU4 (pushU4 acc (0xD800 + w / 1024)) (0xDC00 + w % 1024)
    else acc.push c
  acc.push '"'

/-- `s` as a JSON string literal. -/
def escape (s : String) (ascii := false) : String := escapeInto "" s ascii

partial def compressInto (acc : String) (ascii : Bool) : Json → String
  | .null => acc ++ "null"
  | .bool true => acc ++ "true"
  | .bool false => acc ++ "false"
  | .num n => acc ++ n.toString
  | .str s => escapeInto acc s ascii
  | .arr xs =>
    let (acc, _) := xs.foldl (init := (acc.push '[', true)) fun (acc, first) x =>
      (compressInto (if first then acc else acc.push ',') ascii x, false)
    acc.push ']'
  | .obj fs =>
    let (acc, _) := fs.foldl (init := (acc.push '{', true)) fun (acc, first) (k, v) =>
      (compressInto ((escapeInto (if first then acc else acc.push ',') k ascii).push ':') ascii v, false)
    acc.push '}'

/-- Compact JSON, byte-for-byte what `JSON.stringify(v)` prints. -/
def compress (j : Json) (ascii := false) : String := compressInto "" ascii j

partial def prettyInto (acc : String) (indent cur : String) (ascii : Bool) : Json → String
  | .arr #[] => acc ++ "[]"
  | .obj #[] => acc ++ "{}"
  | .arr xs =>
    let inner := cur ++ indent
    let (acc, _) := xs.foldl (init := (acc.push '[', true)) fun (acc, first) x =>
      (prettyInto ((if first then acc else acc.push ',').push '\n' ++ inner) indent inner ascii x, false)
    (acc.push '\n' ++ cur).push ']'
  | .obj fs =>
    let inner := cur ++ indent
    let (acc, _) := fs.foldl (init := (acc.push '{', true)) fun (acc, first) (k, v) =>
      let acc := escapeInto ((if first then acc else acc.push ',').push '\n' ++ inner) k ascii ++ ": "
      (prettyInto acc indent inner ascii v, false)
    (acc.push '\n' ++ cur).push '}'
  | j => compressInto acc ascii j

/-- Indented JSON, byte-for-byte what `JSON.stringify(v, null, indent)` prints. -/
def pretty (j : Json) (indent := 2) (ascii := false) : String := prettyInto "" ("".pushn ' ' indent) "" ascii j

instance : ToString Json := ⟨compress⟩
instance : Repr Json := ⟨fun j _ => .text (compress j)⟩

/-! ## Parsing -/

/-- Where and why a document is not JSON. `offset` is in bytes, `line` and `column` count from
1, and the column counts characters. -/
structure ParseError where
  offset : Nat
  line : Nat
  column : Nat
  message : String
  deriving Repr, BEq, Inhabited

instance : ToString ParseError := ⟨fun e => s!"line {e.line}, column {e.column}: {e.message}"⟩

namespace Parser

/-- Parser results: a value and the position after it, or a byte offset and a message. -/
abbrev P := Except (Nat × String)

@[inline] def isWs (b : UInt8) : Bool := b == 32 || b == 10 || b == 13 || b == 9
@[inline] def isDigit (b : UInt8) : Bool := b ≥ 48 && b ≤ 57

partial def skipWs (s : ByteArray) (i : Nat) : Nat :=
  if h : i < s.size then (if isWs s[i] then skipWs s (i + 1) else i) else i

/-- `n` in upper-case hex, at least `width` digits. -/
def hexUpper (n : Nat) (width := 4) : String :=
  let h := (String.ofList (Nat.toDigits 16 n)).toUpper
  "".pushn '0' (width - h.length) ++ h

/-- The character at byte `i`, for error messages. -/
def describeAt (s : ByteArray) (i : Nat) : String :=
  if h : i < s.size then
    let b := s[i]
    if b ≥ 0x21 && b < 0x7F then s!"'{Char.ofNat b.toNat}'"
    else
      -- decode one UTF-8 sequence for a readable code point
      let len := if b < 0x80 then 1 else if b < 0xE0 then 2 else if b < 0xF0 then 3 else 4
      match String.fromUTF8? (s.extract i (i + len)) with
      | some ch => s!"U+{hexUpper ch.front.toNat}"
      | none => s!"byte 0x{hexUpper b.toNat 2}"
  else "the end of the input"

def unexpected (s : ByteArray) (i : Nat) (expected : String) : Except (Nat × String) α :=
  .error (i, s!"expected {expected}, found {describeAt s i}")

@[inline] def hexVal (b : UInt8) : Option Nat :=
  if b ≥ 48 && b ≤ 57 then some (b - 48).toNat
  else if b ≥ 97 && b ≤ 102 then some (b - 87).toNat
  else if b ≥ 65 && b ≤ 70 then some (b - 55).toNat
  else none

/-- Four hex digits at `i`. -/
def hex4 (s : ByteArray) (i : Nat) : Except (Nat × String) Nat := do
  let mut v := 0
  for k in [0:4] do
    match hexVal (s[i + k]?.getD 0) with
    | some d => v := v * 16 + d
    | none => throw (i + k, s!"expected 4 hex digits after \\u, found {describeAt s (i + k)}")
  return v

/-- Append the UTF-8 encoding of code point `c`. -/
def pushUtf8 (b : ByteArray) (c : Nat) : ByteArray :=
  if c < 0x80 then b.push c.toUInt8
  else if c < 0x800 then b.push (0xC0 + c / 64).toUInt8 |>.push (0x80 + c % 64).toUInt8
  else if c < 0x10000 then
    b.push (0xE0 + c / 4096).toUInt8 |>.push (0x80 + c / 64 % 64).toUInt8 |>.push (0x80 + c % 64).toUInt8
  else
    b.push (0xF0 + c / 262144).toUInt8 |>.push (0x80 + c / 4096 % 64).toUInt8
      |>.push (0x80 + c / 64 % 64).toUInt8 |>.push (0x80 + c % 64).toUInt8

/-- One escape sequence; `i` is at the backslash. Lone surrogates (which a Lean `String` cannot
hold) become U+FFFD. -/
def escapeSeq (s : ByteArray) (i : Nat) (buf : ByteArray) : Except (Nat × String) (ByteArray × Nat) := do
  let some b := s[i + 1]? | throw (i, "unterminated string")
  match b with
  | 34 => return (buf.push 34, i + 2)
  | 92 => return (buf.push 92, i + 2)
  | 47 => return (buf.push 47, i + 2)
  | 98 => return (buf.push 8, i + 2)
  | 102 => return (buf.push 12, i + 2)
  | 110 => return (buf.push 10, i + 2)
  | 114 => return (buf.push 13, i + 2)
  | 116 => return (buf.push 9, i + 2)
  | 117 =>
    let u ← hex4 s (i + 2)
    if u ≥ 0xD800 && u < 0xDC00 then
      -- a high surrogate: combine with a following \uDC00-\uDFFF
      if s[i + 6]? == some 92 && s[i + 7]? == some 117 then
        match hex4 s (i + 8) with
        | .ok lo =>
          if lo ≥ 0xDC00 && lo < 0xE000 then
            return (pushUtf8 buf (0x10000 + (u - 0xD800) * 1024 + (lo - 0xDC00)), i + 12)
          else return (pushUtf8 buf 0xFFFD, i + 6)
        | .error e => throw e
      else return (pushUtf8 buf 0xFFFD, i + 6)
    else if u ≥ 0xDC00 && u < 0xE000 then return (pushUtf8 buf 0xFFFD, i + 6)
    else return (pushUtf8 buf u, i + 6)
  | _ => throw (i, s!"invalid escape sequence: backslash followed by {describeAt s (i + 1)}")

def toStr (bytes : ByteArray) (at_ : Nat) : Except (Nat × String) String :=
  match String.fromUTF8? bytes with
  | some s => .ok s
  | none => .error (at_, "invalid UTF-8 in string")

/-- A string literal; `i` is just after the opening quote. -/
partial def string (s : ByteArray) (i : Nat) : P (String × Nat) :=
  let rec go (j runStart : Nat) (buf : ByteArray) (escaped : Bool) : P (String × Nat) := do
    if h : j < s.size then
      let b := s[j]
      if b == 34 then
        let bytes := if escaped then s.copySlice runStart buf buf.size (j - runStart) false else s.extract i j
        return (← toStr bytes j, j + 1)
      else if b == 92 then
        let buf := s.copySlice runStart buf buf.size (j - runStart) false
        let (buf, k) ← escapeSeq s j buf
        go k k buf true
      else if b < 0x20 then
        throw (j, s!"control character U+{hexUpper b.toNat} must be escaped in a string")
      else go (j + 1) runStart buf escaped
    else throw (i - 1, "unterminated string")
  go i i ByteArray.empty false

/-- The decimal digits at `[a, b)`, skipping the byte at `skip` (the decimal point); read 18
digits at a time so long numbers stay cheap. -/
def digitsToNat (s : ByteArray) (a b : Nat) (skip : Nat) : Nat := Id.run do
  let mut acc := 0
  let mut chunk := 0
  let mut len := 0
  for k in [a:b] do
    if k != skip then
      chunk := chunk * 10 + (s[k]! - 48).toNat
      len := len + 1
      if len == 18 then
        acc := acc * 1000000000000000000 + chunk
        chunk := 0; len := 0
  return acc * 10 ^ len + chunk

partial def scanDigits (s : ByteArray) (i : Nat) : Nat :=
  if h : i < s.size then (if isDigit s[i] then scanDigits s (i + 1) else i) else i

/-- A number literal starting at `i`. -/
def number (s : ByteArray) (i : Nat) : P (JsonNumber × Nat) := do
  let neg := s[i]? == some 45
  let j := if neg then i + 1 else i
  let some d := s[j]? | throw (j, "expected a digit, found the end of the input")
  unless isDigit d do unexpected s j "a digit"
  let intEnd := if d == 48 then j + 1 else scanDigits s j
  if d == 48 && (s[intEnd]?.map isDigit).getD false then
    throw (intEnd, "leading zeros are not allowed")
  -- fraction
  let (dot, fracEnd) ← if s[intEnd]? == some 46 then do
      let e := scanDigits s (intEnd + 1)
      if e == intEnd + 1 then unexpected s e "a digit after the decimal point"
      pure (intEnd, e)
    else pure (s.size + 1, intEnd)
  let fracLen := if dot ≤ s.size then fracEnd - dot - 1 else 0
  -- exponent
  let (expo, endPos) ← if s[fracEnd]? == some 101 || s[fracEnd]? == some 69 then do
      let sgn := s[fracEnd + 1]?
      let a := if sgn == some 43 || sgn == some 45 then fracEnd + 2 else fracEnd + 1
      let e := scanDigits s a
      if e == a then unexpected s e "a digit in the exponent"
      let v : Int := digitsToNat s a e (s.size + 1)
      pure (if sgn == some 45 then -v else v, e)
    else pure (0, fracEnd)
  -- trailing zeros of the digit string go into the exponent
  let mut tz := 0
  let mut k := fracEnd
  while k > j do
    k := k - 1
    if k == dot then continue
    if s[k]! == 48 then tz := tz + 1 else break
  let digits := (fracEnd - j) - (if dot ≤ s.size then 1 else 0)
  if tz == digits then return (JsonNumber.zero, endPos)
  -- the significant digits end `tz` digits before fracEnd (counting past the dot)
  let mut stop := fracEnd
  let mut left := tz
  while left > 0 do
    stop := stop - 1
    if stop != dot then left := left - 1
  let m := digitsToNat s j stop dot
  return (⟨if neg then -(m : Int) else m, expo - fracLen + tz⟩, endPos)

def literal (s : ByteArray) (i : Nat) (word : String) (v : Json) : P (Json × Nat) :=
  let w := word.toUTF8
  if s.extract i (i + w.size) == w then .ok (v, i + w.size)
  else .error (i, s!"expected a value, found {describeAt s i}")

/-- Insert or overwrite a key. Small objects scan; large ones keep a key index. -/
@[inline] def addField (fs : Array (String × Json)) (idx : Std.HashMap String Nat) (k : String) (v : Json) :
    Array (String × Json) × Std.HashMap String Nat :=
  if fs.size < 8 then
    match fs.findIdx? (·.1 == k) with
    | some p => (fs.set! p (k, v), idx)
    | none =>
      let fs := fs.push (k, v)
      if fs.size == 8 then (fs, fs.foldl (init := (idx, 0)) (fun (m, n) (key, _) => (m.insert key n, n + 1)) |>.1)
      else (fs, idx)
  else
    match idx.get? k with
    | some p => (fs.set! p (k, v), idx)
    | none => (fs.push (k, v), idx.insert k fs.size)

mutual
partial def value (s : ByteArray) (i : Nat) (depth maxDepth : Nat) : P (Json × Nat) := do
  let i := skipWs s i
  let some b := s[i]? | throw (i, "expected a value, found the end of the input")
  if b == 123 then object s i depth maxDepth
  else if b == 91 then array s i depth maxDepth
  else if b == 34 then
    let (text, j) ← string s (i + 1)
    return (.str text, j)
  else if b == 116 then literal s i "true" (.bool true)
  else if b == 102 then literal s i "false" (.bool false)
  else if b == 110 then literal s i "null" .null
  else if b == 45 || isDigit b then
    let (n, j) ← number s i
    return (.num n, j)
  else unexpected s i "a value"

partial def array (s : ByteArray) (i : Nat) (depth maxDepth : Nat) : P (Json × Nat) := do
  if depth ≥ maxDepth then throw (i, s!"nesting deeper than {maxDepth} levels")
  let j := skipWs s (i + 1)
  if s[j]? == some 93 then return (.arr #[], j + 1)
  let rec items (j : Nat) (acc : Array Json) : P (Json × Nat) := do
    let (v, j) ← value s j (depth + 1) maxDepth
    let acc := acc.push v
    let j := skipWs s j
    match s[j]? with
    | some 44 => items (j + 1) acc
    | some 93 => return (.arr acc, j + 1)
    | _ => unexpected s j "',' or ']'"
  items j #[]

partial def object (s : ByteArray) (i : Nat) (depth maxDepth : Nat) : P (Json × Nat) := do
  if depth ≥ maxDepth then throw (i, s!"nesting deeper than {maxDepth} levels")
  let j := skipWs s (i + 1)
  if s[j]? == some 125 then return (.obj #[], j + 1)
  let rec fields (j : Nat) (acc : Array (String × Json)) (idx : Std.HashMap String Nat) : P (Json × Nat) := do
    let j := skipWs s j
    unless s[j]? == some 34 do unexpected s j "a string key"
    let (k, j) ← string s (j + 1)
    let j := skipWs s j
    unless s[j]? == some 58 do unexpected s j "':' after the key"
    let (v, j) ← value s (j + 1) (depth + 1) maxDepth
    let (acc, idx) := addField acc idx k v
    let j := skipWs s j
    match s[j]? with
    | some 44 => fields (j + 1) acc idx
    | some 125 => return (.obj acc, j + 1)
    | _ => unexpected s j "',' or '}'"
  fields j #[] {}
end

/-- Line and column (both from 1; the column counts characters) of byte offset `off`. -/
def lineCol (s : ByteArray) (off : Nat) : Nat × Nat := Id.run do
  let mut line := 1
  let mut col := 1
  for k in [0:min off s.size] do
    let b := s[k]!
    if b == 10 then line := line + 1; col := 1
    else if b &&& 0xC0 != 0x80 then col := col + 1
  return (line, col)

end Parser

/-- Parse a JSON document (RFC 8259). Arrays and objects may nest `maxDepth` levels. -/
def parseE (input : String) (maxDepth := 512) : Except ParseError Json :=
  let s := input.toUTF8
  let r : Except (Nat × String) Json := do
    let (v, j) ← Parser.value s 0 0 maxDepth
    let j := Parser.skipWs s j
    if j < s.size then throw (j, s!"unexpected {Parser.describeAt s j} after the JSON value")
    return v
  match r with
  | .ok v => .ok v
  | .error (off, msg) =>
    let (line, column) := Parser.lineCol s off
    .error { offset := off, line, column, message := msg }

/-- Parse a JSON document; the error says where (`line 3, column 7: ...`). -/
def parse (input : String) (maxDepth := 512) : Except String Json :=
  (parseE input maxDepth).mapError toString

/-- Parse UTF-8 bytes (for example a fetched body read as bytes). -/
def parseUTF8 (bytes : ByteArray) (maxDepth := 512) : Except String Json :=
  match String.fromUTF8? bytes with
  | some s => parse s maxDepth
  | none => .error "the input is not valid UTF-8"

/-! ## Reading values -/

/-- A short description of a value for error messages: `42`, `"abc"`, `an object`. -/
def describe : Json → String
  | .null => "null"
  | .bool b => toString b
  | .num n => n.toString
  | .str s => if s.length ≤ 24 then escape s else escape ((s.take 21).toString ++ "...")
  | .arr _ => "an array"
  | .obj _ => "an object"

def getStr? : Json → Except String String
  | .str s => .ok s | j => .error s!"expected a string, got {j.describe}"
def getBool? : Json → Except String Bool
  | .bool b => .ok b | j => .error s!"expected a boolean, got {j.describe}"
def getNum? : Json → Except String JsonNumber
  | .num n => .ok n | j => .error s!"expected a number, got {j.describe}"
def getInt? : Json → Except String Int
  | .num n => match n.toInt? with | some i => .ok i | none => .error s!"expected an integer, got {n}"
  | j => .error s!"expected an integer, got {j.describe}"
def getNat? : Json → Except String Nat
  | .num n => match n.toNat? with | some i => .ok i | none => .error s!"expected a natural number, got {n}"
  | j => .error s!"expected a natural number, got {j.describe}"
def getFloat? : Json → Except String Float
  | .num n => .ok n.toFloat | j => .error s!"expected a number, got {j.describe}"
def getArr? : Json → Except String (Array Json)
  | .arr xs => .ok xs | j => .error s!"expected an array, got {j.describe}"
def getObj? : Json → Except String (Array (String × Json))
  | .obj fs => .ok fs | j => .error s!"expected an object, got {j.describe}"

/-- Field `k` of an object. -/
def getObjVal? (j : Json) (k : String) : Except String Json :=
  match j with
  | .obj fs => match fs.find? (·.1 == k) with
    | some (_, v) => .ok v
    | none => .error s!"missing field {escape k}"
  | j => .error s!"expected an object, got {j.describe}"

/-- Field `k`, or `null` if it is missing. -/
def getObjValD (j : Json) (k : String) : Json := (j.find? k).getD .null

/-- Element `i` of an array. -/
def getArrVal? (j : Json) (i : Nat) : Except String Json :=
  match j with
  | .arr xs => match xs[i]? with
    | some v => .ok v
    | none => .error s!"index {i} out of bounds (length {xs.size})"
  | j => .error s!"expected an array, got {j.describe}"

end Json

/-! ## Conversions -/

/-- Values that have a JSON form. -/
class ToJson (α : Type u) where
  toJson : α → Json

/-- Values that can be read back from JSON. Errors start with the path to the bad value when
it is nested (`.users[3].name: expected a string, got 42`). -/
class FromJson (α : Type u) where
  fromJson? : Json → Except String α

export ToJson (toJson)
export FromJson (fromJson?)

namespace Json

def isIdent (k : String) : Bool :=
  !k.isEmpty && k.all (fun c => c.isAlphanum || c == '_') && !(k.front.isDigit)

/-- Prefix a decoding error with one path step (`.name` or `[3]`). -/
def withPath (step : String) (r : Except String α) : Except String α :=
  r.mapError fun e => if e.startsWith "." || e.startsWith "[" then step ++ e else step ++ ": " ++ e

/-- The path step for field `k`: `.name`, or `["odd key"]`. -/
def fieldStep (k : String) : String := if isIdent k then "." ++ k else "[" ++ escape k ++ "]"

/-- Decode field `k` of an object. A missing field decodes like `null`, so `Option` fields may
be left out; other types report the field as missing. -/
def getObjValAs? (j : Json) (α : Type) [FromJson α] (k : String) : Except String α :=
  match j with
  | .obj fs => match fs.find? (·.1 == k) with
    | some (_, v) => withPath (fieldStep k) (fromJson? v)
    | none => match (fromJson? Json.null : Except String α) with
      | .ok a => .ok a
      | .error _ => .error s!"missing field {escape k}"
  | j => .error s!"expected an object, got {j.describe}"

/-- Decode field `k` if it is present (`none` if it is missing), for fields that have a
default value. -/
def getObjValAsOpt? (j : Json) (α : Type) [FromJson α] (k : String) : Except String (Option α) :=
  match j with
  | .obj fs => match fs.find? (·.1 == k) with
    | some (_, v) => some <$> withPath (fieldStep k) (fromJson? v)
    | none => .ok none
  | j => .error s!"expected an object, got {j.describe}"

/-- Decode element `i` of an array. -/
def getArrValAs? (j : Json) (α : Type) [FromJson α] (i : Nat) : Except String α := do
  withPath s!"[{i}]" (fromJson? (← j.getArrVal? i))

/-- A constructor tag, as derived instances encode inductive types: `"name"` for a constructor
without fields, `{"name": payload}` otherwise. Returns the name and the payload (`null` for a
bare string). -/
def getTag? (j : Json) : Except String (String × Json) :=
  match j with
  | .str s => .ok (s, .null)
  | .obj #[(k, v)] => .ok (k, v)
  | j => .error s!"expected a constructor (a string or an object with one field), got {j.describe}"

/-- An array of exactly `n` elements. -/
def getArrN? (j : Json) (n : Nat) : Except String (Array Json) := do
  let xs ← j.getArr?
  if xs.size == n then return xs else throw s!"expected an array of {n} elements, got {xs.size}"

/-- Parse and decode a document; errors are rooted at `$`. -/
def decode (α : Type) [FromJson α] (input : String) : Except String α := do
  let j ← parse input
  (fromJson? j : Except String α).mapError fun e =>
    if e.startsWith "." || e.startsWith "[" then "$" ++ e else e

/-- `toJson a`, printed compactly. -/
def encode [ToJson α] (a : α) : String := (toJson a).compress

end Json

instance : ToJson Json := ⟨id⟩
instance : FromJson Json := ⟨.ok⟩
instance : ToJson JsonNumber := ⟨.num⟩
instance : FromJson JsonNumber := ⟨Json.getNum?⟩
instance : ToJson Bool := ⟨.bool⟩
instance : FromJson Bool := ⟨Json.getBool?⟩
instance : ToJson String := ⟨.str⟩
instance : FromJson String := ⟨Json.getStr?⟩
instance : ToJson Nat := ⟨fun n => .num (JsonNumber.ofNat n)⟩
instance : FromJson Nat := ⟨Json.getNat?⟩
instance : ToJson Int := ⟨fun n => .num (JsonNumber.ofInt n)⟩
instance : FromJson Int := ⟨Json.getInt?⟩
instance : ToJson Unit := ⟨fun _ => .null⟩
instance : FromJson Unit := ⟨fun | .null => .ok () | j => .error s!"expected null, got {j.describe}"⟩

instance : ToJson Char := ⟨fun c => .str (String.singleton c)⟩
instance : FromJson Char where
  fromJson? j := do
    let s ← j.getStr?
    if s.length == 1 then return s.front else throw s!"expected a one-character string, got {j.describe}"

def Json.boundedNat (what : String) (bound : Nat) (j : Json) : Except String Nat := do
  let n ← j.getNat?
  if n < bound then return n else throw s!"expected a {what}, got {n}"

instance : ToJson UInt8 := ⟨fun n => toJson n.toNat⟩
instance : FromJson UInt8 := ⟨fun j => (·.toUInt8) <$> Json.boundedNat "UInt8" 256 j⟩
instance : ToJson UInt16 := ⟨fun n => toJson n.toNat⟩
instance : FromJson UInt16 := ⟨fun j => (·.toUInt16) <$> Json.boundedNat "UInt16" 65536 j⟩
instance : ToJson UInt32 := ⟨fun n => toJson n.toNat⟩
instance : FromJson UInt32 := ⟨fun j => (·.toUInt32) <$> Json.boundedNat "UInt32" (2 ^ 32) j⟩
instance : ToJson UInt64 := ⟨fun n => toJson n.toNat⟩
instance : FromJson UInt64 := ⟨fun j => (·.toUInt64) <$> Json.boundedNat "UInt64" (2 ^ 64) j⟩

/-- Finite doubles are numbers (shortest round-trip digits); NaN and the infinities, which JSON
has no number for, are the strings `"NaN"`, `"Infinity"`, `"-Infinity"` (as in `Lean.Json`). -/
instance : ToJson Float where
  toJson f := match JsonNumber.ofFloat? f with
    | some n => .num n
    | none => .str (if f.isNaN then "NaN" else if f > 0 then "Infinity" else "-Infinity")
instance : FromJson Float where
  fromJson?
    | .num n => .ok n.toFloat
    | .str "NaN" => .ok (0.0 / 0.0)
    | .str "Infinity" => .ok (1.0 / 0.0)
    | .str "-Infinity" => .ok (-1.0 / 0.0)
    | j => .error s!"expected a number, got {j.describe}"

instance [ToJson α] : ToJson (Option α) := ⟨fun | some a => toJson a | none => .null⟩
instance [FromJson α] : FromJson (Option α) := ⟨fun | .null => .ok none | j => some <$> fromJson? j⟩

instance [ToJson α] : ToJson (Array α) := ⟨fun xs => .arr (xs.map toJson)⟩
instance [FromJson α] : FromJson (Array α) where
  fromJson? j := do
    let xs ← j.getArr?
    let mut out := Array.mkEmpty xs.size
    for h : i in [0:xs.size] do
      out := out.push (← Json.withPath s!"[{i}]" (fromJson? xs[i]))
    return out

instance [ToJson α] : ToJson (List α) := ⟨fun xs => .arr (xs.toArray.map toJson)⟩
instance [FromJson α] : FromJson (List α) := ⟨fun j => Array.toList <$> (fromJson? j : Except String (Array α))⟩

/-- Pairs are two-element arrays. -/
instance [ToJson α] [ToJson β] : ToJson (α × β) := ⟨fun (a, b) => .arr #[toJson a, toJson b]⟩
instance [FromJson α] [FromJson β] : FromJson (α × β) where
  fromJson? j := do
    let xs ← j.getArrN? 2
    return (← Json.withPath "[0]" (fromJson? xs[0]!), ← Json.withPath "[1]" (fromJson? xs[1]!))

end LeanUI
