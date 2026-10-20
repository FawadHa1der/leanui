module
public import LeanUI
public import Editor.Doc
/-!
# Editor benchmark app

A page that runs one image operation of `Editor.Core` at a time, synchronously and at full
resolution, so the browser can time it (`tests/browser/editor-bench.mjs` times the `input` event
that carries the command, against plain JavaScript and canvas built-ins on the same image size).

Commands (the value of `#cmd`):
* `make W H`: a `W × H` test image (`Editor.testImage`), and a translucent copy to composite;
* `run OP`: run operation `OP` (`ops` lists them) on the image; the result is kept, so the next
  run allocates as an app would;
* `sum`: the checksum of the last result into `#sum` (outside the timed commands);
* `blit`: show the image on `#bench-canvas` (`Cmd.drawBitmap`).
-/
public section
open LeanUI Attr

namespace EditorBench
open Editor

structure Model where
  img : Image := Image.blank 1 1
  top : Image := Image.blank 1 1
  out : Image := Image.blank 1 1
  /-- Bytes of the last PNG encoding. -/
  png : Nat := 0
  status : String := "ready"
  sum : String := ""
  deriving Inhabited

/-- The operations, by name, with their fixed parameters. -/
def ops : List String :=
  ["adjust-lut", "adjust-color", "blur-2", "blur-8", "sharpen", "emboss", "edges", "rotate-90", "rotate-180",
   "flip-h", "flip-v", "resize-50", "downscale-8", "composite-normal", "composite-overlay", "histogram",
   "png-stored", "png-1", "crop-half"]

def lutAdjust : Adjust := { Adjust.identity with brightness := 20, contrast := 15, gamma := 1.2 }
def colorAdjust : Adjust := { Adjust.identity with saturation := 30, hue := 20 }

/-- A translucent version of the image (alpha 160), for compositing. -/
def translucent (img : Image) : Image :=
  match img with
  | { width, height, data } =>
    let rec go (d : ByteArray) (i n : Nat) : ByteArray := if i < n then go (d.set! i 160) (i + 4) n else d
    termination_by n - i
    { width, height, data := go (Image.copy ⟨width, height, data⟩).data 3 data.size }

def run (m : Model) (op : String) : Model :=
  let img := m.img
  let (out, png) : Image × Nat := match op with
    | "adjust-lut" => (Adjust.apply lutAdjust img, 0)
    | "adjust-color" => (Adjust.apply colorAdjust img, 0)
    | "blur-2" => (blur img 2, 0)
    | "blur-8" => (blur img 8, 0)
    | "sharpen" => (sharpen img 1 2, 0)
    | "emboss" => (emboss img, 0)
    | "edges" => (edgeDetect img, 0)
    | "rotate-90" => (rotate90cw img, 0)
    | "rotate-180" => (rotate180 img, 0)
    | "flip-h" => (flipH img, 0)
    | "flip-v" => (flipV img, 0)
    | "resize-50" => (resize img (img.width / 2) (img.height / 2), 0)
    | "downscale-8" => (downscaleBox img (img.width / 8) (img.height / 8), 0)
    | "composite-normal" => (composite (Image.copy img) m.top 60 .normal, 0)
    | "composite-overlay" => (composite (Image.copy img) m.top 60 .overlay, 0)
    | "histogram" => let h := histogram img; (Image.blank 1 1, h.foldl (· + ·) 0)
    | "png-stored" => (Image.blank 1 1, (Png.encode img 0).size)
    | "png-1" => (Image.blank 1 1, (Png.encode img 1).size)
    | "crop-half" => (crop img ⟨img.width / 4, img.height / 4, img.width / 2, img.height / 2⟩, 0)
    | _ => (Image.blank 1 1, 0)
  { m with out, png, status := s!"{op} {out.width}x{out.height} {png}" }

def update (cmd : String) (m : Model) : Model × Cmd String :=
  match cmd.splitOn " " with
  | ["make", w, h] =>
    let img := testImage (w.toNat?.getD 1) (h.toNat?.getD 1)
    ({ m with img, top := translucent img, out := Image.blank 1 1, status := s!"made {img.width}x{img.height}" }, .none)
  | ["run", op] => (run m op, .none)
  | ["sum"] => ({ m with sum := toString m.out.checksum }, .none)
  | ["blit"] => (m, .drawBitmap "#bench-canvas" { width := m.img.width, height := m.img.height, data := m.img.data })
  | _ => ({ m with status := s!"unknown command {cmd}" }, .none)

def view (m : Model) : Html String :=
  el "div" #[] #[
    el "input" #[Attr.id "cmd", onInput fun s => s] #[],
    el "output" #[Attr.id "status"] #[text m.status],
    el "output" #[Attr.id "sum"] #[text m.sum],
    el "canvas" #[Attr.id "bench-canvas", .attr "width" (toString m.img.width), .attr "height" (toString m.img.height)] #[]]

def program : Program Model String where
  init _ := ({}, .none)
  update := update
  view := view

end EditorBench
