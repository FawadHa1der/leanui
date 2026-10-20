# Photo-editor operations: Lean (wasm64) against JavaScript and canvas

The image operations of the photo editor (`examples/Editor/*.lean`, pure Lean compiled to wasm64)
timed in one browser page against:

- **JS**: [`ops.js`](ops.js), the same algorithms with the same parameters in plain JavaScript:
  typed arrays and straightforward loops, as a competent developer writes them without heroic
  optimisation (no WebGL, SIMD, workers or 32-bit pixel views). Every operation produces the same
  bytes as the Lean code; this is checked, not assumed (below).
- **canvas built-in**, where one exists: `ctx.filter` (`blur`, `brightness`/`contrast`,
  `saturate`/`hue-rotate`), transforms + `drawImage` (rotate, flip), scaled `drawImage` (resize,
  downscale), `globalAlpha` + `globalCompositeOperation` (composite), `toBlob` (PNG). These are
  *not* the same algorithms (the browser's own, in C++ on Skia, possibly on a GPU) and are labelled
  as such.

The operations and their parameters are `EditorBench.ops` / `EditorBench.run`
([`examples/EditorBench.lean`](../../examples/EditorBench.lean)): adjustments (a lookup table;
saturation and hue as a fixed-point matrix), Gaussian blur of radius 2 and 8, unsharp mask, emboss,
Sobel edges, rotations, flips, bilinear resize to 50%, box downscale to 1/8, compositing (normal and
overlay at 60%), histogram, PNG encoding (stored, and level 1: filters, LZ77, fixed Huffman), crop.

## What is timed

On the same image (`Editor.testImage`, made in Lean and in JS) at 1 MP (1152×864), 4 MP
(2304×1728) and 12 MP (4000×3000); per operation one warm-up, then interleaved runs (Lean, JS,
canvas); the tables give the median and the minimum, MPix/s (input pixels per second) and the
Lean ÷ JS and Lean ÷ canvas time ratios.

- **Lean**: the synchronous `input` event that carries `run OP` to the app (`performance.now()`
  around `el.value = …; el.dispatchEvent(new Event("input", { bubbles: true }))`): Lean's update
  (the operation), view and diff in wasm, then applying a three-node DOM patch. The view is tiny;
  the time is the operation's. The result stays in the model until the next run, and an operation
  that works in place first copies the source image (the model still holds it), as the JS version
  allocates a new output.
- **JS**: the call of `EditorOps.run(op, img, top)`.
- **canvas built-in**: the draw on a 2D canvas, then `getImageData` of the whole result, which
  forces the work to complete and returns the pixels to JavaScript (the comparable result: Lean's
  and JS's outputs are pixels the program holds). Also recorded: the draw followed by a 1-pixel
  `getImageData` (the work without the full readback), the draw call alone (Chrome records canvas
  draws and rasterises them at the next flush, so this is only the cost of issuing them), and
  `getImageData` of a whole drawn canvas alone. `toBlob` (PNG) is timed until its callback.
- **blit**: Lean's `Cmd.drawBitmap` (`putImageData` of the image straight from wasm memory, inside
  the event) against JS `putImageData` of an equal `Uint8ClampedArray`.
- **memory**: the wasm linear memory after each size (`__leanui.stats.heapBytes`, the bytes of the
  `WebAssembly.Memory`; it never shrinks).

## Same bytes

- `node bench/editor/check-goldens.mjs` runs `ops.js` on the generated images of
  `tests/Editor.lean` and compares with its pinned golden checksums (computed natively by the Lean
  core and, except the compressed PNG files, by the independent Python reference): adjustments,
  histogram, blur, sharpen, convolutions, geometry, every blend mode, PNG at levels 0, 1, 4 and 9.
  It also round-trips PNG files through zlib, and checks that `ops.js` has exactly the operations
  of `EditorBench.ops`.
- The browser runner first runs every operation on a 333×250 test image in Lean (wasm) and in JS
  and compares: the image checksum (`Image.checksum`, FNV-1a; Lean's through the `sum` command),
  the sum of the histogram's counts, the PNG's size. It prints MATCH or DIFF per operation, and
  whether the canvas built-in gives the same pixels (rotations, flips and crop do). The
  floating-point steps (the adjustment table, the colour matrix, the Gaussian weights, Sobel's
  square root) use the same IEEE double operations in the same order (`testImage` is integer
  arithmetic); `Math.pow`,
  `exp`, `sin` and `cos` may differ from the C library's in the last bit, which only matters for a
  value within an ulp of a rounding boundary.

## Running

```bash
tools/build-app.sh EditorBenchApp editor-bench       # dist/editor-bench (needs the wasm64 archives)
lake build leanui && .lake/build/bin/leanui serve dist --port 5341 --quiet &
node bench/editor/check-goldens.mjs                  # ops.js against the Lean goldens (Node only)
node tests/browser/editor-bench.mjs http://127.0.0.1:5341/ chromium [firefox] \
  [--sizes 1,4,12] [--runs 5] [--out bench/editor/results-<engine>.json] [--date YYYY-MM-DD]
```

Playwright comes from `LEANUI_PLAYWRIGHT_FROM` (see `tests/browser/playwright.mjs`). The browser is
Playwright's own build, else `$LEANUI_CHROMIUM` / `$LEANUI_FIREFOX`, else
`$PLAYWRIGHT_BROWSERS_PATH/<engine>`. An operation whose warm-up takes over 1.5 s (`--slow-ms`)
gets 3 runs (`--slow-runs`) at that size, marked † in the tables; at 1, 4 and 12 MP with 5 runs
Chromium takes under 4 minutes on a 4-core cloud machine (221 s at `eb0414f`), 7 s of them Lean
making the test images (below). Other sizes: `--sizes 640x480,…`. The JSON holds every run's time, the browser version and
user agent, the bytes check, and the date if given.

## Caveats

- **Timings from cloud and CI machines are noisy**, and absolute numbers describe that machine
  ("CI machine"), shared and of unknown load. The comparable figure is the **ratio within one
  browser process**: Lean, JS and canvas run interleaved on the same image in the same page.
  Repeat a run before believing a difference of less than about 20%.
- **Playwright's Firefox runs wasm several times slower than release Firefox** (about 8×,
  [`docs/BENCHMARKS.md`](../../docs/BENCHMARKS.md), "Findings about measuring"): its Lean ÷ JS
  ratios say nothing about Firefox. Use it for correctness, release browsers for speed.
- Chromium's `performance.now()` is coarsened to 0.1 ms without cross-origin isolation, so
  sub-millisecond operations (crop, flips at 1 MP) are coarse.
- The canvas built-ins are different algorithms with different results (PNG sizes differ too).
  In a headless browser without a GPU (as in CI) the 2D canvas is rasterised in software; with a
  GPU, the draw may run on it, and the readback then dominates.
- Allocation: each run allocates its output, as an app would. A JS run gets a fresh typed array,
  whose pages are touched for the first time: about 30 ms per 48 MB (in Node, a 12 MP flip-v takes
  50 ms into a fresh array and 19 ms into a reused one), and it may include a collection of earlier
  outputs. Lean's allocator reuses wasm memory that has already grown (memory never shrinks), so
  copy-bound operations (flip-v, crop) favour Lean for that reason alone.
- Making the test image is not timed, and not optimised: Lean takes 4.7 s at 12 MP (JS 0.4 s),
  pushing the image a byte at a time. It is integer arithmetic since the first version, which
  converted five `Nat`s to `Float` per pixel and took 70 s at 12 MP: `Float.ofNat` (Lean 4.34's
  compiled `Float.ofScientific`) parsed the literal `2^53` from a decimal string on every call.
- Results: each JSON file holds the raw timings of a run (the machine is in the user agent).
  `results-chromium.json` and `results-chromium-2.json` are two runs on the 4-core cloud VM
  (Chromium 141); `results-ci-chromium.json` and `results-ci-firefox.json` are GitHub's runner
  (Chromium 151, Playwright's Firefox 153: the `editor-bench` artifact of a run with the `bench`
  label). [`docs/BENCHMARKS.md`](../../docs/BENCHMARKS.md) says where and at which commit each was
  measured, and `node bench/editor/mpix-table.mjs <file.json>` prints its MPix/s tables.
