module
/-!
# Images: RGBA8 pixel buffers, checksums, dirty rectangles

An `Image` is the DOM's `ImageData` layout: `width * height` pixels, row-major, 4 bytes per pixel
(R, G, B, A), straight (not premultiplied) alpha. Every operation of the editor core works on this
one type, so a buffer goes to and from a canvas without conversion.

## How the pixel loops are written

The loops of `Editor.*` run on 12-megapixel images in single-threaded wasm, so they follow a few
rules (checked in the generated C, `.lake/build/ir/Editor/*.c`):

* A buffer being written is uniquely owned and threaded through a tail-recursive loop (which the
  compiler turns into a `goto`), so `uset` writes in place. A function destructures its `Image`
  argument first and rebuilds it at the end: holding the structure while writing its `data` would
  keep a second reference, and the first write would copy the whole buffer.
* Indices are `USize`, colour arithmetic is `UInt32`/`UInt64` (or local `Float`, which is unboxed):
  no `Nat` arithmetic, no tuples, `Option`s or closures inside a loop. An inner loop that produces
  a pixel writes it into the destination buffer and returns the buffer, instead of returning the
  accumulated values.
* Pixel access is checked once per pixel, not once per byte: `if h : InPx d i then …` (two `USize`
  comparisons) proves that bytes `i .. i + 3` of `d` exist, and `px`, `put4`, `put3`, `setPx` then
  use `uget`/`uset` with that proof, which a write preserves (`InPx.uset`). A bounds check per
  byte costs more than it seems: a byte store may alias anything, so the C compiler reloads the
  buffer's size after every store, and the loop runs about three times slower (measured: 195
  against 580 megapixels per second for a table lookup). A byte loop over a read-only buffer
  carries `n.toNat ≤ d.size` as a parameter instead (`InRange`).
* `rd`/`wr` (one comparison per byte; 0 / no write out of range) remain for the few accesses that
  are not per pixel.
-/
public section
namespace Editor

/-! ## Byte and word access with `USize` indices -/

theorem lt_size_of_lt_usize {a : ByteArray} {i : USize} (h : i < a.usize) : i.toNat < a.size := by
  have := USize.lt_iff_toNat_lt.mp h
  simp [ByteArray.usize] at this
  exact Nat.lt_of_lt_of_le this (Nat.mod_le _ _)

theorem lt_asize_of_lt_usize {α : Type} {a : Array α} {i : USize} (h : i < a.usize) :
    i.toNat < a.size := by
  have := USize.lt_iff_toNat_lt.mp h
  simp [Array.usize] at this
  exact Nat.lt_of_lt_of_le this (Nat.mod_le _ _)

/-- Byte `i` of `a`, or 0 past the end. -/
@[inline] def rd (a : ByteArray) (i : USize) : UInt8 :=
  if h : i < a.usize then a.uget i (lt_size_of_lt_usize h) else 0

/-- `a` with byte `i` set to `v` (in place when `a` is unique); unchanged past the end. -/
@[inline] def wr (a : ByteArray) (i : USize) (v : UInt8) : ByteArray :=
  if h : i < a.usize then a.uset i v (lt_size_of_lt_usize h) else a

/-- Byte `i` of `a` as a `UInt32`. -/
@[inline] def rd32 (a : ByteArray) (i : USize) : UInt32 := (rd a i).toUInt32

/-- Write the low byte of `v` (callers clamp first). -/
@[inline] def wr32 (a : ByteArray) (i : USize) (v : UInt32) : ByteArray := wr a i v.toUInt8

/-- Element `i` of a word table (`Array UInt32` holds unboxed scalars), or 0 past the end. -/
@[inline] def rdW (a : Array UInt32) (i : USize) : UInt32 :=
  if h : i < a.usize then a.uget i (lt_asize_of_lt_usize h) else 0

/-- Set element `i` of a word table (in place when unique). -/
@[inline] def wrW (a : Array UInt32) (i : USize) (v : UInt32) : Array UInt32 :=
  if h : i < a.usize then a.uset i v (lt_asize_of_lt_usize h) else a

/-! ## Checked-once pixel access -/

/-- Bytes `i .. i + 3` (one pixel) are in range of `a`, checked by `i + 3 < a.usize` and that
`i + 3` does not wrap around. -/
abbrev InPx (a : ByteArray) (i : USize) : Prop := i + 3 < a.usize ∧ i ≤ i + 3

theorem size_uset (a : ByteArray) (i : USize) (v : UInt8) (h : i.toNat < a.size) :
    (a.uset i v h).size = a.size := by
  cases a; simp [ByteArray.uset, ByteArray.size]

theorem usize_uset (a : ByteArray) (i : USize) (v : UInt8) (h : i.toNat < a.size) :
    (a.uset i v h).usize = a.usize := by
  simp [ByteArray.usize, size_uset]

theorem InPx.uset {a : ByteArray} {i : USize} (j : USize) (v : UInt8) (hj : j.toNat < a.size) (h : InPx a i) :
    InPx (a.uset j v hj) i := by
  unfold InPx at *; rw [usize_uset]; exact h

theorem InPx.lt {a : ByteArray} {i : USize} (h : InPx a i) (k : USize) (hk : k ≤ 3) :
    (i + k).toNat < a.size := by
  obtain ⟨h1, h2⟩ := h
  have hk' := USize.le_iff_toNat_le.mp hk
  have h1' := USize.lt_iff_toNat_lt.mp h1
  have h2' := USize.le_iff_toNat_le.mp h2
  simp only [USize.toNat_add, ByteArray.usize, USize.toNat_ofNat', Nat.toUSize] at *
  have hs := USize.size_eq
  have h3 : (3 : USize).toNat = 3 := by
    rcases hs with hs | hs <;> simp [USize.toNat, hs]
  rw [h3] at h1' h2' hk'
  rcases hs with hs | hs <;> simp only [USize.size, hs] at * <;> omega

theorem usize_le3 (k : USize) (hk : k.toNat ≤ 3) : k ≤ 3 := by
  apply USize.le_iff_toNat_le.mpr
  have : (3 : USize).toNat = 3 := by rcases USize.size_eq with hs | hs <;> simp [USize.toNat, hs]
  omega

/-- Byte `k` (0..3) of the pixel at `i`. -/
@[inline] def px (a : ByteArray) (i : USize) (h : InPx a i) (k : USize)
    (hk : k ≤ 3 := by exact usize_le3 _ (by simp)) : UInt8 :=
  a.uget (i + k) (h.lt k hk)

/-- Byte `k` (0..3) of the pixel at `i`, as a `UInt32`. -/
@[inline] def px32 (a : ByteArray) (i : USize) (h : InPx a i) (k : USize)
    (hk : k ≤ 3 := by exact usize_le3 _ (by simp)) : UInt32 :=
  (a.uget (i + k) (h.lt k hk)).toUInt32

/-- Set byte `k` (0..3) of the pixel at `i`; the result is still known to hold the pixel. -/
@[inline] def setPx (a : ByteArray) (i : USize) (h : InPx a i) (k : USize) (v : UInt8)
    (hk : k ≤ 3 := by exact usize_le3 _ (by simp)) : { b : ByteArray // InPx b i } :=
  ⟨a.uset (i + k) v (h.lt k hk), h.uset _ _ _⟩

/-- Write the pixel at `i`. -/
@[inline] def put4 (a : ByteArray) (i : USize) (h : InPx a i) (r g b α : UInt8) : ByteArray :=
  let ⟨a, h⟩ := setPx a i h 0 r
  let ⟨a, h⟩ := setPx a i h 1 g
  let ⟨a, h⟩ := setPx a i h 2 b
  (setPx a i h 3 α).1

/-- Write the colour of the pixel at `i` (alpha kept). -/
@[inline] def put3 (a : ByteArray) (i : USize) (h : InPx a i) (r g b : UInt8) : ByteArray :=
  let ⟨a, h⟩ := setPx a i h 0 r
  let ⟨a, h⟩ := setPx a i h 1 g
  (setPx a i h 2 b).1

/-- `put4` from the low bytes of 32-bit values (callers clamp first). -/
@[inline] def put4w (a : ByteArray) (i : USize) (h : InPx a i) (r g b α : UInt32) : ByteArray :=
  put4 a i h r.toUInt8 g.toUInt8 b.toUInt8 α.toUInt8

/-- `put3` from the low bytes of 32-bit values. -/
@[inline] def put3w (a : ByteArray) (i : USize) (h : InPx a i) (r g b : UInt32) : ByteArray :=
  put3 a i h r.toUInt8 g.toUInt8 b.toUInt8

/-- Copy the pixel at `s` of `src` to `o` of `dst`. -/
@[inline] def copyPx (src : ByteArray) (s : USize) (hs : InPx src s) (dst : ByteArray) (o : USize) (ho : InPx dst o) :
    ByteArray :=
  put4 dst o ho (px src s hs 0) (px src s hs 1) (px src s hs 2) (px src s hs 3)

/-! ## Whole-pixel access (inline C)

A pixel is read and written as one little-endian word, `r ||| g <<< 8 ||| b <<< 16 ||| a <<< 24`.
The Lean bodies below are the specification (what proofs see); compiled code uses the C
expression of `extern c inline` instead, pasted at each call site, natively and in wasm (as
`LeanUI.Patch` does for its buffer: no C file). The C reads or writes the four bytes with one
exclusivity check per pixel instead of four, as one 32-bit access. That matters most in wasm64,
where every memory access is bounds-checked: a pixel loop then does a quarter of the loads and
stores. The store is a `uint32_t` store (of an unaligned type, little-endian on any host), not four
byte stores: a byte store may alias anything, so after it the C compiler reloads every array's size
and reference count; after a `uint32_t` store it can keep the sizes (`size_t`) in registers. -/

/-- The pixel at byte `i` as a little-endian word (one unaligned 32-bit load: a `memcpy` of 4
bytes). -/
@[extern c inline "({ uint32_t v_; __builtin_memcpy(&v_, lean_sarray_cptr(#1) + #2, 4); \
  __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__ ? v_ : __builtin_bswap32(v_); })", expose]
def get32 (a : @& ByteArray) (i : USize) (h : InPx a i) : UInt32 :=
  px32 a i h 0 ||| (px32 a i h 1 <<< 8) ||| (px32 a i h 2 <<< 16) ||| (px32 a i h 3 <<< 24)

/-- Write the pixel at byte `i` from a little-endian word (in place when `a` is unique). -/
@[extern c inline "({ lean_object *a_ = #1; size_t i_ = #2; uint32_t v_ = #3; \
  if (LEAN_UNLIKELY(!lean_is_exclusive(a_))) a_ = lean_copy_byte_array(a_); \
  typedef uint32_t __attribute__((aligned(1))) u32u_; \
  *(u32u_ *)(lean_sarray_cptr(a_) + i_) = \
    __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__ ? v_ : __builtin_bswap32(v_); a_; })", expose]
def set32 (a : ByteArray) (i : USize) (v : UInt32) (h : InPx a i) : ByteArray :=
  put4w a i h v (v >>> 8) (v >>> 16) (v >>> 24)

theorem size_set32 (a : ByteArray) (i : USize) (v : UInt32) (h : InPx a i) : (set32 a i v h).size = a.size := by
  simp [set32, put4w, put4, setPx, size_uset]

theorem usize_set32 (a : ByteArray) (i : USize) (v : UInt32) (h : InPx a i) : (set32 a i v h).usize = a.usize := by
  simp only [ByteArray.usize, size_set32]

theorem InPx.set32 {a : ByteArray} {i : USize} (j : USize) (v : UInt32) (hj : InPx a j) (h : InPx a i) :
    InPx (Editor.set32 a j v hj) i := by
  unfold InPx at *; rw [usize_set32]; exact h

/-! ### Two channels per multiplication

Red and blue (`rbOf`), or green and alpha (`gaOf`), of a pixel word sit 16 bits apart; `spread`
moves the two lanes to the halves of a 64-bit word, where one multiplication by a weight of at most
65536 handles both without a carry between them: a sum of such products with weights totalling
65536 stays below `255 · 65536 < 2²⁴` per lane. Adding two `rbOf` values before spreading is safe
too (each lane at most 510). -/

/-- Red and blue of a pixel word, 16 bits apart. -/
@[inline] def rbOf (v : UInt32) : UInt32 := v &&& 0x00ff00ff
/-- Green and alpha of a pixel word, 16 bits apart. -/
@[inline] def gaOf (v : UInt32) : UInt32 := (v >>> 8) &&& 0x00ff00ff
/-- Two 16-bit lanes spread to the two halves of a 64-bit word. -/
@[inline] def spread (x : UInt32) : UInt64 := (x &&& 0xffff).toUInt64 ||| ((x >>> 16).toUInt64 <<< 32)
@[inline] def lane0 (v : UInt64) : UInt32 := (v &&& 0xffffffff).toUInt32
@[inline] def lane1 (v : UInt64) : UInt32 := (v >>> 32).toUInt32

/-- The pixel word of lane sums (`rb`: red and blue, `ga`: green and alpha) with weights
totalling 65536, each rounded to 8 bits. -/
@[inline] def roundWord (rb ga : UInt64) : UInt32 :=
  ((lane0 rb + 32768) >>> 16) ||| (((lane0 ga + 32768) >>> 16) <<< 8) ||| (((lane1 rb + 32768) >>> 16) <<< 16) |||
    (((lane1 ga + 32768) >>> 16) <<< 24)

theorem byte_lt {t : ByteArray} (ht : 256 ≤ t.size) (v : UInt8) : v.toUSize.toNat < t.size := by
  have := v.toNat_lt
  simp only [UInt8.toNat_toUSize] at *
  omega

/-- Entry `v` of a table of (at least) 256 bytes. -/
@[inline] def tab (t : ByteArray) (ht : 256 ≤ t.size) (v : UInt8) : UInt8 := t.uget v.toUSize (byte_lt ht v)

/-- A read-only buffer holds at least `n` bytes: a byte loop over `i < n` needs no other check. -/
abbrev InRange (a : ByteArray) (n : USize) : Prop := n.toNat ≤ a.size

theorem InRange.lt {a : ByteArray} {n i : USize} (hn : InRange a n) (hi : i < n) : i.toNat < a.size :=
  Nat.lt_of_lt_of_le (USize.lt_iff_toNat_lt.mp hi) hn

/-- `n` clamped to the size of `a`, with the proof that `a` holds that many bytes. -/
@[inline] def rangeOf (a : ByteArray) (n : USize) : { m : USize // InRange a m } :=
  if h : n ≤ a.usize ∧ a.usize.toNat = a.size then
    ⟨n, by have := USize.le_iff_toNat_le.mp h.1; unfold InRange; omega⟩
  else ⟨0, by unfold InRange; simp⟩

/-- Bytes `base .. base + len - 1` (a row) are in range of `a`, and `base + len` does not wrap:
checked once per row, it covers every byte of the row and the bytes before a position within it. -/
abbrev RowIn (a : ByteArray) (base len : USize) : Prop := base ≤ base + len ∧ base + len ≤ a.usize

theorem RowIn.lt {a : ByteArray} {base len i : USize} (h : RowIn a base len) (hi : i < len) :
    (base + i).toNat < a.size := by
  obtain ⟨h1, h2⟩ := h
  have h1' := USize.le_iff_toNat_le.mp h1
  have h2' := USize.le_iff_toNat_le.mp h2
  have hi' := USize.lt_iff_toNat_lt.mp hi
  have hb := base.toNat_lt_size
  have hl := len.toNat_lt_size
  have hx := i.toNat_lt_size
  simp only [USize.toNat_add, ByteArray.usize, USize.toNat_ofNat', Nat.toUSize] at *
  have hs := USize.size_eq
  rcases hs with hs | hs <;> simp only [USize.size, hs] at * <;> omega

/-- The byte `k` before position `i` of the row (for `k ≤ i`). -/
theorem RowIn.lt_sub {a : ByteArray} {base len i k : USize} (h : RowIn a base len) (hi : i < len) (hk : k ≤ i) :
    (base + i - k).toNat < a.size := by
  obtain ⟨h1, h2⟩ := h
  have h1' := USize.le_iff_toNat_le.mp h1
  have h2' := USize.le_iff_toNat_le.mp h2
  have hi' := USize.lt_iff_toNat_lt.mp hi
  have hk' := USize.le_iff_toNat_le.mp hk
  have hb := base.toNat_lt_size
  have hl := len.toNat_lt_size
  have hx := i.toNat_lt_size
  have hkk := k.toNat_lt_size
  simp only [USize.toNat_add, USize.toNat_sub, ByteArray.usize, USize.toNat_ofNat', Nat.toUSize] at *
  have hs := USize.size_eq
  rcases hs with hs | hs <;> simp only [USize.size, hs] at * <;> omega

theorem RowIn.uset {a : ByteArray} {base len : USize} (j : USize) (v : UInt8) (hj : j.toNat < a.size)
    (h : RowIn a base len) : RowIn (a.uset j v hj) base len := by
  unfold RowIn at *; rw [usize_uset]; exact h

theorem RowIn.set32 {a : ByteArray} {base len : USize} (j : USize) (v : UInt32) (hj : InPx a j)
    (h : RowIn a base len) : RowIn (Editor.set32 a j v hj) base len := by
  unfold RowIn at *; rw [usize_set32]; exact h

/-- The pixel at byte `i` of the row, for `i < len - 3` (`3 ≤ len`): a loop over the row's pixels
needs one comparison per pixel. -/
theorem RowIn.px {a : ByteArray} {base len i : USize} (h : RowIn a base len) (h3 : 3 ≤ len) (hi : i < len - 3) :
    InPx a (base + i) := by
  obtain ⟨h1, h2⟩ := h
  have h1' := USize.le_iff_toNat_le.mp h1
  have h2' := USize.le_iff_toNat_le.mp h2
  have h3' := USize.le_iff_toNat_le.mp h3
  have hi' := USize.lt_iff_toNat_lt.mp hi
  have hb := base.toNat_lt_size
  have hl := len.toNat_lt_size
  have hx := i.toNat_lt_size
  have e3 : (3 : USize).toNat = 3 := by rcases USize.size_eq with hs | hs <;> simp [USize.toNat, hs]
  rw [e3] at h3'
  refine ⟨USize.lt_iff_toNat_lt.mpr ?_, USize.le_iff_toNat_le.mpr ?_⟩ <;>
  simp only [USize.toNat_add, USize.toNat_sub, ByteArray.usize, USize.toNat_ofNat', Nat.toUSize, e3] at * <;>
  (rcases USize.size_eq with hs | hs <;> simp only [USize.size, hs] at * <;> omega)

theorem RowIn.range {a : ByteArray} {n : USize} (h : RowIn a 0 n) : InRange a n := by
  obtain ⟨_, h2⟩ := h
  have h2' := USize.le_iff_toNat_le.mp h2
  have hn := n.toNat_lt_size
  have hm := Nat.mod_le a.size USize.size
  unfold InRange
  simp only [USize.zero_add, ByteArray.usize, USize.toNat_ofNat', Nat.toUSize] at h2'
  rcases USize.size_eq with hs | hs <;> simp only [USize.size, hs] at * <;> omega

/-- Byte `i` of the row at `base`. -/
@[inline] def rowGet (a : ByteArray) (base len : USize) (h : RowIn a base len) (i : USize) (hi : i < len) : UInt8 :=
  a.uget (base + i) (h.lt hi)

/-- The byte `k` before byte `i` of the row (`k ≤ i`). -/
@[inline] def rowBack (a : ByteArray) (base len : USize) (h : RowIn a base len) (i k : USize) (hi : i < len)
    (hk : k ≤ i) : UInt8 :=
  a.uget (base + i - k) (h.lt_sub hi hk)

/-- A word table holds at least `n` entries. -/
abbrev WRange (a : Array UInt32) (n : USize) : Prop := n.toNat ≤ a.size

theorem WRange.lt {a : Array UInt32} {n i : USize} (hn : WRange a n) (hi : i < n) : i.toNat < a.size :=
  Nat.lt_of_lt_of_le (USize.lt_iff_toNat_lt.mp hi) hn

/-- `n` clamped to the size of `a`, with the proof that `a` holds that many entries. -/
@[inline] def wrangeOf (a : Array UInt32) (n : USize) : { m : USize // WRange a m } :=
  if h : n ≤ a.usize ∧ a.usize.toNat = a.size then
    ⟨n, by have := USize.le_iff_toNat_le.mp h.1; unfold WRange; omega⟩
  else ⟨0, by unfold WRange; simp⟩

/-- Clamp to 0..255. -/
@[inline] def clamp255 (v : UInt32) : UInt32 := if v > 255 then 255 else v

/-- `x / 255` rounded to nearest (halves up), exact for every `x ≤ 65535`. -/
@[inline] def div255 (x : UInt32) : UInt32 := let t := x + 128; (t + (t >>> 8)) >>> 8

/-- `0.5`. A decimal literal inside a loop compiles to a call of `Float.ofScientific` (with `Nat`
arguments) on every iteration; a top-level constant is a global read. An integer literal is
`Float.ofNat` of a `Nat`, which the compiler usually hoists, but not always (when the same `Nat`
also serves another literal, it can end up a loop variable, and `Float.ofNat` goes through
`Float.ofScientific` on every iteration): the loops use constants for those too. -/
def fHalf : Float := 0.5

/-- `0` and `255` as constants (see `fHalf`). -/
def fZero : Float := 0
def f255 : Float := 255

/-- A float clamped to 0..255 and rounded to the nearest byte. -/
@[inline] def toByte (v : Float) : UInt8 :=
  if v ≤ fZero then 0 else if v ≥ f255 then 255 else (v + fHalf).toUInt8

/-! ## Filling and copying buffers -/

/-- Append `len` bytes of `seed` (repeated) to `dst`, one `memcpy` per seed-sized block. -/
partial def fillFrom (seed : ByteArray) (dst : ByteArray) (len : Nat) : ByteArray :=
  if len == 0 then dst
  else
    let k := min len seed.size
    fillFrom seed (seed.copySlice 0 dst dst.size k) (len - k)

private partial def pushPixels (acc : ByteArray) (n : Nat) (r g b a : UInt8) : ByteArray :=
  if n == 0 then acc else pushPixels (acc.push r |>.push g |>.push b |>.push a) (n - 1) r g b a

/-- `n` copies of the 4 bytes `r g b a`, allocated once and filled by block copies of a 64 KB seed
(pushing 48 million bytes one by one would cost a call each). -/
def fillPixels (n : Nat) (r g b a : UInt8) : ByteArray :=
  let k := min n 16384
  let seed := pushPixels (ByteArray.emptyWithCapacity (4 * k)) k r g b a
  fillFrom seed (ByteArray.emptyWithCapacity (4 * n)) (4 * n)

/-- `n` zero bytes. -/
def zeros (n : Nat) : ByteArray :=
  let seed := (fillPixels (min (n / 4 + 1) 16384) 0 0 0 0)
  fillFrom seed (ByteArray.emptyWithCapacity n) n

/-- A fresh copy of `a` (one allocation and one `memcpy`): writing it never touches `a`. -/
def copyBytes (a : ByteArray) : ByteArray :=
  a.copySlice 0 (ByteArray.emptyWithCapacity a.size) 0 a.size

/-! ## Colours and images -/

/-- A straight-alpha RGBA colour. -/
structure Color where
  r : UInt8
  g : UInt8
  b : UInt8
  a : UInt8 := 255
  deriving BEq, Repr, Inhabited

structure Image where
  width : Nat
  height : Nat
  /-- `4 * width * height` bytes: R, G, B, A per pixel, rows top to bottom, straight alpha. -/
  data : ByteArray
  deriving Inhabited

instance : BEq Image where
  beq a b := a.width == b.width && a.height == b.height && a.data == b.data

namespace Image

/-- A `w × h` image filled with one colour. -/
def new (w h : Nat) (r g b a : UInt8) : Image := ⟨w, h, fillPixels (w * h) r g b a⟩

/-- A transparent black `w × h` image. -/
def blank (w h : Nat) : Image := new w h 0 0 0 0

/-- An image filled with `c`. -/
def filled (w h : Nat) (c : Color) : Image := new w h c.r c.g c.b c.a

/-- The number of pixels. -/
def pixels (img : Image) : Nat := img.width * img.height

/-- Bytes per row. -/
def stride (img : Image) : Nat := 4 * img.width

/-- Whether the buffer has exactly `4 * width * height` bytes. -/
def valid (img : Image) : Bool := img.data.size == 4 * img.width * img.height

/-- Byte offset of pixel `(x, y)`. -/
def offset (img : Image) (x y : Nat) : Nat := 4 * (y * img.width + x)

/-- Pixel `(x, y)`, or transparent black outside the image. -/
def get (img : Image) (x y : Nat) : Color :=
  if x < img.width && y < img.height then
    let i := img.offset x y
    ⟨img.data.get! i, img.data.get! (i + 1), img.data.get! (i + 2), img.data.get! (i + 3)⟩
  else ⟨0, 0, 0, 0⟩

/-- Set pixel `(x, y)` (no change outside the image). In place when the image is unique. -/
def set (img : Image) (x y : Nat) (c : Color) : Image :=
  if x < img.width && y < img.height then
    let i := img.offset x y
    let ⟨w, h, d⟩ := img
    ⟨w, h, d.set! i c.r |>.set! (i + 1) c.g |>.set! (i + 2) c.b |>.set! (i + 3) c.a⟩
  else img

/-- Channel `c` (0 = R … 3 = A) of pixel `(x, y)`, or 0 outside the image. -/
def channel (img : Image) (x y c : Nat) : UInt8 :=
  if x < img.width && y < img.height && c < 4 then img.data.get! (img.offset x y + c) else 0

/-- A copy with its own buffer. -/
def copy (img : Image) : Image := ⟨img.width, img.height, copyBytes img.data⟩

private partial def genLoop (f : Nat → Nat → Color) (w h x y : Nat) (d : ByteArray) : ByteArray :=
  if y ≥ h then d
  else if x ≥ w then genLoop f w h 0 (y + 1) d
  else
    let c := f x y
    genLoop f w h (x + 1) y (d.push c.r |>.push c.g |>.push c.b |>.push c.a)

/-- An image whose pixel `(x, y)` is `f x y` (for tests and small images: it calls `f` per pixel). -/
def generate (w h : Nat) (f : Nat → Nat → Color) : Image :=
  ⟨w, h, genLoop f w h 0 0 (ByteArray.emptyWithCapacity (4 * w * h))⟩

private partial def fnvLoop (d : @& ByteArray) (n : USize) (hn : InRange d n) (i : USize) (h : UInt64) : UInt64 :=
  if hi : i < n then fnvLoop d n hn (i + 1) ((h ^^^ (d.uget i (hn.lt hi)).toUInt64) * 0x100000001b3) else h

private def fnvWord (h : UInt64) (v : Nat) : UInt64 :=
  let v := v.toUInt32
  let step (h : UInt64) (b : UInt32) := (h ^^^ (b &&& 0xff).toUInt64) * 0x100000001b3
  step (step (step (step h v) (v >>> 8)) (v >>> 16)) (v >>> 24)

/-- FNV-1a (64-bit) over the width and height (each as 4 little-endian bytes) and the pixel
bytes: the golden value the tests pin for each operation. -/
def checksum (img : Image) : UInt64 :=
  let h := fnvWord (fnvWord 0xcbf29ce484222325 img.width) img.height
  let ⟨n, hn⟩ := rangeOf img.data img.data.usize
  fnvLoop img.data n hn 0 h

end Image

/-! ## Aliasing and row copies -/

/-- Pointer equality of two buffers, used only to choose an in-place path whose result is the
same either way. -/
unsafe def sameRefImpl (a b : @& ByteArray) : Bool := ptrAddrUnsafe a == ptrAddrUnsafe b
@[implemented_by sameRefImpl] opaque sameRef (a b : @& ByteArray) : Bool

/-- Copy rows `y0 .. y1 - 1` of `src` into `dst` (a `memcpy`): the two-buffer form of an
in-place operation. Both images must have the same size. -/
def copyRows (src dst : Image) (y0 y1 : Nat) : Image :=
  let y1 := min y1 dst.height
  if y1 ≤ y0 || src.width != dst.width || src.height != dst.height then dst
  else
    let s := 4 * dst.width
    let ⟨w, h, d⟩ := dst
    ⟨w, h, src.data.copySlice (y0 * s) d (y0 * s) ((y1 - y0) * s)⟩

/-- Whether `a` and `b` are the same buffer with the same size (so an operation from `a` into `b`
can run in place). -/
def aliases (a b : Image) : Bool := sameRef a.data b.data && a.width == b.width && a.height == b.height

/-! ## Rectangles (dirty regions) -/

/-- An axis-aligned rectangle of pixels: columns `x .. x + w - 1`, rows `y .. y + h - 1`. -/
structure Rect where
  x : Nat
  y : Nat
  w : Nat
  h : Nat
  deriving BEq, Repr, Inhabited

namespace Rect

def empty : Rect := ⟨0, 0, 0, 0⟩

/-- The rectangle with corners `(x0, y0)` (inclusive) and `(x1, y1)` (exclusive). -/
def ofBounds (x0 y0 x1 y1 : Nat) : Rect :=
  if x1 ≤ x0 || y1 ≤ y0 then empty else ⟨x0, y0, x1 - x0, y1 - y0⟩

/-- The whole of a `w × h` image. -/
def full (w h : Nat) : Rect := ⟨0, 0, w, h⟩

def isEmpty (r : Rect) : Bool := r.w == 0 || r.h == 0

/-- One past the last column / row. -/
def right (r : Rect) : Nat := r.x + r.w
def bottom (r : Rect) : Nat := r.y + r.h

def area (r : Rect) : Nat := r.w * r.h

def contains (r : Rect) (x y : Nat) : Bool := r.x ≤ x && x < r.right && r.y ≤ y && y < r.bottom

/-- The pixels in both (empty if they do not overlap). -/
def inter (a b : Rect) : Rect := ofBounds (max a.x b.x) (max a.y b.y) (min a.right b.right) (min a.bottom b.bottom)

/-- The smallest rectangle holding both; an empty rectangle adds nothing. -/
def union (a b : Rect) : Rect :=
  if a.isEmpty then b else if b.isEmpty then a
  else ofBounds (min a.x b.x) (min a.y b.y) (max a.right b.right) (max a.bottom b.bottom)

/-- The part inside a `w × h` image. -/
def clamp (r : Rect) (w h : Nat) : Rect := r.inter (full w h)

end Rect
end Editor
