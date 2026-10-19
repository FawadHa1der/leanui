module
public import LeanUI
public import Editor.Doc
public import Editor.Ops
/-!
# LeanUI Photo: an image editor

Everything after the browser hands over pixels runs in Lean: the layer model, adjustments,
filters, geometry, painting, compositing, the histogram, undo history and PNG export
(`Editor.Core`). The browser decodes JPEG and PNG files (`Cmd.decodeImage`) and shows pixels
(`Cmd.putImage`, straight from wasm memory).

**Two resolutions.** Each layer keeps its full-resolution image and a preview (at most
`Editor.previewMax` pixels on its longest side). The canvas shows the composite of the previews,
so live previews (a slider being dragged) cost a preview-sized operation and a preview composite,
whatever the image size. Painting changes the full-resolution layer and the preview rectangle
under the brush only. *Apply* runs the operation on the full-resolution layer as a **job** that
does a slice of rows per animation frame (`Cmd.nextFrame`), sized so a frame stays near 25 ms,
so the page stays responsive and shows progress.

**History** keeps whole documents. Layers that a step did not change are shared with the step
before (the same `ByteArray`), so a step costs only the images it replaced; the oldest steps are
dropped beyond `historyBudget` bytes or `historyMax` steps. A paint stroke copies the layer it
paints on once, at its first dab (the previous step still holds the old pixels), and then paints
in place.
-/
public section
open LeanUI Attr

namespace Editor

/-! ## Model -/

inductive Tool where
  | hand | brush | eraser | crop
  deriving BEq, Inhabited, Repr

def Tool.name : Tool → String
  | .hand => "hand" | .brush => "brush" | .eraser => "eraser" | .crop => "crop"

/-- Slider state of the adjustments panel (integers, as the sliders report them). -/
structure AdjustUI where
  brightness : Int := 0
  contrast : Int := 0
  /-- Hundredths of a stop. -/
  exposure : Int := 0
  saturation : Int := 0
  hue : Int := 0
  black : Nat := 0
  white : Nat := 255
  /-- Hundredths. -/
  gamma : Nat := 100
  /-- Curve offsets at 64, 128 and 192. -/
  shadows : Int := 0
  midtones : Int := 0
  highlights : Int := 0
  invert : Bool := false
  grayscale : Bool := false
  deriving BEq, Inhabited

instance : ToDep AdjustUI where
  toDep a := toDep ([a.brightness, a.contrast, a.exposure, a.saturation, a.hue, a.black, a.gamma, a.white,
    a.shadows, a.midtones, a.highlights], a.invert, a.grayscale)

/-- Brush settings as the tool options show them. -/
structure BrushUI where
  /-- Diameter in document pixels. -/
  size : Nat := 24
  /-- Percent. -/
  hardness : Nat := 70
  opacity : Nat := 100
  color : Nat × Nat × Nat := (20, 20, 20)
  deriving Inhabited

def BrushUI.toBrush (b : BrushUI) (erase : Bool) : Brush :=
  { radius := Float.ofNat b.size / 2, hardness := Float.ofNat b.hardness / 100, opacity := Float.ofNat b.opacity / 100,
    color := ⟨b.color.1.toUInt8, b.color.2.1.toUInt8, b.color.2.2.toUInt8, 255⟩, erase }

def hexDigit (c : Char) : Nat :=
  if c.isDigit then c.toNat - '0'.toNat
  else if 'a' ≤ c && c ≤ 'f' then c.toNat - 'a'.toNat + 10
  else if 'A' ≤ c && c ≤ 'F' then c.toNat - 'A'.toNat + 10 else 0

/-- `#rrggbb` to a colour. -/
def parseHex (s : String) : Nat × Nat × Nat :=
  match s.toList with
  | ['#', a, b, c, d, e, f] => (hexDigit a * 16 + hexDigit b, hexDigit c * 16 + hexDigit d, hexDigit e * 16 + hexDigit f)
  | _ => (0, 0, 0)

def hexOf (c : Nat × Nat × Nat) : String :=
  let h (n : Nat) : String := String.ofList [Nat.digitChar (n / 16 % 16), Nat.digitChar (n % 16)]
  "#" ++ h c.1 ++ h c.2.1 ++ h c.2.2

def Blend.ofName (s : String) : Blend := (Blend.all.find? (·.name == s)).getD .normal

/-- The operation a panel previews live, if any. -/
inductive Pending where
  | adjust
  | blur
  | sharpen
  deriving BEq, Inhabited

/-- One undo step: the document after it, and the bytes of the images it introduced. -/
structure Step where
  label : String
  doc : Doc
  cost : Nat

structure Model where
  doc : Option Doc := none
  /-- The canvas: the composite of the layer previews (with a pending operation applied). -/
  comp : Image := Image.new 1 1 0 0 0 0
  /-- Bumped whenever `comp` changes (the histogram depends on it). -/
  compVersion : Nat := 0
  hist : Array Nat := #[]
  history : Array Step := #[]
  /-- The current step in `history`. -/
  cursor : Nat := 0
  active : Nat := 0
  tool : Tool := .brush
  brush : BrushUI := {}
  adjust : AdjustUI := {}
  blurRadius : Nat := 6
  sharpAmount : Nat := 80
  sharpRadius : Nat := 2
  pending : Option Pending := none
  job : Option Job := none
  /-- Pixels of work per animation frame for jobs; adapted to the frame times. -/
  budget : Nat := 1500000
  lastFrame : Float := 0
  /-- `none`: fit to the window. -/
  zoom : Option Float := none
  panX : Float := 0
  panY : Float := 0
  /-- The canvas's displayed width the last time a pointer event reported it. -/
  boxW : Float := 0
  /-- The last stroke position, in document pixels. -/
  stroke : Option (Float × Float) := none
  /-- A hand drag: pointer and pan at its start. -/
  drag : Option (Float × Float × Float × Float) := none
  crop : Option Rect := none
  cropFrom : Option (Float × Float) := none
  renaming : Option Nat := none
  resizeW : Nat := 0
  resizeH : Nat := 0
  keepRatio : Bool := true
  dropping : Bool := false
  status : String := "Open an image, or make a test image."
  fileName : String := "image"
  deriving Inhabited

inductive Msg where
  | files (fs : Array FileInfo)
  | decoded (name : String) (r : Except String Bitmap)
  | newImage (mp : Nat)
  | dragOver
  | dragLeave
  | setTool (t : Tool)
  | brushSize (n : Nat)
  | brushHardness (n : Nat)
  | brushOpacity (n : Nat)
  | brushColor (hex : String)
  | down (p : Pointer)
  | move (p : Pointer)
  | up (p : Pointer)
  | wheel (p : Pointer)
  | zoomBy (factor : Float)
  | zoomFit
  | zoom100
  | setAdjust (a : AdjustUI)
  | setBlur (r : Nat)
  | setSharpen (amount radius : Nat)
  | preview (p : Pending)
  | apply (p : Pending)
  | cancelPending
  | filter (op : Op)
  | geometry (g : Geo)
  | setResize (w h : Nat)
  | setKeepRatio (b : Bool)
  | applyCrop
  | clearCrop
  | frame (t : Float)
  | addLayer
  | duplicateLayer
  | deleteLayer
  | moveLayer (up : Bool)
  | selectLayer (id : Nat)
  | toggleLayer (id : Nat)
  | layerOpacity (n : Nat)
  | layerBlend (b : String)
  | startRename (id : Nat)
  | rename (id : Nat) (name : String)
  | stopRename
  | jump (i : Nat)
  | undo
  | redo
  | exportPng
  | key (k : Keys)

/-! ## Helpers -/

def historyMax := 200
/-- Bytes of replaced images the history may hold (1 GiB). -/
def historyBudget := 1 <<< 30

def AdjustUI.toAdjust (a : AdjustUI) : Adjust :=
  let curve : Array (Nat × Nat) :=
    if a.shadows == 0 && a.midtones == 0 && a.highlights == 0 then #[]
    else
      let pt (x : Nat) (d : Int) : Nat × Nat := (x, (max 0 (min 255 (Int.ofNat x + d))).toNat)
      #[(0, 0), pt 64 a.shadows, pt 128 a.midtones, pt 192 a.highlights, (255, 255)]
  { Adjust.identity with
    brightness := a.brightness, contrast := a.contrast,
    exposure := Float.ofInt a.exposure / 100, saturation := a.saturation, hue := a.hue,
    inBlack := a.black, inWhite := a.white, gamma := Float.ofNat a.gamma / 100,
    curve, invert := a.invert, grayscale := a.grayscale }

def Pending.op (m : Model) : Pending → Op
  | .adjust => .adjust m.adjust.toAdjust
  | .blur => .blur m.blurRadius
  | .sharpen => .sharpen m.sharpAmount m.sharpRadius

def bitmap (i : Image) : Bitmap := { width := i.width, height := i.height, data := i.data }

def show (m : Model) : Cmd Msg := .drawBitmap "#canvas" (bitmap m.comp)

def parseNat (s : String) : Nat := s.toNat?.getD 0
def parseInt (s : String) : Int := s.toInt?.getD 0

/-- Recompute the canvas from the document (with the pending operation on the active layer),
and its histogram. -/
def recomposite (m : Model) : Model :=
  match m.doc with
  | none => m
  | some d =>
    let swap := match m.pending with
      | some p => (d.layerIndex? m.active).map fun i => (i, (p.op m).preview d.scale d.layers[i]!.prev)
      | none => none
    let comp := d.composite swap
    { m with comp, compVersion := m.compVersion + 1, hist := histogram comp }

def refresh (m : Model) : Model × Cmd Msg :=
  let m := recomposite m
  (m, show m)

/-- Record a step (dropping any redo steps, then the oldest steps over the budget). -/
def push (m : Model) (label : String) (cost : Nat) : Model :=
  match m.doc with
  | none => m
  | some d =>
    let hist := (m.history.extract 0 (m.cursor + 1)).push { label, doc := d, cost }
    let rec trim (h : Array Step) (fuel : Nat) : Array Step :=
      match fuel with
      | 0 => h
      | fuel + 1 =>
        let total := h.foldl (fun n s => n + s.cost) 0
        if h.size > 1 && (h.size > historyMax || total - (h.back?.map (·.cost)).getD 0 > historyBudget)
        then trim (h.extract 1 h.size) fuel else h
    let hist := trim hist hist.size
    { m with history := hist, cursor := hist.size - 1 }

def openDoc (m : Model) (d : Doc) (label name : String) : Model × Cmd Msg :=
  let active := (d.layers.back?.map (·.id)).getD 0
  let m := { m with doc := some d, history := #[], cursor := 0, active, pending := none, job := none,
                    crop := none, zoom := none, panX := 0, panY := 0, stroke := none,
                    resizeW := d.width, resizeH := d.height, fileName := name,
                    status := s!"{name}: {d.width}×{d.height}" }
  let m := push m label (d.width * d.height * 4)
  refresh m

/-- Replace the document (keeping the active layer if it still exists) and record a step. -/
def commit (m : Model) (d : Doc) (label : String) (cost : Nat) : Model × Cmd Msg :=
  let active := if (d.layerIndex? m.active).isSome then m.active else (d.layers.back?.map (·.id)).getD 0
  refresh (push { m with doc := some d, active, pending := none, resizeW := d.width, resizeH := d.height } label cost)

def busy (m : Model) : Bool := m.job.isSome

/-- Where a pointer is in document pixels. -/
def docPoint (d : Doc) (p : Pointer) : Float × Float := p.scaledTo d.width d.height

def clampRect (d : Doc) (a b : Float × Float) : Rect :=
  let cl (v : Float) (n : Nat) : Nat := (max 0 (min (Float.ofNat n) v)).toUInt64.toNat
  let x0 := cl (min a.1 b.1) d.width; let x1 := cl (max a.1 b.1) d.width
  let y0 := cl (min a.2 b.2) d.height; let y1 := cl (max a.2 b.2) d.height
  { x := x0, y := y0, w := x1 - x0, h := y1 - y0 }

/-- Start a full-resolution job on the active layer. -/
def startJob (m : Model) (op : Op) : Model × Cmd Msg :=
  match m.doc with
  | none => (m, .none)
  | some d =>
    match d.layerIndex? m.active with
    | none => (m, .none)
    | some i =>
      let job := Job.layer op m.active d.layers[i]!.img
      ({ m with job := some job, status := s!"{op.label}…", lastFrame := 0 }, .nextFrame .frame)

/-- Paint from the last stroke position to `p`, update the canvas under the brush. -/
def paintTo (m : Model) (p : Pointer) : Model × Cmd Msg :=
  -- take the document and the canvas out of the model, so both are painted in place
  let (doc, comp, m) := (m.doc, m.comp, { m with doc := none, comp := default })
  match doc, m.stroke with
  | some d, some last =>
    let pt := docPoint d p
    let (d, dirty) := d.paint m.active last pt (m.brush.toBrush (m.tool == .eraser))
    if dirty.w == 0 || dirty.h == 0 then ({ m with doc := some d, comp, stroke := some pt }, .none)
    else
      let comp := d.compositeRect comp dirty
      let r := d.toPreviewRect dirty
      ({ m with doc := some d, stroke := some pt, comp }, .putImage "#canvas" (bitmap comp) r)
  | doc, _ => ({ m with doc, comp }, .none)

def zoomTo (m : Model) (z : Float) : Model :=
  { m with zoom := some (max 0.05 (min 32 z)) }

def currentZoom (m : Model) : Float :=
  match m.zoom, m.doc with
  | some z, _ => z
  | none, some d => if m.boxW > 0 then m.boxW / Float.ofNat d.pw else 1
  | none, none => 1

/-! ## Update -/

def update (msg : Msg) (m : Model) : Model × Cmd Msg :=
  match msg with
  | .files fs =>
    match fs[0]? with
    | some f => ({ m with dropping := false, status := s!"Decoding {f.name}…" }, .decodeImage f.id (.decoded f.name))
    | none => ({ m with dropping := false }, .none)
  | .decoded name (.ok b) =>
    let base := (name.splitOn ".").head!
    openDoc m (Doc.ofImage { width := b.width, height := b.height, data := b.data } "Background") "Open" base
  | .decoded name (.error e) => ({ m with status := s!"{name}: {e}" }, .none)
  | .newImage mp =>
    let (w, h) := if mp ≥ 12 then (4000, 3000) else if mp ≥ 4 then (2304, 1728) else (1152, 864)
    openDoc m (Doc.ofImage (testImage w h) "Background") s!"New {w}×{h}" s!"test-{w}x{h}"
  | .dragOver => (if m.dropping then m else { m with dropping := true }, .none)
  | .dragLeave => ({ m with dropping := false }, .none)
  | .setTool t => ({ m with tool := t, crop := if t == .crop then m.crop else none }, .none)
  | .brushSize n => ({ m with brush := { m.brush with size := max 1 n } }, .none)
  | .brushHardness n => ({ m with brush := { m.brush with hardness := n } }, .none)
  | .brushOpacity n => ({ m with brush := { m.brush with opacity := n } }, .none)
  | .brushColor hex => ({ m with brush := { m.brush with color := parseHex hex } }, .none)
  | .down p =>
    if busy m then (m, .none) else
    match m.doc with
    | none => (m, .none)
    | some d =>
      let m := { m with boxW := p.width }
      match m.tool with
      | .hand => ({ m with drag := some (p.clientX, p.clientY, m.panX, m.panY), zoom := some (currentZoom m) }, .none)
      | .crop => ({ m with cropFrom := some (docPoint d p), crop := none }, .none)
      | .brush | .eraser =>
        -- a pending preview is dropped: painting works on the layer as it is
        let (m, c) := if m.pending.isSome then refresh { m with pending := none } else (m, .none)
        let pt := docPoint d p
        let (m', c') := paintTo { m with stroke := some pt } p
        (m', .batch #[c, c'])
  | .move p =>
    match m.drag, m.cropFrom, m.stroke, m.doc with
    | some (x0, y0, px, py), _, _, _ =>
      if p.buttons &&& 1 == 0 then ({ m with drag := none }, .none)
      else ({ m with panX := px + p.clientX - x0, panY := py + p.clientY - y0 }, .none)
    | none, some a, _, some d =>
      if p.buttons &&& 1 == 0 then ({ m with cropFrom := none }, .none)
      else ({ m with crop := some (clampRect d a (docPoint d p)) }, .none)
    | none, none, some _, _ =>
      if p.buttons &&& 1 == 0 then (m, .none) else paintTo m p
    | _, _, _, _ => (m, .none)
  | .up _ =>
    if m.stroke.isSome then
      let m := { m with stroke := none }
      match m.doc with
      | some d =>
        let label := if m.tool == .eraser then "Eraser" else "Brush"
        let m := push m label (d.width * d.height * 4)
        ({ m with hist := histogram m.comp, compVersion := m.compVersion + 1 }, .none)
      | none => (m, .none)
    else ({ m with drag := none, cropFrom := none }, .none)
  | .wheel p =>
    if m.doc.isNone then (m, .none)
    else
      let f := Float.exp (-p.deltaY / 500)
      (zoomTo m (currentZoom { m with boxW := if m.zoom.isNone then p.width else m.boxW } * f), .none)
  | .zoomBy f => (zoomTo m (currentZoom m * f), .none)
  | .zoomFit => ({ m with zoom := none, panX := 0, panY := 0 }, .none)
  | .zoom100 =>
    match m.doc with
    | some d => (zoomTo m (Float.ofNat d.width / Float.ofNat d.pw), .none)
    | none => (m, .none)
  | .setAdjust a => refresh { m with adjust := a, pending := if a == {} then none else some .adjust }
  | .setBlur r => refresh { m with blurRadius := r, pending := some .blur }
  | .setSharpen a r => refresh { m with sharpAmount := a, sharpRadius := r, pending := some .sharpen }
  | .preview p => refresh { m with pending := some p }
  | .cancelPending => refresh { m with pending := none, adjust := {} }
  | .apply p => if busy m then (m, .none) else startJob { m with pending := some p } (p.op m)
  | .filter op => if busy m then (m, .none) else startJob { m with pending := none } op
  | .frame t =>
    -- take the job out of the model, so its buffers are written in place
    let (job?, m) := (m.job, { m with job := none })
    match job? with
    | none => (m, .none)
    | some job =>
      -- adapt the slice to the frame time: about 25 ms of work per frame
      let gap := t - m.lastFrame
      let budget := if m.lastFrame == 0 then m.budget
        else if gap > 40 then max 100000 (m.budget * 2 / 3)
        else if gap < 24 then min 50000000 (m.budget * 5 / 4) else m.budget
      let job := job.run budget
      match job.finished? with
      | none => ({ m with job := some job, budget, lastFrame := t }, .nextFrame .frame)
      | some result =>
        let m := { m with job := none, budget, lastFrame := 0, adjust := if m.pending == some .adjust then {} else m.adjust }
        match result, m.doc with
        | .layer id img, some d =>
          let (m, c) := commit m (d.setLayerImage id img) job.label (img.width * img.height * 4)
          ({ m with status := s!"{job.label} done" }, c)
        | .png bytes, _ =>
          ({ m with status := s!"Exported {m.fileName}.png ({bytes.size / 1024} KB)" },
           .download s!"{m.fileName}.png" "image/png" bytes)
        | _, none => (m, .none)
  | .geometry g =>
    match m.doc with
    | none => (m, .none)
    | some d =>
      if busy m then (m, .none) else
      let d := d.transform g
      let (m, c) := commit { m with crop := none } d g.label (d.layers.size * d.width * d.height * 4)
      ({ m with zoom := none, panX := 0, panY := 0 }, c)
  | .setResize w h =>
    match m.doc with
    | none => (m, .none)
    | some d =>
      if !m.keepRatio then ({ m with resizeW := w, resizeH := h }, .none)
      else if w != m.resizeW then ({ m with resizeW := w, resizeH := max 1 (w * d.height / max 1 d.width) }, .none)
      else ({ m with resizeH := h, resizeW := max 1 (h * d.width / max 1 d.height) }, .none)
  | .setKeepRatio b => ({ m with keepRatio := b }, .none)
  | .applyCrop =>
    match m.crop with
    | some r => if r.w > 0 && r.h > 0 then update (.geometry (.crop r)) m else (m, .none)
    | none => (m, .none)
  | .clearCrop => ({ m with crop := none }, .none)
  | .addLayer =>
    match m.doc with
    | some d =>
      let (d, id) := d.addLayer m.active
      let (m, c) := commit m d "New layer" (d.width * d.height * 4)
      ({ m with active := id }, c)
    | none => (m, .none)
  | .duplicateLayer =>
    match m.doc with
    | some d =>
      let (d, id) := d.duplicateLayer m.active
      let (m, c) := commit m d "Duplicate layer" 0
      ({ m with active := id }, c)
    | none => (m, .none)
  | .deleteLayer =>
    match m.doc with
    | some d => if d.layers.size ≤ 1 then (m, .none) else commit m (d.deleteLayer m.active) "Delete layer" 0
    | none => (m, .none)
  | .moveLayer up =>
    match m.doc with
    | some d => commit m (d.moveLayer m.active up) (if up then "Layer up" else "Layer down") 0
    | none => (m, .none)
  | .selectLayer id => (if m.active == id then m else { m with active := id, pending := none }, .none)
  | .toggleLayer id =>
    match m.doc with
    | some d => commit m (d.modifyLayer id fun l => { l with visible := !l.visible }) "Visibility" 0
    | none => (m, .none)
  | .layerOpacity n =>
    match m.doc with
    | some d => commit m (d.modifyLayer m.active fun l => { l with opacity := n }) "Layer opacity" 0
    | none => (m, .none)
  | .layerBlend b =>
    match m.doc with
    | some d => commit m (d.modifyLayer m.active fun l => { l with blend := Blend.ofName b }) "Blend mode" 0
    | none => (m, .none)
  | .startRename id => ({ m with renaming := some id }, .focus "#rename")
  | .rename id name =>
    match m.doc with
    | some d =>
      let name := name.trimAscii.toString
      if name.isEmpty then ({ m with renaming := none }, .none)
      else
        let (m, c) := commit { m with renaming := none } (d.modifyLayer id fun l => { l with name }) "Rename layer" 0
        (m, c)
    | none => (m, .none)
  | .stopRename => ({ m with renaming := none }, .none)
  | .jump i =>
    match m.history[i]? with
    | some s =>
      if busy m then (m, .none) else
      let active := if (s.doc.layerIndex? m.active).isSome then m.active else (s.doc.layers.back?.map (·.id)).getD 0
      let resized := match m.doc with | some d => d.width != s.doc.width || d.height != s.doc.height | none => true
      let m := { m with doc := some s.doc, cursor := i, active, pending := none, crop := none,
                        resizeW := s.doc.width, resizeH := s.doc.height }
      refresh (if resized then { m with zoom := none, panX := 0, panY := 0 } else m)
    | none => (m, .none)
  | .undo => if m.cursor > 0 then update (.jump (m.cursor - 1)) m else (m, .none)
  | .redo => if m.cursor + 1 < m.history.size then update (.jump (m.cursor + 1)) m else (m, .none)
  | .exportPng =>
    match m.doc with
    | some d => if busy m then (m, .none) else ({ m with job := some (Job.export d), status := "Exporting…", lastFrame := 0 }, .nextFrame .frame)
    | none => (m, .none)
  | .key k =>
    if k.cmd && (k.key == "z" || k.key == "Z") then update (if k.shift then .redo else .undo) m
    else if k.cmd && k.key == "y" then update .redo m
    else if k.cmd || k.alt then (m, .none)
    else match k.key with
      | "b" => update (.setTool .brush) m
      | "e" => update (.setTool .eraser) m
      | "h" | " " => update (.setTool .hand) m
      | "c" => update (.setTool .crop) m
      | "+" | "=" => update (.zoomBy 1.25) m
      | "-" => update (.zoomBy 0.8) m
      | "0" => update .zoomFit m
      | "1" => update .zoom100 m
      | "[" => update (.brushSize (m.brush.size * 4 / 5)) m
      | "]" => update (.brushSize (m.brush.size * 5 / 4 + 1)) m
      | "Enter" => if m.crop.isSome then update .applyCrop m else (m, .none)
      | "Escape" => if m.crop.isSome then update .clearCrop m else if m.pending.isSome then update .cancelPending m else (m, .none)
      | _ => (m, .none)

/-! ## View -/

def fmt1 (x : Float) : String :=
  let t := (x * 10).round
  let i := (if t < 0 then -t else t).toUInt64.toNat
  (if t < 0 then "-" else "") ++ s!"{i / 10}.{i % 10}"

def slider (label ident : String) (lo hi step v : Int) (shown : String) (f : Int → Msg) : Html Msg :=
  el "label" #[cls "row"] #[
    el "span" #[] #[text label],
    el "input" #[id ident, .attr "type" "range", .attr "min" (toString lo), .attr "max" (toString hi),
      .attr "step" (toString step), .prop "value" (.str (toString v)), onInput fun s => f (parseInt s)] #[],
    el "output" #[] #[text shown]]

def check (label ident : String) (v : Bool) (f : Bool → Msg) : Html Msg :=
  el "label" #[] #[el "input" #[id ident, .attr "type" "checkbox", .prop "checked" (.bool v), onCheck f] #[], text (" " ++ label)]

def button (label ident : String) (m : Msg) (disabled := false) (extra : Array (Attr Msg) := #[]) : Html Msg :=
  el "button" (#[id ident, onClick m, .prop "disabled" (.bool disabled)] ++ extra) #[text label]

def toolButton (cur t : Tool) (icon title : String) : Html Msg :=
  el "button" #[id s!"tool-{t.name}", .attr "title" title, cls (if cur == t then "on" else ""), onClick (.setTool t)] #[text icon]

def topbar (m : Model) : Html Msg :=
  let hasDoc := m.doc.isSome
  el "header" #[cls "topbar"] #[
    el "div" #[cls "brand"] #[el "a" #[.attr "href" "/"] #[text "LeanUI "], text "Photo ", el "small" #[] #[text "· pixels in Lean"]],
    el "label" #[cls "file-label"] #[
      el "button" #[.attr "tabindex" "-1"] #[text "Open…"],
      el "input" #[id "open", .attr "type" "file", .attr "accept" "image/*", .prop "value" (.str ""), onFiles .files] #[]],
    el "select" #[id "new", .prop "value" (.str ""), onChange fun s => .newImage (parseNat s)] #[
      el "option" #[.attr "value" ""] #[text "New test image…"],
      el "option" #[.attr "value" "1"] #[text "1 MP (1152×864)"],
      el "option" #[.attr "value" "4"] #[text "4 MP (2304×1728)"],
      el "option" #[.attr "value" "12"] #[text "12 MP (4000×3000)"]],
    button "Export PNG" "export" .exportPng (!hasDoc || busy m) #[cls "primary"],
    button "↶ Undo" "undo" .undo (m.cursor == 0 || busy m),
    button "↷ Redo" "redo" .redo (m.cursor + 1 ≥ m.history.size || busy m),
    el "span" #[cls "spacer"] #[],
    button "−" "zoom-out" (.zoomBy 0.8) (!hasDoc),
    el "span" #[id "zoom"] #[text (if hasDoc then s!"{(currentZoom m * 100).round.toUInt64}%" else "")],
    button "+" "zoom-in" (.zoomBy 1.25) (!hasDoc),
    button "Fit" "zoom-fit" .zoomFit (!hasDoc),
    el "span" #[id "status", cls "status"] #[text m.status]]

def options (m : Model) : Html Msg :=
  let b := m.brush
  el "div" #[cls "options"] (match m.tool with
    | .brush | .eraser => #[
        el "label" #[] #[text "Size", el "input" #[id "brush-size", .attr "type" "range", .attr "min" "1", .attr "max" "400",
          .prop "value" (.str (toString b.size)), onInput fun s => .brushSize (parseNat s)] #[], el "output" #[] #[text s!"{b.size}px"]],
        el "label" #[] #[text "Hardness", el "input" #[id "brush-hardness", .attr "type" "range", .attr "min" "0", .attr "max" "100",
          .prop "value" (.str (toString b.hardness)), onInput fun s => .brushHardness (parseNat s)] #[], el "output" #[] #[text s!"{b.hardness}%"]],
        el "label" #[] #[text "Opacity", el "input" #[id "brush-opacity", .attr "type" "range", .attr "min" "1", .attr "max" "100",
          .prop "value" (.str (toString b.opacity)), onInput fun s => .brushOpacity (parseNat s)] #[], el "output" #[] #[text s!"{b.opacity}%"]],
        if m.tool == .brush then
          el "label" #[] #[text "Colour", el "input" #[id "brush-color", .attr "type" "color", .prop "value" (.str (hexOf b.color)),
            onInput .brushColor] #[]]
        else el "span" #[cls "note"] #[text "The eraser makes the active layer transparent."]]
    | .hand => #[el "span" #[cls "note"] #[text "Drag to pan; the wheel zooms. Keys: + − 0 (fit) 1 (100%)."]]
    | .crop => #[
        el "span" #[cls "note"] #[text (match m.crop with
          | some r => s!"Crop to {r.w}×{r.h} at ({r.x}, {r.y})"
          | none => "Drag a rectangle on the image.")],
        button "Crop" "crop-apply" .applyCrop (m.crop.isNone || busy m) #[cls "primary"],
        button "Cancel" "crop-cancel" .clearCrop m.crop.isNone])

def tools (m : Model) : Html Msg :=
  el "nav" #[cls "tools"] #[
    toolButton m.tool .brush "🖌" "Brush (B)",
    toolButton m.tool .eraser "⌫" "Eraser (E)",
    toolButton m.tool .hand "✋" "Hand (H)",
    toolButton m.tool .crop "⛶" "Crop (C)"]

def stage (m : Model) (d : Doc) : Html Msg :=
  let pct (a b : Nat) : String := s!"{fmt1 (100 * Float.ofNat a / Float.ofNat (max 1 b))}%"
  let (cls', style) := match m.zoom with
    | none => ("stage fit", "")
    | some z =>
      ("stage zoomed", s!"width:{fmt1 (Float.ofNat d.pw * z)}px;height:{fmt1 (Float.ofNat d.ph * z)}px;transform:translate({fmt1 m.panX}px,{fmt1 m.panY}px)")
  el "div" #[cls s!"{cls'} t-{m.tool.name}", .attr "style" style] #[
    el "canvas" #[id "canvas", .attr "width" (toString d.pw), .attr "height" (toString d.ph),
      onPointer "pointerdown" (some ∘ .down) (capture := true) (preventDefault := true),
      onPointer "pointermove" (some ∘ .move),
      onPointer "pointerup" (some ∘ .up),
      onPointer "pointercancel" (some ∘ .up)] #[],
    match m.crop with
    | some r => el "div" #[id "crop-box", cls "crop", .attr "style"
        s!"left:{pct r.x d.width};top:{pct r.y d.height};width:{pct r.w d.width};height:{pct r.h d.height}"] #[]
    | none => el "div" #[.attr "hidden" ""] #[]]

def viewport (m : Model) : Html Msg :=
  el "section" #[id "viewport", cls (if m.dropping then "viewport drag" else "viewport"),
      onDragOver (some .dragOver), .on "dragleave" { decode := fun _ => some .dragLeave }, onDrop .files, onWheel (some ∘ .wheel)] #[
    match m.doc with
    | some d => stage m d
    | none => el "div" #[cls "empty"] #[
        el "h2" #[] #[text "LeanUI Photo"],
        el "p" #[] #[text "Drop an image here, use Open…, or make a test image."],
        el "p" #[] #[button "Make a 1 MP test image" "new-1" (.newImage 1)]],
    match m.job with
    | some j => el "div" #[id "busy", cls "busy"] #[
        text s!"{j.label}… {(j.progress * 100).round.toUInt64}%",
        el "div" #[cls "bar"] #[el "i" #[.attr "style" s!"width:{fmt1 (j.progress * 100)}%"] #[]]]
    | none => el "div" #[.attr "hidden" ""] #[]]

/-- The histogram as three SVG paths (red, green, blue) and the luminance. -/
def histogramView (h : Array Nat) : Html Msg :=
  if h.size < 1024 then el "svg" #[cls "hist"] #[] else
  let peak := Id.run do
    let mut p := 1
    for i in [0:1024] do p := max p h[i]!
    return p
  let path (ch : Nat) : String := Id.run do
    let mut s := "M0 100"
    for i in [0:256] do
      let v := h[ch * 256 + i]!
      s := s ++ s!" L{i} {100 - (100 * v / peak)}"
    return s ++ " L255 100 Z"
  svg "svg" #[id "histogram", cls "hist", .attr "viewBox" "0 0 256 100", .attr "preserveAspectRatio" "none"] #[
    svg "path" #[.attr "d" (path 3), .attr "fill" "rgba(220,220,220,.35)"] #[],
    svg "path" #[.attr "d" (path 0), .attr "fill" "none", .attr "stroke" "#e5646e", .attr "stroke-width" "1"] #[],
    svg "path" #[.attr "d" (path 1), .attr "fill" "none", .attr "stroke" "#5fd08a", .attr "stroke-width" "1"] #[],
    svg "path" #[.attr "d" (path 2), .attr "fill" "none", .attr "stroke" "#5f9bff", .attr "stroke-width" "1"] #[]]

def section (title ident : String) (open_ : Bool) (kids : Array (Html Msg)) : Html Msg :=
  el "details" (#[id ident] ++ (if open_ then #[.attr "open" ""] else #[])) #[
    el "summary" #[] #[text title], el "div" #[cls "sec"] kids]

def adjustPanel (a : AdjustUI) (pending : Bool) (dis : Bool) : Html Msg :=
  section "Adjustments" "adjust" true #[
    slider "Brightness" "adj-brightness" (-100) 100 1 a.brightness (toString a.brightness) fun v => .setAdjust { a with brightness := v },
    slider "Contrast" "adj-contrast" (-100) 100 1 a.contrast (toString a.contrast) fun v => .setAdjust { a with contrast := v },
    slider "Exposure" "adj-exposure" (-300) 300 5 a.exposure (fmt1 (Float.ofInt a.exposure / 100)) fun v => .setAdjust { a with exposure := v },
    slider "Saturation" "adj-saturation" (-100) 100 1 a.saturation (toString a.saturation) fun v => .setAdjust { a with saturation := v },
    slider "Hue" "adj-hue" (-180) 180 1 a.hue s!"{a.hue}°" fun v => .setAdjust { a with hue := v },
    slider "Black point" "adj-black" 0 254 1 a.black (toString a.black) fun v => .setAdjust { a with black := v.toNat },
    slider "White point" "adj-white" 1 255 1 a.white (toString a.white) fun v => .setAdjust { a with white := v.toNat },
    slider "Gamma" "adj-gamma" 10 300 1 a.gamma (fmt1 (Float.ofNat a.gamma / 100)) fun v => .setAdjust { a with gamma := v.toNat },
    slider "Shadows" "adj-shadows" (-64) 64 1 a.shadows (toString a.shadows) fun v => .setAdjust { a with shadows := v },
    slider "Midtones" "adj-midtones" (-64) 64 1 a.midtones (toString a.midtones) fun v => .setAdjust { a with midtones := v },
    slider "Highlights" "adj-highlights" (-64) 64 1 a.highlights (toString a.highlights) fun v => .setAdjust { a with highlights := v },
    el "div" #[cls "btns"] #[check "Invert" "adj-invert" a.invert fun b => .setAdjust { a with invert := b },
      check "Grayscale" "adj-grayscale" a.grayscale fun b => .setAdjust { a with grayscale := b }],
    el "div" #[cls "btns"] #[button "Apply" "adj-apply" (.apply .adjust) (!pending || dis) #[cls "primary"],
      button "Reset" "adj-reset" .cancelPending (!pending)]]

def filterPanel (m : Model) (dis : Bool) : Html Msg :=
  section "Filters" "filters" true #[
    slider "Blur radius" "blur-radius" 1 60 1 m.blurRadius (toString m.blurRadius) fun v => .setBlur v.toNat,
    el "div" #[cls "btns"] #[button "Apply blur" "blur-apply" (.apply .blur) dis #[cls "primary"]],
    slider "Sharpen" "sharpen-amount" 10 300 5 m.sharpAmount s!"{m.sharpAmount}%" fun v => .setSharpen v.toNat m.sharpRadius,
    slider "Radius" "sharpen-radius" 1 10 1 m.sharpRadius (toString m.sharpRadius) fun v => .setSharpen m.sharpAmount v.toNat,
    el "div" #[cls "btns"] #[button "Apply sharpen" "sharpen-apply" (.apply .sharpen) dis #[cls "primary"]],
    el "div" #[cls "btns"] #[button "Edge detect" "edges" (.filter .edges) dis, button "Emboss" "emboss" (.filter .emboss) dis,
      button "Cancel preview" "filter-cancel" .cancelPending (m.pending.isNone || m.pending == some .adjust)]]

def transformPanel (m : Model) (dis : Bool) : Html Msg :=
  section "Transform" "transform" false #[
    el "div" #[cls "btns"] #[button "⟲ 90°" "rot-ccw" (.geometry .rotCCW) dis, button "⟳ 90°" "rot-cw" (.geometry .rotCW) dis,
      button "180°" "rot-180" (.geometry .rot180) dis, button "Flip ⇆" "flip-h" (.geometry .flipH) dis,
      button "Flip ⇅" "flip-v" (.geometry .flipV) dis],
    el "div" #[cls "btns"] #[
      el "input" #[id "resize-w", .attr "type" "number", .attr "min" "1", .prop "value" (.str (toString m.resizeW)),
        onChange fun s => .setResize (parseNat s) m.resizeH] #[],
      text "×",
      el "input" #[id "resize-h", .attr "type" "number", .attr "min" "1", .prop "value" (.str (toString m.resizeH)),
        onChange fun s => .setResize m.resizeW (parseNat s)] #[],
      check "keep ratio" "resize-ratio" m.keepRatio .setKeepRatio,
      button "Resize" "resize" (.geometry (.resize m.resizeW m.resizeH)) (dis || m.resizeW == 0 || m.resizeH == 0)]]

def layerRow (active renaming : Bool) (l : Layer) : Html Msg :=
  el "li" #[.key (toString l.id), id s!"layer-{l.id}", cls (if active then "active" else ""), onClick (.selectLayer l.id)] #[
    el "input" #[.attr "type" "checkbox", .attr "title" "Visible", .prop "checked" (.bool l.visible),
      .on "click" { decode := fun _ => none, stopPropagation := true },
      .on "change" { payload := .checked, decode := fun _ => some (.toggleLayer l.id) }] #[],
    el "span" #[cls "name", .on "dblclick" { decode := fun _ => some (.startRename l.id) }] #[
      if renaming then
        el "input" #[id "rename", .attr "type" "text", .prop "value" (.str l.name),
          .on "keydown" { payload := .value, decode := fun _ => none },
          .on "change" { payload := .value, decode := fun s => some (.rename l.id s) },
          .on "focusout" { decode := fun _ => some .stopRename }] #[]
      else text l.name],
    el "span" #[cls "meta"] #[text s!"{l.opacity}% {l.blend.name}"]]

def layersPanel (d : Doc) (active : Nat) (renaming : Option Nat) (dis : Bool) : Html Msg :=
  let cur := d.layers.find? (·.id == active)
  section "Layers" "layers" true #[
    el "ul" #[cls "layers"] (d.layers.reverse.map fun l =>
      keyedMemo (toString l.id) (l.id == active, renaming == some l.id, l.name, l.visible, l.opacity, l.blend.name)
        fun _ => layerRow (l.id == active) (renaming == some l.id) l),
    match cur with
    | some l => el "div" #[cls "sec", .attr "style" "padding:0"] #[
        slider "Opacity" "layer-opacity" 0 100 1 l.opacity s!"{l.opacity}%" fun v => .layerOpacity v.toNat,
        el "label" #[cls "row"] #[el "span" #[] #[text "Blend"],
          el "select" #[id "layer-blend", .prop "value" (.str l.blend.name), onChange .layerBlend]
            (Blend.all.map fun b => el "option" #[.attr "value" b.name] #[text b.name]), el "span" #[] #[]]]
    | none => el "div" #[] #[],
    el "div" #[cls "btns"] #[button "+ Layer" "layer-add" .addLayer dis, button "Duplicate" "layer-dup" .duplicateLayer dis,
      button "Delete" "layer-delete" .deleteLayer (dis || d.layers.size ≤ 1),
      button "↑" "layer-up" (.moveLayer true) dis, button "↓" "layer-down" (.moveLayer false) dis]]

def historyPanel (labels : Array String) (cursor : Nat) : Html Msg :=
  section "History" "history" true #[
    el "ol" #[cls "history"] (labels.mapIdx fun i l =>
      keyedMemo (toString i) (l, if i < cursor then 0 else if i == cursor then 1 else 2) fun _ =>
        el "li" #[id s!"step-{i}", cls (if i == cursor then "current" else if i > cursor then "future" else ""), onClick (.jump i)] #[
          el "span" #[cls "n"] #[text (toString (i + 1))], text l])]

def view (m : Model) : Html Msg :=
  let dis := busy m || m.doc.isNone
  el "div" #[cls "editor"] #[
    topbar m,
    options m,
    tools m,
    viewport m,
    el "aside" #[cls "side"] #[
      section "Histogram" "histo" true #[memo m.compVersion fun _ => histogramView m.hist],
      memo (m.adjust, m.pending == some .adjust, dis) fun (a, p, dis) => adjustPanel a p dis,
      filterPanel m dis,
      transformPanel m dis,
      match m.doc with
      | some d => layersPanel d m.active m.renaming dis
      | none => el "div" #[] #[],
      memo (m.history.map (·.label), m.cursor) fun (ls, c) => historyPanel ls c]]

def program : Program Model Msg where
  init _ := ({}, .none)
  update := update
  view := view
  subscriptions _ := .keys fun s => some (.key (Keys.parse s))

end Editor
