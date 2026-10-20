module
public import Editor.Image
/-!
# Painting: round soft brushes

A dab is a disc of radius `r` centred at `(cx, cy)` (pixel centres are at `x + ½`). Its strength at
distance `d` is `opacity · falloff(d) · edge(d)`:

* `falloff` is 1 up to `hardness · r` and then falls smoothly to 0 at `r` (`1 − smoothstep`),
  measured from the pixel's near side (`d − ½`), so that a brush narrower than a pixel still
  paints the pixels around its centre;
* `edge` is the pixel's coverage of the disc's rim, `clamp (r + ½ − d) 0 1`, which anti-aliases
  hard brushes.

Paint is composited source-over (straight alpha) with the colour's alpha times the strength;
erasing multiplies the pixel's alpha by `1 − strength`. A dab works in place on a unique image
and returns the rectangle it may have changed (`dab`'s `Rect`), which is what the app has to send
to the canvas. `stroke` places dabs every `max 1 (radius / 4)` pixels along a segment.
-/
public section
namespace Editor

structure Brush where
  radius : Float := 8
  /-- 0..1: the fraction of the radius painted at full strength. -/
  hardness : Float := 0.5
  /-- 0..1. -/
  opacity : Float := 1
  color : Color := ⟨0, 0, 0, 255⟩
  erase : Bool := false
  deriving Inhabited

/-- `1 / 255`. -/
def fInv255 : Float := 1 / 255

/-- Pixels `x .. x1 - 1` of row `y` of a dab (`w` is the image width; `dy2` the row's squared
vertical distance). `ca` is the colour's alpha times the opacity (0..1). -/
partial def dabRow (d : ByteArray) (w x x1 y : USize) (cx dy2 r inner span ca cr cg cb : Float) (erase : Bool) :
    ByteArray :=
  if x < x1 then
    let dx := x.toUInt64.toFloat + fHalf - cx
    let dist := Float.sqrt (dx * dx + dy2)
    let edge := r + fHalf - dist
    if edge ≤ 0 then dabRow d w (x + 1) x1 y cx dy2 r inner span ca cr cg cb erase
    else
      let edge := if edge > 1 then 1 else edge
      let near := dist - fHalf
      let fall :=
        if near ≤ inner then 1
        else
          let t := (near - inner) / span
          let t := if t > 1 then 1 else t
          1 - t * t * (3 - 2 * t)
      let s := ca * fall * edge
      let o := 4 * (y * w + x)
      if s ≤ 0 then dabRow d w (x + 1) x1 y cx dy2 r inner span ca cr cg cb erase
      else if h : InPx d o then
        let v := get32 d o h
        let ab := (v >>> 24).toFloat * fInv255
        let v' :=
          if erase then (v &&& (0xffffff : UInt32)) ||| ((toByte (ab * (1 - s) * f255)).toUInt32 <<< 24)
          else
            let ao := s + ab * (1 - s)
            let kb := ab * (1 - s) / ao
            let ks := s / ao
            (toByte (ks * cr + kb * (v &&& (255 : UInt32)).toFloat)).toUInt32 |||
              ((toByte (ks * cg + kb * ((v >>> 8) &&& (255 : UInt32)).toFloat)).toUInt32 <<< 8) |||
              ((toByte (ks * cb + kb * ((v >>> 16) &&& (255 : UInt32)).toFloat)).toUInt32 <<< 16) |||
              ((toByte (ao * f255)).toUInt32 <<< 24)
        dabRow (set32 d o v' h) w (x + 1) x1 y cx dy2 r inner span ca cr cg cb erase
      else d
  else d

partial def dabRows (d : ByteArray) (w x0 x1 y y1 : USize) (cx cy r inner span ca cr cg cb : Float) (erase : Bool) :
    ByteArray :=
  if y < y1 then
    let dy := y.toUInt64.toFloat + fHalf - cy
    dabRows (dabRow d w x0 x1 y cx (dy * dy) r inner span ca cr cg cb erase) w x0 x1 (y + 1) y1 cx cy r inner
      span ca cr cg cb erase
  else d

/-- `⌊v⌋` clamped to `0 .. n`. -/
def floorClamp (v : Float) (n : Nat) : Nat :=
  if v ≤ 0 then 0 else min n v.floor.toUInt64.toNat

/-- `⌈v⌉` clamped to `0 .. n`. -/
def ceilClamp (v : Float) (n : Nat) : Nat :=
  if v ≤ 0 then 0 else min n v.ceil.toUInt64.toNat

/-- The pixels a dab at `(cx, cy)` of radius `radius` can touch, clamped to the image. -/
def dabRect (w h : Nat) (cx cy radius : Float) : Rect :=
  let r := (if radius > 0 then radius else 0) + fHalf
  Rect.ofBounds (floorClamp (cx - r) w) (floorClamp (cy - r) h) (ceilClamp (cx + r) w) (ceilClamp (cy + r) h)

/-- Paint (or, with `erase`, erase) one round dab in place. `hardness` and `opacity` are 0..1.
Returns the image and the rectangle that contains every changed pixel. -/
def dab (img : Image) (cx cy radius hardness opacity : Float) (color : Color) (erase : Bool := false) :
    Image × Rect :=
  let clamp01 (v : Float) : Float := if v < 0 then 0 else if v > 1 then 1 else v
  let rect := dabRect img.width img.height cx cy radius
  let opacity := clamp01 opacity
  if rect.isEmpty || !(radius > 0) || opacity == 0 then (img, Rect.empty)
  else
    let hardness := clamp01 hardness
    let inner := hardness * radius
    let span := radius - inner
    let span := if span > 0 then span else 1
    let ca := if erase then opacity else opacity * color.a.toFloat * fInv255
    let ⟨w, h, d⟩ := img
    let d := dabRows d w.toUSize rect.x.toUSize rect.right.toUSize rect.y.toUSize rect.bottom.toUSize cx cy radius
      inner span ca color.r.toFloat color.g.toFloat color.b.toFloat erase
    (⟨w, h, d⟩, rect)

/-- A dab with `brush`. -/
def Brush.dab (b : Brush) (img : Image) (cx cy : Float) : Image × Rect :=
  Editor.dab img cx cy b.radius b.hardness b.opacity b.color b.erase

private partial def strokeLoop (b : Brush) (img : Image) (x0 y0 dx dy : Float) (i n : Nat) (acc : Rect) : Image × Rect :=
  if i > n then (img, acc)
  else
    let t := Float.ofNat i / Float.ofNat n
    let (img, r) := b.dab img (x0 + dx * t) (y0 + dy * t)
    strokeLoop b img x0 y0 dx dy (i + 1) n (acc.union r)

/-- Dabs from `(x0, y0)` to `(x1, y1)`, every `max 1 (radius / 4)` pixels (both ends included;
with `skipFirst`, the first dab is left out, so consecutive segments of a stroke do not paint
their shared point twice). Returns the image and the union of the dabs' rectangles. -/
def stroke (img : Image) (x0 y0 x1 y1 : Float) (b : Brush) (skipFirst : Bool := false) : Image × Rect :=
  let dx := x1 - x0
  let dy := y1 - y0
  let len := Float.sqrt (dx * dx + dy * dy)
  let spacing := max 1 (b.radius / 4)
  let n := (len / spacing).ceil.toUInt64.toNat
  if n == 0 then
    if skipFirst then (img, Rect.empty) else b.dab img x0 y0
  else strokeLoop b img x0 y0 dx dy (if skipFirst then 1 else 0) n Rect.empty

end Editor
