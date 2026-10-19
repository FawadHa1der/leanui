module
public import Editor.Image
/-!
# Filters: Gaussian blur, unsharp mask, 3×3 convolutions

* **Blur** is a separable Gaussian with a fixed-point kernel: `2k + 1` integer weights summing to
  exactly 65536, `k = ⌈radius⌉`, `σ = radius / 2`, edges clamped. Colour is blurred premultiplied
  by alpha, so transparent pixels do not darken the edges of what is next to them. The horizontal
  pass (`blurHRows`) writes *premultiplied* pixels; the vertical pass (`blurVRows`) reads them and
  writes straight alpha again, dividing the colour sums by the alpha sum (a constant image stays
  exactly the same). For a blur in chunks, run the horizontal pass over every row first: an output
  row of the vertical pass reads `k` rows above and below it.
* **Sharpen** is an unsharp mask: `v + amount · (v − blur(v))` per colour channel, where
  `|v − blur(v)| ≥ threshold`.
* **Convolutions** apply a 3×3 kernel with a divisor and a bias to the colour channels (edges
  clamped, alpha kept). `edgeDetect` is the Sobel gradient magnitude of the luminance (gray
  output), `Kernel3.emboss` the classic emboss kernel.

Row functions write rows `y0 .. y1 - 1` of `dst` (same size as `src`) and keep its other rows.
-/
public section
namespace Editor

/-! ## Gaussian blur

A pixel is handled as one word (`get32`, `set32`), its channels two at a time (`rbOf`, `gaOf`,
`spread`: one multiplication by a weight handles two channels). The weights are symmetric, so the
two taps at the same distance from the centre are added before the multiplication. -/

/-- The Gaussian kernel for `radius`: `2k + 1` weights (`k = ⌈radius⌉`, at most 250, `σ = radius / 2`)
summing to exactly 65536; `#[65536]` (no blur) when `radius ≤ 0`. -/
def gaussKernel (radius : Float) : Array UInt32 :=
  if !(radius > 0) then #[65536] else
  let radius := if radius > 250 then 250 else radius
  let k := radius.ceil.toUInt32.toNat
  let sigma := radius / 2
  let ws := (Array.range (2 * k + 1)).map fun i =>
    let x := Float.ofNat i - Float.ofNat k
    Float.exp (-(x * x) / (2 * sigma * sigma))
  let total := ws.foldl (· + ·) 0
  let fixed := ws.map fun w => (w / total * 65536).round.toUInt32
  let s := fixed.foldl (· + ·) 0
  -- put the rounding residue on the centre weight (wrapping arithmetic: the result is positive)
  fixed.set! k (fixed[k]! + 65536 - s)

/-- A colour sum divided by the alpha sum (both with the kernel's weights), as straight colour:
`255 · c / a`, rounded, at most 255. -/
@[inline] def unpremul (c a : UInt32) : UInt32 :=
  let a : UInt64 := a.toUInt64
  let v : UInt64 := (c.toUInt64 * 255 + a / 2) / a
  if v > 255 then 255 else v.toUInt32

/-- The straight-alpha pixel word of weighted sums (weights totalling 65536) of premultiplied
colour and of alpha: `255 · c / a` per colour channel. Where every pixel under the kernel is opaque
(`a = 255 · 65536`) that is exactly `(c + 32768) / 65536`, without dividing. -/
@[inline] def unpremulWord (rb ga : UInt64) : UInt32 :=
  let aa := lane1 ga
  if aa == 16711680 then roundWord rb ga
  else if aa == 0 then 0
  else unpremul (lane0 rb) aa ||| (unpremul (lane0 ga) aa <<< 8) ||| (unpremul (lane1 rb) aa <<< 16) |||
    (((aa + 32768) >>> 16) <<< 24)

/-- Fill `pad` (at least `4 * (w + 2k)` bytes) with row `rowOff` of `src`, premultiplied and
extended by `k` copies of the edge pixels on each side: pad pixel `p` is source pixel
`clamp (p - k) 0 (w - 1)`. -/
partial def padRow (src : @& ByteArray) (pad : ByteArray) (rowOff w k p n : USize) : ByteArray :=
  if p < n then
    let x := if p < k then 0 else if p - k ≥ w then w - 1 else p - k
    let s := rowOff + 4 * x
    if hs : InPx src s then
      if ho : InPx pad (4 * p) then
        let v := get32 src s hs
        let a := v >>> 24
        -- premultiplying an opaque pixel changes nothing (`div255 (c · 255) = c`)
        let v := if a == 255 then v else
          div255 ((v &&& 255) * a) ||| (div255 (((v >>> 8) &&& 255) * a) <<< 8) |||
            (div255 (((v >>> 16) &&& 255) * a) <<< 16) ||| (v &&& 0xff000000)
        padRow src (set32 pad (4 * p) v ho) rowOff w k (p + 1) n
      else pad
    else pad
  else pad

/-- Pixels `x .. w - 1` of one row of the horizontal pass (`o`: the output byte). Output pixel `x`
sums pad pixels `x .. x + 2k`: the pairs `x + j`, `x + 2k - j` for `j < k` (weight `kern[j]`),
then the centre `x + k` (weight `kern[k]`); `rb`, `ga` are the sums so far. -/
partial def hRow (pad : @& ByteArray) (kern : @& Array UInt32) (k n : USize) (hn : WRange kern n) (hkn : k < n)
    (dst : ByteArray) (o x w j : USize) (rb ga : UInt64) : ByteArray :=
  if x < w then
    if hj : j < k then
      let q1 := 4 * (x + j)
      let q2 := 4 * (x + 2 * k - j)
      if h1 : InPx pad q1 then
        if h2 : InPx pad q2 then
          let wt := (kern.uget j (hn.lt (USize.lt_trans hj hkn))).toUInt64
          let v1 := get32 pad q1 h1
          let v2 := get32 pad q2 h2
          hRow pad kern k n hn hkn dst o x w (j + 1) (rb + wt * spread (rbOf v1 + rbOf v2))
            (ga + wt * spread (gaOf v1 + gaOf v2))
        else dst
      else dst
    else
      let q := 4 * (x + k)
      if hq : InPx pad q then
        if ho : InPx dst o then
          let wt := (kern.uget k (hn.lt hkn)).toUInt64
          let v := get32 pad q hq
          let w' := roundWord (rb + wt * spread (rbOf v)) (ga + wt * spread (gaOf v))
          hRow pad kern k n hn hkn (set32 dst o w' ho) (o + 4) (x + 1) w 0 0 0
        else dst
      else dst
  else dst

/-- Rows `y .. y1 - 1` of the horizontal pass. -/
partial def hRows (src : @& ByteArray) (kern : @& Array UInt32) (k n : USize) (hn : WRange kern n) (hkn : k < n)
    (pad dst : ByteArray) (y y1 w : USize) : ByteArray :=
  if y < y1 then
    let rowOff := 4 * w * y
    let pad := padRow src pad rowOff w k 0 (w + 2 * k)
    let dst := hRow pad kern k n hn hkn dst rowOff 0 w 0 0 0
    hRows src kern k n hn hkn pad dst (y + 1) y1 w
  else dst

/-- The kernel of `radius`, its half width `k`, and the proof that it has `k + 1` entries. -/
structure Kern where
  w : Array UInt32
  k : USize
  n : USize
  hn : WRange w n
  hkn : k < n

def Kern.of (radius : Float) : Option Kern :=
  let w := gaussKernel radius
  let k := (w.size / 2).toUSize
  let ⟨n, hn⟩ := wrangeOf w (k + 1)
  if hkn : k < n then some ⟨w, k, n, hn, hkn⟩ else none

/-- The horizontal blur pass on rows `y0 .. y1 - 1`: `dst` gets `src` (straight alpha) blurred
along rows, **premultiplied** (the input `blurVRows` expects). -/
def blurHRows (radius : Float) (src dst : Image) (y0 y1 : Nat) : Image :=
  let y1 := min y1 dst.height
  if y1 ≤ y0 || src.width != dst.width || src.height != dst.height || src.width == 0 then dst
  else match Kern.of radius with
  | none => dst
  | some ⟨kern, k, n, hn, hkn⟩ =>
    let pad := fillPixels (src.width + 2 * k.toNat) 0 0 0 0
    let ⟨w, h, d⟩ := dst
    ⟨w, h, hRows src.data kern k n hn hkn pad d y0.toUSize y1.toUSize w.toUSize⟩

/-- Pixels `x .. w - 1` of output row `y` of the vertical pass, for `y` at least `k` rows from the
top and bottom (no clamping): the tap rows start at byte offsets `top = (y - k) · stride` and
`bot = (y + k) · stride`; pair `j` reads `q1 = top + j · stride` and `q2 = bot - j · stride` (plus
the column), and after the `k` pairs `q1` is the centre. -/
partial def vRowIn (src : @& ByteArray) (kern : @& Array UInt32) (k n : USize) (hn : WRange kern n) (hkn : k < n)
    (dst : ByteArray) (o top bot stride x w j q1 q2 : USize) (rb ga : UInt64) : ByteArray :=
  if x < w then
    if hj : j < k then
      if h1 : InPx src q1 then
        if h2 : InPx src q2 then
          let wt := (kern.uget j (hn.lt (USize.lt_trans hj hkn))).toUInt64
          let v1 := get32 src q1 h1
          let v2 := get32 src q2 h2
          vRowIn src kern k n hn hkn dst o top bot stride x w (j + 1) (q1 + stride) (q2 - stride)
            (rb + wt * spread (rbOf v1 + rbOf v2)) (ga + wt * spread (gaOf v1 + gaOf v2))
        else dst
      else dst
    else
      if hq : InPx src q1 then
        if ho : InPx dst o then
          let wt := (kern.uget k (hn.lt hkn)).toUInt64
          let v := get32 src q1 hq
          let w' := unpremulWord (rb + wt * spread (rbOf v)) (ga + wt * spread (gaOf v))
          let c := 4 * (x + 1)
          vRowIn src kern k n hn hkn (set32 dst o w' ho) (o + 4) top bot stride (x + 1) w 0 (top + c) (bot + c) 0 0
        else dst
      else dst
  else dst

/-- Pixels `x .. w - 1` of output row `y` of the vertical pass near the top or bottom: the tap
rows clamped to `0 .. h - 1`. -/
partial def vRowClamp (src : @& ByteArray) (kern : @& Array UInt32) (k n : USize) (hn : WRange kern n) (hkn : k < n)
    (dst : ByteArray) (o stride y h x w j : USize) (rb ga : UInt64) : ByteArray :=
  if x < w then
    let col := 4 * x
    if hj : j < k then
      let r1 := if y + j < k then 0 else y + j - k
      let r2 := if y + k - j ≥ h then h - 1 else y + k - j
      let q1 := r1 * stride + col
      let q2 := r2 * stride + col
      if h1 : InPx src q1 then
        if h2 : InPx src q2 then
          let wt := (kern.uget j (hn.lt (USize.lt_trans hj hkn))).toUInt64
          let v1 := get32 src q1 h1
          let v2 := get32 src q2 h2
          vRowClamp src kern k n hn hkn dst o stride y h x w (j + 1) (rb + wt * spread (rbOf v1 + rbOf v2))
            (ga + wt * spread (gaOf v1 + gaOf v2))
        else dst
      else dst
    else
      let q := y * stride + col
      if hq : InPx src q then
        if ho : InPx dst o then
          let wt := (kern.uget k (hn.lt hkn)).toUInt64
          let v := get32 src q hq
          let w' := unpremulWord (rb + wt * spread (rbOf v)) (ga + wt * spread (gaOf v))
          vRowClamp src kern k n hn hkn (set32 dst o w' ho) (o + 4) stride y h (x + 1) w 0 0 0
        else dst
      else dst
  else dst

partial def vRows (src : @& ByteArray) (kern : @& Array UInt32) (k n : USize) (hn : WRange kern n) (hkn : k < n)
    (dst : ByteArray) (y y1 w h : USize) : ByteArray :=
  if y < y1 then
    let stride := 4 * w
    let dst :=
      if y ≥ k && y + k < h then
        vRowIn src kern k n hn hkn dst (stride * y) ((y - k) * stride) ((y + k) * stride) stride 0 w 0 ((y - k) * stride)
          ((y + k) * stride) 0 0
      else vRowClamp src kern k n hn hkn dst (stride * y) stride y h 0 w 0 0 0
    vRows src kern k n hn hkn dst (y + 1) y1 w h
  else dst

/-- The vertical blur pass on rows `y0 .. y1 - 1`: `src` is the premultiplied output of
`blurHRows` (all of it, or at least rows `y0 - k .. y1 + k - 1`), `dst` gets straight alpha. -/
def blurVRows (radius : Float) (src dst : Image) (y0 y1 : Nat) : Image :=
  let y1 := min y1 dst.height
  if y1 ≤ y0 || src.width != dst.width || src.height != dst.height then dst
  else match Kern.of radius with
  | none => dst
  | some ⟨kern, k, n, hn, hkn⟩ =>
    let ⟨w, h, d⟩ := dst
    ⟨w, h, vRows src.data kern k n hn hkn d y0.toUSize y1.toUSize w.toUSize h.toUSize⟩

/-- `img` blurred with a Gaussian of `radius` pixels (`σ = radius / 2`). The result reuses `img`'s
buffer when `img` is unique; one temporary image of the same size. -/
def blur (img : Image) (radius : Float) : Image :=
  if !(radius > 0) || img.width == 0 || img.height == 0 then img
  else
    let tmp := blurHRows radius img (Image.blank img.width img.height) 0 img.height
    blurVRows radius tmp img 0 img.height

/-! ## Unsharp mask -/

/-- One colour channel of the unsharp mask (`amt` is the amount ×256). -/
@[inline] def usm (o b amt thr : UInt32) : UInt32 :=
  if o ≥ b then
    let diff := o - b
    if diff < thr then o else clamp255 (o + ((diff * amt + 128) >>> 8))
  else
    let diff := b - o
    if diff < thr then o else
      let s := (diff * amt + 128) >>> 8
      if s ≥ o then 0 else o - s

/-- Unsharp mask in place on the pixels at bytes `i .. n - 1` of `d`, against the blurred `bl`. -/
partial def usmLoop (bl : @& ByteArray) (d : ByteArray) (amt thr : UInt32) (i n : USize) : ByteArray :=
  if i < n then
    if h : InPx d i then
      if hb : InPx bl i then
        let v := get32 d i h
        let u := get32 bl i hb
        let w := usm (v &&& 255) (u &&& 255) amt thr ||| (usm ((v >>> 8) &&& 255) ((u >>> 8) &&& 255) amt thr <<< 8) |||
          (usm ((v >>> 16) &&& 255) ((u >>> 16) &&& 255) amt thr <<< 16) ||| (v &&& 0xff000000)
        usmLoop bl (set32 d i w h) amt thr (i + 4) n
      else d
    else d
  else d

/-- Rows `y0 .. y1 - 1` of `dst` = `src` sharpened against `blurred` (= `blur src radius`):
`v + amount · (v − blurred)` where `|v − blurred| ≥ threshold` (0..255), per colour channel;
`amount` is a factor (1 = 100 %, at most 16). `dst` may be `src` itself (then in place). -/
def sharpenRows (amount : Float) (threshold : Nat) (src blurred dst : Image) (y0 y1 : Nat) : Image :=
  let amt := (if amount < 0 then 0 else if amount > 16 then 16 else amount) * 256
  let run (img : Image) : Image :=
    let y1 := min y1 img.height
    if y1 ≤ y0 || blurred.width != img.width || blurred.height != img.height then img
    else
      let i := (4 * img.width * y0).toUSize
      let n := (4 * img.width * y1).toUSize
      let ⟨w, h, d⟩ := img
      ⟨w, h, usmLoop blurred.data d amt.round.toUInt32 (min threshold 256).toUInt32 i n⟩
  if aliases src dst then run src else run (copyRows src dst y0 y1)

/-- Unsharp mask: `amount` (factor, 1 = 100 %), `radius` of the blur, `threshold` (0..255). -/
def sharpen (img : Image) (amount radius : Float) (threshold : Nat := 0) : Image :=
  let blurred := blur img.copy radius
  sharpenRows amount threshold img blurred img 0 img.height

/-! ## 3×3 convolutions

A row is swept left to right with its 3×3 window in hand: each step reads the three pixels of the
next column and shifts the window, so a pixel is read three times in all instead of nine. -/

/-- A 3×3 kernel (rows first), applied as `Σ wᵢ·vᵢ / divisor + bias` to each colour channel. -/
structure Kernel3 where
  weights : Array Int
  divisor : Int := 1
  bias : Int := 0
  deriving Inhabited

namespace Kernel3
def identity : Kernel3 := ⟨#[0, 0, 0, 0, 1, 0, 0, 0, 0], 1, 0⟩
/-- The classic emboss kernel (light from the top left). -/
def emboss : Kernel3 := ⟨#[-2, -1, 0, -1, 1, 1, 0, 1, 2], 1, 0⟩
def sharpen : Kernel3 := ⟨#[0, -1, 0, -1, 5, -1, 0, -1, 0], 1, 0⟩
def boxBlur : Kernel3 := ⟨#[1, 1, 1, 1, 1, 1, 1, 1, 1], 9, 0⟩
end Kernel3

/-- A two's-complement `UInt32` as a `Float`. -/
@[inline] def signedToFloat (v : UInt32) : Float := if v >>> 31 != 0 then -(0 - v).toFloat else v.toFloat

/-- The channel at bit `s` of a pixel word. -/
@[inline] def chan (v s : UInt32) : UInt32 := (v >>> s) &&& 255

/-- One channel (bit `s`) of the convolved pixel from the window's columns `a` (left), `b`, `c`
(right), rows 0 (above) to 2 (below): `Σ kᵢ · vᵢ` in wrapping (two's-complement) arithmetic,
exact for weights below 2²⁰, then `· inv + bias`. -/
@[inline] def convCh (a0 b0 c0 a1 b1 c1 a2 b2 c2 s : UInt32) (k0 k1 k2 k3 k4 k5 k6 k7 k8 : UInt32) (inv bias : Float) :
    UInt32 :=
  let sum := k0 * chan a0 s + k1 * chan b0 s + k2 * chan c0 s + k3 * chan a1 s + k4 * chan b1 s + k5 * chan c1 s +
    k6 * chan a2 s + k7 * chan b2 s + k8 * chan c2 s
  (toByte (signedToFloat sum * inv + bias)).toUInt32

/-- Pixels `x .. w - 1` of output row `y`; `up`, `mid`, `dn` are the byte offsets of the rows
above, at and below `y` (clamped); `a*` and `b*` the window's left and middle columns (words). -/
partial def convRow (src : @& ByteArray) (dst : ByteArray) (up mid dn x w : USize) (a0 a1 a2 b0 b1 b2 : UInt32)
    (k0 k1 k2 k3 k4 k5 k6 k7 k8 : UInt32) (inv bias : Float) : ByteArray :=
  if x < w then
    let r := 4 * (if x + 1 ≥ w then x else x + 1)
    let o := mid + 4 * x
    if h0 : InPx src (up + r) then
      if h1 : InPx src (mid + r) then
        if h2 : InPx src (dn + r) then
          if ho : InPx dst o then
            let c0 := get32 src (up + r) h0
            let c1 := get32 src (mid + r) h1
            let c2 := get32 src (dn + r) h2
            let out := convCh a0 b0 c0 a1 b1 c1 a2 b2 c2 0 k0 k1 k2 k3 k4 k5 k6 k7 k8 inv bias |||
              (convCh a0 b0 c0 a1 b1 c1 a2 b2 c2 8 k0 k1 k2 k3 k4 k5 k6 k7 k8 inv bias <<< 8) |||
              (convCh a0 b0 c0 a1 b1 c1 a2 b2 c2 16 k0 k1 k2 k3 k4 k5 k6 k7 k8 inv bias <<< 16) ||| (b1 &&& 0xff000000)
            convRow src (set32 dst o out ho) up mid dn (x + 1) w b0 b1 b2 c0 c1 c2 k0 k1 k2 k3 k4 k5 k6 k7 k8 inv bias
          else dst
        else dst
      else dst
    else dst
  else dst

/-- The byte offsets of the rows above, at and below row `y` (clamped), with the proof that their
first pixels exist. -/
structure Rows3 (d : ByteArray) where
  up : USize
  mid : USize
  dn : USize
  hup : InPx d up
  hmid : InPx d mid
  hdn : InPx d dn

@[inline] def rows3 (d : ByteArray) (y w h : USize) : Option (Rows3 d) :=
  let s := 4 * w
  let up := s * (if y == 0 then 0 else y - 1)
  let mid := s * y
  let dn := s * (if y + 1 ≥ h then y else y + 1)
  if h1 : InPx d up then if h2 : InPx d mid then if h3 : InPx d dn then some ⟨up, mid, dn, h1, h2, h3⟩
  else none else none else none

partial def convRows (src : @& ByteArray) (dst : ByteArray) (y y1 w h : USize)
    (k0 k1 k2 k3 k4 k5 k6 k7 k8 : UInt32) (inv bias : Float) : ByteArray :=
  if y < y1 then
    match rows3 src y w h with
    | some r =>
      -- at the left edge the window's left column is the first column again
      let a0 := get32 src r.up r.hup
      let a1 := get32 src r.mid r.hmid
      let a2 := get32 src r.dn r.hdn
      let dst := convRow src dst r.up r.mid r.dn 0 w a0 a1 a2 a0 a1 a2 k0 k1 k2 k3 k4 k5 k6 k7 k8 inv bias
      convRows src dst (y + 1) y1 w h k0 k1 k2 k3 k4 k5 k6 k7 k8 inv bias
    | none => dst
  else dst

/-- Rows `y0 .. y1 - 1` of `dst` = `src` convolved with `k` (edges clamped, alpha kept). A zero
divisor counts as 1; weights are clamped to ±2²⁰. -/
def convolveRows (k : Kernel3) (src dst : Image) (y0 y1 : Nat) : Image :=
  let y1 := min y1 dst.height
  if y1 ≤ y0 || src.width != dst.width || src.height != dst.height || src.width == 0 then dst
  else
    let wt (i : Nat) : UInt32 :=
      let v := max (-1048576) (min 1048576 (k.weights[i]?.getD 0))
      if v < 0 then 0 - (-v).toNat.toUInt32 else v.toNat.toUInt32
    let inv := 1 / Float.ofInt (if k.divisor == 0 then 1 else k.divisor)
    let ⟨w, h, d⟩ := dst
    ⟨w, h, convRows src.data d y0.toUSize y1.toUSize w.toUSize h.toUSize
      (wt 0) (wt 1) (wt 2) (wt 3) (wt 4) (wt 5) (wt 6) (wt 7) (wt 8) inv (Float.ofInt k.bias)⟩

/-- `img` convolved with `k`. -/
def convolve (k : Kernel3) (img : Image) : Image :=
  convolveRows k img (Image.blank img.width img.height) 0 img.height

/-- The emboss preset. -/
def emboss (img : Image) : Image := convolve Kernel3.emboss img

/-! ## Edge detection -/

/-- Rec. 709 luminance of a pixel word, `(54 R + 183 G + 19 B + 128) / 256`. -/
@[inline] def lumOf (v : UInt32) : UInt32 :=
  let r : UInt32 := v &&& 255
  let g : UInt32 := (v >>> 8) &&& 255
  let b : UInt32 := (v >>> 16) &&& 255
  (54 * r + 183 * g + 19 * b + 128) >>> 8

/-- Pixels `x .. w - 1` of output row `y`: the luminances of the window's left (`l*`) and middle
(`m*`) columns are carried along, `ma` is the pixel under the window's centre (for its alpha).
The gradients are integers (`|gx|, |gy| ≤ 1020`, squares exact in wrapping `UInt32` arithmetic);
only the square root is `Float`, of the same exact value as before, so the bytes are unchanged. -/
partial def sobelRow (src : @& ByteArray) (dst : ByteArray) (up mid dn x w : USize) (l0 l1 l2 m0 m1 m2 ma : UInt32) :
    ByteArray :=
  if x < w then
    let r := 4 * (if x + 1 ≥ w then x else x + 1)
    let o := mid + 4 * x
    if h0 : InPx src (up + r) then
      if h1 : InPx src (mid + r) then
        if h2 : InPx src (dn + r) then
          if ho : InPx dst o then
            let c1 := get32 src (mid + r) h1
            let r0 := lumOf (get32 src (up + r) h0)
            let r1 := lumOf c1
            let r2 := lumOf (get32 src (dn + r) h2)
            let gx := (r0 + 2 * r1 + r2) - (l0 + 2 * l1 + l2)
            let gy := (l2 + 2 * m2 + r2) - (l0 + 2 * m0 + r0)
            let m := (toByte (Float.sqrt (gx * gx + gy * gy).toFloat)).toUInt32
            let out := m ||| (m <<< 8) ||| (m <<< 16) ||| (ma &&& 0xff000000)
            sobelRow src (set32 dst o out ho) up mid dn (x + 1) w m0 m1 m2 r0 r1 r2 c1
          else dst
        else dst
      else dst
    else dst
  else dst

partial def sobelRows (src : @& ByteArray) (dst : ByteArray) (y y1 w h : USize) : ByteArray :=
  if y < y1 then
    match rows3 src y w h with
    | some r =>
      let ma := get32 src r.mid r.hmid
      let l0 := lumOf (get32 src r.up r.hup)
      let l1 := lumOf ma
      let l2 := lumOf (get32 src r.dn r.hdn)
      sobelRows src (sobelRow src dst r.up r.mid r.dn 0 w l0 l1 l2 l0 l1 l2 ma) (y + 1) y1 w h
    | none => dst
  else dst

/-- Rows `y0 .. y1 - 1` of `dst` = the Sobel gradient magnitude of `src`'s luminance (clamped to
255), as gray; alpha kept. -/
def edgeDetectRows (src dst : Image) (y0 y1 : Nat) : Image :=
  let y1 := min y1 dst.height
  if y1 ≤ y0 || src.width != dst.width || src.height != dst.height || src.width == 0 then dst
  else
    let ⟨w, h, d⟩ := dst
    ⟨w, h, sobelRows src.data d y0.toUSize y1.toUSize w.toUSize h.toUSize⟩

/-- Sobel edge detection (gray output, alpha kept). -/
def edgeDetect (img : Image) : Image :=
  edgeDetectRows img (Image.blank img.width img.height) 0 img.height

end Editor
