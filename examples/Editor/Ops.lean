module
public import Editor.Doc
/-!
# Operations and jobs

An `Op` is what the adjustments and filters panels apply to the active layer. `Op.preview` runs
it on a preview image (radii scaled to the preview), in one go: previews are small. On apply it
runs on the full-resolution layer as a `Job`: a few passes over rows (a blur is a horizontal and
a vertical pass), done a slice of rows at a time (`Job.run budget` does about `budget` pixels of
work), so the editor can spread a 12-megapixel operation over animation frames and stay
responsive. A job's `budget` counts work units: a pixel of a pass costs `Job.cost` of them (a blur
pass costs more per pixel the larger its radius), so one budget suits every operation. Export is a
job too: the layers composited at full resolution, row slices again,
then the PNG encoding in one step.
-/
public section
namespace Editor

inductive Op where
  | adjust (a : Adjust)
  /-- Gaussian blur, radius in document pixels. -/
  | blur (radius : Nat)
  /-- Unsharp mask: amount in percent, radius in document pixels. -/
  | sharpen (amount radius : Nat)
  | edges
  | emboss
  deriving Inhabited

def Op.label : Op → String
  | .adjust _ => "Adjustments" | .blur r => s!"Blur {r}px" | .sharpen a r => s!"Sharpen {a}% {r}px"
  | .edges => "Edge detect" | .emboss => "Emboss"

/-- The operation on a preview image whose pixels are `scale` document pixels wide. A blur of a
radius of 2 preview pixels or more is previewed on a half-size proxy (downscaled, blurred at half
the radius, scaled back up): an eighth of the work, and a blur hides the lost resolution. Apply
runs the exact operation at full resolution. -/
def Op.preview (op : Op) (scale : Float) (img : Image) : Image :=
  match op with
  | .adjust a => Adjust.apply a img
  | .blur r =>
    let pr := max 0.5 (Float.ofNat r * scale)
    if pr ≥ 2 && img.width ≥ 4 && img.height ≥ 4 then
      let small := downscaleBox img (img.width / 2) (img.height / 2)
      resize (Editor.blur small (pr / 2)) img.width img.height
    else Editor.blur img pr
  | .sharpen a r => Editor.sharpen img (Float.ofNat a / 100) (max 0.5 (Float.ofNat r * scale))
  | .edges => Editor.edgeDetect img
  | .emboss => Editor.emboss img

/-- What a finished job produced: a layer's new image and, for a layer larger than a preview,
its new preview (made by the job's last pass); a transformed document; or the bytes of an export. -/
inductive JobResult where
  | layer (id : Nat) (img : Image) (prev : Option Image)
  | doc (d : Doc)
  | png (bytes : ByteArray)

inductive JobKind where
  | layer (op : Op) (id : Nat)
  /-- A geometric operation on every layer of `doc`. -/
  | geo (g : Geo) (doc : Doc)
  | export (layers : Array Layer)
  deriving Inhabited

/-- Work in progress: pass `pass` of `passes`, next row `row`. The buffers are fields so that a
job updates them in place (it is taken apart before each slice). -/
structure Job where
  label : String
  kind : JobKind
  passes : Nat
  pass : Nat := 0
  row : Nat := 0
  /-- The size of the operation's output. -/
  width : Nat
  height : Nat
  /-- Work units per pixel of an operation pass. -/
  cost : Nat := 1
  /-- The preview size, when the job ends a layer with a pass that remakes its preview. -/
  prevSize : Option (Nat × Nat) := none
  src : Image := default
  /-- First intermediate: the horizontal blur, or the output of a one-pass operation. -/
  a : Image := default
  /-- Second intermediate: the vertical blur. -/
  b : Image := default
  /-- The new preview. -/
  p : Image := default
  /-- Export: the PNG encoding in progress. -/
  enc : Option Png.Encoder := none
  /-- Geometry: each layer's new image and preview, so far. -/
  outs : Array (Image × Option Image) := #[]
  result : Option JobResult := none
  deriving Inhabited

instance : Inhabited JobResult := ⟨.png .empty⟩

/-- Passes of the operation itself. -/
def Op.passes : Op → Nat
  | .blur _ => 2 | .sharpen .. => 3 | _ => 1

/-- The preview size for an image, when it needs a preview. -/
def previewOf (w h : Nat) : Option (Nat × Nat) :=
  let (pw, ph) := previewSize w h
  if pw == w && ph == h then none else some (pw, ph)

/-- A job applying `op` to layer `id`'s image; `prevSize`: the document's preview size, when the
layer needs a preview. -/
def Job.layer (op : Op) (id : Nat) (img : Image) (prevSize : Option (Nat × Nat) := none) : Job :=
  let cost := match op with
    | .adjust a => if a.saturation == 0 && a.hue == 0 && !a.grayscale then 1 else 3
    | .blur r | .sharpen _ r => 2 + r
    | .edges | .emboss => 4
  let prevSize := prevSize.filter fun (pw, ph) => pw != img.width || ph != img.height
  { label := op.label, kind := .layer op id, passes := op.passes + (if prevSize.isSome then 1 else 0), cost,
    width := img.width, height := img.height, prevSize, src := img, a := Image.blank img.width img.height,
    b := if op.passes ≥ 2 then Image.blank img.width img.height else default }

/-- A geometric operation on every layer, a pass of output rows per layer (and one for its
preview when the result is larger than a preview). -/
def Job.geo (g : Geo) (d : Doc) : Job :=
  let (w, h) := g.outSize d.width d.height
  let prevSize := previewOf w h
  { label := g.label, kind := .geo g d, passes := d.layers.size * (if prevSize.isSome then 2 else 1),
    cost := 2, width := w, height := h, prevSize }

/-- Export: the visible layers composited at full resolution (a pass each), then the PNG encoding
(a pass of rows). -/
def Job.export (d : Doc) : Job :=
  let ls := d.layers.filter fun l => l.visible && l.opacity > 0 && !l.blank
  { label := "Export", kind := .export ls, passes := ls.size + 1, cost := 3, width := d.width, height := d.height,
    a := Image.blank d.width d.height }

def Job.finished? (j : Job) : Option JobResult := j.result

/-- The image a layer job's operation passes leave. -/
def Job.output (j : Job) : Image :=
  match j.kind with
  | .layer (.blur _) _ => j.b
  | _ => j.a

/-- What pass `p` is: for a layer or geometry job, whether it remakes a preview (and for geometry,
the layer it works on). -/
def Job.previewPass (j : Job) (p : Nat) : Bool :=
  match j.kind with
  | .layer op _ => j.prevSize.isSome && p == op.passes
  | .geo _ _ => j.prevSize.isSome && p % 2 == 1
  | .export _ => false

def Job.layerOf (j : Job) (p : Nat) : Nat := if j.prevSize.isSome then p / 2 else p

/-- Width, height (rows to do) and work units per pixel of pass `p`. -/
def Job.dims (j : Job) (p : Nat) : Nat × Nat × Nat :=
  match j.prevSize with
  | some (pw, ph) =>
    if j.previewPass p then (pw, ph, 1 + (j.width * j.height) / max 1 (pw * ph)) else (j.width, j.height, j.cost)
  | none =>
    match j.kind with
    | .export ls => if p == ls.size then (j.width, j.height, 8) else (j.width, j.height, j.cost)
    | _ => (j.width, j.height, j.cost)

/-- Fraction done. -/
def Job.progress (j : Job) : Float :=
  (Float.ofNat j.pass + Float.ofNat j.row / Float.ofNat (max 1 (j.dims j.pass).2.1)) / Float.ofNat (max 1 j.passes)

/-- Set a pass up at its first row: allocate its output, or start the encoder. -/
def Job.begin (j : Job) : Job :=
  if j.previewPass j.pass then
    match j.prevSize with
    | some (pw, ph) => { j with p := Image.blank pw ph }
    | none => j
  else match j.kind with
    | .geo _ _ => { j with a := Image.blank j.width j.height }
    | .export ls => if j.pass == ls.size then { j with enc := some (Png.Encoder.start j.a 1) } else j
    | .layer .. => j

/-- Rows `[y0, y1)` of the current pass. -/
def Job.slice (j : Job) (y0 y1 : Nat) : Job :=
  let preview := j.previewPass j.pass
  let li := j.layerOf j.pass
  match j with
  | { label, kind, passes, pass, row, width, height, cost, prevSize, src, a, b, p, enc, outs, result } =>
    let (a, b, p, enc) := if preview then
        -- the preview, from the operation's output (`b` after a blur, else `a`)
        match kind with
        | .layer (.blur _) _ => (a, b, downscaleBoxRows b p y0 y1, enc)
        | _ => (a, b, downscaleBoxRows a p y0 y1, enc)
      else match kind, pass with
      | .layer (.adjust adj) _, _ => (Adjust.applyRows adj src a y0 y1, b, p, enc)
      | .layer (.blur r) _, 0 => (blurHRows (Float.ofNat r) src a y0 y1, b, p, enc)
      | .layer (.blur r) _, _ => (a, blurVRows (Float.ofNat r) a b y0 y1, p, enc)
      | .layer (.sharpen _ r) _, 0 => (blurHRows (Float.ofNat r) src a y0 y1, b, p, enc)
      | .layer (.sharpen _ r) _, 1 => (a, blurVRows (Float.ofNat r) a b y0 y1, p, enc)
      -- the horizontal blur is no longer needed: the sharpened rows go there
      | .layer (.sharpen amt _) _, _ => (sharpenRows (Float.ofNat amt / 100) 0 src b a y0 y1, b, p, enc)
      | .layer .edges _, _ => (edgeDetectRows src a y0 y1, b, p, enc)
      | .layer .emboss _, _ => (convolveRows Kernel3.emboss src a y0 y1, b, p, enc)
      | .geo g d, _ => match d.layers[li]? with
        | some l => (g.rows l.img a y0 y1, b, p, enc)
        | none => (a, b, p, enc)
      -- as `Doc.flatten`: a normal bottom layer at full opacity is copied
      | .export ls, q => match ls[q]?, enc with
        | some l, _ =>
          if q == 0 && l.opacity == 100 && l.blend == .normal then (Doc.copyRows l.img a y0 y1, b, p, enc)
          else (compositeRows a l.img l.opacity l.blend y0 y1, b, p, enc)
        | none, some e => (a, b, p, some (e.step (y1 - y0)))
        | none, none => (a, b, p, enc)
    { label, kind, passes, pass, row, width, height, cost, prevSize, src, a, b, p, enc, outs, result }

/-- Finish a pass: collect a geometry layer's results; at the end of the job, the result. -/
def Job.endPass (j : Job) : Job :=
  let j := match j.kind with
    | .geo _ _ =>
      -- the layer's last pass: keep its image (and preview)
      if !j.prevSize.isSome || j.previewPass j.pass then
        let prev := if j.prevSize.isSome then some j.p else none
        { j with outs := j.outs.push (j.a, prev), a := default, p := default }
      else j
    | _ => j
  let j := { j with pass := j.pass + 1, row := 0 }
  if j.pass < j.passes then j else
  match j.kind with
  | .layer _ id =>
    let out := j.output
    let prev := if j.prevSize.isSome then some j.p else none
    { j with result := some (.layer id out prev), a := default, b := default, p := default, src := default }
  | .geo _ d =>
    let (pw, ph) := previewSize j.width j.height
    let layers := d.layers.mapIdx fun i l => match j.outs[i]? with
      | some (img, prev) => { l with img, prev }
      | none => l
    { j with result := some (.doc { d with width := j.width, height := j.height, pw, ph, layers }), outs := #[] }
  | .export _ =>
    match j.enc with
    | some e => { j with result := some (.png e.finish), enc := none, a := default }
    | none => j

/-- Do about `budget` work units (at least one row). -/
partial def Job.run (j : Job) (budget : Nat) : Job :=
  if j.result.isSome || j.pass ≥ j.passes then j else
  let (w, h, cost) := j.dims j.pass
  let j := if j.row == 0 then j.begin else j
  let n := max 1 (budget / max 1 (w * cost))
  let y1 := min h (j.row + n)
  let done := y1 - j.row
  let j := j.slice j.row y1
  let j := if y1 ≥ h then j.endPass else { j with row := y1 }
  if j.result.isNone && budget > done * w * cost then j.run (budget - done * w * cost) else j

end Editor
