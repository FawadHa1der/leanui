module
public import Editor.Core
/-!
# Native speed of the photo editor core

`lake build leanui-editor-perf && .lake/build/bin/leanui-editor-perf` times each operation of
`examples/Editor` on generated 1-megapixel (1024×1024) and 12-megapixel (4000×3000) images and
prints megapixels per second (the median of a few runs; 12 MP runs once per operation with
`--quick`). Native code is the upper bound of what the wasm build can do.

`leanui-editor-perf png-out DIR` writes a few encoded PNG files (for checking the encoder with
other decoders).
-/
public section
open Editor

private partial def noiseLoop (n : Nat) (s : UInt32) (d : ByteArray) : ByteArray :=
  if n == 0 then d
  else
    let s1 := s * 1103515245 + 12345
    let s2 := s1 * 1103515245 + 12345
    let s3 := s2 * 1103515245 + 12345
    noiseLoop (n - 1) s3 (d.push (s1 >>> 24).toUInt8 |>.push (s2 >>> 24).toUInt8 |>.push (s3 >>> 24).toUInt8 |>.push 255)

/-- A photo-like test image: a smooth gradient with pseudo-random noise (so that compression and
blurs see realistic data), opaque. Built at run time (`@[noinline]`, from arguments), so it is not a
persistent closed term and in-place operations on it really are in place. -/
@[noinline] def photo (w h : Nat) (seed : UInt32) : IO Image := do
  let n := noiseLoop (w * h) seed (ByteArray.emptyWithCapacity (4 * w * h))
  let g := Image.generate w 1 fun x _ => ⟨(x * 255 / max 1 (w - 1)).toUInt8, 128, (255 - x * 255 / max 1 (w - 1)).toUInt8, 255⟩
  -- a gradient with 8 % noise composited over it (about as compressible as a photo)
  let grad := resize g w h
  return composite grad ⟨w, h, n⟩ 8 .normal

/-- A copy made outside the timed region, so the timed operation gets a unique image. -/
@[noinline] def fresh (img : Image) : IO Image := pure img.copy

/-- Time `f` on a fresh copy of `img` `reps` times; the median in seconds. -/
def timeOp (img : Image) (reps : Nat) (f : Image → Image) : IO Float := do
  let mut ts : Array Nat := #[]
  for _ in [0:reps] do
    let input ← fresh img
    let t0 ← IO.monoNanosNow
    let out ← IO.lazyPure fun _ => f input
    let t1 ← IO.monoNanosNow
    if out.data.size == 1 then IO.println "?"
    ts := ts.push (t1 - t0)
  let sorted := ts.qsort (· < ·)
  return Float.ofNat sorted[sorted.size / 2]! / 1e9

def pad (s : String) (n : Nat) : String := s.pushn ' ' (n - s.length)
def lpad (s : String) (n : Nat) : String := "".pushn ' ' (n - s.length) ++ s

def fmt (v : Float) : String :=
  let r := (v * 10).round / 10
  let s := toString r
  -- toString of a Float prints 6 decimals: keep one
  match s.splitOn "." with
  | [a, b] => a ++ "." ++ (b.take 1)
  | _ => s

def ops (small : Image) : Array (String × (Image → Image)) :=
  let dabs (img : Image) : Image := Id.run do
    -- 200 dabs of radius 24 (the pixels they cover, about 200 · π · 24², not the image size, count)
    let mut img := img
    for i in [0:200] do
      img := (dab img (Float.ofNat (37 * i % img.width)) (Float.ofNat (53 * i % img.height)) 24 0.5 0.8
        ⟨200, 30, 30, 255⟩).1
    return img
  #[("adjust: table (brightness, contrast, curve)", Adjust.apply { brightness := 10, contrast := 20, curve := #[(128, 150)] }),
    ("adjust: table + colour matrix", Adjust.apply { brightness := 10, saturation := 30, hue := 20 }),
    ("histogram", fun img => ⟨(histogramRows img 0 img.height).foldl (· + ·.toNat) 0, 0, .empty⟩),
    ("blur radius 2", fun img => blur img 2),
    ("blur radius 8", fun img => blur img 8),
    ("sharpen (amount 1, radius 2)", fun img => sharpen img 1 2 2),
    ("convolve 3×3 (emboss)", emboss),
    ("edge detect (Sobel)", edgeDetect),
    ("rotate 90° clockwise", rotate90cw),
    ("rotate 180°", rotate180),
    ("flip horizontal", flipH),
    ("flip vertical", flipV),
    ("crop (centre half)", fun img => crop img ⟨img.width / 4, img.height / 4, img.width / 2, img.height / 2⟩),
    ("resize bilinear to 50 %", fun img => resize img (img.width / 2) (img.height / 2)),
    ("resize bilinear to 150 %", fun img => resize img (img.width * 3 / 2) (img.height * 3 / 2)),
    ("box downscale to 1/8 (preview)", fun img => downscaleBox img (img.width / 8) (img.height / 8)),
    ("composite normal 60 %", fun img => composite img small 60 .normal),
    ("composite overlay 60 %", fun img => composite img small 60 .overlay),
    ("checksum (FNV-1a)", fun img => if img.checksum == 0 then img.copy else img),
    ("PNG encode, stored (level 0)", fun img => ⟨(Png.encode img 0).size, 0, .empty⟩),
    ("PNG encode, level 1", fun img => ⟨(Png.encode img 1).size, 0, .empty⟩),
    ("PNG encode, level 6", fun img => ⟨(Png.encode img 6).size, 0, .empty⟩),
    ("200 dabs, radius 24 (MPix/s of the image)", dabs)]

def runSize (label : String) (img : Image) (reps : Nat) : IO (Array (String × Float)) := do
  let top ← photo img.width img.height 99
  let mut res := #[]
  for (name, f) in ops top do
    let s ← timeOp img reps f
    res := res.push (name, Float.ofNat img.pixels / s / 1e6)
  -- decoding: of what level 1 writes
  let png1 := Png.encode img 1
  let png0 := Png.encode img 0
  for (name, bytes) in [("PNG decode (level 1 file)", png1), ("PNG decode (stored file)", png0)] do
    let mut ts : Array Nat := #[]
    for _ in [0:reps] do
      let t0 ← IO.monoNanosNow
      let out ← IO.lazyPure fun _ => Png.decode bytes
      let t1 ← IO.monoNanosNow
      match out with
      | .ok o => if o.width != img.width then IO.println "decode mismatch"
      | .error e => IO.println s!"decode failed: {e}"
      ts := ts.push (t1 - t0)
    let med := (ts.qsort (· < ·))[ts.size / 2]!
    res := res.push (name, Float.ofNat img.pixels / (Float.ofNat med / 1e9) / 1e6)
  IO.println s!"  {label}: level 1 PNG {png1.size / 1024} KB, stored {png0.size / 1024} KB"
  return res

def pngOut (dir : String) : IO Unit := do
  IO.FS.createDirAll dir
  let imgs : List (String × Image) := [("photo", ← photo 333 211 5), ("gradient", resize (Image.generate 2 2 fun x y =>
      ⟨(x * 255).toUInt8, (y * 255).toUInt8, 90, (128 + 127 * x).toUInt8⟩) 97 61)]
  for (name, img) in imgs do
    for level in [0, 1, 6, 9] do
      let path := s!"{dir}/{name}-{img.width}x{img.height}-level{level}.png"
      IO.FS.writeBinFile path (Png.encode img level)
      IO.FS.writeBinFile s!"{dir}/{name}-{img.width}x{img.height}.rgba" img.data
      IO.println path

public def main (args : List String) : IO UInt32 := do
  if let "png-out" :: dir :: _ := args then
    pngOut dir; return 0
  let quick := args.contains "--quick"
  IO.println "editor core, native: megapixels per second (median)"
  let small ← photo 1024 1024 7
  let r1 ← runSize "1 MP (1024×1024)" small 5
  let big ← photo 4000 3000 7
  let r12 ← runSize "12 MP (4000×3000)" big (if quick then 1 else 3)
  IO.println s!"  {pad "operation" 44} {lpad "1 MP" 9} {lpad "12 MP" 9}"
  for ((name, a), (_, b)) in r1.zip r12 do
    IO.println s!"  {pad name 44} {lpad (fmt a) 9} {lpad (fmt b) 9}"
  return 0
