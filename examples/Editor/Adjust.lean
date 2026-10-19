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
partial def lutLoop (lut : @& ByteArray) (hl : 256 ≤ lut.size) (d : ByteArray) (i n : USize) : ByteArray :=
  if i < n then
    if h : InPx d i then
      lutLoop lut hl (put3 d i h (tab lut hl (px d i h 0)) (tab lut hl (px d i h 1)) (tab lut hl (px d i h 2)))
        (i + 4) n
    else d
  else d

/-- Table lookups, then the colour matrix. -/
partial def lutMatLoop (lut : @& ByteArray) (hl : 256 ≤ lut.size) (m0 m1 m2 m3 m4 m5 m6 m7 m8 : UInt32)
    (d : ByteArray) (i n : USize) : ByteArray :=
  if i < n then
    if h : InPx d i then
      let r := (tab lut hl (px d i h 0)).toUInt32
      let g := (tab lut hl (px d i h 1)).toUInt32
      let b := (tab lut hl (px d i h 2)).toUInt32
      lutMatLoop lut hl m0 m1 m2 m3 m4 m5 m6 m7 m8
        (put3w d i h (matRow m0 m1 m2 r g b) (matRow m3 m4 m5 r g b) (matRow m6 m7 m8 r g b)) (i + 4) n
    else d
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
      if a.colorNeutral then
        ⟨w, h, lutLoop lut hl d i n⟩
      else
        let m := Adjust.fixedMatrix a.matrix
        ⟨w, h, lutMatLoop lut hl m[0]! m[1]! m[2]! m[3]! m[4]! m[5]! m[6]! m[7]! m[8]! d i n⟩
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

/-! ## Histogram -/

/-- Count bytes `i .. n - 1` of `d` into `t`: bins 0..255 red, 256..511 green, 512..767 blue,
768..1023 luminance (Rec. 709, `(54 R + 183 G + 19 B + 128) / 256`). -/
partial def histLoop (d : @& ByteArray) (t : Array UInt32) (i n : USize) : Array UInt32 :=
  if i < n then
    if h : InPx d i then
      let r := px32 d i h 0
      let g := px32 d i h 1
      let b := px32 d i h 2
      let y := (54 * r + 183 * g + 19 * b + 128) >>> 8
      let t := wrW t r.toUSize (rdW t r.toUSize + 1)
      let t := wrW t (256 + g.toUSize) (rdW t (256 + g.toUSize) + 1)
      let t := wrW t (512 + b.toUSize) (rdW t (512 + b.toUSize) + 1)
      let t := wrW t (768 + y.toUSize) (rdW t (768 + y.toUSize) + 1)
      histLoop d t (i + 4) n
    else t
  else t

/-- Add the pixels of rows `y0 .. y1 - 1` to the counts `t` (1024 entries, as `histogram`), for
computing a histogram in chunks. Counts are 32-bit (images up to 4 billion pixels). -/
def histogramRows (img : Image) (y0 y1 : Nat) (t : Array UInt32 := Array.replicate 1024 0) : Array UInt32 :=
  let y1 := min y1 img.height
  if y1 ≤ y0 then t
  else histLoop img.data t (4 * img.width * y0).toUSize (4 * img.width * y1).toUSize

/-- 1024 counts: 256 bins each for red, green, blue and luminance (Rec. 709 integer weights,
`(54 R + 183 G + 19 B + 128) / 256`), in that order. Each group sums to the pixel count. -/
def histogram (img : Image) : Array Nat :=
  (histogramRows img 0 img.height).map (·.toNat)

end Editor
