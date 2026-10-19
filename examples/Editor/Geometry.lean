module
public import Editor.Image
/-!
# Geometry: crop, rotate, flip, resize, box downscale

Every function here returns a new image with its own buffer (a fresh allocation, never sharing
the source's), since the output has a different shape or reads pixels the output would overwrite.

* Rotations and flips are one loop (`walk`): the destination is written in order while the source
  offset moves by a fixed (possibly negative, as wrapping `USize`) step per pixel and per row.
* `resize` is bilinear with pixel centres aligned (`(x + ½) · sw / dw − ½`), 8-bit fractions,
  colour interpolated premultiplied by alpha (straight interpolation when all four neighbours are
  opaque, which is exact and faster). Same size is the identity.
* `downscaleBox` averages each output pixel's block of source pixels (block edges at
  `⌊x · sw / dw⌋`), premultiplied: every source pixel is read once, and a constant image stays
  exactly constant. It is the preview path for large images.
-/
public section
namespace Editor

/-! ## Crop -/

private partial def cropRows (src : @& ByteArray) (dst : ByteArray) (off stride rowBytes : Nat) (n : Nat) : ByteArray :=
  if n == 0 then dst
  else cropRows src (src.copySlice off dst dst.size rowBytes) (off + stride) stride rowBytes (n - 1)

/-- The part of `img` inside `r` (clamped to the image; empty when they do not overlap). -/
def crop (img : Image) (r : Rect) : Image :=
  let r := r.clamp img.width img.height
  if r.isEmpty then ⟨0, 0, .empty⟩
  else
    let d := cropRows img.data (ByteArray.emptyWithCapacity (4 * r.w * r.h)) (4 * (r.y * img.width + r.x))
      (4 * img.width) (4 * r.w) r.h
    ⟨r.w, r.h, d⟩

/-! ## Rotations and flips -/

/-- Fill `dst` (`w × h` pixels) in order from `src`: pixel `(x, y)` of `dst` comes from source
byte offset `s0 + y · dr + x · ds` (wrapping arithmetic, so steps may be negative). `o` is the
destination offset, `s` the source offset of the current pixel, `rs` of the current row's start. -/
partial def walk (src : @& ByteArray) (dst : ByteArray) (o s rs ds dr x y w h : USize) : ByteArray :=
  if x < w then
    if hs : InPx src s then
      if ho : InPx dst o then walk src (copyPx src s hs dst o ho) (o + 4) (s + ds) rs ds dr (x + 1) y w h
      else dst
    else dst
  else if y + 1 < h then walk src dst o (rs + dr) (rs + dr) ds dr 0 (y + 1) w h
  else dst

/-- A `w × h` image filled from `img` by `walk` (`s0`, `ds`, `dr` in bytes, as `Int`). -/
def walkImage (img : Image) (w h : Nat) (s0 ds dr : Int) : Image :=
  if w == 0 || h == 0 then ⟨w, h, .empty⟩
  else
    let u (v : Int) : USize := if v < 0 then 0 - (-v).toNat.toUSize else v.toNat.toUSize
    let dst := (Image.blank w h).data
    ⟨w, h, walk img.data dst 0 (u s0) (u s0) (u ds) (u dr) 0 0 w.toUSize h.toUSize⟩

/-- Rotated a quarter turn clockwise (`width` and `height` swap). -/
def rotate90cw (img : Image) : Image :=
  let w : Int := img.width
  let h : Int := img.height
  -- destination (x, y) = source (y, h - 1 - x)
  walkImage img img.height img.width (4 * (h - 1) * w) (-4 * w) 4

/-- Rotated a quarter turn counter-clockwise. -/
def rotate90ccw (img : Image) : Image :=
  let w : Int := img.width
  -- destination (x, y) = source (w - 1 - y, x)
  walkImage img img.height img.width (4 * (w - 1)) (4 * w) (-4)

/-- Rotated half a turn. -/
def rotate180 (img : Image) : Image :=
  let w : Int := img.width
  let h : Int := img.height
  walkImage img img.width img.height (4 * (h * w - 1)) (-4) (-4 * w)

/-- Mirrored left to right. -/
def flipH (img : Image) : Image :=
  let w : Int := img.width
  walkImage img img.width img.height (4 * (w - 1)) (-4) (4 * w)

private partial def flipVRows (src : @& ByteArray) (dst : ByteArray) (off stride : Nat) (n : Nat) : ByteArray :=
  if n == 0 then dst
  else flipVRows src (src.copySlice off dst dst.size stride) (off - stride) stride (n - 1)

/-- Mirrored top to bottom (one `memcpy` per row). -/
def flipV (img : Image) : Image :=
  if img.width == 0 || img.height == 0 then img.copy
  else
    let s := 4 * img.width
    ⟨img.width, img.height,
      flipVRows img.data (ByteArray.emptyWithCapacity (s * img.height)) (s * (img.height - 1)) s img.height⟩

/-! ## Bilinear resize -/

/-- Source sample positions for `dn` output samples over `sn` source samples, 8-bit fixed point:
for output `i`, `(i + ½) · sn / dn − ½` clamped to `0 .. sn − 1`. Three words per output sample:
the byte offset (`× scale`) of the lower neighbour, of the upper one (clamped), and the fraction. -/
def samplePositions (sn dn scale : Nat) : Array UInt32 := Id.run do
  let mut t : Array UInt32 := Array.emptyWithCapacity (3 * dn)
  for i in [0:dn] do
    -- (2i + 1) · sn · 256 / (2 dn) − 128, as an integer
    let p : Int := ((2 * i + 1) * sn * 256 / (2 * dn) : Nat) - 128
    let p := if p < 0 then 0 else min p.toNat ((sn - 1) * 256)
    let i0 := p / 256
    let i1 := min (i0 + 1) (sn - 1)
    t := t.push (i0 * scale).toUInt32 |>.push (i1 * scale).toUInt32 |>.push (p % 256).toUInt32
  return t

/-- The four neighbours of a bilinear sample are pixels of `d`. -/
abbrev In4 (d : ByteArray) (p00 p01 p10 p11 : USize) : Prop := InPx d p00 ∧ InPx d p01 ∧ InPx d p10 ∧ InPx d p11

/-- Bilinear blend of channel `c` from four pixels with weights summing to 65536 (straight). -/
@[inline] def bilin (src : ByteArray) (p00 p01 p10 p11 : USize) (h : In4 src p00 p01 p10 p11) (w00 w01 w10 w11 : UInt32)
    (c : USize) (hc : c ≤ 3 := by exact usize_le3 _ (by simp)) : UInt32 :=
  (w00 * px32 src p00 h.1 c hc + w01 * px32 src p01 h.2.1 c hc + w10 * px32 src p10 h.2.2.1 c hc +
    w11 * px32 src p11 h.2.2.2 c hc + 32768) >>> 16

/-- Bilinear blend of colour channel `c`, premultiplied by the alphas `a..`; `sa` is the weighted
alpha sum (> 0). -/
@[inline] def bilinPremul (src : ByteArray) (p00 p01 p10 p11 : USize) (h : In4 src p00 p01 p10 p11)
    (w00 w01 w10 w11 : UInt64) (a00 a01 a10 a11 sa : UInt64) (c : USize)
    (hc : c ≤ 3 := by exact usize_le3 _ (by simp)) : UInt32 :=
  let s := w00 * a00 * (px32 src p00 h.1 c hc).toUInt64 + w01 * a01 * (px32 src p01 h.2.1 c hc).toUInt64 +
    w10 * a10 * (px32 src p10 h.2.2.1 c hc).toUInt64 + w11 * a11 * (px32 src p11 h.2.2.2 c hc).toUInt64
  let v := (s + sa / 2) / sa
  if v > 255 then 255 else v.toUInt32

/-- Output pixels `x .. w - 1` of one row: source rows at byte offsets `r0`, `r1`, vertical
fraction `fy`; `cols` from `samplePositions`. -/
partial def resizeRow (src : @& ByteArray) (cols : @& Array UInt32) (dst : ByteArray) (o r0 r1 : USize) (fy : UInt32)
    (x w : USize) : ByteArray :=
  if x < w then
    let x0 := (rdW cols (3 * x)).toUSize
    let x1 := (rdW cols (3 * x + 1)).toUSize
    let fx := rdW cols (3 * x + 2)
    let p00 := r0 + x0
    let p01 := r0 + x1
    let p10 := r1 + x0
    let p11 := r1 + x1
    let w00 := (256 - fx) * (256 - fy)
    let w01 := fx * (256 - fy)
    let w10 := (256 - fx) * fy
    let w11 := fx * fy
    if h : In4 src p00 p01 p10 p11 then
      if ho : InPx dst o then
        let a00 := px32 src p00 h.1 3
        let a01 := px32 src p01 h.2.1 3
        let a10 := px32 src p10 h.2.2.1 3
        let a11 := px32 src p11 h.2.2.2 3
        let dst :=
          if a00 &&& a01 &&& a10 &&& a11 == 255 then
            put4w dst o ho (bilin src p00 p01 p10 p11 h w00 w01 w10 w11 0) (bilin src p00 p01 p10 p11 h w00 w01 w10 w11 1)
              (bilin src p00 p01 p10 p11 h w00 w01 w10 w11 2) 255
          else
            let sa := w00.toUInt64 * a00.toUInt64 + w01.toUInt64 * a01.toUInt64 + w10.toUInt64 * a10.toUInt64 +
              w11.toUInt64 * a11.toUInt64
            let alpha := bilin src p00 p01 p10 p11 h w00 w01 w10 w11 3
            if sa == 0 then
              put4w dst o ho (bilin src p00 p01 p10 p11 h w00 w01 w10 w11 0) (bilin src p00 p01 p10 p11 h w00 w01 w10 w11 1)
                (bilin src p00 p01 p10 p11 h w00 w01 w10 w11 2) alpha
            else
              let W00 := w00.toUInt64
              let W01 := w01.toUInt64
              let W10 := w10.toUInt64
              let W11 := w11.toUInt64
              let A00 := a00.toUInt64
              let A01 := a01.toUInt64
              let A10 := a10.toUInt64
              let A11 := a11.toUInt64
              put4w dst o ho (bilinPremul src p00 p01 p10 p11 h W00 W01 W10 W11 A00 A01 A10 A11 sa 0)
                (bilinPremul src p00 p01 p10 p11 h W00 W01 W10 W11 A00 A01 A10 A11 sa 1)
                (bilinPremul src p00 p01 p10 p11 h W00 W01 W10 W11 A00 A01 A10 A11 sa 2) alpha
        resizeRow src cols dst (o + 4) r0 r1 fy (x + 1) w
      else dst
    else dst
  else dst

partial def resizeRowsLoop (src : @& ByteArray) (cols rows : @& Array UInt32) (dst : ByteArray) (y y1 w : USize) :
    ByteArray :=
  if y < y1 then
    let r0 := (rdW rows (3 * y)).toUSize
    let r1 := (rdW rows (3 * y + 1)).toUSize
    let fy := rdW rows (3 * y + 2)
    resizeRowsLoop src cols rows (resizeRow src cols dst (4 * w * y) r0 r1 fy 0 w) (y + 1) y1 w
  else dst

/-- Rows `y0 .. y1 - 1` of `dst` = `src` resized (bilinear) to `dst`'s size. -/
def resizeRows (src dst : Image) (y0 y1 : Nat) : Image :=
  let y1 := min y1 dst.height
  if y1 ≤ y0 || src.width == 0 || src.height == 0 || dst.width == 0 then dst
  else
    let cols := samplePositions src.width dst.width 4
    let rows := samplePositions src.height dst.height (4 * src.width)
    let ⟨w, h, d⟩ := dst
    ⟨w, h, resizeRowsLoop src.data cols rows d y0.toUSize y1.toUSize w.toUSize⟩

/-- `img` resized to `w × h` (bilinear; same size gives the same pixels). -/
def resize (img : Image) (w h : Nat) : Image :=
  if img.width == 0 || img.height == 0 then Image.blank w h
  else resizeRows img (Image.blank w h) 0 h

/-! ## Box downscale -/

/-- Block edges for `dn` output samples over `sn` source samples: `dn + 1` words, entry `i` is
`⌊i · sn / dn⌋`; a block is at least one sample wide. -/
def blockEdges (sn dn : Nat) : Array UInt32 :=
  (Array.range (dn + 1)).map fun i => (i * sn / dn).toUInt32

/-- Sum the block of source pixels from byte `s` (row start `rs`, column bytes `cx .. ce - 1`,
rows up to byte `rEnd`), then write the averaged pixel at `o`. Sums: alpha, colour × alpha, and
plain colour (used when the block is fully transparent). -/
partial def boxBlock (src : @& ByteArray) (dst : ByteArray) (o stride rs cx ce s rEnd : USize) (n : UInt64)
    (sa sr sg sb tr tg tb : UInt64) : ByteArray :=
  if s < rs + ce then
    if hs : InPx src s then
      let a := (px src s hs 3).toUInt64
      let r := (px src s hs 0).toUInt64
      let g := (px src s hs 1).toUInt64
      let b := (px src s hs 2).toUInt64
      boxBlock src dst o stride rs cx ce (s + 4) rEnd n (sa + a) (sr + a * r) (sg + a * g) (sb + a * b)
        (tr + r) (tg + g) (tb + b)
    else dst
  else if rs + stride < rEnd then
    boxBlock src dst o stride (rs + stride) cx ce (rs + stride + cx) rEnd n sa sr sg sb tr tg tb
  else if ho : InPx dst o then
    let half := n / 2
    let alpha := ((sa + half) / n).toUInt8
    if sa == 0 then
      put4 dst o ho ((tr + half) / n).toUInt8 ((tg + half) / n).toUInt8 ((tb + half) / n).toUInt8 alpha
    else
      let ha := sa / 2
      put4 dst o ho ((sr + ha) / sa).toUInt8 ((sg + ha) / sa).toUInt8 ((sb + ha) / sa).toUInt8 alpha
  else dst

partial def boxRow (src : @& ByteArray) (cols : @& Array UInt32) (dst : ByteArray) (o stride r0 r1 x w : USize) :
    ByteArray :=
  if x < w then
    let c0 := (rdW cols x).toUSize
    let c1 := (rdW cols (x + 1)).toUSize
    let c1 := if c1 ≤ c0 then c0 + 1 else c1
    let n := ((c1 - c0) * (r1 - r0)).toUInt64
    let rs := r0 * stride
    let dst := boxBlock src dst o stride rs (4 * c0) (4 * c1) (rs + 4 * c0) (r1 * stride) n 0 0 0 0 0 0 0
    boxRow src cols dst (o + 4) stride r0 r1 (x + 1) w
  else dst

partial def boxRows (src : @& ByteArray) (cols rows : @& Array UInt32) (dst : ByteArray) (stride y y1 w : USize) :
    ByteArray :=
  if y < y1 then
    let r0 := (rdW rows y).toUSize
    let r1 := (rdW rows (y + 1)).toUSize
    let r1 := if r1 ≤ r0 then r0 + 1 else r1
    boxRows src cols rows (boxRow src cols dst (4 * w * y) stride r0 r1 0 w) stride (y + 1) y1 w
  else dst

/-- Rows `y0 .. y1 - 1` of `dst` = `src` box-downscaled to `dst`'s size (meant for
`dst` no larger than `src`; a larger `dst` repeats pixels). -/
def downscaleBoxRows (src dst : Image) (y0 y1 : Nat) : Image :=
  let y1 := min y1 dst.height
  if y1 ≤ y0 || src.width == 0 || src.height == 0 || dst.width == 0 then dst
  else
    let cols := blockEdges src.width dst.width
    let rows := blockEdges src.height dst.height
    let ⟨w, h, d⟩ := dst
    ⟨w, h, boxRows src.data cols rows d (4 * src.width).toUSize y0.toUSize y1.toUSize w.toUSize⟩

/-- `img` downscaled to `w × h` by averaging blocks of pixels (a new buffer, never `img`'s). -/
def downscaleBox (img : Image) (w h : Nat) : Image :=
  if img.width == 0 || img.height == 0 then Image.blank w h
  else downscaleBoxRows img (Image.blank w h) 0 h

/-- The largest size within `maxW × maxH` with `img`'s aspect ratio (never larger than `img`). -/
def fitSize (img : Image) (maxW maxH : Nat) : Nat × Nat :=
  if img.width ≤ maxW && img.height ≤ maxH then (img.width, img.height)
  else if img.width * maxH ≥ img.height * maxW then
    (maxW, max 1 ((img.height * maxW + img.width / 2) / img.width))
  else (max 1 ((img.width * maxH + img.height / 2) / img.height), maxH)

end Editor
