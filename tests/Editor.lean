module
public import Editor.Core
public import Editor
public import LeanUI.Testing.Harness
/-!
# Tests for the photo editor core (`examples/Editor/*.lean`)

`lake build leanui-editor-tests && .lake/build/bin/leanui-editor-tests` (`--print-goldens` prints
the golden checksums instead of checking them; `--write-pngs DIR` writes the PNG files the
goldens pin, and the same images encoded a few rows per step, with their raw pixels, for checking
them with another decoder).

* **Goldens**: the FNV-1a checksum of every operation's output on fixed generated images (a
  deterministic pseudo-random RGBA image with transparent, translucent and opaque pixels). All but
  the compressed PNG files agree with an independent Python implementation of every operation
  (`python3 tests/editor-ref/reference.py tests/Editor.lean`), and `testByHand` pins values worked
  out by hand.
* **Properties**: rotations and flips compose to the identity, crops clamp, a same-size resize is
  the identity, blur and box downscale keep a constant image exactly, the identity adjustment and a
  double inversion change nothing, compositing with opacity 0 changes nothing and an opaque normal
  top replaces the bottom, histogram groups sum to the pixel count, row-chunked and in-place runs
  equal whole-image runs (and in-place runs keep the buffer), a dab changes only pixels inside its
  dirty rectangle.
* **PNG**: encode/decode round trips at every level, for sizes from 1×1 to widths that are not a
  multiple of anything, with transparency; decoding of files written by Python's `zlib` (dynamic
  and fixed Huffman blocks, all five row filters, colour types 0, 2, 3, 4, 6, `tRNS`, split
  `IDAT` chunks); errors for corrupt and unsupported files.
* **The editor** (`Editor.Doc`, `Editor.Ops`, `Editor`): previews and preview compositing,
  painting in place (one copy per stroke while history holds the old pixels, none after), every
  job's row-sliced result equals the whole-image operation, export round-trips through PNG, and
  the program itself in the DOM model (`LeanUI.Testing`): open, adjust with live preview, apply,
  filters, paint, undo and redo, layers, geometry, crop, export.
-/
public section
open Editor

/-! ## A tiny test framework -/

structure Suite where
  passed : Nat := 0
  failed : Array String := #[]

abbrev T := StateT Suite IO

def expect (name : String) (ok : Bool) (detail : String := "") : T Unit :=
  modify fun s => if ok then { s with passed := s.passed + 1 } else { s with failed := s.failed.push s!"{name}: {detail}" }

def expectEq {α : Type} [BEq α] [Repr α] (name : String) (got want : α) : T Unit :=
  expect name (got == want) s!"got {repr got}, want {repr want}"

instance : Repr Image where
  reprPrec i _ := s!"<{i.width}×{i.height} image, checksum {i.checksum}>"

/-! ## Test images -/

/-- The LCG `s ↦ 1103515245 s + 12345 (mod 2³²)`, one byte (the top 8 bits) per step. -/
def lcg (s : UInt32) : UInt32 := s * 1103515245 + 12345

private partial def noiseLoop (n : Nat) (s : UInt32) (alpha : Bool) (d : ByteArray) : ByteArray :=
  if n == 0 then d
  else
    let s1 := lcg s
    let s2 := lcg s1
    let s3 := lcg s2
    let s4 := lcg s3
    let a0 := s4 >>> 24
    let a := if !alpha then 255 else if a0 < 64 then 0 else if a0 > 160 then 255 else a0
    noiseLoop (n - 1) s4 alpha
      (d.push (s1 >>> 24).toUInt8 |>.push (s2 >>> 24).toUInt8 |>.push (s3 >>> 24).toUInt8 |>.push a.toUInt8)

/-- Pseudo-random pixels; with `alpha`, a quarter of them transparent, a third opaque. -/
def noise (w h : Nat) (seed : UInt32) (alpha : Bool := true) : Image :=
  ⟨w, h, noiseLoop (w * h) seed alpha (ByteArray.emptyWithCapacity (4 * w * h))⟩

def gradient (w h : Nat) : Image :=
  Image.generate w h fun x y =>
    ⟨(x * 255 / max 1 (w - 1)).toUInt8, (y * 255 / max 1 (h - 1)).toUInt8, ((x + y) * 4 % 256).toUInt8, 255⟩

def checker (w h k : Nat) : Image :=
  Image.generate w h fun x y => if (x / k + y / k) % 2 == 0 then ⟨240, 240, 240, 255⟩ else ⟨20, 40, 60, 255⟩

def hexBytes (s : String) : ByteArray := Id.run do
  let digit (c : Char) : Nat := if c.isDigit then c.toNat - 48 else c.toLower.toNat - 87
  let cs := s.toList.toArray
  let mut b := ByteArray.emptyWithCapacity (cs.size / 2)
  for i in [0:cs.size / 2] do b := b.push (digit cs[2 * i]! * 16 + digit cs[2 * i + 1]!).toUInt8
  return b

def fnvBytes (b : ByteArray) : UInt64 :=
  b.foldl (fun h x => (h ^^^ x.toUInt64) * 0x100000001b3) 0xcbf29ce484222325

/-- Whether every pixel of `img` equals `c`. -/
def isConstant (img : Image) (c : Color) : Bool :=
  (List.range img.height).all fun y => (List.range img.width).all fun x => img.get x y == c

/-- Mean of each channel, as exact sums. -/
def channelSums (img : Image) : Array Nat := Id.run do
  let mut s := #[0, 0, 0, 0]
  for i in [0:img.data.size] do s := s.modify (i % 4) (· + (img.data.get! i).toNat)
  return s

/-- A copy of `img` made at run time. An image built from constants (`noise 64 48 99`) is a closed
term: the compiler computes it once at initialisation and marks it persistent, so it is shared and
the first write to it copies it. Images in the editor come from run-time data and are unique. -/
@[noinline] def fresh (img : Image) : IO Image := do
  let _ ← IO.monoNanosNow
  return img.copy

private unsafe def addrImpl (a : @& ByteArray) : USize := ptrAddrUnsafe a
/-- The address of a buffer (to check that an in-place operation kept it). -/
@[implemented_by addrImpl] opaque addrOf (a : @& ByteArray) : USize

/-- The address of `img`'s buffer, taken now: a pure `addrOf img.data` may be moved after the
operation under test, and the reference it holds would make that operation copy. -/
@[noinline] def addrNow (img : @& Image) : IO USize := pure (addrOf img.data)

/-! ## Goldens -/

def base : Image := noise 37 23 7
def top : Image := noise 37 23 11
def opaqueBase : Image := noise 37 23 5 (alpha := false)

def adjustments : Array (String × Adjust) := #[
  ("brightness +30", { brightness := 30 }),
  ("brightness -45", { brightness := -45 }),
  ("contrast +40", { contrast := 40 }),
  ("contrast -60", { contrast := -60 }),
  ("exposure +1", { exposure := 1 }),
  ("exposure -1.5", { exposure := -1.5 }),
  ("saturation +50", { saturation := 50 }),
  ("saturation -100", { saturation := -100 }),
  ("hue +90", { hue := 90 }),
  ("hue -150", { hue := -150 }),
  ("levels 20 230 1.5", { inBlack := 20, inWhite := 230, gamma := 1.5 }),
  ("curve", { curve := #[(64, 40), (192, 220)] }),
  ("invert", { invert := true }),
  ("grayscale", { grayscale := true }),
  ("everything", { brightness := 10, contrast := 20, exposure := 0.5, saturation := 30, hue := 45, inBlack := 5,
                   inWhite := 250, gamma := 0.8, curve := #[(128, 150)], invert := true })]

/-- Every operation's output checksum on the fixed images. -/
def computeGoldens : Array (String × UInt64) := Id.run do
  let mut g : Array (String × UInt64) := #[]
  g := g.push ("base", base.checksum)
  g := g.push ("top", top.checksum)
  g := g.push ("opaque base", opaqueBase.checksum)
  for (n, a) in adjustments do g := g.push (s!"adjust {n}", (Adjust.apply a base).checksum)
  g := g.push ("histogram", fnvBytes ((histogram base).foldl (fun b n => b.push n.toUInt8 |>.push (n >>> 8).toUInt8) .empty))
  g := g.push ("blur 2", (blur base 2).checksum)
  g := g.push ("blur 5.5", (blur base 5.5).checksum)
  g := g.push ("blur 1 opaque", (blur opaqueBase 1).checksum)
  g := g.push ("sharpen 1.5 2 4", (sharpen base 1.5 2 4).checksum)
  g := g.push ("emboss", (emboss base).checksum)
  g := g.push ("edges", (edgeDetect base).checksum)
  g := g.push ("convolve sharpen", (convolve Kernel3.sharpen base).checksum)
  g := g.push ("convolve box", (convolve Kernel3.boxBlur base).checksum)
  g := g.push ("crop", (crop base ⟨5, 3, 20, 11⟩).checksum)
  g := g.push ("rotate90cw", (rotate90cw base).checksum)
  g := g.push ("rotate90ccw", (rotate90ccw base).checksum)
  g := g.push ("rotate180", (rotate180 base).checksum)
  g := g.push ("flipH", (flipH base).checksum)
  g := g.push ("flipV", (flipV base).checksum)
  g := g.push ("resize 50x31", (resize base 50 31).checksum)
  g := g.push ("resize 19x12", (resize base 19 12).checksum)
  g := g.push ("resize opaque 61x9", (resize opaqueBase 61 9).checksum)
  g := g.push ("downscaleBox 9x6", (downscaleBox base 9 6).checksum)
  g := g.push ("downscaleBox opaque 10x7", (downscaleBox opaqueBase 10 7).checksum)
  for m in Blend.all do
    g := g.push (s!"composite {m.name} 70", (composite base top 70 m).checksum)
  g := g.push ("composite normal 100 opaque", (composite base opaqueBase 100 .normal).checksum)
  let (d1, _) := dab (Image.filled 37 23 ⟨128, 128, 128, 255⟩) 12.3 9.7 6 0.3 0.8 ⟨255, 0, 0, 255⟩
  g := g.push ("dab", d1.checksum)
  let (d2, _) := dab base 20 11 7.5 0.6 0.9 ⟨0, 0, 0, 255⟩ (erase := true)
  g := g.push ("dab erase", d2.checksum)
  let (d3, _) := stroke base 2 3 33 19 { radius := 3, hardness := 0.8, opacity := 0.5, color := ⟨20, 200, 90, 200⟩ }
  g := g.push ("stroke", d3.checksum)
  g := g.push ("png level 0", fnvBytes (Png.encode base 0))
  -- compressed files: regression values (their bytes depend on the match finder; that zlib decodes
  -- them to the same pixels was checked separately, and the round trips below check it here)
  g := g.push ("png level 1 base", fnvBytes (Png.encode base 1))
  g := g.push ("png level 1 gradient", fnvBytes (Png.encode (gradient 61 37) 1))
  g := g.push ("png level 9 gradient", fnvBytes (Png.encode (gradient 61 37) 9))
  g := g.push ("png level 4 checker", fnvBytes (Png.encode (checker 64 48 8) 4))
  return g

/-- The checksums, computed once (`--print-goldens`). Every value without a comment was also
computed by an independent Python implementation of the same operation (integer arithmetic in
unbounded integers, the same `Float` operations), from the module docs rather than from this
code, and agreed bit for bit (`tests/editor-ref/reference.py`); the compressed PNG files depend on
the match finder's choices and are pinned as regression values (zlib decodes each of them to the
right pixels: `--write-pngs DIR`, then `tests/editor-ref/checkpng.py DIR`). -/
def goldens : Array (String × UInt64) := #[
  ("base", 3669157684786124675),
  ("top", 8388644841955276691),
  ("opaque base", 5664073072405071361),
  ("adjust brightness +30", 12979794080992187372),
  ("adjust brightness -45", 11867916135128231460),
  ("adjust contrast +40", 7386388244830165220),
  ("adjust contrast -60", 6262515543700386758),
  ("adjust exposure +1", 10787792860769411046),
  ("adjust exposure -1.5", 13499554741655916783),
  ("adjust saturation +50", 4092951747386455940),
  ("adjust saturation -100", 7438250664282352996),
  ("adjust hue +90", 501723987716219976),
  ("adjust hue -150", 17130046741766851311),
  ("adjust levels 20 230 1.5", 11510289179156089800),
  ("adjust curve", 551716221834668048),
  ("adjust invert", 818808443797961166),
  ("adjust grayscale", 7438250664282352996),
  ("adjust everything", 17341812473990490804),
  ("histogram", 12391668878900486417),
  ("blur 2", 17749764076234417413),
  ("blur 5.5", 18191668895029947395),
  ("blur 1 opaque", 8883701886086679246),
  ("sharpen 1.5 2 4", 14263134377548551677),
  ("emboss", 5711039999915235937),
  ("edges", 6341890161510939502),
  ("convolve sharpen", 9580192720616566484),
  ("convolve box", 5551613313782211426),
  ("crop", 6031776381593341906),
  ("rotate90cw", 12195864118447180135),
  ("rotate90ccw", 373260738159065803),
  ("rotate180", 11797608333238582495),
  ("flipH", 7459363040189247611),
  ("flipV", 4169942354124224343),
  ("resize 50x31", 16534357420678752096),
  ("resize 19x12", 10460529478379884920),
  ("resize opaque 61x9", 11174950451946468907),
  ("downscaleBox 9x6", 9957795955556798395),
  ("downscaleBox opaque 10x7", 3908144773044773232),
  ("composite normal 70", 5960856787130741741),
  ("composite multiply 70", 15229122953356335545),
  ("composite screen 70", 4481823708232635485),
  ("composite overlay 70", 10387752543394756760),
  ("composite darken 70", 11203951836086756554),
  ("composite lighten 70", 5561912806900770683),
  ("composite add 70", 9234481257250460095),
  ("composite difference 70", 10476984485680221852),
  ("composite normal 100 opaque", 5664073072405071361),
  ("dab", 7676936011403969229),
  ("dab erase", 9647572622887803743),
  ("stroke", 11456490241125041107),
  ("png level 0", 6806697601329155686),
  ("png level 1 base", 1990139527323276070),  -- regression value (no reference)
  ("png level 1 gradient", 9433216412011867151),  -- regression value (no reference)
  ("png level 9 gradient", 4648973054096427166),  -- regression value (no reference)
  ("png level 4 checker", 6439162997708695296)]  -- regression value (no reference)

def testGoldens : T Unit := do
  let got := computeGoldens
  for (n, want) in goldens do
    match got.find? (·.1 == n) with
    | some (_, v) => expectEq s!"golden {n}" v want
    | none => expect s!"golden {n}" false "not computed"
  expect "every golden is pinned" (goldens.size == got.size) s!"{got.size} computed, {goldens.size} pinned"

/-! ## Values worked out by hand -/

def testByHand : T Unit := do
  -- FNV-1a 64 of a 1×1 image: width 1 and height 1 as 4 LE bytes each, then the pixel
  let one := Image.new 1 1 1 2 3 4
  let manual := [1, 0, 0, 0, 1, 0, 0, 0, 1, 2, 3, 4].foldl
    (fun (h : UInt64) (b : Nat) => (h ^^^ b.toUInt64) * 0x100000001b3) 0xcbf29ce484222325
  expectEq "checksum of a 1×1 image" one.checksum manual
  expectEq "Image.new fills every pixel" (Image.new 3 2 9 8 7 6).data.toList
    ((List.replicate 6 [9, 8, 7, 6]).flatten.map (·.toUInt8))
  expectEq "zeros" (zeros 70001).toList (List.replicate 70001 0)
  -- brightness +30 adds 38.25 → 38 (rounded) to every channel, clamps at 255
  let b := Adjust.apply { brightness := 30 } (Image.new 2 1 100 230 0 77)
  expectEq "brightness +30 by hand" (b.get 0 0) ⟨138, 255, 38, 77⟩
  -- invert: 255 - v, alpha kept
  expectEq "invert by hand" ((Adjust.apply { invert := true } (Image.new 1 1 0 100 255 9)).get 0 0) ⟨255, 155, 0, 9⟩
  -- grayscale: Rec. 709 matrix rows (871, 2929, 296)/4096 → (10, 20, 30) → 18.5... = 19
  expectEq "grayscale by hand" ((Adjust.apply { grayscale := true } (Image.new 1 1 10 20 30 255)).get 0 0) ⟨19, 19, 19, 255⟩
  expectEq "fixed grayscale matrix" (Adjust.fixedMatrix (Adjust.saturateMat 0)).toList
    [871, 2929, 296, 871, 2929, 296, 871, 2929, 296]
  -- levels 0..255 → gamma 2: 64 → 255 · (64/255)^(1/2) = 127.7 → 128
  expectEq "levels gamma by hand" ((Adjust.apply { gamma := 2 } (Image.new 1 1 64 0 255 255)).get 0 0) ⟨128, 0, 255, 255⟩
  -- contrast -100 makes everything mid-gray
  expectEq "contrast -100" ((Adjust.apply { contrast := -100 } (Image.new 1 1 3 200 255 255)).get 0 0) ⟨128, 128, 128, 255⟩
  -- multiply 50% gray over white, opaque: 255·128/255 = 128
  let m := composite (Image.new 1 1 255 255 255 255) (Image.new 1 1 128 64 0 255) 100 .multiply
  expectEq "multiply by hand" (m.get 0 0) ⟨128, 64, 0, 255⟩
  -- normal at 50% (127.5 → 128 of 255) over opaque black: colour 255·128/255 = 128
  let n := composite (Image.new 1 1 0 0 0 255) (Image.new 1 1 255 255 255 255) 50 .normal
  expectEq "50% normal by hand" (n.get 0 0) ⟨128, 128, 128, 255⟩
  -- normal over transparent: the top pixel with its alpha times the opacity (255·0.5 → 128)
  let t := composite (Image.blank 1 1) (Image.new 1 1 10 20 30 255) 50 .normal
  expectEq "normal over transparent by hand" (t.get 0 0) ⟨10, 20, 30, 128⟩
  -- screen 100 over 200: 200 + 100 − 200·100/255 = 221.6 → 222; difference 100 vs 200 = 100
  expectEq "screen by hand" ((composite (Image.new 1 1 200 0 0 255) (Image.new 1 1 100 0 0 255) 100 .screen).get 0 0) ⟨222, 0, 0, 255⟩
  expectEq "difference by hand" ((composite (Image.new 1 1 200 9 0 255) (Image.new 1 1 100 9 0 255) 100 .difference).get 0 0) ⟨100, 0, 0, 255⟩
  -- box downscale of a 2×2 block: (10 + 20 + 30 + 41) / 4 = 25.25 → 25
  let q := Image.generate 2 2 fun x y => ⟨(10 + 10 * (x + 2 * y) + (if x + y == 2 then 1 else 0)).toUInt8, 0, 0, 255⟩
  expectEq "box average by hand" ((downscaleBox q 1 1).get 0 0) ⟨25, 0, 0, 255⟩
  -- bilinear 2×1 → 4×1: sample positions −0.25, 0.25, 0.75, 1.25 → 0, 64/256, 192/256, 1 of the way
  let r := resize (Image.generate 2 1 fun x _ => ⟨(x * 200).toUInt8, 0, 0, 255⟩) 4 1
  expectEq "bilinear by hand" ((List.range 4).map fun x => (r.get x 0).r) [0, 50, 150, 200]
  -- Sobel on a vertical edge 0 | 255: gx = 4·255 at the edge, clamped to 255
  let e := edgeDetect (Image.generate 4 3 fun x _ => if x < 2 then ⟨0, 0, 0, 255⟩ else ⟨255, 255, 255, 255⟩)
  expectEq "sobel by hand" ((List.range 4).map fun x => (e.get x 1).r) [0, 255, 255, 0]
  -- Gaussian kernel: symmetric, sums to 65536
  for r in [0.5, 1, 2.5, 7] do
    let k := gaussKernel r
    expect s!"gauss kernel {r} sums to 65536" (k.foldl (· + ·.toNat) 0 == 65536)
    expect s!"gauss kernel {r} is symmetric" (k == k.reverse)
  -- CRC-32 and Adler-32 of "123456789" (the standard check values)
  let nine := "123456789".toUTF8
  expectEq "crc32 check value" (Png.crc32 nine 0 9) 0xCBF43926
  expectEq "adler32 check value" (Png.adler32 nine 0 9) 0x091E01DE
  -- rectangles
  expectEq "rect inter" (Rect.inter ⟨0, 0, 10, 10⟩ ⟨5, 7, 10, 10⟩) ⟨5, 7, 5, 3⟩
  expectEq "rect disjoint" (Rect.inter ⟨0, 0, 10, 10⟩ ⟨10, 0, 5, 5⟩).isEmpty true
  expectEq "rect union" (Rect.union ⟨0, 0, 2, 2⟩ ⟨5, 7, 1, 1⟩) ⟨0, 0, 6, 8⟩
  expectEq "rect union empty" (Rect.union Rect.empty ⟨5, 7, 1, 1⟩) ⟨5, 7, 1, 1⟩
  expectEq "rect clamp" (Rect.clamp ⟨30, 20, 50, 50⟩ 37 23) ⟨30, 20, 7, 3⟩

/-! ## Properties -/

def testGeometry : T Unit := do
  for img in [base, noise 1 1 3, noise 5 1 4, noise 1 6 5, noise 16 9 6, gradient 13 8] do
    let s := s!"{img.width}×{img.height}"
    expectEq s!"rotate90cw ×4 = id ({s})" (rotate90cw (rotate90cw (rotate90cw (rotate90cw img)))) img
    expectEq s!"rotate90ccw ×4 = id ({s})" (rotate90ccw (rotate90ccw (rotate90ccw (rotate90ccw img)))) img
    expectEq s!"rotate cw then ccw = id ({s})" (rotate90ccw (rotate90cw img)) img
    expectEq s!"rotate ccw then cw = id ({s})" (rotate90cw (rotate90ccw img)) img
    expectEq s!"flipH ×2 = id ({s})" (flipH (flipH img)) img
    expectEq s!"flipV ×2 = id ({s})" (flipV (flipV img)) img
    expectEq s!"rotate180 = flipH ∘ flipV ({s})" (rotate180 img) (flipH (flipV img))
    expectEq s!"rotate180 = rotate90cw ×2 ({s})" (rotate180 img) (rotate90cw (rotate90cw img))
    expectEq s!"rotate90cw size ({s})" ((rotate90cw img).width, (rotate90cw img).height) (img.height, img.width)
    expectEq s!"resize to the same size = id ({s})" (resize img img.width img.height) img
    expectEq s!"crop everything = id ({s})" (crop img ⟨0, 0, img.width, img.height⟩) img
  -- rotate90cw moves (x, y) to (h - 1 - y, x)
  let r := rotate90cw base
  expect "rotate90cw pixel mapping" ((List.range base.height).all fun y => (List.range base.width).all fun x =>
    r.get (base.height - 1 - y) x == base.get x y)
  -- crop bounds and clamping
  let c := crop base ⟨30, 20, 50, 50⟩
  expectEq "crop clamps to the image" (c.width, c.height) (7, 3)
  expect "crop pixels" ((List.range 3).all fun y => (List.range 7).all fun x => c.get x y == base.get (30 + x) (20 + y))
  expectEq "crop outside is empty" ((crop base ⟨40, 0, 5, 5⟩).width, (crop base ⟨40, 0, 5, 5⟩).height) (0, 0)
  expect "crop is valid" (c.valid && (crop base ⟨5, 3, 20, 11⟩).valid)
  -- resize and box downscale of constant images
  for col in [(⟨12, 200, 99, 255⟩ : Color), ⟨1, 2, 3, 128⟩, ⟨250, 250, 250, 0⟩] do
    let k := Image.filled 37 23 col
    expect s!"box downscale keeps constant {repr col}" (isConstant (downscaleBox k 9 6) col)
    expect s!"box downscale (not a divisor) keeps constant {repr col}" (isConstant (downscaleBox k 10 7) col)
    expect s!"resize up keeps constant {repr col}" (isConstant (resize k 50 31) col)
    expect s!"resize down keeps constant {repr col}" (isConstant (resize k 11 4) col)
  -- downscale never aliases its source, and a preview fits
  let p := downscaleBox base 37 23
  expectEq "box downscale to the same size = id" p base
  expect "box downscale has its own buffer" (addrOf p.data != addrOf base.data)
  expectEq "fitSize" (fitSize (Image.blank 4000 3000) 1024 1024) (1024, 768)
  -- rows variants equal the whole operation
  let dst := Image.blank 50 31
  let chunked := resizeRows base (resizeRows base (resizeRows base dst 0 7) 7 20) 20 31
  expectEq "resize in row chunks" chunked (resize base 50 31)
  let dst := Image.blank 9 6
  let chunked := downscaleBoxRows base (downscaleBoxRows base dst 0 4) 4 6
  expectEq "box downscale in row chunks" chunked (downscaleBox base 9 6)
  -- rotations, flips and crop in row chunks (as the editor's jobs run them) equal the whole operation
  let r : Rect := ⟨3, 2, 30, 15⟩
  for img in [base, noise 1 6 5, noise 5 1 4, gradient 13 8] do
    let s := s!"{img.width}×{img.height}"
    let rc := r.clamp img.width img.height
    for k in [1, 3] do
      let inChunks (f : Image → Image → Nat → Nat → Image) (dst : Image) : Image := Id.run do
        let mut d := dst
        let mut y := 0
        while y < dst.height do
          d := f img d y (y + k)
          y := y + k
        return d
      let swapped := Image.blank img.height img.width
      let same := Image.blank img.width img.height
      expectEq s!"rotate90cw in chunks of {k} rows ({s})" (inChunks rotate90cwRows swapped) (rotate90cw img)
      expectEq s!"rotate90ccw in chunks of {k} rows ({s})" (inChunks rotate90ccwRows swapped) (rotate90ccw img)
      expectEq s!"rotate180 in chunks of {k} rows ({s})" (inChunks rotate180Rows same) (rotate180 img)
      expectEq s!"flipH in chunks of {k} rows ({s})" (inChunks flipHRows same) (flipH img)
      expectEq s!"flipV in chunks of {k} rows ({s})" (inChunks flipVRows same) (flipV img)
      expectEq s!"crop in chunks of {k} rows ({s})" (inChunks (cropRows r) (Image.blank rc.w rc.h)) (crop img r)
  let wrong := Image.blank 5 5
  expectEq "rows variants leave a wrongly sized destination alone"
    [rotate90cwRows base wrong 0 5, rotate180Rows base wrong 0 5, flipVRows base wrong 0 5, cropRows r base wrong 0 5]
    [wrong, wrong, wrong, wrong]

def testFilters : T Unit := do
  for col in [(⟨12, 200, 99, 255⟩ : Color), ⟨0, 0, 0, 255⟩, ⟨255, 255, 255, 255⟩] do
    let k := Image.filled 23 17 col
    for r in [0.5, 2, 6, 40] do
      let b := blur k r
      expect s!"blur {r} keeps constant {repr col}" (isConstant b col)
      expectEq s!"blur {r} keeps the channel sums of {repr col}" (channelSums b) (channelSums k)
  -- a translucent constant image stays constant (same pixels everywhere)
  let tr := blur (Image.filled 23 17 ⟨200, 100, 50, 77⟩) 3
  expect "blur keeps a translucent constant image constant" (isConstant tr (tr.get 0 0))
  -- transparent pixels do not darken: an opaque red square on transparent black stays pure red
  let sq := Image.generate 20 20 fun x y => if x ≥ 5 && x < 15 && y ≥ 5 && y < 15 then ⟨255, 0, 0, 255⟩ else ⟨0, 0, 0, 0⟩
  let bs := blur sq 4
  expect "blur premultiplies (no dark fringe)" ((List.range 20).all fun y => (List.range 20).all fun x =>
    let c := bs.get x y; c.a == 0 || (c.r == 255 && c.g == 0 && c.b == 0))
  expect "blur spreads alpha" ((bs.get 4 10).a > 0 && (bs.get 4 10).a < 255)
  expectEq "blur radius 0 = id" (blur base 0) base
  -- blur in row chunks
  let h := blurHRows 3 base (Image.blank 37 23) 0 23
  let v := blurVRows 3 h (blurVRows 3 h (Image.blank 37 23) 0 10) 10 23
  expectEq "blur in row chunks" v (blur base 3)
  expectEq "sharpen amount 0 = id" (sharpen base 0 2) base
  expectEq "sharpen of a constant image = id" (sharpen (Image.filled 9 9 ⟨9, 99, 199, 255⟩) 3 2) (Image.filled 9 9 ⟨9, 99, 199, 255⟩)
  expectEq "convolve identity = id" (convolve Kernel3.identity base) base
  expect "edges of a constant image are black" (isConstant (edgeDetect (Image.filled 8 5 ⟨70, 80, 90, 200⟩)) ⟨0, 0, 0, 200⟩)
  expectEq "emboss keeps alpha" ((emboss base).data.toList.toArray.zipIdx.filter (·.2 % 4 == 3) |>.map (·.1))
    (base.data.toList.toArray.zipIdx.filter (·.2 % 4 == 3) |>.map (·.1))
  -- convolution rows
  let half := convolveRows Kernel3.emboss base (Image.blank 37 23) 0 11
  expectEq "convolve in row chunks" (convolveRows Kernel3.emboss base half 11 23) (emboss base)
  let half := edgeDetectRows base (Image.blank 37 23) 0 5
  expectEq "edge detect in row chunks" (edgeDetectRows base half 5 23) (edgeDetect base)
  let sb := blur base.copy 2
  let half := sharpenRows 1.5 4 base sb (Image.blank 37 23) 0 12
  expectEq "sharpen in row chunks" (sharpenRows 1.5 4 base sb half 12 23) (sharpen base 1.5 2 4)

def testAdjust : T Unit := do
  expect "identity is identity" Adjust.identity.isIdentity
  expectEq "identity changes nothing" (Adjust.apply Adjust.identity base) base
  expectEq "identity applyRows changes nothing" (Adjust.applyRows Adjust.identity base (Image.blank 37 23) 0 23) base
  expect "endpoint-only curve is identity" ({ curve := #[(0, 0), (255, 255)] : Adjust }).isIdentity
  expect "hue 360 is identity" ({ hue := 360 } : Adjust).isIdentity
  expect "brightness is not identity" !({ brightness := 1 } : Adjust).isIdentity
  let inv : Adjust := { invert := true }
  expectEq "invert twice = id" (Adjust.apply inv (Adjust.apply inv base)) base
  -- monotone curve: the table never decreases
  let lut := ({ curve := #[(30, 90), (100, 95), (180, 240)] } : Adjust).lut
  expect "curve table is monotone" ((List.range 255).all fun i => lut.get! i ≤ lut.get! (i + 1))
  expectEq "curve passes through its points" (lut.get! 30, lut.get! 100, lut.get! 180) (90, 95, 240)
  -- saturation keeps gray pixels gray, alpha untouched everywhere
  let g := Adjust.apply { saturation := 80, hue := 33 } (Image.generate 16 1 fun x _ => ⟨(x * 16).toUInt8, (x * 16).toUInt8, (x * 16).toUInt8, 200⟩)
  expect "saturation and hue keep grays" ((List.range 16).all fun x => g.get x 0 == ⟨(x * 16).toUInt8, (x * 16).toUInt8, (x * 16).toUInt8, 200⟩)
  for (n, a) in adjustments do
    let out := Adjust.apply a base
    expect s!"{n} keeps alpha" ((List.range (37 * 23)).all fun i => out.data.get! (4 * i + 3) == base.data.get! (4 * i + 3))
    -- rows: two chunks into a separate destination, and in place
    let two := Adjust.applyRows a base (Adjust.applyRows a base (Image.blank 37 23) 0 9) 9 23
    expectEq s!"{n} in row chunks" two out
  -- in place: the buffer is reused when the image is unique
  let img ← fresh (noise 64 48 99)
  let addr ← addrNow img
  let img := Adjust.applyRows { brightness := 20, saturation := 10 } img img 0 20
  let img := Adjust.applyRows { brightness := 20, saturation := 10 } img img 20 48
  expect "applyRows in place keeps the buffer" (addrOf img.data == addr)
  expectEq "applyRows in place = apply" img (Adjust.apply { brightness := 20, saturation := 10 } (noise 64 48 99))
  -- histogram
  let hs := histogram base
  expectEq "histogram has 1024 bins" hs.size 1024
  for (ch, i) in [("red", 0), ("green", 1), ("blue", 2), ("luminance", 3)] do
    expectEq s!"{ch} histogram sums to the pixel count" ((hs.extract (256 * i) (256 * i + 256)).foldl (· + ·) 0) (37 * 23)
  let hk := histogram (Image.filled 5 4 ⟨10, 20, 30, 255⟩)
  expectEq "histogram of a constant image" (hk[10]!, hk[256 + 20]!, hk[512 + 30]!, hk[768 + 19]!) (20, 20, 20, 20)
  let chunked := (histogramRows base 9 23 (histogramRows base 0 9)).map (·.toNat)
  expectEq "histogram in row chunks" chunked hs
  expectEq "histogram table in row chunks" ((HistTable.empty.addRows base 0 5 |>.addRows base 5 23).counts) hs
  expectEq "histogram of every row" (histogramEvery base 1) hs
  -- every 4th row: the histogram of the image made of rows 0, 4, 8, …
  let sampled := Image.generate base.width ((base.height + 3) / 4) fun x y => base.get x (4 * y)
  expectEq "histogram of every 4th row" (histogramEvery base 4) (histogram sampled)

def testComposite : T Unit := do
  for m in Blend.all do
    expectEq s!"composite {m.name} opacity 0 = bottom" (composite base top 0 m) base
    let half := compositeRows base top 70 m 0 10
    expectEq s!"composite {m.name} in row chunks" (compositeRows half top 70 m 10 23) (composite base top 70 m)
    expectEq s!"composite {m.name} of a transparent top = bottom" (composite base (Image.blank 37 23) 100 m) base
  expectEq "normal composite of an opaque top = top" (composite base opaqueBase 100 .normal) opaqueBase
  expectEq "different sizes leave the bottom" (composite base (Image.blank 3 3) 100 .normal) base
  let img ← fresh (noise 40 30 3)
  let addr ← addrNow img
  let img := composite img (noise 40 30 4) 50 .screen
  expect "composite works in place" (addrOf img.data == addr)

def testPaint : T Unit := do
  let img := base
  for (cx, cy, r, hard, erase) in [(12.3, 9.7, 6.0, 0.3, false), (0.0, 0.0, 4.0, 1.0, false), (36.5, 22.9, 9.0, 0.0, true),
      (20.0, 11.0, 0.4, 0.5, false), (18.0, -3.0, 5.0, 0.5, false)] do
    let (out, rect) := dab img cx cy r hard 0.9 ⟨250, 10, 20, 255⟩ erase
    let changed := (List.range 23).all fun y => (List.range 37).all fun x =>
      rect.contains x y || out.get x y == img.get x y
    expect s!"dab at ({cx}, {cy}) r {r} changes only inside its rect" changed
    expect s!"dab at ({cx}, {cy}) changes something" (out != img)
    if erase then
      expect s!"erase keeps colour, lowers alpha" ((List.range 23).all fun y => (List.range 37).all fun x =>
        let a := img.get x y; let b := out.get x y; a.r == b.r && a.g == b.g && a.b == b.b && b.a ≤ a.a)
  let (out, rect) := dab img 100 100 5 0.5 1 ⟨0, 0, 0, 255⟩
  expect "dab outside the image" (rect.isEmpty && out == img)
  let (out, rect) := dab (Image.filled 21 21 ⟨0, 0, 0, 255⟩) 10.5 10.5 4 1 1 ⟨255, 255, 255, 255⟩
  expectEq "hard dab rect" rect ⟨6, 6, 9, 9⟩
  expectEq "hard dab centre is the colour" (out.get 10 10) ⟨255, 255, 255, 255⟩
  expectEq "hard dab outside the radius is untouched" (out.get 10 15) ⟨0, 0, 0, 255⟩
  let brush : Brush := { radius := 3, hardness := 0.5, opacity := 0.7, color := ⟨0, 0, 255, 255⟩ }
  let (s, sr) := stroke img 2 3 33 19 brush
  expect "stroke changes only inside its rect" ((List.range 23).all fun y => (List.range 37).all fun x =>
    sr.contains x y || s.get x y == img.get x y)
  expect "stroke rect covers both ends" (sr.contains 2 3 && sr.contains 33 19)
  let (s2, _) := stroke img 5 5 5 5 brush (skipFirst := true)
  expectEq "a zero-length stroke that skips its first dab paints nothing" s2 img
  let img ← fresh (noise 30 20 8)
  let addr ← addrNow img
  let (img, _) := dab img 10 10 5 0.5 1 ⟨1, 2, 3, 255⟩
  expect "dab works in place" (addrOf img.data == addr)

/-- PNG files made with Python's `zlib` (level 9; rows filtered with filter types 0..4 in turn) and
the RGBA bytes a decoder must produce (empty: computed by `pix6` below), from
`tests/editor-ref/mkpng.py`. The first and last use dynamic Huffman blocks; the last is split over
three `IDAT` chunks after a `tEXt` chunk. -/
def pngFixtures : Array (String × Nat × Nat × String × String) := #[
  ("rgba16x12", 16, 12,
    "89504e470d0a1a0a0000000d49484452000000100000000c08060000006be73d81000001344944415478daadd0214c026118" ++
    "c6f10738e0ee03c570c5c2d82c143746b110b0502897498437bb8bc49bc5e20649223422342234de068de2068d080d829b3e" ++
    "c7beaa5366f8d567cffe00f079031c4bc0be02eceac02600d66d6019028b0898f580e910184f80d11c18ac80fe16e81e8097" ++
    "04fc782071ba549203809fa024a5c8a13465284b2e7964284779baa26b2a20853222d7243f5c93b21c2b6d65acace55ade99" ++
    "737e003e001f700f70fe48d840d2c792987d450abbbaf89b406ed76d292e43b95b44529ef5e47e3a94ea78220fa3b9d4062b" ++
    "79ec6fa5d13d4893113b71c4cce952ff10b11547fc5d30d7182b67e5bf8bc807e003f001f800de0f940dd41c4beaef2b5adc" ++
    "d5b5bc09b4ba6e6b6d196a63116930eb696b3a54194ff46934d7ce60a5cffdadbe760ffac688ef71c4dce9525f48efaef261" ++
    "4c6eae0000000049454e44ae426082",
    "000000ff100000f7200000ef300000e7400000df500000d7600000cf700000c7800000bf900000b7a00000afb00000a7c000" ++
    "009fd0000097e000008ff0000087001400ff101401f7201402ef301403e7401404df501405d7601406cf701407c7801408bf" ++
    "901409b7a0140aafb0140ba7c0140c9fd0140d97e0140e8ff0140f87002800ff102802f7202804ef302806e7402808df5028" ++
    "0ad760280ccf70280ec7802810bf902812b7a02814afb02816a7c028189fd0281a97e0281c8ff0281e87003c00ff103c03f7" ++
    "203c06ef303c09e7403c0cdf503c0fd7603c12cf703c15c7803c18bf903c1bb7a03c1eafb03c21a7c03c249fd03c2797e03c" ++
    "2a8ff03c2d87005000ff105004f7205008ef30500ce7405010df505014d7605018cf70501cc7805020bf905024b7a05028af" ++
    "b0502ca7c050309fd0503497e050388ff0503c87006400ff106405f720640aef30640fe7406414df506419d760641ecf7064" ++
    "23c7806428bf90642db7a06432afb06437a7c0643c9fd0644197e064468ff0644b87007800ff107806f720780cef307812e7" ++
    "407818df50781ed7607824cf70782ac7807830bf907836b7a0783cafb07842a7c078489fd0784e97e078548ff0785a87008c" ++
    "00ff108c07f7208c0eef308c15e7408c1cdf508c23d7608c2acf708c31c7808c38bf908c3fb7a08c46afb08c4da7c08c549f" ++
    "d08c5b97e08c628ff08c698700a000ff10a008f720a010ef30a018e740a020df50a028d760a030cf70a038c780a040bf90a0" ++
    "48b7a0a050afb0a058a7c0a0609fd0a06897e0a0708ff0a0788700b400ff10b409f720b412ef30b41be740b424df50b42dd7" ++
    "60b436cf70b43fc780b448bf90b451b7a0b45aafb0b463a7c0b46c9fd0b47597e0b47e8ff0b4878700c800ff10c80af720c8" ++
    "14ef30c81ee740c828df50c832d760c83ccf70c846c780c850bf90c85ab7a0c864afb0c86ea7c0c8789fd0c88297e0c88c8f" ++
    "f0c8968700dc00ff10dc0bf720dc16ef30dc21e740dc2cdf50dc37d760dc42cf70dc4dc780dc58bf90dc63b7a0dc6eafb0dc" ++
    "79a7c0dc849fd0dc8f97e0dc9a8ff0dca587"),
  ("rgb9x7trns", 9, 7,
    "89504e470d0a1a0a0000000d494844520000000900000007080200000055f9f0370000000674524e53000a0014001ec53629" ++
    "ff000000a94944415478da63e01291936160b660600b61e004b27b18f85730081d611005b21919545881724074e983709ac0" ++
    "67083be903fb3581ff4c403920024a78997c85b08112bb4c407a98193cb8feec12d08bf8ce27c402443dbb58e6453043d82c" ++
    "5c2bf8856a7e3230b0323030cf6a616caa01318048abe52b03c31649992d32165be48196176c51edd9a2b1628b3690fd608b" ++
    "2123c30d903bdfd9fcf53ac20971489dcdc75d4744810c00fdb12ed0850fe35b0000000049454e44ae426082",
    "0a141e001c0003ff380006ff540009ff0a141e008c000fffa80012ffc40015ff0a141e00002405ff1c2408ff38240bff0a14" ++
    "1e00702411ff8c2414ffa82417ff0a141e00e0241dff00480aff1c480dff0a141e00544813ff704816ff8c4819ff0a141e00" ++
    "c4481fffe04822ff006c0fff0a141e00386c15ff546c18ff706c1bff0a141e00a86c21ffc46c24ffe06c27ff0a141e001c90" ++
    "17ff38901aff54901dff0a141e008c9023ffa89026ffc49029ff0a141e0000b419ff1cb41cff38b41fff0a141e0070b425ff" ++
    "8cb428ffa8b42bff0a141e00e0b431ff00d81eff1cd821ff0a141e0054d827ff70d82aff8cd82dff0a141e00c4d833ffe0d8" ++
    "36ff"),
  ("gray11x5trns", 11, 5,
    "89504e470d0a1a0a0000000d494844520000000b000000050800000000b6cd498a0000000274524e53004d7efef015000000" ++
    "384944415478da63f015d7738d29ee5ab8e3fc33464d152e712860d294f9a60905cc410a566ba3141416282828b0688a8bcf" ++
    "4939a509520300d68d0e749227fe4e0000000049454e44ae426082",
    "4d4d4d00171717ff2e2e2eff454545ff5c5c5cff737373ff8a8a8affa1a1a1ffb8b8b8ffcfcfcfffe6e6e6ff292929ff4d4d" ++
    "4d00575757ff6e6e6eff858585ff9c9c9cffb3b3b3ffcacacaffe1e1e1fff8f8f8ff0f0f0fff525252ff696969ff4d4d4d00" ++
    "979797ffaeaeaeffc5c5c5ffdcdcdcfff3f3f3ff0a0a0aff212121ff383838ff7b7b7bff929292ffa9a9a9ff4d4d4d00d7d7" ++
    "d7ffeeeeeeff050505ff1c1c1cff333333ff4a4a4aff616161ffa4a4a4ffbbbbbbffd2d2d2ffe9e9e9ff4d4d4d00171717ff" ++
    "2e2e2eff454545ff5c5c5cff737373ff8a8a8aff"),
  ("pal6x5", 6, 5,
    "89504e470d0a1a0a0000000d494844520000000600000005080300000051866dd400000015504c5445ff000000ff000000ff" ++
    "112233c86432010203fafafa6bb40cc80000000374524e530080c8544a1617000000274944415478da636060666362656464" ++
    "64fec3ccfc8709c860fcc5c8ccc4f41f0859187f3103f9005b320624d1345c280000000049454e44ae426082",
    "ff000000112233fffafafaff0000ffc8010203ff00ff008000ff0080c86432ffff000000112233fffafafaff0000ffc80000" ++
    "ffc8010203ff00ff0080c86432ffff000000112233ff112233fffafafaff0000ffc8010203ff00ff0080c86432ffc86432ff" ++
    "ff000000112233fffafafaff0000ffc8010203ff"),
  ("grayalpha7x3", 7, 3,
    "89504e470d0a1a0a0000000d4948445200000007000000030804000000f5cadd4e000000234944415478da6360f8affad0eb" ++
    "70fed229ed3b33ef793332fe507d84804c8c3f912100e6a31589cac0835e0000000049454e44ae426082",
    "000000ff252525e14a4a4ac36f6f6fa594949487b9b9b969dedede4b010101f8262626da4b4b4bbc7070709e95959580baba" ++
    "ba62dfdfdf44020202f1272727d34c4c4cb57171719796969679bbbbbb5be0e0e03d"),
  ("rgba64x40split", 64, 40,
    "89504e470d0a1a0a0000000d49484452000000400000002808060000004ecefce90000001274455874436f6d6d656e740073" ++
    "706c697420494441543e7126b00000006449444154789ced987978a3d755c6bf7b3fc9b2246bb12dd9966c4b5ee445b6252f" ++
    "f2becebeef9af578f67ddfb75202210442589281304918122684192693501118528690049aa684a134a50da5292594a42943" ++
    "084d09c330e3ba9f4edf5877a6f12dfc0d24f3f8391efca0a50000000149444154cf23e3a2c900000ecb494441549bf35c9d" ++
    "3fe2e4f9f9a7d7300c838421c86648721a26f9858d42c24e319147edc24153643e2f954ede2a5dfc29e9e65366015f343dfc" ++
    "8ae9e5b74c1f1b363f55db0a6986ad8876d98ae9943d407f620fd23bf6122ab497d294bc323e9417e2737961fe465e39fb1d" ++
    "153cd751c9f73a22fc3947948dfc2a9a9a5f4df7e6d7d095fc5af23b63b4c65947e79cf5f481b381a6b81af9575d717ec7d5" ++
    "c47dae663ee56ee177dd099ee14ef26fbb5bd92868a34d05edf44a4107c50b5274cad349639e2edaeae9a6af787a688ab797" ++
    "ffc0dbc7316f3fff867780fdbe41bedf37c436df30ff8c6f848530057e016c98f8b1231dc2349c4837760fd227ccf385c862" ++
    "ec416429de43c872ec95c8a83047ab91b5d8eb900d788f239bb12790adb86f47a6b077217bf0de871cc03e841cc1fd54e474" ++
    "ec3391b3f13e17391ffb42e462dc2f45a6b1af40aec2fb1ae428f675c80db8df84dc827d1b7207de7721f760df873c80fb43" ++
    "c823d88f214fe0fd53c84f63bf0b29f10b308469622c0c1b9fb4dd94793221247e13d2c082ffa3a5cdb023f3b03b90f9d296" ++
    "76225dd8ddc802bc7b905eec3ee42969cb14228bb0172303780f224bb03f822cc37d0819c65e8e7c0cef95c808f628f209dc" ++
    "57236bb0d722cfe1bd0e598fbd01f914eee3c826eccf205bf09e4066b0b7229fc57d3bb203fb256427debb909fc5de83bc8c" ++
    "fb3ee4f3d807902fe07d08f912f6910fff7d277e238634c4ad1f31f6a37f9ed83fdeef86dd67a73c9f8d9c3e07797d7914f4" ++
    "0b8af80d8afb4deaf64b9a59e8e1958505bcabd0c73f55e8e5d3454ece14e5f3952237ff73918bedc541aa2f0ed0dce252da" ++
    "5f5c42a70385f452c04fef068aa92450443383957c3c58c1178351fec760848325215e5452c6f79794f35f9484d95e5a47b3" ++
    "4a63747f6903bd565a4fc1b26a5a5f564517cb6ae9bfca6a686628c10f8700be502b0f87927c3a1ce7f7c38d3c37dcccbf1b" ++
    "6e627b79176d2fefa42be53d942cefa6d315ed94ad68a35d1529fabb8a0e9a5939c49fad1ce478e508ff56e53007237dfc40" ++
    "a4979d9101fef9483f8bbca2bc0fff0a000916202800410b101480a005080a40d003080a40d0020405206801820210b40041" ++
    "01087a004101085a80a000042d4050008216202800410f202800410b101480a005080a40d002040520e80104052068018202" ++
    "10b4004101085a80a000043d80a000042d4050008216202800410b101480a007101480a005080a40d0020405206801820210" ++
    "f400820210b4004101085a80a000042d4050dc82e02d387cf2d2b47bed5f1552a6a534d326806193f6b45de6a5f3a423ed90" ++
    "f9e97cf9c1a8537e3fe392e319b7fc41a6405a198fcc66bc92333e69644e49e7f942dc17e1be18f701dc07715f82fb47705f" ++
    "86fb10eec3b82fc7fd63b8afc47d04f751dc3f81fb6adcd7e0be16f7e7705f87fb7adc37e0fe29dcc771df84fb6770df82fb" ++
    "04ee33b86fc5fdb3b86fc77d07ee2fe1be13f7cfe1be1bf73db8bf8cfb3edc3f8ffb01dcbf80fb21dcbf84fb11dc2b08b202" ++
    "0552486dff78bf1bae888bdd11377b23f95c1c717238eae5daa88f93d1021e887a785e95a4d12a93f65719f4b35582ce54e7" ++
    "d1a56a07bd566da3f7aaede4aa0973734d392faa29e32335213e531be1cfd746f9fdda0a2eafade479b122fa74ac9832313f" ++
    "7d3b5648e1ba124ad795d2037501fa625d905cf54d3cbfbe991fa86fe4d7ebe31c6e48f2968656ce34b4f0784382e735d6d0" ++
    "6f36d6d2fb8d5534bdb19acec4ebe95abc8116c563f44cbc8e5c4dfdbca769805f6beae554531f9f691e66b37984f7370ff2" ++
    "379b87785e4b07fd694b8a922d6df43b2ded144e74d343891ef2263ae997125d24dcd56ece99202b13742813646582374673" ++
    "26c8ca041dca04599960e9f99c09b2324187324156267863346782ac4cd0a14c909509969ecf99202b137428136465823746" ++
    "7326c8ca041dca04599960e9f99c09b2324187324156267863346782ac4cd0a14c907513c4df00d381c1df4973fcbf31a78f" ++
    "e7bbe9083aeece99a054269855262895096633391394ca04b3ca04a532416f3a67825299605699a0542698cde44c502a13cc" ++
    "2a1394ca04bde99c094a658259658252996036933341a94c30ab4c502a13f4a67326289509668de790ddd8732698cde44c50" ++
    "2a13cc2a1394ba095a9a397d3276c397f0b13fe1e5e28487cb12051c4dbab931e9e254d2c95392f9bcb8d5411b5bf3e848ab" ++
    "9d7ea1d54667db4cbadc26e9f53641ffde6690af3dca6ded114eb757f2c9f60a3edb51ce7fd911e66b1d21aeea28e3c5a952" ++
    "ba3b5542975241fa975480a29dc5b4bab3881eea2ca4bfe9f493afab95977425f9a1ae04bfd1d5c2d1ee66ded9ddc497bae3" ++
    "f8cfd8c88b7b1ae8891e80afa78ee6f4c4e86c6f2dddecada1746f353ddb5b45bebe113ed837ccaff70d716fdf209fed1fe0" ++
    "fcfe7e3ed2dfc7ffd4dfcb8b077ae8cf07ba2935d0454f0d74527430458f0e7650f1603b9d1a6c23e16ff32b1314ca048532" ++
    "41a14c50281314ca04853241a14cf02d65824299a050262894090a65824299a05026289409562b1314ca04853241a14c5028" ++
    "1314ca04853241a14cf02d65824299a050262894090a65824299a0502628ee98e004045d952e7c1d9680a005081a80a00908" ++
    "4a40d002040d40d0c4d76109085a80a001089a80a004042d40d00004afe1ebb004042d40d000044d40500282162068008226" ++
    "be0e4b40d002040d40d0040425206801820620588cafc31210b40041031034014109085ac605ec8db88f636fc2fe0cf616bc" ++
    "27b067b0c30401c16bf83a2c01410b1034004113109480a005081a80a089afc31210b40041031034014109085a80a0617cc4" ++
    "0485664e9f8cdd080c06283818a4b2c112aa1c2ca5d8909f124385d43b84afb243c5b47cb882b70d0370c311fe95e1289f1b" ++
    "29e3174742fcc64898af8f9473608a8dbaa6d869f5943cba6b8a83ce4d35e84b5305dd9c2aa96eaa49cba715f0cf4df3f0e5" ++
    "695efeee341fc7a6e7f3bae94e7e74ba8bbf36ddcd81199db46246173d3aa39bde9cd143b1996db46f663b5d9ed941f69929" ++
    "5a3e6b90cfcf1ae29bb38679e1ac113e37bb97add97dbc7a763f3f377b80037362746c4e1dbd31a79e86e634d0b9b955e499" ++
    "5b4d27e7d6d077e6d6d2f2792dfc857909ee9d97e4cfcc6be5d8fc467e7c7e9ccbe637f1e9f9cd2c822341ad131cd73a41b7" ++
    "d6098e6b9de07b5a2738ae75826ead131cd73ac166ad131cd73a41b7d6098e6b9de07b5a2738ae75826ead131cbfd3094eea" ++
    "040b62055a2768689d60bed6091a5a277853eb040dad13ccd73a4143eb04cbb44ed0b8dd095e4036e27e7227684c9860f276" ++
    "277853eb040d6582b73ac17cad13347eac133c3fb93313c6a41ff1c1e8e45d7fffff7d6f84e687383cbf8c2be79773cdfc30" ++
    "c7175472c7820a1e5a10e5790b22bc666121ed5ee8a7bb1616d3af2d2ca28b8b82f4f2a200bdb9a894bebfa884428b9ddcbf" ++
    "18605bece67b16bbf8e2120f7f7549015b4b7cdcb4c4cb6b960afac5a506bdb8d4a4ff582a29becc4e9b97d9e8f1650efafb" ++
    "6579144af731b48e1f4f0ff0dbe97e8e2f1fe2c3cb07f9c5e523ec5a3ecc6b56b4d3d32bdac85a91a2652b3ae8e2ca2e922b" ++
    "3b69ddca1e7a7e65378556c5f9275635f29bab9a79daaa26beb83ac145ab5bf8aed5adfcafab93bc664d35fdd59a2a1a5a53" ++
    "4b7fb8a686e254474f528c2aa981ce503d89f0a2307ff89bf8512768d73ac1eba3933b41bbd6095ec7d7e18f768276ad13bc" ++
    "3e3ab913b46b9d6017be0e7fb413b46b9de0f5d1c99da05deb04afe3ebf0473b41bbd6095e1f9ddc09daef7482934cd0d7e2" ++
    "bb3b6782f843286d80e018209805045999a095c999a00908da00c13140300b08b232412b9d33411310b401826380601610c4" ++
    "9fcc0913b43239133401411b2038060866014156265899ce99a00908da00c13140300b08b232412b933341d368c67b0bde3f" ++
    "83f724de732668a573266802823640700c10cc0282ac4cd0cae44cd004046d80e018209805045937c1ffa943fb78ef468422" ++
    "1ca528d750053750252747c3dc335aced346f1557634c4ebd796d081b5a574cfda003db23648997545f4eaba627a7b9d9f78" ++
    "5d2145d67b7964bd8f37af2fe0fbd67b38b3c1c55fdfe066b9219f5b373879fdc63c7a70a3835ede68a31b1bed94dc2469c7" ++
    "26939edc64d0b736098a6c1ee60d9b47f8c9cd837c75f31027b7f4f3892d03fcf2965ef66de9e3f55bbbe9f7b7f690dcda49" ++
    "abb67651665b0739b6a568f3b636fab36ded14d99ee49fdedeca6f6f6fe1d9db139cd9d1c4a53b9af99e1d8dfcbd1d715ebf" ++
    "b39ebebcb381a6ed8cd11fefaca3e4ae1abab0ab966a7655d1d95dd524a2eba25a27c85a27c85a27c85a27c85a27c85a27c8" ++
    "5a27c85a2738a27582ac7582ac7582ac7582ac7582ac7582ac7582fc639de028cc0863c738304e8c1be3c1f83085e785598c" ++
    "09624a31214c39a61213c554e333b5983a4c03268e69c62430ad98767c2685e9c2f460fa30039821cc08e673f8cce7315fc0" ++
    "bc8ab982f922e64b982f63be82cfbc8ef91ae6eb986f60be897913f32dcc5bf8ccb731dfc15cc5bc8b790ff35dccf7301fe0" ++
    "33d730d73137306398718c85e1f36661aa3031b913945a2728d3933b4179bb137c10e9973233b913941326f830b274c20465" ++
    "7a722728b54ef0edcce44e50deee04732628274cf069eccd13262801c10f4df056272833933b41a97582323db91394773ac1" ++
    "499d602d801003181a0084168021b5bb810677d7d3ecdd75b47c778cb6ec69e6a37b9af8be3d717e6c4f235fdadbca7fbd37" ++
    "c957f726d8b6b7856bf7a568c6be0edab1af9d7e795f1b5ddadf43ffb0bf9b1cfbbba8737f276d3930c0bf7ea09f5f3dd0c7" ++
    "3f38d0cba98323bcf7e0305f3838c4ef1c1ce4da43266d3d24e9c22141ff76c8a0d46107fde4e13c7af5b09d02876db4e588" ++
    "9bffe8888b1d479cbcf6483e5f3aeae382a35ede71d4c3af1c2de0da63c574efb122ba7aac90161cf3d3a5e3a55471bc84ee" ++
    "3b1ea4ff3c1ea02d27caf96f4f8479f68910bf70a28c5327a3fc7b2723dc70b292cf9dac6011db1bd33ac131ad13746a9de0" ++
    "98d6093ab54e704ceb049d5a2738a6758257b44e704ceb049d5a2738a675824ead131cd33a41a7d6098edde9042799606020" ++
    "a07582ac75820ead13e4db9de083d8fdd2a175823cd1093e8c3d67820ead1364ad13bcaa7582ac75828e894ef069eccd139d" ++
    "2003821210bcd5093ab44e90b54ed0a17582fcbfdb09f6fc1feb047f08813312d2d234c4a80000000049454e44ae426082",
    "")]

/-- The last fixture's pixels. -/
def pix6 : Image := Image.generate 64 40 fun x y =>
  ⟨((x * x + y) % 256).toUInt8, ((y * 3 + x / 4) % 256).toUInt8, ((x ^^^ y) % 256).toUInt8,
    if (x / 8 + y / 8) % 2 == 1 then 255 else 90⟩

/-- `img` encoded by `Png.Encoder`, `k` rows per step. -/
def encodeInSteps (img : Image) (level k : Nat) : ByteArray := Id.run do
  let mut e := Png.Encoder.start img level
  for _ in [0:(img.height + k - 1) / max 1 k] do e := e.step k
  return e.finish

def testPng : T Unit := do
  let imgs := [Image.new 1 1 1 2 3 4, Image.blank 1 1, noise 1 9 3, noise 7 1 4, noise 3 5 5, base, noise 61 13 6,
    gradient 100 37, checker 64 64 8, noise 301 7 9 (alpha := false), Image.new 2 2 0 0 0 0]
  for img in imgs do
    for level in [0, 1, 4, 9] do
      let bytes := Png.encode img level
      match Png.decode bytes with
      | .ok back => expectEq s!"png round trip {img.width}×{img.height} level {level}" back img
      | .error e => expect s!"png round trip {img.width}×{img.height} level {level}" false e
  -- a large compressible image compresses, a stored one does not
  let g := gradient 256 256
  let stored := Png.encode g 0
  let packed := Png.encode g 6
  expect "stored PNG holds the raw rows" (stored.size > 256 * (1 + 4 * 256))
  expect "level 6 compresses a gradient at least 4:1" (packed.size * 4 < stored.size)
  expectEq "png round trip of a 256×256 gradient" (Png.decode packed |>.toOption) (some g)
  -- matches at every distance up to the 32 KB window: a 100-pixel-wide image repeating every 1 to
  -- 81 rows (401..32481 bytes back), with the extra-bit counts of all distance codes
  for period in [1, 3, 7, 20, 41, 60, 81] do
    let tile := noise 100 period (period.toUInt32 + 40)
    let img := Image.generate 100 170 fun x y => tile.get x (y % period)
    for level in [1, 9] do
      expectEq s!"png round trip, rows repeating every {period} (level {level})" (Png.decode (Png.encode img level) |>.toOption) (some img)
  -- stored blocks over the 65535-byte limit
  let big := noise 200 100 12
  expectEq "png round trip with several stored blocks" (Png.decode (Png.encode big 0) |>.toOption) (some big)
  -- the incremental encoder: any split into steps decodes to the same pixels, one step is `encode`
  for img in [noise 7 9 21, gradient 61 37, checker 64 48 8, big] do
    let s := s!"{img.width}×{img.height}"
    for level in [0, 1, 9] do
      for k in [1, 2, 5] do
        expectEq s!"png in steps of {k} rows ({s}, level {level})" (Png.decode (encodeInSteps img level k) |>.toOption)
          (some img)
      expect s!"png in one step = encode ({s}, level {level})"
        ((encodeInSteps img level img.height).data == (Png.encode img level).data)
  -- `finish` encodes the rows not yet stepped
  let g37 := gradient 61 37
  expectEq "png finish after some steps" (Png.decode ((Png.Encoder.start g37 1).step 10 |>.step 4).finish |>.toOption)
    (some g37)
  -- matches reach back into earlier blocks: rows repeating every 20 rows, encoded 5 rows per step
  let tile := noise 100 20 77
  let rep := Image.generate 100 170 fun x y => tile.get x (y % 20)
  let stepped := encodeInSteps rep 1 5
  expectEq "png in steps with matches across blocks" (Png.decode stepped |>.toOption) (some rep)
  expect "png in steps compresses repeats across blocks" (stepped.size * 4 < (Png.encode rep 0).size)
  -- files written by zlib
  for (name, w, h, file, want) in pngFixtures do
    match Png.decode (hexBytes file) with
    | .ok img =>
      let want := if want.isEmpty then pix6 else ⟨w, h, hexBytes want⟩
      expectEq s!"decode {name}" img want
    | .error e => expect s!"decode {name}" false e
  -- errors
  let ok := Png.encode (noise 4 4 1) 1
  let bad (name : String) (b : ByteArray) (msg : String) : T Unit :=
    match Png.decode b with
    | .ok _ => expect s!"decode rejects {name}" false "decoded"
    | .error e => expect s!"decode rejects {name}" (e.startsWith msg) e
  bad "a non-PNG" "GIF89a".toUTF8 "not a PNG"
  bad "a truncated file" (ok.extract 0 40) "truncated"
  bad "a bad CRC" (ok.set! 20 (ok.get! 20 ^^^ 1)) "bad CRC in IHDR"
  -- a 16-bit and an interlaced header (with the CRC fixed up)
  let patch (b : ByteArray) (i : Nat) (v : UInt8) : ByteArray :=
    let b := b.set! i v
    Png.setU32BE b 29 (Png.crc32 b 12 29)
  bad "16-bit samples" (patch ok 24 16) "unsupported bit depth 16"
  bad "interlacing" (patch ok 28 1) "interlaced"
  bad "colour type 5" (patch ok 25 5) "unsupported colour type 5"
  -- corrupt compressed data: flip a byte inside the IDAT data and fix the chunk CRC
  let idatLen := Png.readU32BE ok 33
  let corrupt := ok.set! 45 (ok.get! 45 ^^^ 0x55)
  let corrupt := Png.setU32BE corrupt (41 + idatLen) (Png.crc32 corrupt 37 (41 + idatLen))
  match Png.decode corrupt with
  | .ok img => expect "corrupt deflate data is detected" (img != noise 4 4 1) "decoded to the original"
  | .error _ => expect "corrupt deflate data is detected" true
  -- random corruption of the compressed data (chunk CRC fixed up so that inflate sees it), and
  -- every truncation: the decoder returns an error or an image of the declared size, never crashes
  for level in [0, 1, 9] do
    let good := Png.encode (gradient 16 16) level
    let idatLen := Png.readU32BE good 33
    let mut rng : UInt32 := 99 + level.toUInt32
    let mut fine := 0
    for _ in [0:300] do
      rng := lcg rng
      let pos := 41 + (rng >>> 8).toNat % idatLen
      rng := lcg rng
      let b := good.set! pos (rng >>> 24).toUInt8
      let b := Png.setU32BE b (41 + idatLen) (Png.crc32 b 37 (41 + idatLen))
      match Png.decode b with
      | .ok img => if img.width == 16 && img.height == 16 && img.valid then fine := fine + 1
      | .error _ => fine := fine + 1
    expectEq s!"decoder handles 300 corrupted level {level} files" fine 300
    let truncated := (List.range good.size).all fun n => (Png.decode (good.extract 0 n)).toOption.isNone
    expect s!"decoder rejects every truncation of a level {level} file" truncated

/-! ## The editor: document, jobs, program -/

unsafe def addrIOImpl (b : @& ByteArray) : BaseIO USize := pure (ptrAddrUnsafe b)
/-- The address of a layer's pixels (to see in-place updates), read without taking a reference. -/
@[implemented_by addrIOImpl] opaque addrOfBytes (b : @& ByteArray) : BaseIO USize

def layerAddr (d : @& Doc) (i : Nat) : BaseIO USize := addrOfBytes d.layers[i]!.img.data

def testDoc : T Unit := do
  expectEq "preview size: large" (previewSize 4000 3000) (1280, 960)
  expectEq "preview size: tall" (previewSize 1000 2000) (640, 1280)
  expectEq "preview size: small" (previewSize 800 600) (800, 600)
  -- the test image is the same in bench/editor/ops.js (checked there against this value)
  expectEq "test image" (testImage 333 250).checksum 9856192619645684931
  let big := Doc.ofImage (testImage 2000 1000) "Background"
  expectEq "doc preview" (big.pw, big.ph, big.layers[0]!.prev.map (·.width)) (1280, 640, some 1280)
  let small := Doc.ofImage (testImage 300 200) "Background"
  expect "small image is its own preview" (small.layers[0]!.prev.isNone)
  -- the composite of one opaque layer is its preview
  expectEq "composite of one layer" small.composite.checksum (small.layers[0]!.img.checksum)
  -- painting: the history keeps the first document, so the first dab copies the layer; the
  -- following dabs paint the copy in place
  let d0 := Doc.ofImage (testImage 640 480) "Background"
  let a0 ← layerAddr d0 0
  let brush : Brush := { radius := 10, hardness := 1, color := ⟨255, 0, 0, 255⟩ }
  let (d1, r1) := d0.paint 1 (100, 100) (200, 100) brush
  let a1 ← layerAddr d1 0
  let (d2, _) := d1.paint 1 (200, 100) (300, 150) brush
  let a2 ← layerAddr d2 0
  let (d3, _) := d2.paint 1 (300, 150) (310, 300) brush
  let a3 ← layerAddr d3 0
  expect "first dab copies (history holds the old pixels)" (a1 != a0)
  expect "later dabs paint in place" (a2 == a1 && a3 == a1) s!"{a1} {a2} {a3}"
  expect "the old document is unchanged" (d0.layers[0]!.img.get 150 100 != ⟨255, 0, 0, 255⟩)
  expectEq "painted" (d3.layers[0]!.img.get 150 100) ⟨255, 0, 0, 255⟩
  expect "dirty rect covers the segment" (r1.x ≤ 100 && r1.x + r1.w ≥ 200 && r1.y ≤ 95 && r1.y + r1.h ≥ 105) s!"{repr r1}"
  -- painting on a large image updates the preview under the stroke, so the band composite equals
  -- a full composite
  let e0 := Doc.ofImage (testImage 2560 1280) "Background"
  let comp0 := e0.composite
  let (e1, r) := e0.paint 1 (500, 500) (900, 640) { brush with radius := 40 }
  let band := e1.compositeRect comp0 r
  expectEq "preview band = full composite" band.checksum e1.composite.checksum
  expectEq "preview = downscale of the painted layer" e1.layers[0]!.prev.get!.checksum (downscaleBox e1.layers[0]!.img 1280 640).checksum
  let p := e1.toPreviewRect r
  expect "preview rect covers the stroke" (p.x ≤ 250 && p.x + p.w ≥ 450 && p.y ≤ 250 && p.y + p.h ≥ 320) s!"{repr p}"
  -- the bottom layer is copied, not composited onto transparent: the same pixels, also for a
  -- translucent layer; a blank layer is skipped
  let trans := noise 300 200 11
  let over := composite (Image.blank 300 200) trans 100 .normal
  let worst := (List.range (300 * 200)).foldl (init := 0) fun w i =>
    if trans.data[4 * i + 3]! == 0 then w
    else (List.range 4).foldl (init := w) fun w c =>
      let a := trans.data[4 * i + c]!.toNat; let b := over.data[4 * i + c]!.toNat
      max w (if a > b then a - b else b - a)
  expect "normal over transparent = top, up to rounding (the copy is exact)" (worst ≤ 1) s!"{worst}"
  let td := Doc.ofImage trans "T"
  let comp1 := td.composite
  let (td2, _) := td.addLayer 1
  expectEq "copied bottom layer, skipped blank layer" (comp1.checksum, td2.composite.checksum) (trans.checksum, trans.checksum)
  let td3 := td.modifyLayer 1 fun l => { l with opacity := 50 }
  expectEq "a bottom layer at 50% is composited" td3.composite.checksum (composite (Image.blank 300 200) trans 50 .normal).checksum
  -- layers
  let (l2, id2) := small.addLayer 1
  let l2 := l2.modifyLayer id2 fun l => { l with name := "Top" }
  expectEq "add layer" (l2.layers.map (·.name)) #["Background", "Top"]
  expectEq "a transparent layer changes nothing" l2.composite.checksum small.composite.checksum
  expectEq "move down" ((l2.moveLayer id2 false).layers.map (·.name)) #["Top", "Background"]
  expectEq "move up at the top" ((l2.moveLayer id2 true).layers.map (·.name)) #["Background", "Top"]
  expectEq "delete" ((l2.deleteLayer id2).layers.map (·.name)) #["Background"]
  expectEq "never delete the last layer" ((small.deleteLayer 1).layers.size) 1
  let (l3, id3) := small.duplicateLayer 1
  expectEq "duplicate" (l3.layers.map (·.name), id3) (#["Background", "Background copy"], 2)
  -- geometry on every layer
  let g := l2.transform .rotCW
  expectEq "rotate: size" (g.width, g.height, g.pw, g.ph) (200, 300, 200, 300)
  expectEq "rotate: every layer" (g.layers.map (·.img.width)) #[200, 200]
  let c := big.transform (.crop ⟨100, 100, 1500, 700⟩)
  expectEq "crop" (c.width, c.height, c.pw, c.ph) (1500, 700, 1280, 597)

/-- Run a job to the end in slices of `budget` pixels. -/
partial def finish (j : Job) (budget : Nat) (n : Nat := 0) : Option JobResult × Nat :=
  match j.finished? with
  | some r => (some r, n)
  | none => if n > 100000 then (none, n) else finish (j.run budget) budget (n + 1)

def testJobs : T Unit := do
  let img := testImage 301 203
  let cases : List (Op × Image) := [
    (.adjust { Adjust.identity with brightness := 30, saturation := 40, hue := 25 }, Adjust.apply { Adjust.identity with brightness := 30, saturation := 40, hue := 25 } img),
    (.blur 4, Editor.blur img 4), (.sharpen 120 2, Editor.sharpen img 1.2 2), (.edges, edgeDetect img), (.emboss, Editor.emboss img)]
  for (op, want) in cases do
    for budget in [1, 5000, 1000000] do
      match finish (Job.layer op 7 img) budget with
      | (some (.layer 7 out _), steps) =>
        expectEq s!"{op.label} in slices of {budget}" out.checksum want.checksum
        if budget == 1 then expect s!"{op.label}: one row per slice" (steps ≥ 203) s!"{steps}"
      | _ => expect s!"{op.label} finishes" false
  -- export: the layers composited at full resolution, encoded as PNG
  let d := Doc.ofImage img "Background"
  let (d, id) := d.addLayer 1
  let (d, _) := d.paint id (10, 10) (200, 150) { radius := 12, color := ⟨0, 0, 255, 200⟩ }
  let d := d.modifyLayer id fun l => { l with opacity := 70, blend := .multiply }
  match finish (Job.export d) 20000 with
  | (some (.png bytes), _) =>
    match Png.decode bytes with
    | .ok back => expectEq "export decodes to the flattened document" back.checksum d.flatten.checksum
    | .error e => expect "export decodes" false e
  | _ => expect "export finishes" false
  expect "progress" ((Job.layer (.blur 2) 1 img).progress == 0)
  -- a layer larger than a preview: the job's last pass makes the new preview, sliced like the rest
  let big := testImage 1500 700
  for (op, budget) in [(Op.blur 3, 30000), (Op.adjust { Adjust.identity with brightness := 20 }, 1)] do
    match finish (Job.layer op 1 big (some (1280, 597))) budget with
    | (some (.layer 1 out (some prev)), _) =>
      expectEq s!"{op.label}: preview pass" prev.checksum (downscaleBox out 1280 597).checksum
    | _ => expect s!"{op.label}: a preview" false
  match finish (Job.layer (.blur 3) 1 img (some (301, 203))) 100000 with
  | (some (.layer 1 _ none), _) => expect "no preview pass for a small image" true
  | _ => expect "no preview pass for a small image" false

/-! ### The program in the DOM model -/

partial def textUnder (d : LeanUI.Testing.Dom) (h : UInt32) : String :=
  let n := d.get h
  if n.isText then n.text else String.join (n.kids.toList.map (textUnder d))

def textOf (r : LeanUI.Testing.Running) (ident : String) : IO String := do
  return textUnder (← r.dom.get) (← r.find "id" ident)

def attrOf (r : LeanUI.Testing.Running) (ident a : String) : IO (Option String) := do
  return ((← r.dom.get).get (← r.find "id" ident)).attrs.find? (·.1 == a) |>.map (·.2)

/-- The history panel's labels. -/
def steps (r : LeanUI.Testing.Running) : IO (Array String) := do
  let d ← r.dom.get
  let ol ← r.find "class" "history"
  return (d.get ol).kids.map fun li => ((d.get li).kids.toList.drop 1 |>.map (textUnder d) |> String.join)

/-- Deliver animation frames (16 ms apart) until the program stops asking for them. -/
partial def frames (r : LeanUI.Testing.Running) (t : Nat := 1000) (n : Nat := 0) : IO Nat := do
  let effs := (← r.dom.get).effects
  match effs.back? with
  | some e =>
    if e.startsWith s!"op{LeanUI.Op.frame} " && n < 10000 then
      let cb := (e.drop s!"op{LeanUI.Op.frame} ".length).toString.toNat!.toUInt32
      r.inst.callback cb true (toString t)
      frames r (t + 16) (n + 1)
    else return n
  | none => return n

def canvasPuts (r : LeanUI.Testing.Running) (since : Nat) : IO (Array String) := do
  return ((← r.dom.get).effects.extract since (← r.dom.get).effects.size).filter (·.startsWith "putImage #canvas")

def testProgram : T Unit := do
  let r ← LeanUI.Testing.run Editor.program
  let mark := (← r.dom.get).effects.size
  r.click "id" "new-1"
  expectEq "new: canvas size" ((← attrOf r "canvas" "width"), (← attrOf r "canvas" "height")) (some "1152", some "864")
  expectEq "new: drawn whole" (← canvasPuts r mark) #["putImage #canvas blob=0 1152x864 dirty=0,0,1152,864"]
  expectEq "new: history" (← steps r) #["New 1152×864"]
  -- a slider previews without a step; apply runs a job over frames
  r.fire (← r.find "id" "adj-brightness") "input" "40"
  expectEq "preview: no step" (← steps r).size 1
  r.click "id" "adj-apply"
  expect "apply: busy" ((← r.find "id" "busy") > 0)
  let n ← frames r
  expect "apply: took frames" (n ≥ 1) s!"{n}"
  expectEq "apply: step" (← steps r) #["New 1152×864", "Adjustments"]
  expectEq "apply: sliders reset" ((← r.dom.get).get (← r.find "id" "adj-brightness")).props (#[("value", "0")])
  -- a filter, then paint a stroke: its moves send dirty rectangles only
  r.fire (← r.find "id" "blur-radius") "input" "2"
  r.click "id" "blur-apply"
  let _ ← frames r
  let canvas ← r.find "id" "canvas"
  let mark := (← r.dom.get).effects.size
  r.fire canvas "pointerdown" "100 100 1152 864 1 0 1 0.5 0 0 100 100"
  r.fire canvas "pointermove" "200 100 1152 864 1 0 1 0.5 0 0 200 100"
  r.fire canvas "pointermove" "300 150 1152 864 1 0 1 0.5 0 0 300 150"
  r.fire canvas "pointerup" "300 150 1152 864 0 0 1 0 0 0 300 150"
  let puts ← canvasPuts r mark
  expect "paint: dirty rectangles" (puts.size == 3 && puts.all fun p => !p.endsWith "dirty=0,0,1152,864") s!"{puts}"
  expectEq "paint: step" (← steps r) #["New 1152×864", "Adjustments", "Blur 2px", "Brush"]
  -- undo and redo redraw the canvas; the panel marks the redo steps
  r.click "id" "undo"
  expectEq "undo: future step" (← attrOf r "step-3" "class") (some "future")
  r.inst.callback (← lastKeysCb r) true "Ctrl+Shift+z"
  expectEq "redo by key" (← attrOf r "step-3" "class") (some "current")
  r.click "id" "step-0"
  expectEq "jump" (← attrOf r "step-0" "class") (some "current")
  r.click "id" "step-3"
  -- layers
  r.click "id" "layer-add"
  let d ← r.dom.get
  expectEq "layers" ((d.get (← r.find "class" "layers")).kids.size) 2
  r.click "id" "layer-delete"
  expectEq "one layer again" (((← r.dom.get).get (← r.find "class" "layers")).kids.size) 1
  -- geometry, then crop with the tool
  r.click "id" "rot-cw"
  expectEq "rotate" ((← attrOf r "canvas" "width"), (← attrOf r "canvas" "height")) (some "864", some "1152")
  r.click "id" "undo"
  r.click "id" "tool-crop"
  r.fire canvas "pointerdown" "100 100 1152 864 1 0 1 0.5 0 0 100 100"
  r.fire canvas "pointermove" "400 300 1152 864 1 0 1 0.5 0 0 400 300"
  r.fire canvas "pointerup" "400 300 1152 864 0 0 1 0 0 0 400 300"
  r.click "id" "crop-apply"
  expectEq "crop" ((← attrOf r "canvas" "width"), (← attrOf r "canvas" "height")) (some "300", some "200")
  -- open a PNG: its bytes come back to Lean, which decodes them
  let png := Png.encode (testImage 40 30) 1
  r.fire (← r.find "id" "open") "change" "9\t100\timage/png\tsmall.png"
  let effs := (← r.dom.get).effects
  let cb := ((effs.reverse.find? (·.startsWith "readFile cb=")).getD "").drop "readFile cb=".length |>.toString |>.takeWhile Char.isDigit
  r.inst.callbackBytes cb.toString.toNat!.toUInt32 true "" png
  expectEq "open PNG (Lean decoder)" ((← attrOf r "canvas" "width"), (← attrOf r "canvas" "height"), (← steps r)) (some "40", some "30", #["Open"])
  -- a file Lean's decoder declines goes to the browser's
  r.fire (← r.find "id" "open") "change" "10\t5\timage/png\tbad.png"
  let effs := (← r.dom.get).effects
  let cb := ((effs.reverse.find? (·.startsWith "readFile cb=")).getD "").drop "readFile cb=".length |>.toString |>.takeWhile Char.isDigit
  r.inst.callbackBytes cb.toString.toNat!.toUInt32 true "" (ByteArray.mk #[1, 2, 3, 4, 5])
  expect "undecodable PNG: the browser's decoder" (((← r.dom.get).effects.back?.getD "").startsWith "decodeImage cb=") s!"{(← r.dom.get).effects.back?}"
  r.click "id" "undo"
  -- export: a download of a PNG of the document's size
  r.click "id" "export"
  let _ ← frames r
  expect "export: download" (((← r.dom.get).effects.back?.getD "").startsWith "download small.png image/png") s!"{(← r.dom.get).effects.back?}"
  let d ← r.dom.get
  expect "protocol" d.errors.isEmpty s!"{d.errors}"
where
  lastKeysCb (r : LeanUI.Testing.Running) : IO UInt32 := do
    let pfx := s!"op{LeanUI.Op.keysListen} "
    let some e := (← r.dom.get).effects.reverse.find? (·.startsWith pfx) | throw (IO.userError "no keys subscription")
    return (e.drop pfx.length).toString.toNat!.toUInt32

/-! ## Main -/

/-- The images of the PNG goldens, for `--write-pngs` (which also writes them encoded 1 and 5 rows
per step by `Png.Encoder`). -/
def goldenPngs : List (String × Image × Nat) :=
  [("base", base, 0), ("base", base, 1), ("gradient", gradient 61 37, 1), ("gradient", gradient 61 37, 9),
    ("checker", checker 64 48 8, 4)]

public def main (args : List String) : IO UInt32 := do
  if args.contains "--print-goldens" then
    for (n, v) in computeGoldens do IO.println s!"  (\"{n}\", {v}),"
    return 0
  if let "--write-pngs" :: dir :: _ := args then
    -- the compressed golden files and their pixels, to check the encoder with other decoders
    IO.FS.createDirAll dir
    for (name, img, level) in goldenPngs do
      IO.FS.writeBinFile s!"{dir}/{name}-{img.width}x{img.height}-level{level}.png" (Png.encode img level)
      for k in [1, 5] do
        IO.FS.writeBinFile s!"{dir}/{name}-{img.width}x{img.height}-level{level}-rows{k}.png" (encodeInSteps img level k)
      IO.FS.writeBinFile s!"{dir}/{name}-{img.width}x{img.height}.rgba" img.data
    return 0
  IO.println "leanui editor tests"
  let ((), s) ← (do
    testByHand; testGoldens; testGeometry; testFilters; testAdjust; testComposite; testPaint; testPng
    testDoc; testJobs; testProgram : T Unit).run {}
  for f in s.failed do IO.println s!"FAIL {f}"
  if s.failed.isEmpty then
    IO.println s!"all {s.passed} checks passed"; return 0
  else
    IO.println s!"{s.failed.size} of {s.passed + s.failed.size} checks FAILED"; return 1
