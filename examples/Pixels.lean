module
public import LeanUI
/-!
# Pixels lab

The commands and payloads for pixel and file work, in one page (`tests/browser/pixels.mjs` drives
it in Chromium and Firefox; `tests/Kit.lean` in the DOM model):

* a 256×128 canvas the model owns as a `Bitmap`: `Cmd.drawBitmap` shows it once, then every
  pointer move with the button down paints a 5×5 square into the bitmap *in place* and sends only
  that square (`Cmd.putImage` with a dirty rectangle);
* pointer events relative to the canvas, scaled to its pixels (`Pointer.scaledTo`), with the
  pointer captured while the button is held, and the wheel;
* files from a file input or dropped on a zone: their bytes (`Cmd.readFile`) and their pixels
  (`Cmd.decodeImage`), shown on a second canvas;
* a download of the canvas's raw pixels (`Cmd.download`);
* document-wide key presses (`Sub.keys`).
-/
public section
open LeanUI Attr

namespace Pixels

def W := 256
def H := 128

/-- A gradient: red across, green down, blue constant, opaque. -/
def gradient : Bitmap := Id.run do
  let mut d := ByteArray.emptyWithCapacity (4 * W * H)
  for y in [0:H] do
    for x in [0:W] do
      d := d.push (x * 255 / (W - 1)).toUInt8 |>.push (y * 255 / (H - 1)).toUInt8 |>.push 128 |>.push 255
  return { width := W, height := H, data := d }

/-- Paint a black `size`×`size` square centred at (`cx`, `cy`), clamped; the bitmap is updated in
place when it is unique. Returns the bitmap and the rectangle that changed. -/
def square (img : Bitmap) (cx cy size : Nat) : Bitmap × PixelRect :=
  match img with
  | { width, height, data } =>
    let x0 := min (cx - size / 2) width; let y0 := min (cy - size / 2) height
    let x1 := min (cx + (size - size / 2)) width; let y1 := min (cy + (size - size / 2)) height
    let data := Id.run do
      let mut d := data
      for y in [y0:y1] do
        for x in [x0:x1] do
          let i := 4 * (y * width + x)
          d := d.set! i 0 |>.set! (i + 1) 0 |>.set! (i + 2) 0
      return d
    ({ width, height, data }, { x := x0, y := y0, w := x1 - x0, h := y1 - y0 })

structure Model where
  canvas : Bitmap := gradient
  dabs : Nat := 0
  pointer : String := ""
  capturing : Bool := false
  wheel : Float := 0
  files : Array FileInfo := #[]
  bytes : String := ""
  decoded : Option Bitmap := none
  error : String := ""
  keys : Array String := #[]

inductive Msg where
  | down (p : Pointer)
  | move (p : Pointer)
  | up (p : Pointer)
  | wheel (p : Pointer)
  | files (fs : Array FileInfo)
  | gotBytes (name : String) (r : Except String ByteArray)
  | gotImage (r : Except String Bitmap)
  | download
  | key (k : String)

def hex (b : ByteArray) (n : Nat) : String :=
  " ".intercalate ((List.range (min n b.size)).map fun i =>
    let v := b[i]!.toNat
    String.ofList [Nat.digitChar (v / 16), Nat.digitChar (v % 16)])

def describe (p : Pointer) : String :=
  let (x, y) := p.scaledTo W H
  s!"{x.toUInt32},{y.toUInt32} buttons {p.buttons}{if p.shift then " shift" else ""}"

/-- Paint at the pointer, if its primary button is down. The model is taken apart first, so the
bitmap it holds is unique and painted in place. -/
def paint (m : Model) (p : Pointer) : Model × Cmd Msg :=
  match m with
  | { canvas, dabs, pointer := _, capturing, wheel, files, bytes, decoded, error, keys } =>
    let pointer := describe p
    if p.buttons &&& 1 == 0 then
      ({ canvas, dabs, pointer, capturing, wheel, files, bytes, decoded, error, keys }, .none)
    else
      let (x, y) := p.scaledTo W H
      let (canvas, r) := square canvas x.toUInt32.toNat y.toUInt32.toNat 5
      ({ canvas, dabs := dabs + 1, pointer, capturing, wheel, files, bytes, decoded, error, keys },
       .putImage "#px-canvas" canvas r)

def update (msg : Msg) (m : Model) : Model × Cmd Msg :=
  match msg with
  | .down p => paint { m with capturing := true } p
  | .move p => paint m p
  | .up p => ({ m with capturing := false, pointer := describe p }, .none)
  | .wheel p => ({ m with wheel := m.wheel + p.deltaY }, .none)
  | .files fs =>
    ({ m with files := fs, bytes := "", decoded := none, error := "" },
     .batch (fs.toList.take 1 |>.map fun f => .batch #[.readFile f.id (.gotBytes f.name), .decodeImage f.id .gotImage]).toArray)
  | .gotBytes name (.ok b) => ({ m with bytes := s!"{name}: {b.size} bytes: {hex b 8}" }, .none)
  | .gotBytes name (.error e) => ({ m with bytes := s!"{name}: {e}" }, .none)
  | .gotImage (.ok img) => ({ m with decoded := some img }, .drawBitmap "#px-image" img)
  | .gotImage (.error e) => ({ m with decoded := none, error := e }, .none)
  | .download => (m, .download "pixels.rgba" "application/octet-stream" m.canvas.data)
  | .key k => ({ m with keys := (m.keys.push k).extract (m.keys.size + 1 - min 5 (m.keys.size + 1)) }, .none)

def view (m : Model) : Html Msg :=
  el "div" #[cls "pixels"] #[
    el "h1" #[] #[text "Pixels lab"],
    el "canvas" #[id "px-canvas", .attr "width" (toString W), .attr "height" (toString H),
      .attr "style" "width:512px;height:256px;touch-action:none;image-rendering:pixelated",
      onPointer "pointerdown" (some ∘ .down) (capture := true),
      onPointer "pointermove" (some ∘ .move),
      onPointer "pointerup" (some ∘ .up),
      onWheel (some ∘ .wheel)] #[],
    el "p" #[] #[text "pointer ", el "output" #[id "px-pointer"] #[text m.pointer],
      text " · dabs ", el "output" #[id "px-dabs"] #[text (toString m.dabs)],
      text " · captured ", el "output" #[id "px-capturing"] #[text (toString m.capturing)],
      text " · wheel ", el "output" #[id "px-wheel"] #[text (toString m.wheel.toInt64)]],
    el "p" #[] #[
      el "input" #[id "px-file", .attr "type" "file", onFiles .files] #[],
      el "span" #[id "px-drop", .attr "style" "display:inline-block;padding:1em;border:2px dashed",
        onDragOver, onDrop .files] #[text "or drop a file here"],
      el "button" #[id "px-download", onClick .download] #[text "Download the pixels"]],
    el "p" #[] #[text "files ", el "output" #[id "px-files"]
      #[text (", ".intercalate (m.files.toList.map fun f => s!"{f.name} ({f.size} bytes, {f.type})"))]],
    el "p" #[] #[text "bytes ", el "output" #[id "px-bytes"] #[text m.bytes]],
    el "p" #[] #[text "image ", el "output" #[id "px-decoded"]
      #[text (match m.decoded with | some i => s!"{i.width}×{i.height}" | none => m.error)]],
    match m.decoded with
    | some i => el "canvas" #[id "px-image", .attr "width" (toString i.width), .attr "height" (toString i.height)] #[]
    | none => el "span" #[] #[],
    el "p" #[] #[text "keys ", el "output" #[id "px-keys"] #[text (" ".intercalate m.keys.toList)]]]

def program : Program Model Msg where
  init _ := ({}, .drawBitmap "#px-canvas" gradient)
  update := update
  view := view
  subscriptions _ := .keys (some ∘ .key)

end Pixels
