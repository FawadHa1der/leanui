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

/-- What a finished job produced. -/
inductive JobResult where
  | layer (id : Nat) (img : Image)
  | png (bytes : ByteArray)

inductive JobKind where
  | layer (op : Op) (id : Nat)
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
  width : Nat
  height : Nat
  /-- Work units per pixel of a pass. -/
  cost : Nat := 1
  src : Image
  /-- First intermediate: the horizontal blur, or the output of a one-pass operation. -/
  a : Image
  /-- Second intermediate: the vertical blur. -/
  b : Image := default
  result : Option JobResult := none
  deriving Inhabited

instance : Inhabited JobResult := ⟨.png .empty⟩

def Job.layer (op : Op) (id : Nat) (img : Image) : Job :=
  let passes := match op with | .blur _ => 2 | .sharpen .. => 3 | _ => 1
  let cost := match op with
    | .adjust a => if a.saturation == 0 && a.hue == 0 && !a.grayscale then 1 else 3
    | .blur r | .sharpen _ r => 2 + r
    | .edges | .emboss => 4
  { label := op.label, kind := .layer op id, passes, cost, width := img.width, height := img.height,
    src := img, a := Image.blank img.width img.height,
    b := if passes ≥ 2 then Image.blank img.width img.height else default }

def Job.export (d : Doc) : Job :=
  let ls := d.layers.filter fun l => l.visible && l.opacity > 0 && !l.blank
  { label := "Export", kind := .export ls, passes := ls.size + 1, cost := 3, width := d.width, height := d.height,
    src := default, a := Image.blank d.width d.height }

/-- Fraction done. -/
def Job.progress (j : Job) : Float :=
  (Float.ofNat j.pass + Float.ofNat j.row / Float.ofNat (max 1 j.height)) / Float.ofNat (max 1 j.passes)

def Job.finished? (j : Job) : Option JobResult := j.result

/-- Rows `[y0, y1)` of the current pass. -/
def Job.slice (j : Job) (y0 y1 : Nat) : Job :=
  match j with
  | { label, kind, passes, pass, row, width, height, cost, src, a, b, result } =>
    let (a, b) := match kind, pass with
      | .layer (.adjust adj) _, _ => (Adjust.applyRows adj src a y0 y1, b)
      | .layer (.blur r) _, 0 => (blurHRows (Float.ofNat r) src a y0 y1, b)
      | .layer (.blur r) _, _ => (a, blurVRows (Float.ofNat r) a b y0 y1)
      | .layer (.sharpen _ r) _, 0 => (blurHRows (Float.ofNat r) src a y0 y1, b)
      | .layer (.sharpen _ r) _, 1 => (a, blurVRows (Float.ofNat r) a b y0 y1)
      -- the horizontal blur is no longer needed: the sharpened rows go there
      | .layer (.sharpen amt _) _, _ => (sharpenRows (Float.ofNat amt / 100) 0 src b a y0 y1, b)
      | .layer .edges _, _ => (edgeDetectRows src a y0 y1, b)
      | .layer .emboss _, _ => (convolveRows Kernel3.emboss src a y0 y1, b)
      -- as `Doc.flatten`: a normal bottom layer at full opacity is copied
      | .export ls, p => match ls[p]? with
        | some l =>
          if p == 0 && l.opacity == 100 && l.blend == .normal then (Doc.copyRows l.img a y0 y1, b)
          else (compositeRows a l.img l.opacity l.blend y0 y1, b)
        | none => (a, b)
    { label, kind, passes, pass, row, width, height, cost, src, a, b, result }

/-- The image a finished layer job leaves. -/
def Job.output (j : Job) : Image :=
  match j.kind with
  | .layer (.blur _) _ => j.b
  | _ => j.a

/-- Do about `budget` pixels of work (at least one row). -/
partial def Job.run (j : Job) (budget : Nat) : Job :=
  if j.result.isSome then j else
  if j.pass ≥ j.passes then j else
  match j.kind with
  | .export ls =>
    if j.pass == ls.size then
      -- the last pass: encode
      let png := Png.encode j.a
      { j with pass := j.passes, row := 0, result := some (.png png), a := default }
    else rows j budget
  | .layer _ _ => rows j budget
where
  rows (j : Job) (budget : Nat) : Job :=
    let n := max 1 (budget / max 1 (j.width * j.cost))
    let y1 := min j.height (j.row + n)
    let j := j.slice j.row y1
    let done := y1 - j.row
    let j := if y1 ≥ j.height then { j with pass := j.pass + 1, row := 0 } else { j with row := y1 }
    if j.pass ≥ j.passes then
      match j.kind with
      | .layer _ id =>
        let out := j.output
        { j with result := some (.layer id out), a := default, b := default, src := default }
      | .export _ => j
    else if j.pass == j.passes - 1 && (match j.kind with | .export _ => true | _ => false) then j
    else if budget > done * j.width * j.cost then j.run (budget - done * j.width * j.cost) else j

end Editor
