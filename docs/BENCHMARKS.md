# LeanUI performance

LeanUI is measured with the [js-framework-benchmark](https://github.com/krausest/js-framework-benchmark)
keyed operations, against a hand-written vanilla JavaScript implementation, in Chromium (with
traces), in release Chrome and Firefox, and natively. This page gives the results, the method,
and what was learned getting there.

Measured at commit `9a4c9c6` (2026-10-18). All numbers: an Apple M4 Max (10 performance and 4 efficiency cores), macOS 26, headless
browsers, medians. Each browser measurement loads a fresh page, does the operation's warm-up
clicks, busy-waits 30 ms (so the click does not land on an efficiency core; see below) and times
one click.

## Summary

- **Against hand-written JavaScript**, LeanUI's keyed-suite CPU time is **1.33×** vanilla's in
  Chromium (geometric mean over the nine operations, script and rendering), **1.68×** in
  release Chrome (1.38× without "highlight a row", a 0.8 ms operation that Chrome's 0.1 ms timer
  steps distort) and **1.66×** in release Firefox (script and layout). Rendering work is the
  same for both (identical DOM); the difference is script: Lean's update, view and diff in wasm,
  and applying the command buffer.
- **Natively**, selecting a row costs Lean 0.12 ms (update, view, diff, encoding), and
  re-rendering 1,000 unchanged rows 0.06 ms.
- **Memory**: 16 MB of wasm memory at load,
  34.13 MB after creating 10,000 rows (wasm memory never shrinks);
  the JavaScript heap stays within 2.5 MB of vanilla's.
- **Startup**: ready 25.3 ms after navigation (vanilla
  4.8 ms), of which 20.2 ms is
  compiling and instantiating the wasm, initializing Lean and the first render;
  154.6 KB over the wire with brotli.

## Results

### Chromium 151, traced: CPU time per click (median of 9 fresh loads)

| operation | LeanUI total | script | render | vanilla total | script | render | LeanUI ÷ vanilla |
|---|--:|--:|--:|--:|--:|--:|--:|
| create 1,000 rows | 22.61 ms | 7.21 | 15.57 | 17.83 ms | 1.87 | 15.95 | **1.27×** |
| replace all 1,000 rows | 26.70 ms | 10.59 | 16.02 | 18.79 ms | 3.48 | 15.44 | **1.42×** |
| update every 10th of 1,000 rows | 3.66 ms | 0.98 | 2.68 | 3.03 ms | 0.10 | 2.93 | **1.21×** |
| highlight a row (of 1,000) | 1.14 ms | 0.40 | 0.72 | 0.78 ms | 0.03 | 0.75 | **1.46×** |
| swap 2 of 1,000 rows | 4.16 ms | 0.87 | 3.29 | 3.56 ms | 0.05 | 3.50 | **1.17×** |
| remove one of 1,000 rows | 4.64 ms | 0.55 | 4.10 | 4.18 ms | 0.05 | 4.13 | **1.11×** |
| create 10,000 rows | 242.58 ms | 64.52 | 177.91 | 166.83 ms | 17.47 | 149.20 | **1.45×** |
| append 1,000 rows to 1,000 | 25.42 ms | 8.18 | 17.26 | 18.96 ms | 1.74 | 17.26 | **1.34×** |
| clear 1,000 rows | 3.24 ms | 2.99 | 0.24 | 1.96 ms | 1.72 | 0.24 | **1.65×** |

Geometric mean of the ratios: **1.33×**.

### Firefox 158 (release, no automation): script and layout per click (median of 9 fresh loads)

| operation | LeanUI layout | script | vanilla layout | script | LeanUI ÷ vanilla |
|---|--:|--:|--:|--:|--:|
| create 1,000 rows | 17.00 ms | 8.40 | 11.02 ms | 2.10 | **1.54×** |
| replace all 1,000 rows | 23.40 ms | 15.52 | 12.36 ms | 4.20 | **1.89×** |
| update every 10th of 1,000 rows | 3.36 ms | 1.20 | 1.92 ms | 0.12 | **1.75×** |
| highlight a row (of 1,000) | 0.78 ms | 0.56 | 0.26 ms | 0.06 | **3.00×** |
| swap 2 of 1,000 rows | 6.18 ms | 1.18 | 4.74 ms | 0.18 | **1.30×** |
| remove one of 1,000 rows | 5.86 ms | 0.90 | 5.30 ms | 0.16 | **1.11×** |
| create 10,000 rows | 177.06 ms | 81.56 | 116.12 ms | 24.62 | **1.52×** |
| append 1,000 rows to 1,000 | 23.42 ms | 11.72 | 12.92 ms | 1.94 | **1.81×** |
| clear 1,000 rows | 3.94 ms | 3.74 | 2.58 ms | 2.38 | **1.53×** |

Geometric mean: **1.66×**. Ready after navigation: LeanUI 25.44 ms, vanilla 2.76 ms.

### Chrome 155 (release, no automation): script and layout per click (median of 9 fresh loads)

| operation | LeanUI layout | script | vanilla layout | script | LeanUI ÷ vanilla |
|---|--:|--:|--:|--:|--:|
| create 1,000 rows | 18.20 ms | 6.30 | 14.20 ms | 1.80 | **1.28×** |
| replace all 1,000 rows | 21.20 ms | 9.70 | 14.40 ms | 3.30 | **1.47×** |
| update every 10th of 1,000 rows | 3.00 ms | 1.20 | 2.30 ms | 0.20 | **1.30×** |
| highlight a row (of 1,000) | 0.80 ms | 0.60 | 0.10 ms | 0.00 | **8.00×** |
| swap 2 of 1,000 rows | 2.30 ms | 0.70 | 1.70 ms | 0.00 | **1.35×** |
| remove one of 1,000 rows | 3.00 ms | 0.70 | 2.30 ms | 0.00 | **1.30×** |
| create 10,000 rows | 172.70 ms | 57.90 | 131.70 ms | 15.90 | **1.31×** |
| append 1,000 rows to 1,000 | 20.10 ms | 7.10 | 15.00 ms | 1.70 | **1.34×** |
| clear 1,000 rows | 3.10 ms | 3.10 | 1.80 ms | 1.80 | **1.72×** |

Geometric mean: **1.68×**. Ready after navigation: LeanUI 8.8 ms, vanilla 3.4 ms.

### Memory (Chromium, after a full GC)

| after | LeanUI JS heap | LeanUI wasm memory | vanilla JS heap | DOM nodes |
|---|--:|--:|--:|--:|
| load | 1.48 MB | 16 MB | 1.06 MB | 47 |
| creating 1,000 rows | 1.89 MB | 16 MB | 1.24 MB | 11047 |
| 5 updates of every 10th row | 1.9 MB | 16 MB | 1.26 MB | 11047 |
| 5 create/clear cycles | 1.6 MB | 16 MB | 1.11 MB | 47 |
| creating 10,000 rows | 5.12 MB | 34.13 MB | 2.6 MB | 110047 |

### Startup and size (Chromium)

| | LeanUI | vanilla |
|---|--:|--:|
| ready after navigation | 25.3 ms | 4.8 ms |
| of which wasm instantiation + Lean init + first render | 20.2 ms | |
| transferred (uncompressed) | 1087.6 KB | 5.94 KB |
| brotli | 154.6 KB | 2.06 KB |

### Native Lean (update, view, diff, encoding; no DOM)

| operation | lazy rows | eager rows | command words |
|---|--:|--:|--:|
| create 1,000 rows | 1.99 ms | 1.97 ms | 122000 |
| replace all 1,000 rows | 2.63 ms | 2.69 ms | 144999 |
| update every 10th of 1,000 rows | 0.26 ms | 0.68 ms | 400 |
| highlight a row (of 1,000) | 0.12 ms | 0.55 ms | 8 |
| swap 2 of 1,000 rows | 0.32 ms | 0.82 ms | 8 |
| remove one of 1,000 rows | 0.21 ms | 0.71 ms | 22 |
| create 10,000 rows | 20.40 ms | 20.05 ms | 1220000 |
| append 1,000 rows to 1,000 | 2.30 ms | 2.72 ms | 122999 |
| clear 1,000 rows | 0.49 ms | 0.47 ms | 22000 |

## Where LeanUI's time goes

Sampled CPU profiles of the synchronous click in Chromium, on a build with function names
(`tools/build-app.sh BenchApp bench-prof --debug`, `tests/browser/profile.mjs`):

| | create 1,000 rows (6.7 ms per click) | select a row (0.22 ms per click) |
|---|--:|--:|
| Lean, in wasm | 59% | 76% |
| the browser's DOM work | 25% | 4% |
| LeanUI's JavaScript runtime (applying commands, events) | 8% | 1.5% |
| other (engine, GC) | 8% | 18% |

- **Creating rows** costs most in the DOM calls themselves (`appendChild` 9%, `setAttribute` 6%,
  `createElement` 5%), in `mount` (8.5%), in writing the command buffer a byte at a time
  (`lean_byte_array_push`, 7.5%), and in the allocator (14%, part of it freeing the previous rows
  during the setup's clear). The hand-written reference clones a template row instead of
  creating its ten nodes one by one, which is most of its advantage on this operation.
- **Small updates** are dominated by allocation: building the new view (one lazy node, its
  closure, its key and its dependencies per row, about ten objects) and freeing the old one is about a
  quarter of the time (`malloc`/`free`), followed by `patchNode`, comparing dependencies and the
  pure check. The DOM work is a few percent.
- **Next steps** this suggests: writing the command buffer a word at a time (done since: see
  "What made encoding cheap"); cloning static subtrees from templates (the template syntax
  knows which parts of a view are static); avoiding the per-row view allocation altogether for
  rows whose model did not change.

## What made the diff fast

The first working diff spent 1.65 ms re-rendering 1,000 unchanged rows natively, almost all of it
allocating and freeing. Five changes took it to 0.06 ms; each is tested by the randomized list
tests and the property suites against an independent reference model.

1. **Change tracking.** `patch` reports whether a node changed. An unchanged node is returned as
   the *same* object, so unchanged parents are not rebuilt either.
2. **A pure check before any monadic work.** Every monadic step in Lean's state monad returns a
   freshly allocated pair. `sameF` decides, without allocating, that a subtree needs no command;
   the subtree then only has its listener slots re-pointed, with one state update for a whole run
   of unchanged siblings. Subtree sizes are cached in the mounted nodes so the check only runs on
   subtrees within its budget, which keeps the total work linear at any depth (patching a
   100,000-level chain went from 294 ms to 21 ms, the cost of mounting it).
3. **Exact lazy rows.** Freeing the discarded view was the largest remaining cost (about 27
   objects per benchmark row). `lazy` with exact dependencies (`Dep`, compared structurally,
   never hashed) and its own key skips both building and diffing a row: selecting a row went from
   0.47 ms (eager rows, with the pure check) to 0.12 ms.
4. **No hidden copies.** The diff state is taken out of the runtime state before diffing, so its
   slot table is updated in place instead of being copied on every update; elements without
   listeners or children share one empty array.
5. **Cheap strings.** The UTF-16 length of an ASCII string is read from the string object
   (byte size equals length) instead of walking it.

## What made encoding cheap

Creating 1,000 rows writes 122,000 words and 10,000 strings into the command buffer and names a
tag, attribute or event 18,000 times. Two changes in `LeanUI/Patch.lean`, with no change to the
protocol:

1. **Inline stores.** A word was four calls to `lean_byte_array_push`, and a string was copied
   twice (`String.toUTF8`, then appended). `pushU32` and `appendUtf8` keep their Lean bodies as
   the specification but compile, through `@[extern c inline]`, to a statement expression pasted
   at each call site: when the array is exclusive and has room, store the bytes and bump the size;
   otherwise run the original runtime calls. There is no C file and no build step, natively or in
   wasm. The cost: the interpreter has no code of its own for an inline C extern, so code that
   writes a buffer needs the compiled LeanUI library. Executables and wasm link it; `#eval` and
   `lean --run` work once it is loaded (`lake build LeanUI:shared`, then
   `lean --load-dynlib=.lake/build/lib/libleanui_LeanUI.dylib`, as `tests/browser/keyed-dom.mjs`
   does), and so does the editor in a downstream library with `precompileModules = true`.
2. **No buffer per command.** Interning returned an `(id, buffer)` pair and looked names up with
   `HashMap.get?`; the compiler took the buffer apart around the pair and allocated a new one for
   every command that names something, plus an `Option` per lookup. Now `named` passes the
   caller's own buffer to an out-of-line writer that takes the id (updated in place), uses
   `getD … 0` (ids start at 1; on a miss a `contains` check keeps a name that really has id 0
   exact), and defines new names out of line.

Measured A/B against `0a415c1` on the same machine and session (native: median of five
alternating runs of `leanui-perf`, lazy rows; Chromium 151 traced script time, the median over
three alternating rounds of nine fresh loads each):

| operation | native before | native after | Chromium script before | after |
|---|--:|--:|--:|--:|
| create 1,000 rows | 1.93 ms | 1.13 ms | 6.94 ms | 5.60 ms |
| replace all 1,000 rows | 2.64 ms | 1.67 ms | 10.28 ms | 8.93 ms |
| create 10,000 rows | 20.25 ms | 11.83 ms | 63.66 ms | 52.66 ms |
| append 1,000 rows to 1,000 | 2.25 ms | 1.39 ms | 8.04 ms | 6.74 ms |
| clear 1,000 rows | 0.49 ms | 0.41 ms | 2.94 ms | 2.87 ms |

The other operations write a few words and did not change. In the create-1,000-rows profile,
Lean's share of the click went from 58% to 51% (`lean_byte_array_push`, 8%, and
`lean_string_to_utf8` are gone); looking names up (`HashMap.getD` and `lean_string_hash`) is now
3%. The wasm grew 2% (1,036,399 to 1,057,465 bytes) and shrank slightly with brotli.

Tried and left out: a C helper per word or per command (out of line, it needs a C build step for
native builds; in a native micro-benchmark a call per word took 7× as long as the inline store),
pure-Lean alternatives (growing with `copySlice`, then `set!`/`uset`: less than half the gain in
the same micro-benchmark), a small
two-way cache in front of the name map (natively no change, in Chromium within noise, 35 KB more
wasm), and keeping the buffers' storage across updates in `reset` (no change in Chromium).

## Findings about measuring

- **Playwright's Firefox is not Firefox.** The Firefox build Playwright drives (Nightly 153 here)
  runs wasm about 8× slower than release Firefox 158, for any wasm (a plain wasm32 C program
  too) and whether or not automation is attached. Firefox numbers in this file come from the
  release browser via the self-driving runner.
- **Efficiency cores.** On Apple silicon, a renderer that is mostly idle between clicks is often
  scheduled on an efficiency core, and per-click timings become bimodal (0.2 ms or 1.2 ms for the
  same select). Back-to-back clicks stay on performance cores; fresh-page medians are robust.
- **What Memory64 costs.** The same allocation-heavy C workload built for wasm32 and wasm64
  ([`bench/wasm64`](../bench/wasm64)) takes 13.5 ms as wasm32 and 14.4 ms as wasm64 in Firefox 158
  (1.07×), 12.5 and 14.2 ms in Chrome 155 (1.14×). Memory64 is not why wasm64 LeanUI costs what it
  does; the remaining overhead is Lean's allocation pattern and the DOM calls.
- **The allocator.** dlmalloc and mimalloc are equally fast here (single-threaded), but mimalloc
  reserves more: wasm memory 26.6 MB at load (dlmalloc: 16 MB, the initial size) and 67 MB after
  10,000 rows (dlmalloc: 34 MB). LeanUI builds with dlmalloc.
- **Fresh loads, not warm pages.** Chrome's optimizing tier changes nothing measurable for
  LeanUI after the first second (a 12-second warm-up probe stays flat once the core scheduling
  effect is removed).

## Method

**The apps.** [`examples/Bench.lean`](../examples/Bench.lean) is the standard benchmark app: the same
buttons, ids, table structure and class names, keyed rows (`keyed` + `lazy` on id, label and
selection), and labels from a 64-bit LCG instead of `Math.random`.
[`bench/vanilla/index.html`](../bench/vanilla/index.html) is the reference: template cloning,
direct node references and event delegation, the usual fastest hand-written approach, with the
same markup and the same LCG, so **both build identical tables** (the harness checks this before
measuring). Both pages load the same stylesheet, [`bench/bench.css`](../bench/bench.css), a small
stand-in for the Bootstrap rules the original benchmark uses, so layout and paint work is identical.

**Operations** ([`bench/ops.mjs`](../bench/ops.mjs)): create 1,000 rows; replace them; update every
10th row; select a row; swap rows 2 and 999; remove a row; create 10,000 rows; append 1,000 rows to
1,000; clear 1,000 rows. Each has the original benchmark's warm-ups.

**Chromium, traced** ([`tests/browser/bench.mjs`](../tests/browser/bench.mjs), Playwright's
Chromium): each measured click is a real input event recorded with the DevTools timeline. *Script*
is the click's `EventDispatch`: for LeanUI, the Lean update, view and diff, and applying the
command buffer to the DOM. *Render* is the main-thread work of the frame that follows (style,
layout, pre-paint, paint, layerize, commit). *Total* is their sum: the CPU time the click costs,
without the wait for the next vsync, which is up to a frame of idle time for every
implementation alike. The same harness records memory after the standard sequences (JS heap after
a full GC, the wasm linear memory, DOM nodes) and startup (navigation to first render, bytes
transferred).

**Release browsers, self-driven** ([`bench/runner.html`](../bench/runner.html),
[`tests/browser/selfbench.mjs`](../tests/browser/selfbench.mjs)): the installed browser is launched
directly on a throwaway profile with no automation protocol attached; the page loads each
implementation in an iframe, performs the operations itself and posts the results back. *Script*
is the synchronous click; *layout* adds a forced layout (no paint). Chrome reports
`performance.now()` in 0.1 ms steps without cross-origin isolation, so its smallest numbers are
coarse.

**Native** ([`tests/Perf.lean`](../tests/Perf.lean), `leanui-perf`): the Lean side alone (update,
view, diff, command encoding, no DOM), on the same app, with lazy rows and with eager rows.

## Reproducing

```bash
tools/build-app.sh BenchApp bench                       # dist/bench (the page is examples/bench.html)
node tests/browser/bench.mjs --runs 7 --json out.json   # Chromium traces, memory, startup
node tests/browser/selfbench.mjs /Applications/Firefox.app/Contents/MacOS/firefox firefox
node tests/browser/selfbench.mjs "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" chromium
./.lake/build/bin/leanui-perf                           # native, lazy and eager rows
LEANUI_PAGE=examples/bench.html tools/build-app.sh BenchApp bench-prof --debug
node tests/browser/profile.mjs dist/bench-prof --op create1k   # where the script time goes
bench/wasm64/build.sh && node tests/browser/wasm64.mjs <browser-binary> <firefox|chromium>
```

Run browser measurements one at a time on an otherwise idle machine.
