module
public import Editor.Image
public import Editor.Adjust
public import Editor.Filter
public import Editor.Geometry
public import Editor.Composite
public import Editor.Paint
public import Editor.Png
/-!
# The photo editor's image-processing core

Pure Lean, `Init` only, written for single-threaded wasm on 12-megapixel images:

* `Editor.Image`: `Image` (RGBA8 like the DOM's `ImageData`), `Color`, `Rect` (dirty regions),
  `Image.checksum`, and the checked-once pixel access the loops are written with.
* `Editor.Adjust`: `Adjust` (brightness, contrast, exposure, saturation, hue, levels, curve,
  invert, grayscale), `Adjust.apply` / `Adjust.applyRows`, `histogram` (`HistTable` in row
  chunks, `histogramEvery` for a sampled one).
* `Editor.Filter`: Gaussian `blur` (`blurHRows`, `blurVRows`), `sharpen`, 3×3 `convolve`,
  `emboss`, `edgeDetect`.
* `Editor.Geometry`: `crop`, `rotate90cw`, `rotate90ccw`, `rotate180`, `flipH`, `flipV` (each with
  a `…Rows` variant into a caller-allocated destination), bilinear `resize`, `downscaleBox`
  (previews).
* `Editor.Composite`: `composite` / `compositeRows` with eight `Blend` modes.
* `Editor.Paint`: `dab` and `stroke` with a round soft `Brush` (paint or erase), returning the
  dirty `Rect`.
* `Editor.Png`: `Png.encode` (or `Png.Encoder`, a few rows per step) and `Png.decode`.

Functions named `…Rows` process a band of rows `y0 .. y1 - 1`, so the app can split work on a
large image across frames; whole-image functions work in place on a unique image where the shape
allows it. `tests/Editor.lean` (`leanui-editor-tests`) tests them, `tests/EditorPerf.lean`
(`leanui-editor-perf`) times them.
-/
