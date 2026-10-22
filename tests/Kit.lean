module
public import LeanUI
public import LeanUI.Json
public import LeanUI.Router
public import LeanUI.Testing.Harness
public import Effects
public import Pixels
public import Life
public import Roster.Solver
meta import LeanUI.Json.Derive
/-!
# Tests for the kit: `LeanUI.Json`, `LeanUI.Router`, and the effects lab

`lake build leanui-kit-tests && .lake/build/bin/leanui-kit-tests` (from the repository root: the
effects tests read `examples/effects-assets/*.json`).

* JSON: accepted and rejected documents (JSONTestSuite-style, with exact error positions),
  canonical number printing, correctly rounded number reading (checked against exact rational
  arithmetic), shortest float printing (round trip, minimality, closest), the printers'
  `JSON.stringify` formats, every `ToJson`/`FromJson` instance, derived instances, accessors.
* Router: percent-encoding, URL parsing and printing, RFC 3986 reference resolution (the RFC's
  own examples), route parse/print round trips (random pages, base paths, hash routing).
* The effects lab running in the DOM model (`LeanUI.Testing`): every command it emits and every
  callback it handles, as the browser would drive it.
* Input payloads (`LeanUI.Input`), the pixel and file commands (the pixels lab in the DOM model),
  and that `update` gets the model uniquely owned (an array in it is updated in place).
* Life (`examples/Life.lean`): the board after 0, 100 and 1,000 generations, the values the race
  page's three implementations must show (`tests/browser/race.mjs`), and 100 clicks on Step in
  the DOM model.
* Roster (`examples/Roster`): on 600 random problems (167 can be staffed) and six edge cases, the
  solver's answer always passes `checkAnswer`, and every lie that changes it is rejected; the
  presets.
-/
public section
open LeanUI

/-! ## A tiny test framework -/

instance {ε α : Type} [BEq ε] [BEq α] : BEq (Except ε α) where
  beq | .ok a, .ok b => a == b | .error a, .error b => a == b | _, _ => false

structure Suite where
  passed : Nat := 0
  failed : Array String := #[]

abbrev T := StateT Suite IO

def expect (name : String) (ok : Bool) (detail : String := "") : T Unit :=
  modify fun s => if ok then { s with passed := s.passed + 1 } else { s with failed := s.failed.push s!"{name}: {detail}" }

def expectEq {α : Type} [BEq α] [Repr α] (name : String) (got want : α) : T Unit :=
  expect name (got == want) s!"got {reprStr got}, want {reprStr want}"

def section_ (title : String) (body : T Unit) : T Unit := do
  let before ← get
  let t0 ← IO.monoMsNow
  body
  let t1 ← IO.monoMsNow
  let after ← get
  let newFails := after.failed.size - before.failed.size
  IO.println s!"  {title}: {after.passed - before.passed} checks{if newFails == 0 then "" else s!", {newFails} FAILED"} ({t1 - t0} ms)"

/-- A deterministic PRNG (64-bit LCG, high bits). -/
structure Rng where
  s : UInt64
def Rng.next (r : Rng) : Rng × UInt64 :=
  let s := r.s * 6364136223846793005 + 1442695040888963407
  (⟨s⟩, s ^^^ (s >>> 29))
def Rng.below (r : Rng) (n : Nat) : Rng × Nat := let (r, x) := r.next; (r, if n == 0 then 0 else (x >>> 11).toNat % n)
def Rng.bits64 (r : Rng) : Rng × UInt64 :=
  let (r, a) := r.next; let (r, b) := r.next; (r, (a >>> 32 <<< 32) ||| (b >>> 32))

/-! ## JSON: documents -/

/-- Documents that must parse, and their compact form. -/
def accepted : List (String × String) := [
  ("[]", "[]"), ("{}", "{}"), (" \t\n\r[ 1 , 2 ]\r\n ", "[1,2]"),
  ("[true,false,null]", "[true,false,null]"),
  ("\"\"", "\"\""), ("\"\\u0000\"", "\"\\u0000\""), ("\"\\u001f\\u007f\"", "\"\\u001f\u007f\""),
  ("\"\\\"\\\\\\/\\b\\f\\n\\r\\t\"", "\"\\\"\\\\/\\b\\f\\n\\r\\t\""),
  ("\"\\u00e9\\u4E2D\\ud83d\\ude00\"", "\"é中😀\""), ("\"\\uD834\\uDD1E\"", "\"𝄞\""),
  ("\"é中😀\"", "\"é中😀\""), ("\"\u2028\u2029\"", "\"\u2028\u2029\""),
  ("-0", "0"), ("-0.0e+0", "0"), ("0e5", "0"), ("1E+2", "100"), ("1e-2", "0.01"), ("123.4560", "123.456"),
  ("0.1e1", "1"), ("[-1.5e-7]", "[-1.5e-7]"), ("[1e400]", "[1e+400]"), ("1E-400", "1e-400"),
  ("{\"a\":{\"b\":{\"c\":[{}]}}}", "{\"a\":{\"b\":{\"c\":[{}]}}}"),
  ("{\"a\":1,\"b\":2,\"a\":3}", "{\"a\":3,\"b\":2}"), ("{\"\":0}", "{\"\":0}"),
  ("{\"k\" : [ 1 , { \"x\" : \"y\" } ] }", "{\"k\":[1,{\"x\":\"y\"}]}"),
  ("123456789012345678901234567890", "1.2345678901234567890123456789e+29")]

/-- Documents that must be rejected, with the exact error. -/
def rejected : List (String × String) := [
  ("", "line 1, column 1: expected a value, found the end of the input"),
  ("[1,]", "line 1, column 4: expected a value, found ']'"),
  ("[1 2]", "line 1, column 4: expected ',' or ']', found '2'"),
  ("{\"a\":1,}", "line 1, column 8: expected a string key, found '}'"),
  ("{a:1}", "line 1, column 2: expected a string key, found 'a'"),
  ("{\"a\" 1}", "line 1, column 6: expected ':' after the key, found '1'"),
  ("{\"a\":1", "line 1, column 7: expected ',' or '}', found the end of the input"),
  ("[", "line 1, column 2: expected a value, found the end of the input"),
  ("01", "line 1, column 2: leading zeros are not allowed"),
  ("-01", "line 1, column 3: leading zeros are not allowed"),
  ("-", "line 1, column 2: expected a digit, found the end of the input"),
  ("-a", "line 1, column 2: expected a digit, found 'a'"),
  ("1.", "line 1, column 3: expected a digit after the decimal point, found the end of the input"),
  ("1.e3", "line 1, column 3: expected a digit after the decimal point, found 'e'"),
  (".5", "line 1, column 1: expected a value, found '.'"),
  ("1e", "line 1, column 3: expected a digit in the exponent, found the end of the input"),
  ("1e+", "line 1, column 4: expected a digit in the exponent, found the end of the input"),
  ("+1", "line 1, column 1: expected a value, found '+'"),
  ("NaN", "line 1, column 1: expected a value, found 'N'"),
  ("Infinity", "line 1, column 1: expected a value, found 'I'"),
  ("tru", "line 1, column 1: expected a value, found 't'"),
  ("nul", "line 1, column 1: expected a value, found 'n'"),
  ("True", "line 1, column 1: expected a value, found 'T'"),
  ("'a'", "line 1, column 1: expected a value, found '''"),
  ("\"a", "line 1, column 1: unterminated string"),
  ("\"\\x\"", "line 1, column 2: invalid escape sequence: backslash followed by 'x'"),
  ("\"\\u12\"", "line 1, column 6: expected 4 hex digits after \\u, found '\"'"),
  ("\"\\uZZZZ\"", "line 1, column 4: expected 4 hex digits after \\u, found 'Z'"),
  ("\"a\nb\"", "line 1, column 3: control character U+000A must be escaped in a string"),
  ("\"\tb\"", "line 1, column 2: control character U+0009 must be escaped in a string"),
  ("[1] [2]", "line 1, column 5: unexpected '[' after the JSON value"),
  ("1 2", "line 1, column 3: unexpected '2' after the JSON value"),
  ("// c\n1", "line 1, column 1: expected a value, found '/'"),
  ("[1, /* c */ 2]", "line 1, column 5: expected a value, found '/'"),
  ("\uFEFF{}", "line 1, column 1: expected a value, found U+FEFF"),
  ("[\u00a0]", "line 1, column 2: expected a value, found U+00A0"),
  ("{\n  \"a\": [1, 2,\n    ]\n}", "line 3, column 5: expected a value, found ']'"),
  ("\"é\" x", "line 1, column 5: unexpected 'x' after the JSON value"),
  ("[\"😀😀\", x]", "line 1, column 8: expected a value, found 'x'")]

def nested (n : Nat) : String := "".pushn '[' n ++ "".pushn ']' n

def testDocuments : T Unit := section_ "JSON documents" do
  for (input, want) in accepted do
    match Json.parse input with
    | .ok j => expectEq s!"accept {input.quote}" j.compress want
    | .error e => expect s!"accept {input.quote}" false e
  for (input, want) in rejected do
    match Json.parse input with
    | .ok j => expect s!"reject {input.quote}" false s!"parsed as {j.compress}"
    | .error e => expectEq s!"reject {input.quote}" e want
  -- implementation-defined: lone surrogates become U+FFFD (a Lean string cannot hold them)
  expectEq "lone high surrogate" ((Json.parse "\"\\ud800x\"").map (·.compress)) (.ok "\"\uFFFDx\"")
  expectEq "lone low surrogate" ((Json.parse "\"\\udc00\"").map (·.compress)) (.ok "\"\uFFFD\"")
  expectEq "high + non-low" ((Json.parse "\"\\ud800\\u0041\"").map (·.compress)) (.ok "\"\uFFFDA\"")
  -- nesting: 512 levels by default, configurable
  expect "512 levels" (Json.parse (nested 512)).toBool
  expectEq "513 levels" (Json.parse (nested 513)) (.error "line 1, column 513: nesting deeper than 512 levels")
  expect "100000 levels: an error, not a stack overflow" (!(Json.parse (nested 100000)).toBool)
  expect "maxDepth 2000" (Json.parse (nested 2000) (maxDepth := 2000)).toBool
  -- the structured error
  match Json.parseE "{\n  \"x\": tru\n}" with
  | .error e => expectEq "ParseError" (e.offset, e.line, e.column) (9, 2, 8)
  | .ok _ => expect "ParseError" false
  -- byte input
  expectEq "parseUTF8" ((Json.parseUTF8 "[\"ü\"]".toUTF8).map (·.compress)) (.ok "[\"ü\"]")
  expect "parseUTF8 invalid" (!(Json.parseUTF8 (ByteArray.mk #[34, 0xFF, 34])).toBool)

/-! ## JSON: printing -/

def sample : Json := Json.mkObj [
  ("name", "LeanUI"), ("tags", .arr #["wasm64", "dom"]), ("empty", .arr #[]), ("obj", .obj #[]),
  ("nested", Json.mkObj [("a", .arr #[1, Json.mkObj [("b", .null)]])]), ("ok", true), ("pi", .num ⟨314159, -5⟩),
  ("esc", "line\nbreak \"quoted\" \\ \u0001 é 😀")]

def testPrinting : T Unit := section_ "JSON printing" do
  expectEq "compress" sample.compress
    "{\"name\":\"LeanUI\",\"tags\":[\"wasm64\",\"dom\"],\"empty\":[],\"obj\":{},\"nested\":{\"a\":[1,{\"b\":null}]},\"ok\":true,\"pi\":3.14159,\"esc\":\"line\\nbreak \\\"quoted\\\" \\\\ \\u0001 é 😀\"}"
  expectEq "pretty" sample.pretty ("{\n  \"name\": \"LeanUI\",\n  \"tags\": [\n    \"wasm64\",\n    \"dom\"\n  ],\n  \"empty\": [],\n" ++
    "  \"obj\": {},\n  \"nested\": {\n    \"a\": [\n      1,\n      {\n        \"b\": null\n      }\n    ]\n  },\n  \"ok\": true,\n" ++
    "  \"pi\": 3.14159,\n  \"esc\": \"line\\nbreak \\\"quoted\\\" \\\\ \\u0001 é 😀\"\n}")
  expectEq "pretty indent 4" ((Json.arr #[1, 2]).pretty 4) "[\n    1,\n    2\n]"
  expectEq "pretty scalar" ((Json.str "x").pretty) "\"x\""
  expectEq "ascii" (Json.compress "é😀\u007f~" (ascii := true)) "\"\\u00e9\\ud83d\\ude00\\u007f~\""
  -- every printed document parses back to an equal value
  for j in [sample, Json.arr #[sample, sample], .obj #[("", sample)]] do
    expectEq "compress round trip" ((Json.parse j.compress).map (· == j)) (.ok true)
    expectEq "pretty round trip" ((Json.parse j.pretty).map (· == j)) (.ok true)
    expectEq "ascii round trip" ((Json.parse (j.compress (ascii := true))).map (· == j)) (.ok true)
  -- every control character escapes as JSON.stringify does
  for c in [0:32] do
    let s := String.singleton (Char.ofNat c)
    let want := match c with
      | 8 => "\"\\b\"" | 9 => "\"\\t\"" | 10 => "\"\\n\"" | 12 => "\"\\f\"" | 13 => "\"\\r\""
      | _ => s!"\"\\u00{Json.hexDigit (c / 16)}{Json.hexDigit (c % 16)}\""
    expectEq s!"control {c}" (Json.escape s) want

/-! ## JSON: numbers -/

/-- Exact decimal → canonical printing (the ECMAScript layout on the exact digits). -/
def numberLayout : List (String × String) := [
  ("0", "0"), ("100", "100"), ("1e2", "100"), ("1.5", "1.5"), ("1e20", "100000000000000000000"),
  ("1e21", "1e+21"), ("123e18", "123000000000000000000"), ("1234e18", "1.234e+21"),
  ("0.000001", "0.000001"), ("1e-7", "1e-7"), ("0.0000001234", "1.234e-7"), ("-12.5e-3", "-0.0125"),
  ("12345678901234567890123", "1.2345678901234567890123e+22"), ("5e-1", "0.5"),
  ("1e999999999999999999999", "1e+999999999999999999999"), ("-1E-999999999999999999999", "-1e-999999999999999999999"),
  ("0.000123", "0.000123"), ("1.0000000000000000000001", "1.0000000000000000000001")]

/-- Doubles and what JavaScript's `String(x)` prints for them. -/
def jsDoubles : List (Float × String) := [
  (0.1, "0.1"), (0.1 + 0.2, "0.30000000000000004"), (1.0 / 3.0, "0.3333333333333333"), (2.0 / 3.0, "0.6666666666666666"),
  (100.0, "100"), (1e21, "1e+21"), (1e-7, "1e-7"), (123456789.0, "123456789"), (1.5e300, "1.5e+300"),
  (Float.ofBits 1, "5e-324"), (Float.ofBits 3, "1.5e-323"), (Float.ofBits 0x7FEFFFFFFFFFFFFF, "1.7976931348623157e+308"),
  (Float.ofBits 0x0010000000000000, "2.2250738585072014e-308"), (Float.ofBits 0x000FFFFFFFFFFFFF, "2.225073858507201e-308"),
  (-0.0, "0"), (Float.ofBits 0x4340000000000000, "9007199254740992"), (0.1 + 0.7, "0.7999999999999999"), (1.005, "1.005"),
  (4.35, "4.35"), (1e23, "1e+23"), (5e-7, "5e-7"), (0.000001, "0.000001"), (123e-20, "1.23e-18"),
  (Float.ofBits 0x43E0000000000000, "9223372036854776000"), (-2.5, "-2.5"), (1e22, "1e+22"),
  (Float.ofBits 0x4340000000000000, "9007199254740992"), (Float.ofBits 0x3FF0000000000001, "1.0000000000000002"),
  (Float.ofBits 0x3FEFFFFFFFFFFFFF, "0.9999999999999999"), (Float.ofBits 0x43B0000000000000, "1152921504606847000"),
  (Float.ofBits 0x4450000000000000, "1.1805916207174113e+21"), (Float.ofBits 0x3EB0000000000000, "9.5367431640625e-7")]

/-- Exact rational a/b. -/
structure Q where
  num : Nat
  den : Nat

def Q.lt (a b : Q) : Bool := a.num * b.den < b.num * a.den
def Q.eq (a b : Q) : Bool := a.num * b.den == b.num * a.den
def Q.mid (a b : Q) : Q := ⟨a.num * b.den + b.num * a.den, 2 * a.den * b.den⟩

/-- The exact value of a finite non-negative double. -/
def floatQ (bits : UInt64) : Q :=
  let be := ((bits >>> 52) &&& 0x7FF).toNat
  let frac := (bits &&& 0xFFFFFFFFFFFFF).toNat
  let (m, e) : Nat × Int := if be == 0 then (frac, -1074) else (frac + 2 ^ 52, (be : Int) - 1075)
  if e ≥ 0 then ⟨m * 2 ^ e.toNat, 1⟩ else ⟨m, 2 ^ e.natAbs⟩

def decimalQ (m : Nat) (e : Int) : Q := if e ≥ 0 then ⟨m * 10 ^ e.toNat, 1⟩ else ⟨m, 10 ^ e.natAbs⟩

/-- Is `bits` the double nearest to `x` (ties to even), by exact arithmetic? -/
def nearest (x : Q) (bits : UInt64) : Bool :=
  let maxBits : UInt64 := 0x7FEFFFFFFFFFFFFF
  if bits == 0x7FF0000000000000 then
    -- overflow: x is at least halfway between the largest double and 2^1024
    !(x.lt ((floatQ maxBits).mid ⟨2 ^ 1024, 1⟩))
  else
    let f := floatQ bits
    let lo : Q := if bits == 0 then ⟨0, 1⟩ else (floatQ (bits - 1)).mid f
    let hi : Q := if bits == maxBits then f.mid ⟨2 ^ 1024, 1⟩ else f.mid (floatQ (bits + 1))
    let even := bits % 2 == 0
    (lo.lt x || (lo.eq x && even) || (bits == 0 && lo.eq x)) && (x.lt hi || (x.eq hi && even))

/-- The two candidates with `p` digits around an exact decimal `D × 10^eD` (as `JsonNumber`s). -/
def candidates (D : Nat) (eD : Int) (p : Nat) : List JsonNumber :=
  let L := JsonNumber.numDigits D
  if L ≤ p then [JsonNumber.normalize D eD] else
  let pw := 10 ^ (L - p)
  [JsonNumber.normalize (D / pw) (eD + (L - p)), JsonNumber.normalize (D / pw + 1) (eD + (L - p))]

def exactDecimal (bits : UInt64) : Nat × Int :=
  let be := ((bits >>> 52) &&& 0x7FF).toNat
  let frac := (bits &&& 0xFFFFFFFFFFFFF).toNat
  let (m, e) : Nat × Int := if be == 0 then (frac, -1074) else (frac + 2 ^ 52, (be : Int) - 1075)
  if e ≥ 0 then (m * 2 ^ e.toNat, 0) else (m * 5 ^ e.natAbs, e)

def testNumbers : T Unit := section_ "JSON numbers" do
  for (input, want) in numberLayout do
    expectEq s!"layout {input}" ((Json.parse input).map (·.compress)) (.ok want)
  for (f, want) in jsDoubles do
    expectEq s!"String({want})" ((JsonNumber.ofFloat? f).map toString) (some want)
    expectEq s!"toJson {want}" (toJson f).compress want
  expectEq "NaN" (toJson (0.0 / 0.0 : Float)).compress "\"NaN\""
  expectEq "inf" (toJson (1.0 / 0.0 : Float)).compress "\"Infinity\""
  expectEq "-inf" (toJson (-1.0 / 0.0 : Float)).compress "\"-Infinity\""
  -- reading: hard cases (ties to even, the largest subnormal, overflow and underflow)
  let readBits (s : String) : Option UInt64 := match Json.parse s with
    | .ok (.num n) => some n.toFloat.toBits | _ => none
  expectEq "2^53+1 ties to even" (readBits "9007199254740993") (some 0x4340000000000000)
  expectEq "2^53+3 ties to even" (readBits "9007199254740995") (some 0x4340000000000002)
  expectEq "largest subnormal" (readBits "2.2250738585072011e-308") (some 0x000FFFFFFFFFFFFF)
  expectEq "smallest normal" (readBits "2.2250738585072014e-308") (some 0x0010000000000000)
  expectEq "smallest subnormal" (readBits "4.9406564584124654e-324") (some 1)
  expectEq "below half the smallest subnormal" (readBits "2.4703282292062327e-324") (some 0)
  expectEq "above half the smallest subnormal" (readBits "2.4703282292062328e-324") (some 1)
  expectEq "max" (readBits "1.7976931348623157e308") (some 0x7FEFFFFFFFFFFFFF)
  expectEq "max, rounding up past halfway: inf" (readBits "1.7976931348623159e308") (some 0x7FF0000000000000)
  expectEq "1e400: inf" (readBits "1e400") (some 0x7FF0000000000000)
  expectEq "1e-400: 0" (readBits "1e-400") (some 0)
  expectEq "-1e-400: -0" (readBits "-1e-400") (some 0x8000000000000000)
  expectEq "huge exponent: inf, instantly" (readBits "1e99999999999999999999") (some 0x7FF0000000000000)
  expectEq "0.1" (readBits "0.1") (some (0.1 : Float).toBits)
  expectEq "many digits" (readBits ("0." ++ "".pushn '3' 800)) (some (1.0 / 3.0 : Float).toBits)
  -- integers
  expectEq "toNat 1e3" ((JsonNumber.normalize 1 3).toNat?) (some 1000)
  expectEq "toNat 1.5" ((JsonNumber.normalize 15 (-1)).toNat?) none
  expectEq "toNat -1" ((JsonNumber.normalize (-1) 0).toNat?) none
  expectEq "toInt huge exponent" ((JsonNumber.normalize 1 100000000).toInt?) none
  expectEq "big Nat" ((Json.decode Nat "123456789012345678901234567890")) (.ok 123456789012345678901234567890)
  -- order
  let n (s : String) : JsonNumber := match Json.parse s with | .ok (.num n) => n | _ => 0
  expect "lt" (n "1.5" < n "2" && n "-3" < n "-2.5" && n "1e-5" < n "1e-4" && !(n "2" < n "2") && n "-1e10" < n "1")
  -- correct rounding, checked by exact arithmetic on random decimals across the whole range
  let mut rng : Rng := ⟨2026⟩
  let mut bad := 0
  for _ in [0:4000] do
    let (r, digits) := rng.below 20; rng := r
    let (r, mant) := rng.next; rng := r
    let (r, e) := rng.below 680; rng := r
    let m := (mant.toNat % 10 ^ (digits + 1)) + 1
    let e : Int := (e : Int) - 345
    let f := (JsonNumber.normalize m e).toFloat
    unless nearest (decimalQ m e) f.toBits do bad := bad + 1
  expectEq "4000 random decimals read as the nearest double" bad 0
  -- near-halfway decimals: exactly halfway between two doubles, and one unit either side
  let mut badHalf := 0
  for _ in [0:600] do
    let (r, bits) := rng.bits64; rng := r
    let bits := bits &&& 0x7FEFFFFFFFFFFFFE
    let a := floatQ bits
    let b := floatQ (bits + 1)
    let mid := a.mid b
    -- mid = num/den with den a power of two: write it as a decimal exactly
    let k := mid.den.log2
    let dec : Nat × Int := (mid.num * 5 ^ k, -(k : Int))
    let f := (JsonNumber.normalize dec.1 dec.2).toFloat
    unless f.toBits == bits do badHalf := badHalf + 1   -- bits is even: the tie goes to it
    let up := (JsonNumber.normalize (dec.1 * 10 + 1) (dec.2 - 1)).toFloat
    unless up.toBits == bits + 1 do badHalf := badHalf + 1
    let down := (JsonNumber.normalize (dec.1 * 10 - 1) (dec.2 - 1)).toFloat
    unless down.toBits == bits do badHalf := badHalf + 1
  expectEq "600 exact halfway cases (and their neighbours)" badHalf 0
  -- cost of printing and reading doubles (random bit patterns: every magnitude)
  let mut samples : Array Float := #[]
  for _ in [0:20000] do
    let (r, bits) := rng.bits64; rng := r
    let f := Float.ofBits bits
    unless f.isNaN || f.isInf do samples := samples.push f
  let t0 ← IO.monoMsNow
  let printed := samples.map fun f => ((JsonNumber.ofFloat? f).map toString).getD ""
  let total := printed.foldl (· + ·.length) 0
  let t1 ← IO.monoMsNow
  let reread := printed.foldl (fun n s => match Json.parse s with | .ok (.num x) => if x.toFloat.isNaN then n else n + 1 | _ => n) 0
  let t2 ← IO.monoMsNow
  expect "timing sample" (total > 0 && reread == samples.size)
  IO.println s!"    {samples.size} random doubles: print {t1 - t0} ms, read {t2 - t1} ms"
  -- shortest printing: round trip, no shorter decimal reads back, the closest of the shortest
  let mut badRt := 0
  let mut badShort := 0
  let mut badClosest := 0
  for i in [0:8000] do
    let (r, bits) := rng.bits64; rng := r
    -- a quarter of the samples are subnormal or near powers of two (asymmetric intervals)
    let bits := if i % 4 == 0 then bits &&& 0x800FFFFFFFFFFFFF
      else if i % 4 == 1 then bits &&& 0xFFF0000000000003 else bits
    let f := Float.ofBits bits
    if f.isNaN || f.isInf then continue
    match JsonNumber.ofFloat? f with
    | none => badRt := badRt + 1
    | some n =>
      unless n.toFloat.toBits == bits || (f == 0 && n == 0) do badRt := badRt + 1
      match Json.parse n.toString with
      | .ok (.num m) => unless m == n do badRt := badRt + 1
      | _ => badRt := badRt + 1
      let p := JsonNumber.numDigits n.mantissa.natAbs
      let pos := bits &&& 0x7FFFFFFFFFFFFFFF
      if pos != 0 && p > 1 then
        let (D, eD) := exactDecimal pos
        let target := Float.ofBits pos
        if (candidates D eD (p - 1)).any (·.toFloat == target) then badShort := badShort + 1
        -- n is the closer of the two p-digit candidates that read back
        let others := (candidates D eD p).filter fun c => c.toFloat == target && c != ⟨(n.mantissa.natAbs : Int), n.exponent⟩
        for c in others do
          let x := decimalQ D eD
          let dist (a : Q) : Q := if a.lt x then ⟨a.num * x.den - x.num * a.den, a.den * x.den⟩
            else ⟨x.num * a.den - a.num * x.den, a.den * x.den⟩
          if (dist (decimalQ c.mantissa.natAbs c.exponent)).lt (dist (decimalQ n.mantissa.natAbs n.exponent)) then
            badClosest := badClosest + 1
  expectEq "8000 doubles: print → read is the identity" badRt 0
  expectEq "8000 doubles: no shorter decimal reads back" badShort 0
  expectEq "8000 doubles: the closest shortest decimal" badClosest 0

/-! ## JSON: classes -/

structure Address where
  city : String
  zip? : Option String := none
  deriving ToJson, FromJson, BEq, Repr

structure User where
  name : String
  age : Nat
  email? : Option String := none
  tags : Array String := #[]
  address : Address
  score : Float := 0.5
  deriving ToJson, FromJson, BEq, Repr

inductive Shape where
  | circle (r : Float)
  | rect (w h : Nat)
  | point
  | labeled : String → Shape → Shape
  | pair : Nat → Bool → Shape
  deriving ToJson, FromJson, BEq, Repr

inductive Tree where
  | leaf (n : Nat)
  | node (kids : Array Tree)
  deriving ToJson, FromJson, BEq, Repr

structure Box (α : Type) where
  val : α
  more : List α := []
  deriving ToJson, FromJson, BEq, Repr

mutual
inductive Even where
  | zero
  | succ (o : Odd)
  deriving ToJson, FromJson, BEq, Repr
inductive Odd where
  | succ (e : Even)
  deriving ToJson, FromJson, BEq, Repr
end

def roundTrip {α : Type} [ToJson α] [FromJson α] [BEq α] (a : α) : Bool :=
  match (fromJson? (toJson a) : Except String α) with
  | .ok b => a == b && (match Json.decode α (toJson a).compress with | .ok c => c == a | .error _ => false)
  | .error _ => false

def testClasses : T Unit := section_ "JSON classes" do
  -- basic instances
  expect "Bool" (roundTrip true && roundTrip false)
  expect "Nat" (roundTrip (0 : Nat) && roundTrip (2 ^ 100 : Nat))
  expect "Int" (roundTrip (-(2 ^ 80) : Int) && roundTrip (7 : Int))
  expect "String" (roundTrip "é😀\"\\\n\u0000")
  expect "Char" (roundTrip 'x' && roundTrip '😀')
  expect "Unit" (roundTrip ())
  expect "Option" (roundTrip (some 3 : Option Nat) && roundTrip (none : Option Nat))
  expect "Array" (roundTrip #[1, 2, 3] && roundTrip (#[] : Array Nat))
  expect "List" (roundTrip [["a"], [], ["b", "c"]])
  expect "Prod" (roundTrip ((1, "x") : Nat × String) && roundTrip ((1, 2, 3) : Nat × Nat × Nat))
  expect "UInt" (roundTrip (255 : UInt8) && roundTrip (65535 : UInt16) && roundTrip (4294967295 : UInt32) && roundTrip (18446744073709551615 : UInt64))
  expect "Float" (roundTrip (0.1 : Float) && roundTrip (-1e300 : Float) && roundTrip (1.0 / 0.0 : Float))
  expect "Float NaN" (match (fromJson? (toJson (0.0 / 0.0 : Float)) : Except String Float) with | .ok f => f.isNaN | _ => false)
  expect "JsonNumber" (roundTrip (JsonNumber.normalize 12345 (-300)))
  expect "Json" (roundTrip sample)
  expectEq "UInt8 bound" (Json.decode UInt8 "256") (.error "expected a UInt8, got 256")
  expectEq "Char length" (Json.decode Char "\"ab\"") (.error "expected a one-character string, got \"ab\"")
  expectEq "Option of null" (Json.decode (Option Nat) "null") (.ok none)
  expectEq "Pair length" (Json.decode (Nat × Nat) "[1]") (.error "expected an array of 2 elements, got 1")
  -- errors name the path
  expectEq "path in arrays" (Json.decode (Array (Array Nat)) "[[1],[2,\"x\"]]") (.error "$[1][1]: expected a natural number, got \"x\"")
  expectEq "path in pairs" (Json.decode (Nat × String) "[1, 2]") (.error "$[1]: expected a string, got 2")
  expectEq "parse errors pass through" (Json.decode Nat "[") (.error "line 1, column 2: expected a value, found the end of the input")
  -- derived: structures
  let ada : User := { name := "Ada", age := 36, address := { city := "London" } }
  expectEq "derived struct" (toJson ada).compress "{\"name\":\"Ada\",\"age\":36,\"tags\":[],\"address\":{\"city\":\"London\"},\"score\":0.5}"
  let full : User := { ada with email? := some "ada@example.org", tags := #["math"], address := { city := "London", zip? := some "W1" } }
  expectEq "derived struct, optional fields" (toJson full).compress
    "{\"name\":\"Ada\",\"age\":36,\"email\":\"ada@example.org\",\"tags\":[\"math\"],\"address\":{\"city\":\"London\",\"zip\":\"W1\"},\"score\":0.5}"
  expect "derived struct round trips" (roundTrip ada && roundTrip full)
  expectEq "defaults fill missing fields" (Json.decode User "{\"name\":\"Bo\",\"age\":3,\"address\":{\"city\":\"Oslo\"}}")
    (.ok { name := "Bo", age := 3, address := { city := "Oslo" } })
  expectEq "missing required field" (Json.decode User "{\"name\":\"Bo\",\"address\":{\"city\":\"Oslo\"}}") (.error "missing field \"age\"")
  expectEq "nested error path" (Json.decode User "{\"name\":\"Bo\",\"age\":3,\"address\":{\"city\":7}}")
    (.error "$.address.city: expected a string, got 7")
  expectEq "error path in arrays" (Json.decode User "{\"name\":\"Bo\",\"age\":3,\"tags\":[\"a\",false],\"address\":{\"city\":\"x\"}}")
    (.error "$.tags[1]: expected a string, got false")
  expectEq "not an object" (Json.decode User "[]") (.error "expected an object, got an array")
  -- derived: inductive types
  let shapes : List Shape := [.circle 1.5, .rect 2 3, .point, .labeled "a" (.labeled "b" .point), .pair 4 true]
  expectEq "derived constructors" (shapes.map fun s => (toJson s).compress)
    ["{\"circle\":{\"r\":1.5}}", "{\"rect\":{\"w\":2,\"h\":3}}", "\"point\"",
     "{\"labeled\":[\"a\",{\"labeled\":[\"b\",\"point\"]}]}", "{\"pair\":[4,true]}"]
  expect "derived constructors round trip" (shapes.all roundTrip)
  expectEq "unknown constructor" (Json.decode Shape "\"hexagon\"")
    (.error "unknown constructor \"hexagon\", expected one of circle, rect, point, labeled, pair")
  expectEq "constructor field error" (Json.decode Shape "{\"rect\":{\"w\":2,\"h\":-1}}") (.error "$.rect.h: expected a natural number, got -1")
  expectEq "constructor arity" (Json.decode Shape "{\"pair\":[1]}") (.error "$.pair: expected an array of 2 elements, got 1")
  expectEq "not a constructor" (Json.decode Shape "[]") (.error "expected a constructor (a string or an object with one field), got an array")
  -- derived: recursive, nested, parametric, mutual
  let t := Tree.node #[.leaf 1, .node #[.leaf 2, .node #[]], .leaf 3]
  expect "recursive through Array" (roundTrip t)
  expectEq "recursive encoding" (toJson t).compress "{\"node\":{\"kids\":[{\"leaf\":{\"n\":1}},{\"node\":{\"kids\":[{\"leaf\":{\"n\":2}},{\"node\":{\"kids\":[]}}]}},{\"leaf\":{\"n\":3}}]}}"
  expect "parametric" (roundTrip ({ val := "x", more := ["y"] } : Box String) && roundTrip ({ val := ({ val := 1 } : Box Nat) } : Box (Box Nat)))
  expect "mutual" (roundTrip (Even.succ (.succ (.succ (.succ .zero)))))
  -- deep recursion: a 2000-level tree encodes and decodes
  let deep := (List.range 2000).foldl (fun t _ => Tree.node #[t]) (.leaf 0)
  expect "2000-level tree: over the default depth" (match Json.decode Tree (toJson deep).compress with | .ok _ => false | .error _ => true)
  expect "2000-level tree with maxDepth" (match Json.parse (toJson deep).compress (maxDepth := 7000) with
    | .ok j => (fromJson? j : Except String Tree).toOption == some deep | .error _ => false)

/-! ## JSON: accessors -/

def testAccessors : T Unit := section_ "JSON accessors" do
  let j := Json.mkObj [("a", 1), ("b", .arr #["x", "y"]), ("c", Json.mkObj [("d", true)])]
  expectEq "j[k]?" (j["a"]?) (some (1 : Json))
  expectEq "j[i]?" ((j["b"]?).bind (·[1]?)) (some (Json.str "y"))
  expectEq "missing" (j["z"]?) none
  expectEq "out of bounds" ((j["b"]?).bind (·[5]?)) none
  expectEq "getObjValAs?" (j.getObjValAs? Nat "a") (.ok 1)
  expectEq "getObjValAs? error" (j.getObjValAs? String "a") (.error ".a: expected a string, got 1")
  expectEq "getObjValAs? odd key" ((Json.mkObj [("odd key", 1)]).getObjValAs? String "odd key") (.error "[\"odd key\"]: expected a string, got 1")
  expectEq "getObjVal? missing" ((j.getObjVal? "z").map (·.compress)) (.error "missing field \"z\"")
  expectEq "getArrValAs?" (((j["b"]?).getD .null).getArrValAs? String 0) (.ok "x")
  expectEq "getStr? error" (Json.getStr? (.num 3)) (.error "expected a string, got 3")
  expectEq "describe long string" (Json.describe (.str "abcdefghijklmnopqrstuvwxyz")) "\"abcdefghijklmnopqrstu...\""
  expectEq "setObjVal replaces in place" (j.setObjVal "a" 9).compress "{\"a\":9,\"b\":[\"x\",\"y\"],\"c\":{\"d\":true}}"
  expectEq "setObjVal appends" (j.setObjVal "e" .null).compress "{\"a\":1,\"b\":[\"x\",\"y\"],\"c\":{\"d\":true},\"e\":null}"
  expectEq "eraseObjVal" (j.eraseObjVal "b").compress "{\"a\":1,\"c\":{\"d\":true}}"
  expectEq "mergeObj" (j.mergeObj (Json.mkObj [("a", 2), ("f", 3)])).compress "{\"a\":2,\"b\":[\"x\",\"y\"],\"c\":{\"d\":true},\"f\":3}"
  expectEq "kind" ([Json.null, true, 1, "s", .arr #[], .obj #[]].map Json.kind) ["null", "boolean", "number", "string", "array", "object"]
  expect "objects compare as maps" (Json.mkObj [("a", 1), ("b", 2)] == Json.mkObj [("b", 2), ("a", 1)])
  expect "arrays compare in order" (Json.arr #[1, 2] != Json.arr #[2, 1])
  expect "numbers compare by value" ((Json.parse "[1.50, 100]").toOption == (Json.parse "[1.5, 1e2]").toOption)
  expectEq "mapNumbers" ((Json.arr #[1, Json.mkObj [("x", 2)]]).mapNumbers (fun n => .num (JsonNumber.normalize (n.mantissa * 10) n.exponent)) |>.compress) "[10,{\"x\":20}]"
  -- large objects: duplicate keys resolved through the key index
  let keys := (List.range 50).map fun i => s!"k{i}"
  let doc := "{" ++ ",".intercalate (keys.map (s!"\"{·}\":1") ++ keys.map (s!"\"{·}\":2")) ++ "}"
  let ok := match Json.parse doc with
    | .ok (.obj fs) => fs.size == 50 && fs.toList.map (·.1) == keys && fs.all (·.2 == (2 : Json))
    | _ => false
  expect "50 keys, each repeated: first position, last value" ok

/-! ## JSON: a large document -/

def testLarge : T Unit := section_ "JSON at scale" do
  let rows := (Array.range 20000).map fun i => Json.mkObj [("id", toJson i), ("label", toJson s!"row {i} \"é\""),
    ("v", toJson (i.toFloat / 7.0)), ("ok", toJson (i % 3 == 0))]
  let doc := (Json.arr rows).compress
  let t0 ← IO.monoMsNow
  let parsed ← IO.ofExcept (Json.parse doc)
  let t1 ← IO.monoMsNow
  let back ← IO.ofExcept (pure parsed.compress : Except String String)
  let t2 ← IO.monoMsNow
  expect "20000 rows round trip" (back == doc && back.length > 0)
  IO.println s!"    {doc.utf8ByteSize / 1024} KiB: parse {t1 - t0} ms, print {t2 - t1} ms"

/-! ## Router: percent-encoding and URLs -/

def randomText (rng : Rng) (n : Nat) : Rng × String := Id.run do
  let alphabet : Array String := #["a", "Z", "0", " ", "/", "?", "#", "&", "=", "+", "%", "~", "é", "中", "😀", "\"", ":", "@", "%2F", ";"]
  let mut r := rng
  let mut s := ""
  for _ in [0:n] do
    let (r', i) := r.below alphabet.size; r := r'
    s := s ++ alphabet[i]!
  return (r, s)

def testUrls : T Unit := section_ "URLs" do
  expectEq "encodeComponent" (Url.encodeComponent "a b&c=d/é😀!*'()~") "a%20b%26c%3Dd%2F%C3%A9%F0%9F%98%80!*'()~"
  expectEq "decode" (Url.percentDecode "a%20b%26c%3Dd%2F%C3%A9%F0%9F%98%80") "a b&c=d/é😀"
  expectEq "decode lower hex" (Url.percentDecode "%c3%a9") "é"
  expectEq "decode plus" (Url.percentDecode "a+b" (plusIsSpace := true)) "a b"
  expectEq "plus stays in paths" (Url.percentDecode "a+b") "a+b"
  expectEq "bad escapes stay" (Url.percentDecode "100%-%zz%4") "100%-%zz%4"
  expectEq "invalid UTF-8 becomes U+FFFD" (Url.percentDecode "%FFx%C3") "\uFFFDx\uFFFD"
  let mut rng : Rng := ⟨99⟩
  let mut bad := 0
  for _ in [0:2000] do
    let (r, n) := rng.below 12; rng := r
    let (r, s) := randomText rng n; rng := r
    for safe in [Url.componentSafe, Url.segmentSafe, Url.querySafe, Url.fragmentSafe] do
      unless Url.percentDecode (Url.percentEncode s safe) == s do bad := bad + 1
    unless Url.percentDecode (Url.percentEncode s Url.querySafe) (plusIsSpace := true) == s do bad := bad + 1
  expectEq "2000 random strings: decode ∘ encode = id" bad 0
  -- parsing
  let u := Url.parse "HTTPS://user:pw@Example.COM:8080/a/b%20c/?x=1&y=%E2%9C%93&z&&w=a+b#frag%20x"
  let want : Url := {
    scheme := some "https", host := some "example.com", port := some 8080, path := #["a", "b c"]
    query := #[("x", "1"), ("y", "✓"), ("z", ""), ("w", "a b")], fragment := some "frag x" }
  expectEq "absolute" u want
  expectEq "print" u.toString "https://example.com:8080/a/b%20c?x=1&y=%E2%9C%93&z&w=a%20b#frag%20x"
  expectEq "ipv6" ((Url.parse "http://[::1]:3000/x").host, (Url.parse "http://[::1]:3000/x").port) (some "[::1]", some 3000)
  expectEq "network path" (Url.parse "//cdn.example/lib.js").host (some "cdn.example")
  let rel : Url := { path := #["users", "42"], query := #[("tab", "posts")], fragment := some "top" }
  expectEq "relative" (Url.parse "/users/42?tab=posts#top") rel
  expectEq "root" (Url.parse "/").path #[]
  expectEq "empty" (Url.parse "") ({} : Url)
  expectEq "trailing slash" (Url.parse "/a/b/").path #["a", "b"]
  expectEq "inner empty segment" (Url.parse "/a//b").path #["a", "", "b"]
  expectEq "encoded slash stays in its segment" (Url.parse "/a%2Fb/c").path #["a/b", "c"]
  expectEq "mailto" ((Url.parse "mailto:x@example.org").scheme) (some "mailto")
  expectEq "not a scheme" ((Url.parse "a/b:c").scheme) none
  expectEq "param?" ((Url.parse "/?a=1&b=2&a=3").param? "a") (some "1")
  expectEq "params" ((Url.parse "/?a=1&b=2&a=3").params "a") #["1", "3"]
  expectEq "setParam" ((Url.parse "/x?a=1&b=2&a=3").setParam "a" "9").toString "/x?b=2&a=9"
  expectEq "removeParam" ((Url.parse "/x?a=1&b=2").removeParam "a").toString "/x?b=2"
  let emptyPair : Url := { query := #[("", ""), ("flag", ""), ("", "v")] }
  expectEq "empty keys and values survive" (Url.parse emptyPair.toString) emptyPair
  expectEq "empty keys and values print" emptyPair.toString "/?=&flag&=v"
  let hashed : Url := { path := #["users", "3"], query := #[("tab", "a?b")] }
  expectEq "parseHash" (Url.parseHash "/app/index.html#/users/3?tab=a%3Fb") hashed
  expectEq "parseHash without fragment" (Url.parseHash "/app/") ({} : Url)
  -- print ∘ parse on random URLs
  let mut badUrl := 0
  for _ in [0:1500] do
    let (r, nseg) := rng.below 4; rng := r
    let mut path := #[]
    for _ in [0:nseg] do
      let (r, n) := rng.below 6; rng := r
      let (r, s) := randomText rng (n + 1); rng := r
      path := path.push s
    let (r, nq) := rng.below 3; rng := r
    let mut query := #[]
    for _ in [0:nq] do
      let (r, k) := randomText rng 3; rng := r
      let (r, v) := randomText rng 2; rng := r
      query := query.push (k, v)
    let (r, hasFrag) := rng.below 2; rng := r
    let (r, frag) := randomText rng 4; rng := r
    let u : Url := { path, query, fragment := if hasFrag == 1 then some frag else none }
    unless Url.parse u.toString == u do badUrl := badUrl + 1
  expectEq "1500 random URLs: parse ∘ print = id" badUrl 0

/-- RFC 3986, section 5.4: every normal and abnormal example. -/
def rfcExamples : List (String × String) := [
  ("g:h", "g:h"), ("g", "http://a/b/c/g"), ("./g", "http://a/b/c/g"), ("g/", "http://a/b/c/g/"),
  ("/g", "http://a/g"), ("//g", "http://g"), ("?y", "http://a/b/c/d;p?y"), ("g?y", "http://a/b/c/g?y"),
  ("#s", "http://a/b/c/d;p?q#s"), ("g#s", "http://a/b/c/g#s"), ("g?y#s", "http://a/b/c/g?y#s"),
  (";x", "http://a/b/c/;x"), ("g;x", "http://a/b/c/g;x"), ("g;x?y#s", "http://a/b/c/g;x?y#s"),
  ("", "http://a/b/c/d;p?q"), (".", "http://a/b/c/"), ("./", "http://a/b/c/"), ("..", "http://a/b/"),
  ("../", "http://a/b/"), ("../g", "http://a/b/g"), ("../..", "http://a/"), ("../../", "http://a/"),
  ("../../g", "http://a/g"),
  -- abnormal
  ("../../../g", "http://a/g"), ("../../../../g", "http://a/g"), ("/./g", "http://a/g"), ("/../g", "http://a/g"),
  ("g.", "http://a/b/c/g."), (".g", "http://a/b/c/.g"), ("g..", "http://a/b/c/g.."), ("..g", "http://a/b/c/..g"),
  ("./../g", "http://a/b/g"), ("./g/.", "http://a/b/c/g/"), ("g/./h", "http://a/b/c/g/h"), ("g/../h", "http://a/b/c/h"),
  ("g;x=1/./y", "http://a/b/c/g;x=1/y"), ("g;x=1/../y", "http://a/b/c/y"), ("g?y/./x", "http://a/b/c/g?y/./x"),
  ("g?y/../x", "http://a/b/c/g?y/../x"), ("g#s/./x", "http://a/b/c/g#s/./x"), ("g#s/../x", "http://a/b/c/g#s/../x"),
  ("http:g", "http:g")]

def testResolve : T Unit := section_ "RFC 3986 resolution" do
  for (ref, want) in rfcExamples do
    expectEq s!"resolve {ref.quote}" (Url.resolve "http://a/b/c/d;p?q" ref) want
  expectEq "relative base" (Url.resolve "/plain/effects/index.html" "data.json") "/plain/effects/data.json"
  expectEq "hash against a path" (Url.resolve "/app/users/3?x=1#old" "#/active") "/app/users/3?x=1#/active"
  expectEq "query against a path" (Url.resolve "/app/users/3?x=1" "?tab=a") "/app/users/3?tab=a"

/-! ## Router: routes -/

def testRoutes : T Unit := section_ "Routes" do
  -- the result types drop unit captures
  let _r1 : Route Nat := "users" </> Route.nat
  let _r2 : Route (Nat × String) := "users" </> Route.nat </> "posts" </> Route.str
  let _r3 : Route (Nat × Option String × Bool) := "a" </> Route.nat <?> Route.param "q" <?> Route.flag "f"
  let _r4 : Route Unit := "a" </> "b" </> Route.top
  expectEq "nat canonical" (["0", "7", "42", "007", "+1", "-1", "", "1e3", "1_000"].map Route.natOf?) [some 0, some 7, some 42, none, none, none, none, none, none]
  expectEq "int canonical" (["0", "-7", "-0", "--1", "12"].map Route.intOf?) [some 0, some (-7), none, none, some 12]
  let r : Route (Nat × String) := "users" </> Route.nat </> "posts" </> Route.str
  expectEq "seq parse" (r.run ["users", "4", "posts", "hi"] #[]) [(4, "hi")]
  expectEq "seq leftovers rejected" (r.run ["users", "4", "posts", "hi", "x"] #[]) []
  expectEq "str rejects empty" (r.run ["users", "4", "posts", ""] #[]) []
  expectEq "seq print" (r.print (4, "hi")) (some (#["users", "4", "posts", "hi"], #[]))
  expectEq "str does not print empty" (r.print (4, "")) none
  let q : Route (Option Nat × Array String × Bool) := Route.paramNat "page" <?> Route.params "tag" <?> Route.flag "debug"
  expectEq "query parse" (q.run [] #[("tag", "a"), ("page", "3"), ("tag", "b"), ("debug", "")]) [(some 3, #["a", "b"], true)]
  expectEq "query lenient" (q.run [] #[("page", "x")]) [(none, #[], false)]
  expectEq "query print" (q.print (some 3, #["a", "b"], true)) (some (#[], #[("page", "3"), ("tag", "a"), ("tag", "b"), ("debug", "")]))
  expectEq "rest" ((("files" </> Route.rest) : Route (List String)).run ["files", "a", "b"] #[]) [["a", "b"]]
  expectEq "rest empty" ((("files" </> Route.rest) : Route (List String)).run ["files"] #[]) [[]]
  expectEq "rest print" ((("files" </> Route.rest) : Route (List String)).print ["a", ""]) none
  -- backtracking: an earlier alternative may fail late
  let alts : Route String := Route.oneOf [("a" </> Route.str </> "x") |>.to (· ++ "!x") (fun _ => none), "a" </> Route.str]
  expectEq "oneOf backtracks" (alts.run ["a", "b"] #[]) ["b"]
  -- the effects lab's router: parse, print, and the round-trip law
  let router : Router Effects.Page := { route := Effects.pages, base := #["plain", "effects"] }
  let cases : List (String × Effects.Page) := [
    ("/plain/effects/", .home), ("/plain/effects", .home), ("/plain/effects/index.html", .home),
    ("/plain/effects/about", .about), ("/plain/effects/users/42", .user 42 none),
    ("/plain/effects/users/42?tab=posts", .user 42 (some "posts")), ("/plain/effects/users/42/?tab=a+b", .user 42 (some "a b")),
    ("/plain/effects/search?q=lean%20ui%20%26%20wasm", .search (some "lean ui & wasm")), ("/plain/effects/search", .search none),
    ("/plain/effects/files/docs/read%20me.txt", .files ["docs", "read me.txt"]), ("/plain/effects/files", .files []),
    ("/plain/effects/users/42#/active", .user 42 none), ("http://127.0.0.1:5341/plain/effects/about?x=1", .about)]
  for (url, page) in cases do
    expectEq s!"parse {url}" (router.parse url) (some page)
  for url in ["/plain/effects/users/x", "/plain/effects/users/007", "/plain/effects/nope", "/other/users/1", "/plain", "/"] do
    expectEq s!"no route {url}" (router.parse url) none
  expectEq "href home" (router.href .home) "/plain/effects/"
  expectEq "href user" (router.href (.user 42 (some "posts & more"))) "/plain/effects/users/42?tab=posts%20%26%20more"
  expectEq "href search" (router.href (.search (some "lean ui & wasm"))) "/plain/effects/search?q=lean%20ui%20%26%20wasm"
  expectEq "href files" (router.href (.files ["docs", "read me.txt"])) "/plain/effects/files/docs/read%20me.txt"
  expectEq "href of an unprintable page" (router.href .notFound) "/plain/effects/"
  expectEq "link" ((router.link (.user 1 none) #[Attr.cls "x"] #[text "u"] : Html Unit).render)
    "<a href=\"/plain/effects/users/1\" data-link=\"\" class=\"x\">u</a>"
  expectEq "link helper" ((link "/a?b=1&c" #[] #[text "go"] : Html Unit).render) "<a href=\"/a?b=1&amp;c\" data-link=\"\">go</a>"
  -- random pages: href then parse is the identity (base path and hash routing alike)
  let hashRouter : Router Effects.Page := { route := Effects.pages, hash := true }
  let rootRouter : Router Effects.Page := { route := Effects.pages }
  let mut rng : Rng := ⟨5⟩
  let mut samples : List Effects.Page := [.home, .about, .files [], .search none, .search (some "")]
  for _ in [0:600] do
    let (r, k) := rng.below 4; rng := r
    let (r, n) := rng.below 100000; rng := r
    let (r, len) := rng.below 6; rng := r
    let (r, s) := randomText rng len; rng := r
    let (r, s2) := randomText rng (len + 1); rng := r
    samples := (match k with
      | 0 => Effects.Page.user n (if len == 0 then none else some s)
      | 1 => .search (some s)
      | 2 => .files [s2, s2 ++ s]
      | _ => .user n none) :: samples
  expectEq "base router: 600 random pages round trip" (router.check samples) (.ok ())
  expectEq "hash router: 600 random pages round trip" (hashRouter.check samples) (.ok ())
  expectEq "root router: 600 random pages round trip" (rootRouter.check samples) (.ok ())
  expectEq "hash href" (hashRouter.href (.user 3 (some "a b"))) "#/users/3?tab=a%20b"
  expectEq "hash parse" (hashRouter.parse "/anything/index.html?x=1#/users/3?tab=a%20b") (some (.user 3 (some "a b")))
  expectEq "hash root" (hashRouter.parse "/anything/") (some .home)
  -- navigate / redirect / changes
  match (router.navigate (.user 7 none) id : Cmd Effects.Page) with
  | .batch #[.pushUrl u, .send p] => expect "navigate" (u == "/plain/effects/users/7" && p == .user 7 none)
  | _ => expect "navigate" false
  match (router.redirect .about id : Cmd Effects.Page) with
  | .batch #[.replaceUrl u, .send _] => expectEq "redirect" u "/plain/effects/about"
  | _ => expect "redirect" false
  match (router.changes id : LeanUI.Sub (Option Effects.Page)) with
  | .urlChanges k => expectEq "changes" (k "/plain/effects/about") (some .about)
  | _ => expect "changes" false
  -- a broken router is caught by check
  let broken : Router Nat := { route := ("n" </> Route.nat) |>.to (· + 1) (fun n => some n) }
  expect "check finds a broken law" (!(broken.check [1, 2]).toBool)

/-! ## The effects lab in the DOM model -/

/-- All text under the node with `id`. -/
partial def textUnder (d : Testing.Dom) (h : UInt32) : String :=
  let n := d.get h
  if n.isText then n.text else String.join (n.kids.toList.map (textUnder d))

def textOf (r : Testing.Running) (ident : String) : IO String := do
  return textUnder (← r.dom.get) (← r.find "id" ident)

/-- The callback id of the most recent effect starting with `pfx` (`fetch cb=7 ...`, `op45 7`). -/
def lastCb (r : Testing.Running) (pfx : String) : IO UInt32 := do
  let effs := (← r.dom.get).effects
  let some e := effs.reverse.find? (·.startsWith pfx) | throw (IO.userError s!"no effect {pfx}")
  let rest := (e.drop pfx.length).toString
  let digits := rest.toList.dropWhile (!·.isDigit) |>.takeWhile Char.isDigit
  return (String.ofList digits).toNat!.toUInt32

def effectsSince (r : Testing.Running) (n : Nat) : IO (Array String) := do
  return (← r.dom.get).effects.extract n (← r.dom.get).effects.size

def readAsset (name : String) : IO String := IO.FS.readFile s!"examples/effects-assets/{name}"

def testEffectsApp : T Unit := section_ "effects lab (DOM model)" do
  let flags := "{\"base\":\"/plain/effects/\",\"url\":\"/plain/effects/index.html\"}"
  let r ← Testing.run Effects.program flags
  let eff0 := (← r.dom.get).effects
  expect "init: title" (eff0.contains s!"op{Op.title} Home · LeanUI effects") s!"{eff0}"
  expect "init: storageGet" (eff0.any (·.startsWith "storageGet cb=")) s!"{eff0}"
  expect "init: log" (eff0.contains s!"op{Op.log} effects: started")
  expect "init: url subscription" (eff0.any (·.startsWith s!"op{Op.urlListen} "))
  expectEq "init: route" (← textOf r "route") "home"
  expectEq "init: url" (← textOf r "url") "/plain/effects/index.html"
  -- the visit counter: nothing stored yet, then a stored record
  r.inst.callback (← lastCb r "storageGet cb=") false ""
  expectEq "visits" (← textOf r "visits") "1"
  expect "visits stored as JSON" ((← r.dom.get).effects.back? == some "storageSet leanui.effects.saved={\"visits\":1,\"lastPage\":\"home\"}")
    s!"{(← r.dom.get).effects.back?}"
  -- fetch: the catalog, a 404, a parse error, a decode error
  let mark := (← r.dom.get).effects.size
  r.click "id" "fetch-0"
  expectEq "fetch emitted" (← effectsSince r mark) #[s!"fetch cb={← lastCb r "fetch cb="} GET /plain/effects/data.json"]
  expectEq "loading" (← textOf r "status-0") "loading…"
  r.inst.callback (← lastCb r "fetch cb=") true ("200\n" ++ (← readAsset "data.json"))
  expectEq "catalog" (← textOf r "status-0") "200 · 8 planets"
  let table ← textOf r "planets"
  expect "table" (table.startsWith "The planets — a \"solar system\" catalogplanetmoonsradius kmringsdiscoveredMercury☿02439.7noantiquity") table
  expect "table: escaped surrogate pair, exponent, year" ((table.splitOn "Earth🜨16371no").length == 2 &&
    (table.splitOn "Jupiter♃9569911yes").length == 2 && (table.splitOn "Uranus⛢2825362yes1781").length == 2) table
  r.click "id" "fetch-1"
  r.inst.callback (← lastCb r "fetch cb=") false "404\nnot found"
  expectEq "404" (← textOf r "status-1") "404 · HTTP 404"
  r.click "id" "fetch-2"
  r.inst.callback (← lastCb r "fetch cb=") true ("200\n" ++ (← readAsset "broken.json"))
  expectEq "parse error" (← textOf r "status-2") "200 · line 4, column 25: expected ',' or '}', found '\"'"
  r.click "id" "fetch-3"
  r.inst.callback (← lastCb r "fetch cb=") true ("200\n" ++ (← readAsset "shape.json"))
  expectEq "decode error" (← textOf r "status-3") "200 · $.planets[1].moons: expected a natural number, got -1"
  r.click "id" "fetch-0"
  r.inst.callback (← lastCb r "fetch cb=") false "0\n"
  expectEq "network error" (← textOf r "status-0") "0 · network error"
  -- timers
  r.click "id" "after"
  let afterCb ← lastCb r "timeout "
  expectEq "after pending" (← textOf r "after-status") "pending 1 · fired 0"
  r.inst.callback afterCb true ""
  expectEq "after fired" (← textOf r "after-status") "pending 0 · fired 1"
  r.inst.callback afterCb true ""
  expectEq "a fired timeout's callback is gone" (← textOf r "after-status") "pending 0 · fired 1"
  r.fire (← r.find "id" "fast") "change" "true"
  let fastCb ← lastCb r "interval "
  expect "every 100" ((← r.dom.get).effects.back? == some s!"interval {fastCb} 100")
  for _ in [0:5] do r.inst.callback fastCb true ""
  expectEq "fast ticks" (← textOf r "fast-ticks") "5"
  r.fire (← r.find "id" "slow") "change" "true"
  let slowCb ← lastCb r "interval "
  expect "every 300" ((← r.dom.get).effects.back? == some s!"interval {slowCb} 300" && slowCb != fastCb)
  r.inst.callback slowCb true ""
  r.fire (← r.find "id" "fast") "change" "false"
  expect "fast stopped" ((← r.dom.get).effects.back? == some s!"op{Op.intervalClear} {fastCb}")
  r.inst.callback slowCb true ""
  expectEq "slow ticks" (← textOf r "slow-ticks") "2"
  expectEq "fast ticks frozen" (← textOf r "fast-ticks") "5"
  r.fire (← r.find "id" "slow") "change" "false"
  expect "slow stopped" ((← r.dom.get).effects.back? == some s!"op{Op.intervalClear} {slowCb}")
  -- storage
  r.fire (← r.find "id" "note") "input" "hello ✓"
  let mark := (← r.dom.get).effects.size
  r.click "id" "save-note"
  expectEq "save" (← effectsSince r mark) #["storageSet leanui.effects.note=hello ✓", s!"op{Op.log} saved note \"hello ✓\""]
  r.click "id" "load-note"
  r.inst.callback (← lastCb r "storageGet cb=") true "hello ✓"
  expectEq "loaded" (← textOf r "note-value") "\"hello ✓\""
  r.click "id" "remove-note"
  expect "remove" ((← r.dom.get).effects.back? == some s!"op{Op.storageRemove} leanui.effects.note")
  expectEq "removed" (← textOf r "note-value") "(none)"
  -- router: navigate, redirect, URL changes, hash filter
  let mark := (← r.dom.get).effects.size
  r.click "id" "go-user7"
  expectEq "navigate" (← effectsSince r mark) #[s!"op{Op.urlPush} /plain/effects/users/7", s!"op{Op.title} User 7 · LeanUI effects"]
  expectEq "navigated" (← textOf r "route") "user 7"
  expectEq "url after navigate" (← textOf r "url") "/plain/effects/users/7"
  let mark := (← r.dom.get).effects.size
  r.click "id" "replace"
  expectEq "redirect: same title" (← effectsSince r mark) #[s!"op{Op.urlReplace} /plain/effects/users/7?tab=settings"]
  expectEq "redirected" (← textOf r "route") "user 7 · tab settings"
  let urlCb ← lastCb r s!"op{Op.urlListen} "
  r.inst.callback urlCb true "/plain/effects/search?q=a%20b#/active"
  expectEq "urlChanges: page" (← textOf r "route") "search \"a b\""
  expectEq "urlChanges: hash filter" (← textOf r "filter") "active"
  expect "urlChanges: title" ((← r.dom.get).effects.back? == some s!"op{Op.title} Search \"a b\" · LeanUI effects")
  r.inst.callback urlCb true "/plain/effects/no/such/page"
  expectEq "not found" (← textOf r "route") "not found"
  -- the nav links carry hrefs from the router and the data-link marker
  let d ← r.dom.get
  let navUser := d.get (← r.find "id" "nav-user")
  expect "nav link" (navUser.attrs.contains ("href", "/plain/effects/users/42") && navUser.attrs.contains ("data-link", ""))
  expect "hash link" ((d.get (← r.find "id" "f-done")).attrs.contains ("href", "#/done"))
  -- DOM commands
  let mark := (← r.dom.get).effects.size
  r.click "id" "focus-name"
  r.fire (← r.find "id" "name") "keydown" "a"
  r.fire (← r.find "id" "name") "keydown" "Escape"
  r.click "id" "scroll-bottom"
  r.click "id" "log"
  expectEq "focus, blur, scroll, log" (← effectsSince r mark)
    #[s!"op{Op.focus} #name", s!"op{Op.blur} #name", s!"op{Op.scrollIntoView} #bottom", s!"op{Op.log} LeanUI log #1"]
  -- frames: 30 chained nextFrame callbacks
  r.click "id" "animate"
  for i in [0:30] do
    r.inst.callback (← lastCb r s!"op{Op.frame} ") true (toString (1000 + 16 * i))
  expectEq "frames" (← textOf r "frames") "30/30 · 464 ms · monotonic"
  expect "no 31st frame" (((← r.dom.get).effects.filter (·.startsWith s!"op{Op.frame} ")).size == 30)
  -- JSON lab
  r.fire (← r.find "id" "json-in") "input" "{\"a\": [1.50, 1E400, 12345678901234567890], \"b\": \"\\u00e9\"}"
  expectEq "lab compact" (← textOf r "json-compact") "{\"a\":[1.5,1e+400,12345678901234567890],\"b\":\"é\"}"
  r.fire (← r.find "id" "json-doubles") "change" "true"
  expectEq "lab doubles" (← textOf r "json-compact") "{\"a\":[1.5,null,12345678901234567000],\"b\":\"é\"}"
  r.fire (← r.find "id" "json-in") "input" "[1, 2,]"
  expectEq "lab error" (← textOf r "json-error") "line 1, column 7: expected a value, found ']'"
  -- no protocol errors and no leaked handles after all of it
  let d ← r.dom.get
  expect "protocol" d.errors.isEmpty s!"{d.errors}"
  expectEq "handles" (d.reachable (← r.root)).size d.nodes.size

/-! ## Pixels, files, keys -/

/-- The address of an object (to see that an array was updated in place, not copied). -/
unsafe def addrImpl (b : @& ByteArray) : USize := ptrAddrUnsafe b
@[implemented_by addrImpl] def addrOf (b : @& ByteArray) : USize := 0

/-- A model holding a large array and the array's address after each update. -/
def uniqueProgram : Program (ByteArray × Array USize) Unit where
  init _ := ((ByteArray.mk (Array.replicate 100000 0), #[]), .none)
  update _ m := match m with
    | (data, addrs) =>
      let data := data.set! 0 (data[0]! + 1)
      ((data, addrs.push (addrOf data)), .none)
  view m := text (toString m.2.size)

def testInput : T Unit := section_ "input payloads" do
  expectEq "decimal" ([parseDecimal "12.5", parseDecimal "-3", parseDecimal "0.25", parseDecimal "-0.05", parseDecimal "7.", parseDecimal "x", parseDecimal ""].map (·.toString))
    ["12.500000", "-3.000000", "0.250000", "-0.050000", "7.000000", "0.000000", "0.000000"]
  match Pointer.parse "10.5 -2 200 100 1 3 7 0.5 0 -120 30.25 40" with
  | some p =>
    expectEq "pointer" (p.x, p.y, p.width, p.height, p.buttons, p.shift, p.ctrl, p.alt, p.metaKey, p.id, p.pressure, p.deltaY, p.clientX, p.clientY)
      (10.5, -2, 200, 100, 1, true, true, false, false, 7, 0.5, -120, 30.25, 40)
    expectEq "pointer scaled" (p.scaledTo 400 50) (21, -1)
  | none => expect "pointer parses" false
  expect "pointer: wrong field count" (Pointer.parse "1 2 3").isNone
  expectEq "files" (FileInfo.parse "3\t1024\timage/png\ta b.png\n4\t0\t\tnotes\twith tab")
    #[{ id := 3, size := 1024, type := "image/png", name := "a b.png" }, { id := 4, size := 0, type := "", name := "notes\twith tab" }]
  expectEq "files: empty" (FileInfo.parse "") #[]
  expectEq "keys" (Keys.parse "Ctrl+Shift+Z") { key := "Z", ctrl := true, shift := true }
  expectEq "keys: plus" (Keys.parse "Ctrl++") { key := "+", ctrl := true }
  expectEq "keys: plain" (Keys.parse "Shift") { key := "Shift" }
  expect "keys: cmd" ((Keys.parse "Meta+z").cmd && (Keys.parse "Ctrl+z").cmd && !(Keys.parse "z").cmd)

def testUniqueModel : T Unit := section_ "update owns the model" do
  let mut st := initState uniqueProgram "" "#app" false
  for _ in [0:5] do
    st := ((stepMsgs uniqueProgram #[()]).run st).2
  let (data, addrs) := st.model
  expectEq "updates" (data[0]!, addrs.size) (5, 5)
  expect "one array, updated in place" (addrs.all (· == addrs[0]!) && addrs[0]! != 0) s!"{addrs}"
  -- the control: with every earlier state kept alive, each update must copy the array
  st := initState uniqueProgram "" "#app" false
  let mut kept := #[]
  for _ in [0:3] do
    kept := kept.push st
    st := ((stepMsgs uniqueProgram #[()]).run st).2
  let addrs := st.model.2
  expect "a shared model is copied (the check can fail)" (addrs.size == 3 && addrs[0]! != addrs[1]! && addrs[1]! != addrs[2]!) s!"{addrs}"
  expectEq "kept states unchanged" (kept.map (·.model.1[0]!)) #[0, 1, 2]

unsafe def exclusiveImpl (b : @& ByteArray) : Bool := isExclusiveUnsafe b
/-- Whether `b` is referenced once (so writing into it would not copy it). -/
@[implemented_by exclusiveImpl] def isExclusive (b : @& ByteArray) : Bool := false

/-- Messages carrying bytes: `update` records whether it got them unshared. -/
def bytesProgram : Program (Array Bool) ByteArray where
  init _ := (#[], .none)
  update b m := (m.push (isExclusive b), .none)
  view m := text (toString m.size)

def testUniqueMessages : T Unit := section_ "update owns the message" do
  -- sizes known only at run time, and all different: a closed term would be a persistent (never
  -- unique) constant, and equal expressions may be shared
  let n := ((← IO.getEnv "LEANUI_NO_SUCH_VARIABLE").map (·.length)).getD 1000
  let st := initState bytesProgram "" "#app" false
  let st := ((stepMsgs bytesProgram #[ByteArray.mk (Array.replicate (100 * n) 0), ByteArray.mk (Array.replicate n 0)]).run st).2
  expectEq "messages unshared" st.model #[true, true]
  -- the control: a message still referenced elsewhere
  let kept := #[ByteArray.mk (Array.replicate (n + 1) 0)]
  let st := ((stepMsgs bytesProgram kept).run st).2
  expectEq "a shared message is seen shared (the check can fail)" (st.model, kept.size) (#[true, true, false], 1)

def testPixelsApp : T Unit := section_ "pixels lab (DOM model)" do
  let r ← Testing.run Pixels.program
  let eff0 := (← r.dom.get).effects
  expect "init: whole canvas" (eff0.contains "putImage #px-canvas blob=0 256x128 dirty=0,0,256,128") s!"{eff0}"
  expect "init: keys" (eff0.any (·.startsWith s!"op{Op.keysListen} "))
  let canvas ← r.find "id" "px-canvas"
  -- a move without a button paints nothing; with it, a 5×5 square at the scaled position
  let mark := (← r.dom.get).effects.size
  r.fire canvas "pointermove" "100 50 512 256 0 0 1 0 0 0 0 0"
  expectEq "hover" (← textOf r "px-pointer") "50,25 buttons 0"
  r.fire canvas "pointerdown" "100 50 512 256 1 1 1 0.5 0 0 0 0"
  r.fire canvas "pointermove" "1 1 512 256 1 0 1 0.5 0 0 0 0"
  expectEq "painted" (← effectsSince r mark) #["putImage #px-canvas blob=0 256x128 dirty=48,23,5,5", "putImage #px-canvas blob=0 256x128 dirty=0,0,3,3"]
  expectEq "dabs" (← textOf r "px-dabs") "2"
  expectEq "captured" (← textOf r "px-capturing") "true"
  r.fire canvas "pointerup" "1 1 512 256 0 0 1 0 0 0 0 0"
  expectEq "released" (← textOf r "px-capturing") "false"
  r.fire canvas "wheel" "1 1 512 256 0 0 0 0 0 -240 0 0"
  expectEq "wheel" (← textOf r "px-wheel") "-240"
  -- files: bytes and pixels come back through byte callbacks
  let mark := (← r.dom.get).effects.size
  r.fire (← r.find "id" "px-file") "change" "7\t6\timage/png\tdot.png"
  let effs ← effectsSince r mark
  expect "file commands" (effs.size == 2 && effs[0]!.startsWith "readFile cb=" && effs[1]!.startsWith "decodeImage cb=") s!"{effs}"
  expectEq "files" (← textOf r "px-files") "dot.png (6 bytes, image/png)"
  r.inst.callbackBytes (← lastCb r "readFile cb=") true "" (ByteArray.mk #[0x89, 0x50, 0x4e, 0x47, 13, 10])
  expectEq "bytes" (← textOf r "px-bytes") "dot.png: 6 bytes: 89 50 4e 47 0d 0a"
  r.inst.callbackBytes (← lastCb r "decodeImage cb=") true "1 2" (ByteArray.mk #[1, 2, 3, 4, 5, 6, 7, 8])
  expectEq "decoded" (← textOf r "px-decoded") "1×2"
  expect "decoded drawn" ((← r.dom.get).effects.back? == some "putImage #px-image blob=0 1x2 dirty=0,0,1,2") s!"{(← r.dom.get).effects.back?}"
  -- a decode that fails, and one whose size does not match its bytes
  r.fire (← r.find "id" "px-drop") "drop" "8\t3\t\tjunk"
  r.inst.callbackBytes (← lastCb r "decodeImage cb=") false "The source image cannot be decoded." .empty
  expectEq "decode error" (← textOf r "px-decoded") "The source image cannot be decoded."
  r.fire (← r.find "id" "px-drop") "drop" "9\t3\t\tjunk"
  r.inst.callbackBytes (← lastCb r "decodeImage cb=") true "2 2" (ByteArray.mk #[1, 2, 3])
  expectEq "decode size mismatch" (← textOf r "px-decoded") "decoded 3 bytes for 2×2 pixels"
  -- a byte result through the string path (a server-driven page) is a failure
  r.fire (← r.find "id" "px-drop") "drop" "10\t3\t\tjunk"
  r.inst.callback (← lastCb r "readFile cb=") false "bytes need the in-page (wasm) host"
  expectEq "bytes without wasm" (← textOf r "px-bytes") "junk: bytes need the in-page (wasm) host"
  r.click "id" "px-download"
  expectEq "download" (← r.dom.get).effects.back? (some "download pixels.rgba application/octet-stream blob=0")
  for k in ["a", "Ctrl+z", "b", "c", "d", "Shift+E"] do
    r.inst.callback (← lastCb r s!"op{Op.keysListen} ") true k
  expectEq "keys" (← textOf r "px-keys") "Ctrl+z b c d Shift+E"
  let d ← r.dom.get
  expect "protocol" d.errors.isEmpty s!"{d.errors}"

/-! ## Life -/

/-- Live cells and board hash after `n` generations from the seed. -/
def lifeAfter (n : Nat) : Nat × String :=
  let b := Nat.repeat Life.next n Life.seed
  (Life.population b, Life.hex (Life.hash b))

def testLife : T Unit := section_ "life" do
  -- the reference for tests/browser/race.mjs: vanilla JavaScript, wasm64 and lean-vir must agree
  expectEq "generation 0" (lifeAfter 0) (328, "93b948f3")
  expectEq "generation 100" (lifeAfter 100) (53, "bdbe4aa6")
  expectEq "generation 1000" (lifeAfter 1000) (145, "4e6b3290")
  let r ← Testing.run Life.program
  for _ in [0:100] do r.click "id" "step"
  expectEq "100 clicks shown" [← textOf r "gen", ← textOf r "pop", ← textOf r "hash"] ["100", "53", "bdbe4aa6"]
  r.click "id" "reset"
  expectEq "reset shown" [← textOf r "gen", ← textOf r "pop", ← textOf r "hash"] ["0", "328", "93b948f3"]
  let d ← r.dom.get
  expect "protocol" d.errors.isEmpty s!"{d.errors}"

/-! ## Roster -/

deriving instance BEq for Roster.Answer

def testRoster : T Unit := section_ "roster" do
  let preset (name : String) := (Roster.samples.find? (·.1 == name)).map (·.2) |>.getD default
  let feasible := preset "feasible"
  match Roster.solve feasible with
  | .staffed r => expect "feasible preset" (feasible.checkRoster r) s!"{repr r}"
  | a => expect "feasible preset" false s!"{repr a}"
  let impossible := preset "impossible"
  let a := Roster.solve impossible
  expectEq "impossible preset" a (.impossible [3, 4])
  expect "impossible preset checks" (impossible.checkAnswer a)
  expectEq "impossible preset, in words" (Roster.diagnose impossible a)
    "Bar 12–15 and Bar 15–18 need 6 people, but only 5 can do any of them: Ana, Ben, Chen, Dee and Hana."
  -- edge cases: nobody, no shifts, nobody needed, more needed than there are people, short rows
  let edge : List Roster.Problem := [
    { people := [], shifts := [], need := [], avail := [] },
    { people := ["a", "b"], shifts := [], need := [], avail := [] },
    { people := [], shifts := ["x"], need := [1], avail := [] },
    { people := ["a", "b"], shifts := ["x", "y"], need := [0, 0], avail := [[true], []] },
    { people := ["a", "b"], shifts := ["x", "y"], need := [3, 0], avail := [[true, true], [true, true]] },
    { people := ["a", "b", "c"], shifts := ["x", "y"], need := [1, 1, 5], avail := [[true], [false, true]] }]
  -- random problems of several sizes, both kinds of answer
  let sizes := #[(30, 10), (12, 6), (20, 10), (5, 3), (30, 5), (8, 8)]
  let probs := edge ++ (List.range 600).map fun k =>
    let (n, m) := sizes[k % sizes.size]!
    Roster.random (UInt64.ofNat k) n m
  let mut staffed := 0
  let mut bad := #[]
  let mut lies : Array Nat := Roster.Lie.all.map fun _ => 0
  for p in probs do
    let a := Roster.solve p
    if let .staffed _ := a then staffed := staffed + 1
    if !p.checkAnswer a then bad := bad.push s!"{repr p} answered {repr a}"
    for h : j in [0:Roster.Lie.all.size] do
      let l := Roster.Lie.all[j]
      let b := Roster.lie l p a
      if b != a then
        lies := lies.modify j (· + 1)
        if p.checkAnswer b then bad := bad.push s!"{repr p}: lie {repr l} {repr b} accepted"
  expect "answers check, lies are rejected" bad.isEmpty s!"{bad.size} failures, first: {bad[0]?}"
  let n := probs.length
  expect "both kinds of answer" (100 < staffed && 100 < n - staffed) s!"{staffed} of {n} staffed"
  expect "every lie is told" (lies.all (n / 2 < ·)) s!"{lies}"

/-! ## Main -/

public def main : IO UInt32 := do
  IO.println "leanui kit tests"
  let ((), s) ← (do
    testDocuments; testPrinting; testNumbers; testClasses; testAccessors; testLarge
    testUrls; testResolve; testRoutes; testEffectsApp; testInput; testUniqueModel; testUniqueMessages; testPixelsApp
    testLife; testRoster : T Unit).run {}
  for f in s.failed do IO.println s!"FAIL {f}"
  if s.failed.isEmpty then
    IO.println s!"all {s.passed} checks passed"; return 0
  else
    IO.println s!"{s.failed.size} of {s.passed + s.failed.size} checks FAILED"; return 1
