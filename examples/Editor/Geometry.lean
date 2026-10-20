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

private partial def cropLoop (src : @& ByteArray) (dst : ByteArray) (off stride rowBytes y y1 : Nat) : ByteArray :=
  if y < y1 then
    cropLoop src (src.copySlice (off + y * stride) dst (y * rowBytes) rowBytes) off stride rowBytes (y + 1) y1
  else dst

/-- Rows `y0 .. y1 - 1` of `dst` = the same rows of `src` cropped to `r` (clamped to `src`; `dst`
has the clamped rectangle's size, else it is returned unchanged). One `memcpy` per row. -/
def cropRows (r : Rect) (src dst : Image) (y0 y1 : Nat) : Image :=
  let r := r.clamp src.width src.height
  let y1 := min y1 dst.height
  if y1 ≤ y0 || r.isEmpty || dst.width != r.w || dst.height != r.h then dst
  else
    let ⟨w, h, d⟩ := dst
    ⟨w, h, cropLoop src.data d (4 * (r.y * src.width + r.x)) (4 * src.width) (4 * r.w) y0 y1⟩

/-- The part of `img` inside `r` (clamped to the image; empty when they do not overlap). -/
def crop (img : Image) (r : Rect) : Image :=
  let r := r.clamp img.width img.height
  if r.isEmpty then ⟨0, 0, .empty⟩
  -- all rows in order: each `memcpy` appends to the empty buffer (no zero fill first)
  else cropRows r img ⟨r.w, r.h, ByteArray.emptyWithCapacity (4 * r.w * r.h)⟩ 0 r.h

/-! ## Rotations and flips

Each has a row variant (`…Rows src dst y0 y1`: output rows `y0 .. y1 - 1` of a `dst` of the right
size, allocated by the caller, so that the editor can spread the work over frames); the
whole-image function is the row variant over all rows of a fresh image. -/

/-- One row of `walk`: bytes `i .. rb - 1` of the destination row at `o` from source offsets
`s, s + ds, …` (wrapping arithmetic, so the step may be negative). The row is checked once
(`RowIn`); each source pixel is checked (the source does not change, so its size stays in a
register). A pixel is copied as one word. -/
partial def walkRow (src : @& ByteArray) (dst : ByteArray) (o rb : USize) (ho : RowIn dst o rb) (h3 : 3 ≤ rb)
    (i s ds : USize) : ByteArray :=
  if hi : i < rb - 3 then
    if hs : InPx src s then
      walkRow src (set32 dst (o + i) (get32 src s hs) (ho.px h3 hi)) o rb (ho.set32 _ _ _) h3 (i + 4) (s + ds) ds
    else dst
  else dst

/-- Fill rows `y .. h - 1` of `dst` (`rb` bytes each, the current one at `o`) from `src`: pixel
`(x, y)` of `dst` comes from source byte offset `s0 + y · dr + x · ds`; `rs` is the source offset
of the current row's first pixel. -/
partial def walk (src : @& ByteArray) (dst : ByteArray) (o rs ds dr rb y h : USize) : ByteArray :=
  if y < h then
    if ho : RowIn dst o rb ∧ 3 ≤ rb then
      walk src (walkRow src dst o rb ho.1 ho.2 0 rs ds) (o + rb) (rs + dr) ds dr rb (y + 1) h
    else dst
  else dst

/-- Rows `y0 .. y1 - 1` of `dst` filled from `src` by `walk` (`s0`, `ds`, `dr` in bytes, as `Int`). -/
def walkRows (src dst : Image) (s0 ds dr : Int) (y0 y1 : Nat) : Image :=
  let y1 := min y1 dst.height
  if y1 ≤ y0 || dst.width == 0 then dst
  else
    let u (v : Int) : USize := if v < 0 then 0 - (-v).toNat.toUSize else v.toNat.toUSize
    let rs := u s0 + y0.toUSize * u dr
    let ⟨w, h, d⟩ := dst
    ⟨w, h, walk src.data d (4 * w * y0).toUSize rs (u ds) (u dr) (4 * w).toUSize y0.toUSize y1.toUSize⟩

/-- Rows `y0 .. y1 - 1` of `src` rotated a quarter turn clockwise, into `dst` (`src.height` wide,
`src.width` high). -/
def rotate90cwRows (src dst : Image) (y0 y1 : Nat) : Image :=
  if dst.width != src.height || dst.height != src.width then dst
  else
    let w : Int := src.width
    let h : Int := src.height
    -- destination (x, y) = source (y, h - 1 - x)
    walkRows src dst (4 * (h - 1) * w) (-4 * w) 4 y0 y1

/-- Rotated a quarter turn clockwise (`width` and `height` swap). -/
def rotate90cw (img : Image) : Image := rotate90cwRows img (Image.blank img.height img.width) 0 img.width

/-- Rows `y0 .. y1 - 1` of `src` rotated a quarter turn counter-clockwise, into `dst`
(`src.height` wide, `src.width` high). -/
def rotate90ccwRows (src dst : Image) (y0 y1 : Nat) : Image :=
  if dst.width != src.height || dst.height != src.width then dst
  else
    let w : Int := src.width
    -- destination (x, y) = source (w - 1 - y, x)
    walkRows src dst (4 * (w - 1)) (4 * w) (-4) y0 y1

/-- Rotated a quarter turn counter-clockwise. -/
def rotate90ccw (img : Image) : Image := rotate90ccwRows img (Image.blank img.height img.width) 0 img.width

/-- Rows `y0 .. y1 - 1` of `src` rotated half a turn, into `dst` (same size). -/
def rotate180Rows (src dst : Image) (y0 y1 : Nat) : Image :=
  if dst.width != src.width || dst.height != src.height then dst
  else
    let w : Int := src.width
    let h : Int := src.height
    walkRows src dst (4 * (h * w - 1)) (-4) (-4 * w) y0 y1

/-- Rotated half a turn. -/
def rotate180 (img : Image) : Image := rotate180Rows img (Image.blank img.width img.height) 0 img.height

/-- Rows `y0 .. y1 - 1` of `src` mirrored left to right, into `dst` (same size). -/
def flipHRows (src dst : Image) (y0 y1 : Nat) : Image :=
  if dst.width != src.width || dst.height != src.height then dst
  else
    let w : Int := src.width
    walkRows src dst (4 * (w - 1)) (-4) (4 * w) y0 y1

/-- Mirrored left to right. -/
def flipH (img : Image) : Image := flipHRows img (Image.blank img.width img.height) 0 img.height

private partial def flipVLoop (src : @& ByteArray) (dst : ByteArray) (y y1 h s : Nat) : ByteArray :=
  if y < y1 then flipVLoop src (src.copySlice ((h - 1 - y) * s) dst (y * s) s) (y + 1) y1 h s else dst

/-- Rows `y0 .. y1 - 1` of `src` mirrored top to bottom, into `dst` (same size): one `memcpy` per
row. -/
def flipVRows (src dst : Image) (y0 y1 : Nat) : Image :=
  let y1 := min y1 dst.height
  if y1 ≤ y0 || dst.width != src.width || dst.height != src.height then dst
  else
    let ⟨w, h, d⟩ := dst
    ⟨w, h, flipVLoop src.data d y0 y1 h (4 * w)⟩

/-- Mirrored top to bottom. -/
def flipV (img : Image) : Image :=
  -- all rows in order: each `memcpy` appends to the empty buffer (no zero fill first)
  flipVRows img ⟨img.width, img.height, ByteArray.emptyWithCapacity (4 * img.width * img.height)⟩ 0 img.height

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

/-- Bilinear blend of the colour channel at bit `s`, premultiplied by the alphas `a..`; `sa` is
the weighted alpha sum (> 0). -/
@[inline] def chanAt (v s : UInt32) : UInt64 := ((v >>> s) &&& 255).toUInt64

@[inline] def bilinPremul (v00 v01 v10 v11 : UInt32) (w00 w01 w10 w11 a00 a01 a10 a11 sa : UInt64) (s : UInt32) :
    UInt32 :=
  let t := w00 * a00 * chanAt v00 s + w01 * a01 * chanAt v01 s + w10 * a10 * chanAt v10 s + w11 * a11 * chanAt v11 s
  let v := (t + sa / 2) / sa
  if v > 255 then 255 else v.toUInt32

/-- Output pixels `x ..` of the row at `o` (`len` bytes, byte `i = 4 x` of it next): source rows at
byte offsets `r0`, `r1`, vertical fraction `fy`; `cols` from `samplePositions`. Each neighbour is
read as one word; red and blue, green and alpha are blended two at a time. -/
partial def resizeRow (src : @& ByteArray) (cols : @& Array UInt32) (dst : ByteArray) (o len : USize)
    (ho : RowIn dst o len) (h3 : 3 ≤ len) (r0 r1 : USize) (fy : UInt32) (x i : USize) : ByteArray :=
  if hi : i < len - 3 then
    let x0 := (rdW cols (3 * x)).toUSize
    let x1 := (rdW cols (3 * x + 1)).toUSize
    let fx := rdW cols (3 * x + 2)
    let p00 := r0 + x0
    let p01 := r0 + x1
    let p10 := r1 + x0
    let p11 := r1 + x1
    if h : In4 src p00 p01 p10 p11 then
      let v00 := get32 src p00 h.1
      let v01 := get32 src p01 h.2.1
      let v10 := get32 src p10 h.2.2.1
      let v11 := get32 src p11 h.2.2.2
      let w00 := ((256 - fx) * (256 - fy)).toUInt64
      let w01 := (fx * (256 - fy)).toUInt64
      let w10 := ((256 - fx) * fy).toUInt64
      let w11 := (fx * fy).toUInt64
      let rb := w00 * spread (rbOf v00) + w01 * spread (rbOf v01) + w10 * spread (rbOf v10) +
        w11 * spread (rbOf v11)
      let ga := w00 * spread (gaOf v00) + w01 * spread (gaOf v01) + w10 * spread (gaOf v10) +
        w11 * spread (gaOf v11)
      let straight := roundWord rb ga
      let out :=
        if (v00 &&& v01 &&& v10 &&& v11) >>> 24 == 255 then straight
        else
          let a00 := (v00 >>> 24).toUInt64
          let a01 := (v01 >>> 24).toUInt64
          let a10 := (v10 >>> 24).toUInt64
          let a11 := (v11 >>> 24).toUInt64
          let sa := w00 * a00 + w01 * a01 + w10 * a10 + w11 * a11
          if sa == 0 then straight
          else
            bilinPremul v00 v01 v10 v11 w00 w01 w10 w11 a00 a01 a10 a11 sa 0 |||
              (bilinPremul v00 v01 v10 v11 w00 w01 w10 w11 a00 a01 a10 a11 sa 8 <<< 8) |||
              (bilinPremul v00 v01 v10 v11 w00 w01 w10 w11 a00 a01 a10 a11 sa 16 <<< 16) ||| (straight &&& 0xff000000)
      resizeRow src cols (set32 dst (o + i) out (ho.px h3 hi)) o len (ho.set32 _ _ _) h3 r0 r1 fy (x + 1) (i + 4)
    else dst
  else dst

partial def resizeRowsLoop (src : @& ByteArray) (cols rows : @& Array UInt32) (dst : ByteArray) (y y1 w : USize) :
    ByteArray :=
  if y < y1 then
    let r0 := (rdW rows (3 * y)).toUSize
    let r1 := (rdW rows (3 * y + 1)).toUSize
    let fy := rdW rows (3 * y + 2)
    let o := 4 * w * y
    if ho : RowIn dst o (4 * w) ∧ 3 ≤ 4 * w then
      resizeRowsLoop src cols rows (resizeRow src cols dst o (4 * w) ho.1 ho.2 r0 r1 fy 0 0) (y + 1) y1 w
    else dst
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
      let v := get32 src s hs
      let a := (v >>> 24).toUInt64
      let r := (v &&& 255).toUInt64
      let g := ((v >>> 8) &&& 255).toUInt64
      let b := ((v >>> 16) &&& 255).toUInt64
      boxBlock src dst o stride rs cx ce (s + 4) rEnd n (sa + a) (sr + a * r) (sg + a * g) (sb + a * b)
        (tr + r) (tg + g) (tb + b)
    else dst
  else if rs + stride < rEnd then
    boxBlock src dst o stride (rs + stride) cx ce (rs + stride + cx) rEnd n sa sr sg sb tr tg tb
  else if ho : InPx dst o then
    let half := n / 2
    let alpha := ((sa + half) / n).toUInt32 <<< 24
    if sa == 0 then
      set32 dst o (((tr + half) / n).toUInt32 ||| (((tg + half) / n).toUInt32 <<< 8) |||
        (((tb + half) / n).toUInt32 <<< 16) ||| alpha) ho
    else
      let ha := sa / 2
      set32 dst o (((sr + ha) / sa).toUInt32 ||| (((sg + ha) / sa).toUInt32 <<< 8) |||
        (((sb + ha) / sa).toUInt32 <<< 16) ||| alpha) ho
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
