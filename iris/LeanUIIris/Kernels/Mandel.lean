/-
A pointwise kernel for `ParMapG`: the Mandelbrot iteration count of pixel `p` of a 256-wide image,
in fixed point with 10 fractional bits, at most 200 iterations.

`mandel_spec` proves it implements the Lean function `g` (`ParMap.fSpec`), so with
`ParMapG.pmapG_spec` a parallel render ends with every cell `g` of its pixel index. Pixels cost
from 1 to 200 iterations, so equal bands are uneven work.

The constants keep every intermediate value inside the translation's 29-bit integers: before the
escape test |x|, |y| ≤ 6.4 · 2^10, so a product is below 2^26; the translation would trap, not
wrap, if this argument were wrong.
-/
import LeanUIIris.Kernels.ParMap

namespace LeanUIIris.Mandel
open Iris Iris.HeapLang BI ProgramLogic LeanUIIris.ParMap

def iter : Val := hl_val%
  rec it cx cy x y i :=
    if #(200 : Int) ≤ i then i else
    let xx := (x * x) >>> #(10 : Int);
    let yy := (y * y) >>> #(10 : Int);
    if #(4096 : Int) < xx + yy then i else
    it cx cy (xx - yy + cx) (((x * y) >>> #(9 : Int)) + cy) (i + #(1 : Int))

def mandel : Val := hl_val%
  λ p, &iter (((p % #(256 : Int)) * #(10 : Int)) - #(2048 : Int))
    (((p / #(256 : Int)) * #(10 : Int)) - #(1280 : Int)) #(0 : Int) #(0 : Int) #(0 : Int)

/-- The same iteration in Lean, with `fuel = 200 - i`. -/
def iterL (cx cy : Int) : Nat → Int → Int → Int → Int
  | 0, _, _, i => i
  | fuel + 1, x, y, i =>
    if 4096 < (x * x) >>> (10 : Int) + (y * y) >>> (10 : Int) then i
    else iterL cx cy fuel ((x * x) >>> (10 : Int) - (y * y) >>> (10 : Int) + cx)
      ((x * y) >>> (9 : Int) + cy) (i + 1)

/-- The iteration count of pixel `p`. -/
def g (p : Int) : Int :=
  iterL (p.tmod 256 * 10 - 2048) (p.tdiv 256 * 10 - 1280) 200 0 0 0

variable {GF : BundledGFunctors} [HeapLangGS hlc GF]
local bi (IProp GF)

theorem iter_spec (cx cy : Int) (fuel : Nat) (x y i : Int) (hi : i = 200 - (fuel : Int)) :
    ⊢ WP hl(&iter #cx #cy #x #y #i) {{ w, ⌜w = hl_val(#(iterL cx cy fuel x y i))⌝ }} := by
  induction fuel generalizing x y i with
  | zero =>
    wp_rec
    wp_pures
    have h : (200 : Int) ≤ i := by omega
    simp only [h, _root_.decide_true]
    wp_pures
    ipureintro
    rfl
  | succ fuel ih =>
    wp_rec
    wp_pures
    have h : ¬ ((200 : Int) ≤ i) := by omega
    simp only [h, decide_false]
    wp_pures
    by_cases hesc : 4096 < (x * x) >>> (10 : Int) + (y * y) >>> (10 : Int)
    · simp only [hesc, _root_.decide_true]
      wp_pures
      ipureintro
      simp only [iterL, hesc, ↓reduceIte]
    · simp only [hesc, decide_false]
      wp_pures
      have H := ih ((x * x) >>> (10 : Int) - (y * y) >>> (10 : Int) + cx)
        ((x * y) >>> (9 : Int) + cy) (i + 1) (by omega)
      ihave Hw := H
      iapply wp_wand $$ Hw
      iintro %w %hw
      ipureintro
      rw [hw]
      simp only [iterL, hesc, ↓reduceIte]

theorem mandel_spec : ⊢ fSpec (GF := GF) g mandel := by
  iintro !> %z
  wp_rec
  wp_pures
  have H := iter_spec (GF := GF) (z.tmod 256 * 10 - 2048) (z.tdiv 256 * 10 - 1280) 200 0 0 0
    (by omega)
  ihave Hw := H
  iapply wp_wand $$ Hw
  iintro %w %hw
  ipureintro
  rw [hw]
  rfl

end LeanUIIris.Mandel
