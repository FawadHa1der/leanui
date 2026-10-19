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

/-! ## Gaussian blur -/

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

/-- Fill `pad` (at least `4 * (w + 2k)` bytes) with row `rowOff` of `src`, premultiplied and
extended by `k` copies of the edge pixels on each side: pad pixel `p` is source pixel
`clamp (p - k) 0 (w - 1)`. -/
partial def padRow (src : @& ByteArray) (pad : ByteArray) (rowOff w k p n : USize) : ByteArray :=
  if p < n then
    let x := if p < k then 0 else if p - k ≥ w then w - 1 else p - k
    let s := rowOff + 4 * x
    let o := 4 * p
    if hs : InPx src s then
      if ho : InPx pad o then
        let a := px32 src s hs 3
        let pad := put4w pad o ho (div255 (px32 src s hs 0 * a)) (div255 (px32 src s hs 1 * a))
          (div255 (px32 src s hs 2 * a)) a
        padRow src pad rowOff w k (p + 1) n
      else pad
    else pad
  else pad

/-- A colour sum divided by the alpha sum (both with the kernel's weights), as straight colour:
`255 · c / a`, rounded, at most 255. -/
@[inline] def unpremul (c a : UInt32) : UInt32 :=
  let a : UInt64 := a.toUInt64
  let v : UInt64 := (c.toUInt64 * 255 + a / 2) / a
  if v > 255 then 255 else v.toUInt32

/-- Write a blurred pixel from its weighted sums (weights summing to 65536) of premultiplied
colour and of alpha, as straight alpha: `255 · c / a` per colour channel. Where every pixel under
the kernel is opaque (`a = 255 · 65536`), that is exactly `(c + 32768) / 65536`, without dividing. -/
@[inline] def putUnpremul (dst : ByteArray) (o : USize) (ho : InPx dst o) (ar ag ab aa : UInt32) : ByteArray :=
  if aa == 16711680 then
    put4w dst o ho ((ar + 32768) >>> 16) ((ag + 32768) >>> 16) ((ab + 32768) >>> 16) 255
  else if aa == 0 then put4 dst o ho 0 0 0 0
  else put4w dst o ho (unpremul ar aa) (unpremul ag aa) (unpremul ab aa) ((aa + 32768) >>> 16)

/-- Horizontal taps `j .. n - 1` for the output pixel at byte `o`, whose window starts at byte `q`
of `pad`; writes the (premultiplied) pixel when done. -/
partial def hTaps (pad : @& ByteArray) (kern : @& Array UInt32) (n : USize) (hn : WRange kern n) (dst : ByteArray)
    (o q j : USize) (ar ag ab aa : UInt32) : ByteArray :=
  if hj : j < n then
    if hq : InPx pad q then
      let wt := kern.uget j (hn.lt hj)
      hTaps pad kern n hn dst o (q + 4) (j + 1) (ar + wt * px32 pad q hq 0) (ag + wt * px32 pad q hq 1)
        (ab + wt * px32 pad q hq 2) (aa + wt * px32 pad q hq 3)
    else dst
  else if ho : InPx dst o then
    put4w dst o ho ((ar + 32768) >>> 16) ((ag + 32768) >>> 16) ((ab + 32768) >>> 16) ((aa + 32768) >>> 16)
  else dst

/-- Pixels `x .. w - 1` of one row of the horizontal pass. -/
partial def hRow (pad : @& ByteArray) (kern : @& Array UInt32) (n : USize) (hn : WRange kern n) (dst : ByteArray)
    (o x w : USize) : ByteArray :=
  if x < w then hRow pad kern n hn (hTaps pad kern n hn dst o (4 * x) 0 0 0 0 0) (o + 4) (x + 1) w
  else dst

/-- Rows `y .. y1 - 1` of the horizontal pass. -/
partial def hRows (src : @& ByteArray) (kern : @& Array UInt32) (n : USize) (hn : WRange kern n) (pad dst : ByteArray)
    (y y1 w k : USize) : ByteArray :=
  if y < y1 then
    let rowOff := 4 * w * y
    let pad := padRow src pad rowOff w k 0 (w + 2 * k)
    let dst := hRow pad kern n hn dst rowOff 0 w
    hRows src kern n hn pad dst (y + 1) y1 w k
  else dst

/-- The horizontal blur pass on rows `y0 .. y1 - 1`: `dst` gets `src` (straight alpha) blurred
along rows, **premultiplied** (the input `blurVRows` expects). -/
def blurHRows (radius : Float) (src dst : Image) (y0 y1 : Nat) : Image :=
  let y1 := min y1 dst.height
  if y1 ≤ y0 || src.width != dst.width || src.height != dst.height || src.width == 0 then dst
  else
    let kern := gaussKernel radius
    let k := kern.size / 2
    let ⟨n, hn⟩ := wrangeOf kern kern.usize
    let pad := fillPixels (src.width + 2 * k) 0 0 0 0
    let ⟨w, h, d⟩ := dst
    ⟨w, h, hRows src.data kern n hn pad d y0.toUSize y1.toUSize w.toUSize k.toUSize⟩

/-- Vertical taps `j .. n - 1` for the output pixel at byte `o` (column byte offset `col`, output
row `y`): tap `j` reads row `clamp (y + j - k) 0 (h - 1)`. Writes the pixel, un-premultiplied, when
done. -/
partial def vTaps (src : @& ByteArray) (kern : @& Array UInt32) (n : USize) (hn : WRange kern n) (dst : ByteArray)
    (o col stride y k h j : USize) (ar ag ab aa : UInt32) : ByteArray :=
  if hj : j < n then
    let vr := y + j
    let r := if vr < k then 0 else if vr - k ≥ h then h - 1 else vr - k
    let q := r * stride + col
    if hq : InPx src q then
      let wt := kern.uget j (hn.lt hj)
      vTaps src kern n hn dst o col stride y k h (j + 1) (ar + wt * px32 src q hq 0) (ag + wt * px32 src q hq 1)
        (ab + wt * px32 src q hq 2) (aa + wt * px32 src q hq 3)
    else dst
  else if ho : InPx dst o then putUnpremul dst o ho ar ag ab aa
  else dst

/-- Vertical taps without clamping, for rows at least `k` away from the top and bottom: the window
starts at byte `q` and steps one row (`stride`) per tap. -/
partial def vTapsIn (src : @& ByteArray) (kern : @& Array UInt32) (n : USize) (hn : WRange kern n) (dst : ByteArray)
    (o q stride j : USize) (ar ag ab aa : UInt32) : ByteArray :=
  if hj : j < n then
    if hq : InPx src q then
      let wt := kern.uget j (hn.lt hj)
      vTapsIn src kern n hn dst o (q + stride) stride (j + 1) (ar + wt * px32 src q hq 0) (ag + wt * px32 src q hq 1)
        (ab + wt * px32 src q hq 2) (aa + wt * px32 src q hq 3)
    else dst
  else if ho : InPx dst o then putUnpremul dst o ho ar ag ab aa
  else dst

/-- Pixels `x .. w - 1` of output row `y` of the vertical pass. -/
partial def vRow (src : @& ByteArray) (kern : @& Array UInt32) (n : USize) (hn : WRange kern n) (dst : ByteArray)
    (rowOff x w y k h : USize) : ByteArray :=
  if x < w then
    let stride := 4 * w
    let col := 4 * x
    let dst :=
      if y ≥ k && y + k < h then vTapsIn src kern n hn dst (rowOff + col) ((y - k) * stride + col) stride 0 0 0 0 0
      else vTaps src kern n hn dst (rowOff + col) col stride y k h 0 0 0 0 0
    vRow src kern n hn dst rowOff (x + 1) w y k h
  else dst

partial def vRows (src : @& ByteArray) (kern : @& Array UInt32) (n : USize) (hn : WRange kern n) (dst : ByteArray)
    (y y1 w k h : USize) : ByteArray :=
  if y < y1 then vRows src kern n hn (vRow src kern n hn dst (4 * w * y) 0 w y k h) (y + 1) y1 w k h
  else dst

/-- The vertical blur pass on rows `y0 .. y1 - 1`: `src` is the premultiplied output of
`blurHRows` (all of it, or at least rows `y0 - k .. y1 + k - 1`), `dst` gets straight alpha. -/
def blurVRows (radius : Float) (src dst : Image) (y0 y1 : Nat) : Image :=
  let y1 := min y1 dst.height
  if y1 ≤ y0 || src.width != dst.width || src.height != dst.height then dst
  else
    let kern := gaussKernel radius
    let k := kern.size / 2
    let ⟨n, hn⟩ := wrangeOf kern kern.usize
    let ⟨w, h, d⟩ := dst
    ⟨w, h, vRows src.data kern n hn d y0.toUSize y1.toUSize w.toUSize k.toUSize h.toUSize⟩

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

/-- Unsharp mask in place on bytes `i .. n - 1` of `d`, against the blurred `bl`. -/
partial def usmLoop (bl : @& ByteArray) (d : ByteArray) (amt thr : UInt32) (i n : USize) : ByteArray :=
  if i < n then
    if h : InPx d i then
      if hb : InPx bl i then
        let d := put3w d i h (usm (px32 d i h 0) (px32 bl i hb 0) amt thr) (usm (px32 d i h 1) (px32 bl i hb 1) amt thr)
          (usm (px32 d i h 2) (px32 bl i hb 2) amt thr)
        usmLoop bl d amt thr (i + 4) n
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

/-! ## 3×3 convolutions -/

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

/-- The 9 neighbours of a pixel (rows `up`, `mid`, `dn`, columns `l`, `c`, `r`, as byte offsets)
are pixels of `d`. -/
abbrev In9 (d : ByteArray) (up mid dn l c r : USize) : Prop :=
  InPx d (up + l) ∧ InPx d (up + c) ∧ InPx d (up + r) ∧ InPx d (mid + l) ∧ InPx d (mid + c) ∧
    InPx d (mid + r) ∧ InPx d (dn + l) ∧ InPx d (dn + c) ∧ InPx d (dn + r)

/-- A two's-complement `UInt32` as a `Float`. -/
@[inline] def signedToFloat (v : UInt32) : Float := if v >>> 31 != 0 then -(0 - v).toFloat else v.toFloat

/-- Channel `j` of the convolved pixel: `Σ kᵢ · vᵢ` in wrapping (two's-complement) integer
arithmetic, which is exact (|Σ| < 2³¹ for weights below 2²⁰), then `· inv + bias`. -/
@[inline] def convCh (d : ByteArray) (up mid dn l c r : USize) (h : In9 d up mid dn l c r) (j : USize)
    (k0 k1 k2 k3 k4 k5 k6 k7 k8 : UInt32) (inv bias : Float) (hj : j ≤ 3 := by exact usize_le3 _ (by simp)) : UInt8 :=
  let s := k0 * px32 d (up + l) h.1 j hj + k1 * px32 d (up + c) h.2.1 j hj + k2 * px32 d (up + r) h.2.2.1 j hj +
    k3 * px32 d (mid + l) h.2.2.2.1 j hj + k4 * px32 d (mid + c) h.2.2.2.2.1 j hj +
    k5 * px32 d (mid + r) h.2.2.2.2.2.1 j hj + k6 * px32 d (dn + l) h.2.2.2.2.2.2.1 j hj +
    k7 * px32 d (dn + c) h.2.2.2.2.2.2.2.1 j hj + k8 * px32 d (dn + r) h.2.2.2.2.2.2.2.2 j hj
  toByte (signedToFloat s * inv + bias)

/-- Pixels `x .. w - 1` of output row `y`; `up`, `mid`, `dn` are the byte offsets of the rows
above, at and below `y` (clamped). -/
partial def convRow (src : @& ByteArray) (dst : ByteArray) (up mid dn x w : USize)
    (k0 k1 k2 k3 k4 k5 k6 k7 k8 : UInt32) (inv bias : Float) : ByteArray :=
  if x < w then
    let l := 4 * (if x == 0 then 0 else x - 1)
    let c := 4 * x
    let r := 4 * (if x + 1 ≥ w then x else x + 1)
    let o := mid + c
    if h : In9 src up mid dn l c r then
      if ho : InPx dst o then
        let dst := put4 dst o ho (convCh src up mid dn l c r h 0 k0 k1 k2 k3 k4 k5 k6 k7 k8 inv bias)
          (convCh src up mid dn l c r h 1 k0 k1 k2 k3 k4 k5 k6 k7 k8 inv bias)
          (convCh src up mid dn l c r h 2 k0 k1 k2 k3 k4 k5 k6 k7 k8 inv bias) (px src (mid + c) h.2.2.2.2.1 3)
        convRow src dst up mid dn (x + 1) w k0 k1 k2 k3 k4 k5 k6 k7 k8 inv bias
      else dst
    else dst
  else dst

partial def convRows (src : @& ByteArray) (dst : ByteArray) (y y1 w h : USize)
    (k0 k1 k2 k3 k4 k5 k6 k7 k8 : UInt32) (inv bias : Float) : ByteArray :=
  if y < y1 then
    let s := 4 * w
    let up := s * (if y == 0 then 0 else y - 1)
    let dn := s * (if y + 1 ≥ h then y else y + 1)
    let dst := convRow src dst up (s * y) dn 0 w k0 k1 k2 k3 k4 k5 k6 k7 k8 inv bias
    convRows src dst (y + 1) y1 w h k0 k1 k2 k3 k4 k5 k6 k7 k8 inv bias
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

/-- Rec. 709 luminance of the pixel at byte `o`, `(54 R + 183 G + 19 B + 128) / 256`. -/
@[inline] def lumAt (d : ByteArray) (o : USize) (h : InPx d o) : Float :=
  ((54 * px32 d o h 0 + 183 * px32 d o h 1 + 19 * px32 d o h 2 + 128) >>> 8).toFloat

partial def sobelRow (src : @& ByteArray) (dst : ByteArray) (up mid dn x w : USize) : ByteArray :=
  if x < w then
    let l := 4 * (if x == 0 then 0 else x - 1)
    let c := 4 * x
    let r := 4 * (if x + 1 ≥ w then x else x + 1)
    let o := mid + c
    if h : In9 src up mid dn l c r then
      if ho : InPx dst o then
        let p00 := lumAt src (up + l) h.1
        let p01 := lumAt src (up + c) h.2.1
        let p02 := lumAt src (up + r) h.2.2.1
        let p10 := lumAt src (mid + l) h.2.2.2.1
        let p12 := lumAt src (mid + r) h.2.2.2.2.2.1
        let p20 := lumAt src (dn + l) h.2.2.2.2.2.2.1
        let p21 := lumAt src (dn + c) h.2.2.2.2.2.2.2.1
        let p22 := lumAt src (dn + r) h.2.2.2.2.2.2.2.2
        let gx := (p02 + 2 * p12 + p22) - (p00 + 2 * p10 + p20)
        let gy := (p20 + 2 * p21 + p22) - (p00 + 2 * p01 + p02)
        let m := toByte (Float.sqrt (gx * gx + gy * gy))
        sobelRow src (put4 dst o ho m m m (px src o h.2.2.2.2.1 3)) up mid dn (x + 1) w
      else dst
    else dst
  else dst

partial def sobelRows (src : @& ByteArray) (dst : ByteArray) (y y1 w h : USize) : ByteArray :=
  if y < y1 then
    let s := 4 * w
    let up := s * (if y == 0 then 0 else y - 1)
    let dn := s * (if y + 1 ≥ h then y else y + 1)
    sobelRows src (sobelRow src dst up (s * y) dn 0 w) (y + 1) y1 w h
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
