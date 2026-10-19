module
public import Editor.Core
public import LeanUI.Effect
/-!
# The editor's document: layers at two resolutions

A `Doc` is a stack of same-sized layers. Each layer holds its full-resolution image and, when that
is larger than `previewMax` on a side, a downscaled preview (`none`: the image is its own
preview). The canvas shows the composite of the previews (`Doc.composite`), so interactive work
costs a preview-sized operation whatever the image size; full-resolution work happens on apply
and export (`Editor.Ops`).

**In place.** Painting must not copy a 48 MB layer per pointer move, so every level is taken
apart before it is changed (`takeLayers`, the layer's `img` taken out before painting): a value
that is uniquely referenced is then updated in place. The first dab of a stroke does copy the
layer, once, because the previous history step still holds the old pixels
(`tests/Editor.lean` checks both).
-/
public section
namespace Editor

/-- The longest side of a preview. -/
def previewMax : Nat := 1280

structure Layer where
  id : Nat
  name : String
  visible : Bool := true
  opacity : Nat := 100
  blend : Blend := .normal
  img : Image
  /-- The preview, if the image is larger than `previewMax` on a side. -/
  prev : Option Image := none
  deriving Inhabited

def Layer.preview (l : Layer) : Image :=
  match l.prev with
  | some p => p
  | none => l.img

structure Doc where
  width : Nat
  height : Nat
  /-- Preview size. -/
  pw : Nat
  ph : Nat
  /-- Bottom to top. -/
  layers : Array Layer
  nextId : Nat
  deriving Inhabited

/-- The preview size of a `w × h` image: at most `previewMax` on its longest side. -/
def previewSize (w h : Nat) : Nat × Nat :=
  if w ≤ previewMax && h ≤ previewMax then (w, h)
  else if w ≥ h then (previewMax, max 1 ((h * previewMax + w / 2) / w))
  else (max 1 ((w * previewMax + h / 2) / h), previewMax)

def mkPreview (img : Image) (pw ph : Nat) : Option Image :=
  if img.width == pw && img.height == ph then none else some (downscaleBox img pw ph)

/-! ## Geometry -/

inductive Geo where
  | rotCW | rotCCW | rot180 | flipH | flipV
  | resize (w h : Nat)
  | crop (r : Rect)
  deriving Inhabited

def Geo.label : Geo → String
  | .rotCW => "Rotate 90° clockwise" | .rotCCW => "Rotate 90° counter-clockwise" | .rot180 => "Rotate 180°"
  | .flipH => "Flip horizontal" | .flipV => "Flip vertical"
  | .resize w h => s!"Resize to {w}×{h}" | .crop r => s!"Crop to {r.w}×{r.h}"

def Geo.run (g : Geo) (img : Image) : Image :=
  match g with
  | .rotCW => Editor.rotate90cw img | .rotCCW => Editor.rotate90ccw img | .rot180 => Editor.rotate180 img
  | .flipH => Editor.flipH img | .flipV => Editor.flipV img
  | .resize w h => Editor.resize img w h
  | .crop r => Editor.crop img r

namespace Doc

def ofImage (img : Image) (name : String) : Doc :=
  let (pw, ph) := previewSize img.width img.height
  { width := img.width, height := img.height, pw, ph, nextId := 2,
    layers := #[{ id := 1, name, img, prev := mkPreview img pw ph }] }

/-- Preview pixels per document pixel. -/
def scale (d : Doc) : Float := Float.ofNat d.pw / Float.ofNat d.width

def layerIndex? (d : Doc) (id : Nat) : Option Nat := d.layers.findIdx? (·.id == id)

/-- The layers taken out of the document (so changing them does not copy the array). -/
@[inline] def takeLayers (d : Doc) : Array Layer × Doc := (d.layers, { d with layers := #[] })

def modifyLayer (d : Doc) (id : Nat) (f : Layer → Layer) : Doc :=
  match d.layerIndex? id with
  | none => d
  | some i => let (ls, d) := d.takeLayers; { d with layers := ls.modify i f }

/-- Replace a layer's full-resolution image (and remake its preview). -/
def setLayerImage (d : Doc) (id : Nat) (img : Image) : Doc :=
  let prev := mkPreview img d.pw d.ph
  d.modifyLayer id fun l => { l with img, prev }

/-- A new transparent layer above `above`; returns the document and the new layer's id. -/
def addLayer (d : Doc) (above : Nat) : Doc × Nat :=
  let id := d.nextId
  let blank := Image.blank d.width d.height
  let l : Layer := { id, name := s!"Layer {id}", img := blank, prev := mkPreview blank d.pw d.ph }
  let pos := ((d.layerIndex? above).map (· + 1)).getD d.layers.size
  let (ls, d) := d.takeLayers
  ({ d with layers := ls.insertIdxIfInBounds pos l, nextId := id + 1 }, id)

/-- A copy of layer `id` above it (sharing its pixels until one of them changes). -/
def duplicateLayer (d : Doc) (id : Nat) : Doc × Nat :=
  match d.layerIndex? id with
  | none => (d, id)
  | some i =>
    let nid := d.nextId
    let l := { d.layers[i]! with id := nid, name := d.layers[i]!.name ++ " copy" }
    let (ls, d) := d.takeLayers
    ({ d with layers := ls.insertIdxIfInBounds (i + 1) l, nextId := nid + 1 }, nid)

def deleteLayer (d : Doc) (id : Nat) : Doc :=
  if d.layers.size ≤ 1 then d else
  let (ls, d) := d.takeLayers
  { d with layers := ls.filter (·.id != id) }

def moveLayer (d : Doc) (id : Nat) (up : Bool) : Doc :=
  match d.layerIndex? id with
  | none => d
  | some i =>
    let j := if up then i + 1 else i - 1
    if (up && j ≥ d.layers.size) || (!up && i == 0) then d
    else let (ls, d) := d.takeLayers; { d with layers := ls.swapIfInBounds i j }

/-! ## Compositing (previews) -/

/-- Set rows `[y0, y1)` of an image to transparent, in place. -/
def clearRows (img : Image) (y0 y1 : Nat) : Image :=
  match img with
  | { width, height, data } =>
    let rec go (d : ByteArray) (i n : Nat) : ByteArray :=
      if i < n then go (d.set! i 0) (i + 1) n else d
    termination_by n - i
    { width, height, data := go data (4 * width * min y0 height) (4 * width * min y1 height) }

/-- Composite rows `[y0, y1)` of the visible layers' previews into `out` (cleared first), with
`swap` replacing one layer's preview (a pending operation's result). -/
def compositeRowsInto (d : Doc) (out : Image) (y0 y1 : Nat) (swap : Option (Nat × Image) := none) : Image := Id.run do
  let mut out := clearRows out y0 y1
  for h : i in [0:d.layers.size] do
    let l := d.layers[i]
    if l.visible && l.opacity > 0 then
      match swap with
      | some (j, img) => out := compositeRows out (if j == i then img else l.preview) l.opacity l.blend y0 y1
      | none => out := compositeRows out l.preview l.opacity l.blend y0 y1
  return out

/-- The composite of the visible layers' previews. -/
def composite (d : Doc) (swap : Option (Nat × Image) := none) : Image :=
  d.compositeRowsInto (Image.blank d.pw d.ph) 0 d.ph swap

/-- The preview rectangle covering a document rectangle. -/
def toPreviewRect (d : Doc) (r : Rect) : LeanUI.PixelRect :=
  let x0 := r.x * d.pw / d.width; let y0 := r.y * d.ph / d.height
  let x1 := min d.pw (((r.x + r.w) * d.pw + d.width - 1) / d.width)
  let y1 := min d.ph (((r.y + r.h) * d.ph + d.height - 1) / d.height)
  { x := x0, y := y0, w := x1 - x0, h := y1 - y0 }

/-- Recomposite the preview rows under a document rectangle into `comp`. -/
def compositeRect (d : Doc) (comp : Image) (r : Rect) : Image :=
  let p := d.toPreviewRect r
  d.compositeRowsInto comp p.y (p.y + p.h)

/-! ## Painting -/

/-- Paint a stroke segment (document coordinates) on layer `id`, in place when the layer is
unique; its preview is remade under the stroke. Returns the document rectangle that changed. -/
def paint (d : Doc) (id : Nat) (a b : Float × Float) (brush : Brush) : Doc × Rect :=
  match d.layerIndex? id with
  | none => (d, Rect.empty)
  | some i =>
    let (ph, h) := (d.ph, d.height)
    let (ls, d) := d.takeLayers
    -- take the layer out of the array, and the image out of the layer
    let (l, ls) := ls.swapAt! i default
    let (img, prev, l) := (l.img, l.prev, { l with img := default, prev := none })
    let (img, dirty) := stroke img a.1 a.2 b.1 b.2 brush (skipFirst := a != b)
    let prev := match prev with
      | none => none
      | some p =>
        if dirty.w == 0 || dirty.h == 0 then some p
        else
          let y0 := dirty.y * ph / h
          let y1 := min ph (((dirty.y + dirty.h) * ph + h - 1) / h)
          some (downscaleBoxRows img p y0 y1)
    ({ d with layers := ls.set! i { l with img, prev } }, dirty)

/-- Apply a geometric operation to every layer. -/
def transform (d : Doc) (g : Geo) : Doc :=
  let ls := d.layers.map fun l => { l with img := g.run l.img }
  match ls[0]? with
  | none => d
  | some l0 =>
    let (pw, ph) := previewSize l0.img.width l0.img.height
    { d with width := l0.img.width, height := l0.img.height, pw, ph,
             layers := ls.map fun l => { l with prev := mkPreview l.img pw ph } }

/-- The full-resolution composite of the visible layers (for export). -/
def flatten (d : Doc) : Image := Id.run do
  let mut out := Image.blank d.width d.height
  for l in d.layers do
    if l.visible && l.opacity > 0 then out := Editor.composite out l.img l.opacity l.blend
  return out

end Doc

/-! ## Test images -/

/-- A synthetic photo-like test image: smooth gradients, a few discs, fine stripes and a grain
pattern, opaque. Deterministic, so tests and benchmarks need no binary fixtures. -/
def testImage (w h : Nat) : Image :=
  let rec row (d : ByteArray) (x y : Nat) (fuel : Nat) : ByteArray :=
    match fuel with
    | 0 => d
    | fuel + 1 =>
      if x ≥ w then d else
      let fx := Float.ofNat x / Float.ofNat w; let fy := Float.ofNat y / Float.ofNat h
      let disc (cx cy r : Float) : Bool := (fx - cx) * (fx - cx) * 1.78 + (fy - cy) * (fy - cy) < r * r
      let grain := ((x * 7919 + y * 104729) % 31).toFloat - 15
      let (r, g, b) :=
        if disc 0.3 0.4 0.18 then (230.0, 90.0 + 80 * fy, 60.0)
        else if disc 0.7 0.6 0.22 then (50.0 + 100 * fx, 150.0, 220.0)
        else if fy > 0.82 && (x / 6) % 2 == 0 then (240.0, 240.0, 240.0)
        else (40 + 180 * fx, 60 + 150 * fy, 120 + 100 * (1 - fx))
      let c (v : Float) : UInt8 := (max 0 (min 255 (v + grain))).toUInt8
      row (d.push (c r) |>.push (c g) |>.push (c b) |>.push 255) (x + 1) y fuel
  let rec rows (d : ByteArray) (y : Nat) (fuel : Nat) : ByteArray :=
    match fuel with
    | 0 => d
    | fuel + 1 => if y ≥ h then d else rows (row d 0 y (w + 1)) (y + 1) fuel
  { width := w, height := h, data := rows (ByteArray.emptyWithCapacity (4 * w * h)) 0 (h + 1) }

end Editor
