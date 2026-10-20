module
public import Editor.Image
/-!
# Tone and colour adjustments, histograms

An `Adjust` record holds every slider of the adjustment panel. Applying it costs one table
lookup per channel plus, only when saturation, hue or grayscale are set, one 3×3 integer matrix
per pixel:

* Everything that maps a channel value to a channel value (exposure, brightness, contrast, levels,
  the curve, invert) is folded into one 256-entry table (`Adjust.lut`), built once per call in
  `Float` from the composition of the steps, each clamped to 0..255, rounded once at the end.
* Saturation, hue rotation and grayscale are linear maps of (R, G, B) that keep grays gray: they
  are composed into one matrix (`Adjust.matrix`) in fixed point (12 fractional bits, every row
  summing to exactly 4096), the CSS `saturate()` / `hue-rotate()` / `grayscale()` filters with
  Rec. 709 luminance weights.

Alpha is never changed. `Adjust.applyRows a src dst y0 y1` writes rows `y0 .. y1 - 1` of `dst`
from the same rows of `src`; `dst` may be `src` itself, which then changes in place.
-/
public section
namespace Editor

/-! ## The adjustment record -/

structure Adjust where
  /-- -100..100: adds `brightness * 1.275` to every channel. -/
  brightness : Int := 0
  /-- -100..100: scales the distance from mid-gray (−100: flat gray). -/
  contrast : Int := 0
  /-- Stops, -3..3: multiplies linear-light intensity by `2 ^ exposure`. -/
  exposure : Float := 0
  /-- -100..100: −100 is grayscale, 100 doubles the saturation. -/
  saturation : Int := 0
  /-- Degrees, -180..180: rotates hues around the gray axis. -/
  hue : Int := 0
  /-- Levels: input black and white points (0..255) and gamma (0.1..10). -/
  inBlack : Nat := 0
  inWhite : Nat := 255
  gamma : Float := 1
  /-- Curve control points `(input, output)` in 0..255, interpolated by a monotone cubic
  (Fritsch–Carlson). The end points `(0, 0)` and `(255, 255)` are implied unless points with
  input 0 or 255 are given; empty is the identity. -/
  curve : Array (Nat × Nat) := #[]
  invert : Bool := false
  grayscale : Bool := false
  deriving Inhabited

namespace Adjust

def identity : Adjust := {}

/-! ### The per-channel table -/

private def clampF (v : Float) : Float := if v < 0 then 0 else if v > 255 then 255 else v

private def srgbToLinear (c : Float) : Float :=
  if c ≤ 0.04045 then c / 12.92 else Float.pow ((c + 0.055) / 1.055) 2.4

private def linearToSrgb (c : Float) : Float :=
  if c ≤ 0.0031308 then c * 12.92 else 1.055 * Float.pow c (1 / 2.4) - 0.055

/-- The curve's points: clamped, sorted by input, one point per input (the last given wins),
with the identity end points added where missing. -/
def curvePoints (pts : Array (Nat × Nat)) : Array (Float × Float) :=
  let pts := pts.map fun (x, y) => (min x 255, min y 255)
  -- stable sort by input, then keep the last point of each input
  let sorted := (pts.zipIdx.qsort fun ((x1, _), i1) ((x2, _), i2) => x1 < x2 || (x1 == x2 && i1 < i2)).map (·.1)
  let dedup := sorted.foldl (init := #[]) fun acc p =>
    if acc.size > 0 && acc.back!.1 == p.1 then acc.pop.push p else acc.push p
  let dedup := if dedup.any (·.1 == 0) then dedup else #[(0, 0)] ++ dedup
  let dedup := if dedup.any (·.1 == 255) then dedup else dedup.push (255, 255)
  dedup.map fun (x, y) => (Float.ofNat x, Float.ofNat y)

/-- Fritsch–Carlson tangents for a monotone cubic through `ps` (strictly increasing inputs). -/
def curveTangents (ps : Array (Float × Float)) : Array Float := Id.run do
  let n := ps.size
  if n < 2 then return Array.replicate n 0
  let d := (Array.range (n - 1)).map fun k => (ps[k + 1]!.2 - ps[k]!.2) / (ps[k + 1]!.1 - ps[k]!.1)
  let mut m := (Array.range n).map fun k =>
    if k == 0 then d[0]! else if k == n - 1 then d[n - 2]!
    else if d[k - 1]! * d[k]! ≤ 0 then 0 else (d[k - 1]! + d[k]!) / 2
  for k in [0:n - 1] do
    if d[k]! == 0 then
      m := (m.set! k 0).set! (k + 1) 0
    else
      let a := m[k]! / d[k]!
      let b := m[k + 1]! / d[k]!
      let s := a * a + b * b
      if s > 9 then
        let t := 3 / Float.sqrt s
        m := (m.set! k (t * a * d[k]!)).set! (k + 1) (t * b * d[k]!)
  return m

/-- The curve at input `v` (Hermite form of the monotone cubic; flat outside the points). -/
def curveAt (ps : Array (Float × Float)) (m : Array Float) (v : Float) : Float := Id.run do
  let n := ps.size
  if n == 0 then return v
  if v ≤ ps[0]!.1 then return ps[0]!.2
  if v ≥ ps[n - 1]!.1 then return ps[n - 1]!.2
  let mut k := 0
  while k + 2 < n && ps[k + 1]!.1 ≤ v do k := k + 1
  let (x0, y0) := ps[k]!
  let (x1, y1) := ps[k + 1]!
  let h := x1 - x0
  let t := (v - x0) / h
  let t2 := t * t
  let t3 := t2 * t
  return (2 * t3 - 3 * t2 + 1) * y0 + (t3 - 2 * t2 + t) * h * m[k]! +
    (-2 * t3 + 3 * t2) * y1 + (t3 - t2) * h * m[k + 1]!

/-- The 256-entry table of every per-channel step: exposure (in linear light), brightness,
contrast, levels, curve, invert, in that order. -/
def lut (a : Adjust) : ByteArray := Id.run do
  let cps := if a.curve.isEmpty then #[] else curvePoints a.curve
  let cms := curveTangents cps
  let c := Float.ofInt a.contrast * 2.55
  let cf := (259 * (c + 255)) / (255 * (259 - c))
  let gain := Float.pow 2 a.exposure
  let lo := Float.ofNat (min a.inBlack 255)
  let hi := Float.ofNat (min a.inWhite 255)
  let invGamma := 1 / (if a.gamma < 0.01 then 0.01 else a.gamma)
  let levels := a.inBlack != 0 || a.inWhite != 255 || a.gamma != 1
  let mut t := ByteArray.emptyWithCapacity 256
  for i in [0:256] do
    let mut v := Float.ofNat i
    if a.exposure != 0 then
      v := 255 * linearToSrgb (min 1 (srgbToLinear (v / 255) * gain))
    if a.brightness != 0 then v := clampF (v + Float.ofInt a.brightness * 1.275)
    if a.contrast != 0 then v := clampF (cf * (v - 128) + 128)
    if levels then
      v := if hi ≤ lo then (if v < hi then 0 else 255)
        else if v ≤ lo then 0 else if v ≥ hi then 255
        else 255 * Float.pow ((v - lo) / (hi - lo)) invGamma
    if !cps.isEmpty then v := clampF (curveAt cps cms v)
    if a.invert then v := 255 - v
    t := t.push (toByte v)
  return t

/-! ### The colour matrix -/

/-- A 3×3 matrix, rows first. -/
abbrev Mat3 := Array Float

private def matMul (a b : Mat3) : Mat3 :=
  (Array.range 9).map fun ij =>
    let i := ij / 3
    let j := ij % 3
    a[3 * i]! * b[j]! + a[3 * i + 1]! * b[3 + j]! + a[3 * i + 2]! * b[6 + j]!

/-- Rec. 709 luminance weights. -/
def lumR : Float := 0.2126
def lumG : Float := 0.7152
def lumB : Float := 0.0722

/-- CSS `saturate(s)` with Rec. 709 weights (s = 0: grayscale, 1: identity). -/
def saturateMat (s : Float) : Mat3 :=
  #[lumR + (1 - lumR) * s, lumG - lumG * s, lumB - lumB * s,
    lumR - lumR * s, lumG + (1 - lumG) * s, lumB - lumB * s,
    lumR - lumR * s, lumG - lumG * s, lumB + (1 - lumB) * s]

/-- CSS `hue-rotate(deg)` with Rec. 709 weights. -/
def hueMat (deg : Float) : Mat3 :=
  let r := deg * 3.141592653589793 / 180
  let c := Float.cos r
  let s := Float.sin r
  #[lumR + c * (1 - lumR) - s * lumR, lumG - c * lumG - s * lumG, lumB - c * lumB + s * (1 - lumB),
    lumR - c * lumR + s * 0.143, lumG + c * (1 - lumG) + s * 0.140, lumB - c * lumB - s * 0.283,
    lumR - c * lumR - s * (1 - lumR), lumG - c * lumG + s * lumG, lumB + c * (1 - lumB) + s * lumB]

/-- Whether the colour step does nothing. -/
def colorNeutral (a : Adjust) : Bool := a.saturation == 0 && a.hue % 360 == 0 && !a.grayscale

/-- The colour step as a matrix: saturation, then hue, then grayscale. -/
def matrix (a : Adjust) : Mat3 :=
  let m := saturateMat (1 + Float.ofInt (max (-100) (min 100 a.saturation)) / 100)
  let m := if a.hue % 360 == 0 then m else matMul (hueMat (Float.ofInt a.hue)) m
  if a.grayscale then matMul (saturateMat 0) m else m

/-- The matrix in fixed point (×4096) as two's-complement `UInt32`s; each row is corrected to sum
to exactly 4096 (rows of these matrices sum to 1), so a gray pixel stays exactly gray. -/
def fixedMatrix (m : Mat3) : Array UInt32 := Id.run do
  let toFix (v : Float) : Int := (v * 4096).round.toInt64.toInt
  let mut out : Array UInt32 := #[]
  for i in [0:3] do
    let row := #[toFix m[3 * i]!, toFix m[3 * i + 1]!, toFix m[3 * i + 2]!]
    -- put the rounding residue on the entry of largest magnitude
    let resid : Int := 4096 - (row[0]! + row[1]! + row[2]!)
    let big := if row[0]!.natAbs ≥ row[1]!.natAbs && row[0]!.natAbs ≥ row[2]!.natAbs then 0
      else if row[1]!.natAbs ≥ row[2]!.natAbs then 1 else 2
    let row := row.modify big (· + resid)
    for v in row do out := out.push (if v < 0 then 0 - (-v).toNat.toUInt32 else v.toNat.toUInt32)
  return out

/-- Whether applying `a` changes nothing. -/
def isIdentity (a : Adjust) : Bool :=
  a.colorNeutral && (a.lut.toList.zipIdx.all fun (v, i) => v.toNat == i)

end Adjust

/-! ## The pixel loops (in place) -/

/-- One matrix row applied to `(r, g, b)`, clamped to 0..255 (negative sums have the top bit set). -/
@[inline] def matRow (m0 m1 m2 r g b : UInt32) : UInt32 :=
  let v := m0 * r + m1 * g + m2 * b + 2048
  if v >>> 31 != 0 then 0 else clamp255 (v >>> 12)

/-- Table lookups on the pixels at bytes `i .. n - 1` of `d`; alpha untouched. -/
partial def lutLoop (lut : @& ByteArray) (hl : 256 ≤ lut.size) (d : ByteArray) (n : USize) (hn : RowIn d 0 n)
    (h3 : 3 ≤ n) (i : USize) : ByteArray :=
  if hi : i < n - 3 then
    let h := hn.px h3 hi
    let v := get32 d (0 + i) h
    let r := (tab lut hl v.toUInt8).toUInt32
    let g := (tab lut hl (v >>> 8).toUInt8).toUInt32
    let b := (tab lut hl (v >>> 16).toUInt8).toUInt32
    lutLoop lut hl (set32 d (0 + i) (r ||| (g <<< 8) ||| (b <<< 16) ||| (v &&& 0xff000000)) h) n (hn.set32 _ _ _) h3
      (i + 4)
  else d

/-- Table lookups, then the colour matrix. -/
partial def lutMatLoop (lut : @& ByteArray) (hl : 256 ≤ lut.size) (m0 m1 m2 m3 m4 m5 m6 m7 m8 : UInt32)
    (d : ByteArray) (n : USize) (hn : RowIn d 0 n) (h3 : 3 ≤ n) (i : USize) : ByteArray :=
  if hi : i < n - 3 then
    let h := hn.px h3 hi
    let v := get32 d (0 + i) h
    let r := (tab lut hl v.toUInt8).toUInt32
    let g := (tab lut hl (v >>> 8).toUInt8).toUInt32
    let b := (tab lut hl (v >>> 16).toUInt8).toUInt32
    let w := matRow m0 m1 m2 r g b ||| (matRow m3 m4 m5 r g b <<< 8) ||| (matRow m6 m7 m8 r g b <<< 16) |||
      (v &&& 0xff000000)
    lutMatLoop lut hl m0 m1 m2 m3 m4 m5 m6 m7 m8 (set32 d (0 + i) w h) n (hn.set32 _ _ _) h3 (i + 4)
  else d

namespace Adjust

/-- Apply `a` to rows `y0 .. y1 - 1` of `img`, in place when `img` is unique. -/
def applyRowsIn (a : Adjust) (img : Image) (y0 y1 : Nat) : Image :=
  let y1 := min y1 img.height
  if y1 ≤ y0 then img
  else
    let lut := a.lut
    let i := (4 * img.width * y0).toUSize
    let n := (4 * img.width * y1).toUSize
    if hl : 256 ≤ lut.size then
      let ⟨w, h, d⟩ := img
      -- bytes `0 .. n - 1` checked once: the loops compare `i` only
      let n := min n d.usize
      if hn : RowIn d 0 n ∧ 3 ≤ n then
        if a.colorNeutral then
          ⟨w, h, lutLoop lut hl d n hn.1 hn.2 i⟩
        else
          let m := Adjust.fixedMatrix a.matrix
          ⟨w, h, lutMatLoop lut hl m[0]! m[1]! m[2]! m[3]! m[4]! m[5]! m[6]! m[7]! m[8]! d n hn.1 hn.2 i⟩
      else ⟨w, h, d⟩
    else img

/-- Write rows `y0 .. y1 - 1` of `dst` from the same rows of `src` adjusted by `a` (same-size
images; other rows of `dst` are kept). `dst` may be `src` itself: `applyRows a img img y0 y1`
then adjusts `img` in place when it is otherwise unreferenced (no copy), so a large image can be
processed in chunks of rows. -/
def applyRows (a : Adjust) (src dst : Image) (y0 y1 : Nat) : Image :=
  if aliases src dst then
    applyRowsIn a src y0 y1
  else
    applyRowsIn a (copyRows src dst y0 y1) y0 y1

/-- `img` adjusted by `a` (in place when `img` is unique). -/
def apply (a : Adjust) (img : Image) : Image :=
  if a.isIdentity then img else applyRowsIn a img 0 img.height

end Adjust

/-! ## Histogram

The counts live in a byte array of 1024 little-endian 32-bit words (`HistTable`), and one pixel
updates its four counters in one inline-C step (`histAdd`: one exclusivity check, no boxing, four
32-bit increments). An
`Array UInt32` would box each count, check bounds and exclusivity, and release the old element on
every increment. -/

/-- Add one to the little-endian word at byte `4 k` (the specification of `histAdd`'s steps). -/
def incWord (t : ByteArray) (k : Nat) : ByteArray :=
  let o := 4 * k
  let x := ((t.get! o).toUInt32 ||| ((t.get! (o + 1)).toUInt32 <<< 8) ||| ((t.get! (o + 2)).toUInt32 <<< 16) |||
    ((t.get! (o + 3)).toUInt32 <<< 24)) + 1
  t.set! o x.toUInt8 |>.set! (o + 1) (x >>> 8).toUInt8 |>.set! (o + 2) (x >>> 16).toUInt8
    |>.set! (o + 3) (x >>> 24).toUInt8

theorem incWord_size (t : ByteArray) (k : Nat) : (incWord t k).size = t.size := by
  simp [incWord]

/-- Count the pixel `v` (a little-endian word): one more in bins `r`, `256 + g`, `512 + b` and
`768 + (54 r + 183 g + 19 b + 128) / 256` of the table `t` (at least 4096 bytes). -/
@[extern c inline "({ lean_object *t_ = #1; uint32_t v_ = #2; \
  if (LEAN_UNLIKELY(!lean_is_exclusive(t_))) t_ = lean_copy_byte_array(t_); \
  typedef uint32_t __attribute__((aligned(1))) u32u_; \
  u32u_ *w_ = (u32u_ *)lean_sarray_cptr(t_); \
  uint32_t r_ = v_ & 255, g_ = (v_ >> 8) & 255, l_ = (v_ >> 16) & 255; \
  uint32_t k_[4] = { r_, 256 + g_, 512 + l_, 768 + ((54 * r_ + 183 * g_ + 19 * l_ + 128) >> 8) }; \
  for (int j_ = 0; j_ < 4; j_++) { \
    if (__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__) w_[k_[j_]] += 1; \
    else w_[k_[j_]] = __builtin_bswap32(__builtin_bswap32(w_[k_[j_]]) + 1); } \
  t_; })"]
def histAdd (t : ByteArray) (v : UInt32) (_ht : 4096 ≤ t.size) : ByteArray :=
  let r := v &&& 255
  let g := (v >>> 8) &&& 255
  let b := (v >>> 16) &&& 255
  let y := (54 * r + 183 * g + 19 * b + 128) >>> 8
  incWord (incWord (incWord (incWord t r.toNat) (256 + g.toNat)) (512 + b.toNat)) (768 + y.toNat)

theorem histAdd_size (t : ByteArray) (v : UInt32) (ht : 4096 ≤ t.size) : (histAdd t v ht).size = t.size := by
  simp [histAdd, incWord_size]

/-- Count the pixels at bytes `i, i + 4, …` below `n` of `d` (checked once: `RowIn d 0 n`) into `t`. -/
partial def histTableLoop (d : @& ByteArray) (n : USize) (hn : RowIn d 0 n) (h3 : 3 ≤ n) (t : ByteArray)
    (ht : 4096 ≤ t.size) (i : USize) : ByteArray :=
  if hi : i < n - 3 then
    let t' := histAdd t (get32 d (0 + i) (hn.px h3 hi)) ht
    histTableLoop d n hn h3 t' (by rw [histAdd_size]; exact ht) (i + 4)
  else t

/-- A histogram table: 1024 little-endian 32-bit counts (4096 bytes), in the order of
`histogram`. -/
structure HistTable where
  bytes : ByteArray

def HistTable.empty : HistTable := ⟨zeros 4096⟩

/-- Add the pixels of rows `y0 .. y1 - 1` to the table. -/
def HistTable.addRows (t : HistTable) (img : Image) (y0 y1 : Nat) : HistTable :=
  let ⟨t⟩ := t
  let y1 := min y1 img.height
  if y1 ≤ y0 then ⟨t⟩
  else
    let d := img.data
    let n := min (4 * img.width * y1).toUSize d.usize
    if h : 4096 ≤ t.size ∧ RowIn d 0 n ∧ 3 ≤ n then
      ⟨histTableLoop d n h.2.1 h.2.2 t h.1 (4 * img.width * y0).toUSize⟩
    else ⟨t⟩

/-- The counts. -/
def HistTable.counts (t : HistTable) : Array Nat :=
  let t := t.bytes
  (Array.range 1024).map fun k =>
    (t.get! (4 * k)).toNat ||| ((t.get! (4 * k + 1)).toNat <<< 8) ||| ((t.get! (4 * k + 2)).toNat <<< 16) |||
      ((t.get! (4 * k + 3)).toNat <<< 24)

/-- The histogram of every `step`-th row (`0, step, 2 step, …`), in the order of `histogram`: a
cheaper estimate of its shape for a live display. -/
def histogramEvery (img : Image) (step : Nat) : Array Nat := Id.run do
  let step := max 1 step
  let mut t := HistTable.empty
  let mut y := 0
  while y < img.height do
    t := t.addRows img y (y + 1)
    y := y + step
  return t.counts

/-- 1024 counts: 256 bins each for red, green, blue and luminance (Rec. 709 integer weights,
`(54 R + 183 G + 19 B + 128) / 256`), in that order. Each group sums to the pixel count. -/
def histogram (img : Image) : Array Nat :=
  (HistTable.empty.addRows img 0 img.height).counts

/-- Count the pixels at bytes `i .. n - 1` of `d` into the `Array UInt32` `t` (`histogramRows`). -/
partial def histLoop (d : @& ByteArray) (t : Array UInt32) (i n : USize) : Array UInt32 :=
  if i < n then
    if h : InPx d i then
      let v := get32 d i h
      let r := v &&& 255
      let g := (v >>> 8) &&& 255
      let b := (v >>> 16) &&& 255
      let y := (54 * r + 183 * g + 19 * b + 128) >>> 8
      let t := wrW t r.toUSize (rdW t r.toUSize + 1)
      let t := wrW t (256 + g.toUSize) (rdW t (256 + g.toUSize) + 1)
      let t := wrW t (512 + b.toUSize) (rdW t (512 + b.toUSize) + 1)
      let t := wrW t (768 + y.toUSize) (rdW t (768 + y.toUSize) + 1)
      histLoop d t (i + 4) n
    else t
  else t

/-- Add the pixels of rows `y0 .. y1 - 1` to the counts `t` (1024 entries, as `histogram`), for
computing a histogram in chunks. Counts are 32-bit (images up to 4 billion pixels). An
`Array UInt32` of counts is slower to update than a `HistTable` (each count is boxed): prefer
`HistTable.addRows`, or `histogramEvery` for a sampled histogram. -/
def histogramRows (img : Image) (y0 y1 : Nat) (t : Array UInt32 := Array.replicate 1024 0) : Array UInt32 :=
  let y1 := min y1 img.height
  if y1 ≤ y0 then t
  else histLoop img.data t (4 * img.width * y0).toUSize (4 * img.width * y1).toUSize

end Editor
