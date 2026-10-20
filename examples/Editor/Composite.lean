module
public import Editor.Image
/-!
# Compositing layers

`compositeRows dst top opacity blend y0 y1` draws `top` over `dst` (same size), in place on `dst`,
with the W3C *Compositing and Blending* model on straight alpha: the source colour is first mixed
with the blend result where the backdrop is present, `Cs' = (1 − αb)·Cs + αb·B(Cb, Cs)`, then
composited source-over: `αo = αs + αb(1 − αs)`, `Co = (αs·Cs' + αb(1 − αs)·Cb) / αo`, where
`αs` is the top pixel's alpha times `opacity` (0..100).

All of it is integer arithmetic on 0..255 values, exact for the cases that matter: a fully
transparent top pixel (or opacity 0) leaves the backdrop pixel untouched, and an opaque top pixel
in `normal` mode replaces it exactly. Where the result is opaque (the usual case: an opaque
backdrop), the division by `αo` is a division by a constant.
-/
public section
namespace Editor

inductive Blend
  | normal | multiply | screen | overlay | darken | lighten | add | difference
  deriving BEq, Repr, Inhabited, DecidableEq

namespace Blend
def all : Array Blend := #[.normal, .multiply, .screen, .overlay, .darken, .lighten, .add, .difference]

def name : Blend → String
  | .normal => "normal" | .multiply => "multiply" | .screen => "screen" | .overlay => "overlay"
  | .darken => "darken" | .lighten => "lighten" | .add => "add" | .difference => "difference"
end Blend

/-! The blend functions `B(Cb, Cs)` on 0..255 values (`add` is linear dodge, clamped). -/
@[inline] def bNormal (_cb cs : UInt32) : UInt32 := cs
@[inline] def bMultiply (cb cs : UInt32) : UInt32 := div255 (cb * cs)
@[inline] def bScreen (cb cs : UInt32) : UInt32 := cb + cs - div255 (cb * cs)
/-- Hard light with the layers swapped: multiply or screen by the backdrop. -/
@[inline] def bOverlay (cb cs : UInt32) : UInt32 :=
  if 2 * cb ≤ 255 then div255 (2 * cb * cs) else 255 - div255 (2 * (255 - cb) * (255 - cs))
@[inline] def bDarken (cb cs : UInt32) : UInt32 := if cb < cs then cb else cs
@[inline] def bLighten (cb cs : UInt32) : UInt32 := if cb < cs then cs else cb
@[inline] def bAdd (cb cs : UInt32) : UInt32 := clamp255 (cb + cs)
@[inline] def bDifference (cb cs : UInt32) : UInt32 := if cb < cs then cs - cb else cb - cs

/-- The blend function of a mode. -/
def blendCh : Blend → UInt32 → UInt32 → UInt32
  | .normal => bNormal | .multiply => bMultiply | .screen => bScreen | .overlay => bOverlay
  | .darken => bDarken | .lighten => bLighten | .add => bAdd | .difference => bDifference

/-- One colour channel of the composite: `as`, `ab` alphas (0..255), `ao2 = αo · 255²`. -/
@[inline] def compCh (bf : UInt32 → UInt32 → UInt32) (cb cs as ab ao2 : UInt32) : UInt32 :=
  let csp := (255 - ab) * cs + ab * bf cb cs                 -- Cs' · 255
  let num := as * csp + ab * (255 - as) * cb                 -- Co · αo · 255²
  if ao2 == 65025 then clamp255 ((num + 32512) / 65025) else clamp255 ((num + ao2 / 2) / ao2)

/-- Composite bytes `i .. n - 1` of `top` over `d` in place. `op` is the opacity × 255 / 100.
The blend function is a parameter that is specialized away: one loop per blend mode, with no
dispatch per channel. -/
@[specialize] partial def compLoop (bf : UInt32 → UInt32 → UInt32) (top : @& ByteArray) (d : ByteArray) (op : UInt32)
    (i n : USize) : ByteArray :=
  if i < n then
    if ht : InPx top i then
      let t := get32 top i ht
      let as := div255 ((t >>> 24) * op)
      if as == 0 then compLoop bf top d op (i + 4) n
      else if h : InPx d i then
        let v := get32 d i h
        let ab := v >>> 24
        let ao2 := as * 255 + ab * (255 - as)
        let w := compCh bf (v &&& 255) (t &&& 255) as ab ao2 |||
          (compCh bf ((v >>> 8) &&& 255) ((t >>> 8) &&& 255) as ab ao2 <<< 8) |||
          (compCh bf ((v >>> 16) &&& 255) ((t >>> 16) &&& 255) as ab ao2 <<< 16) ||| (div255 ao2 <<< 24)
        compLoop bf top (set32 d i w h) op (i + 4) n
      else d
    else d
  else d

/-- Draw rows `y0 .. y1 - 1` of `top` over the same rows of `dst`, in place on `dst` (when it is
unique), with `opacity` (0..100) and `blend`. Images of different sizes leave `dst` unchanged. -/
def compositeRows (dst top : Image) (opacity : Nat) (blend : Blend) (y0 y1 : Nat) : Image :=
  let y1 := min y1 dst.height
  if y1 ≤ y0 || opacity == 0 || top.width != dst.width || top.height != dst.height then dst
  else
    let op := ((min opacity 100) * 255 + 50) / 100
    let i := (4 * dst.width * y0).toUSize
    let n := (4 * dst.width * y1).toUSize
    let ⟨w, h, d⟩ := dst
    let t := top.data
    let op := op.toUInt32
    ⟨w, h, match blend with
      | .normal => compLoop bNormal t d op i n
      | .multiply => compLoop bMultiply t d op i n
      | .screen => compLoop bScreen t d op i n
      | .overlay => compLoop bOverlay t d op i n
      | .darken => compLoop bDarken t d op i n
      | .lighten => compLoop bLighten t d op i n
      | .add => compLoop bAdd t d op i n
      | .difference => compLoop bDifference t d op i n⟩

/-- `top` drawn over `dst` (same size) with `opacity` (0..100) and `blend`. -/
def composite (dst top : Image) (opacity : Nat := 100) (blend : Blend := .normal) : Image :=
  compositeRows dst top opacity blend 0 dst.height

end Editor
