# LeanUI performance

LeanUI is measured with the [js-framework-benchmark](https://github.com/krausest/js-framework-benchmark)
keyed operations, against a hand-written vanilla JavaScript implementation, in Chromium (with
traces), in release Chrome and Firefox, and natively. This page gives the results, the method,
and what was learned getting there.

All numbers: Apple-silicon Mac (10 performance and 4 efficiency cores), macOS 26, headless
browsers, medians. Each browser measurement loads a fresh page, does the operation's warm-up clicks,
and times one click.

<!-- SUMMARY -->

<!-- TABLES -->

## Where LeanUI's time goes

<!-- PROFILE -->

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

## Findings about measuring

- **Playwright's Firefox is not Firefox.** The Firefox build Playwright drives (Nightly 153 here)
  runs wasm about 8× slower than release Firefox 158, for any wasm (a plain wasm32 C program
  too) and whether or not automation is attached. Firefox numbers in this file come from the
  release browser via the self-driving runner.
- **Efficiency cores.** On Apple silicon, a renderer that is mostly idle between clicks is often
  scheduled on an efficiency core, and per-click timings become bimodal (0.2 ms or 1.2 ms for the
  same select). Back-to-back clicks stay on performance cores; fresh-page medians are robust.
- **What Memory64 costs.** The same allocation-heavy C workload built for wasm32 and wasm64
  ([`bench/wasm64`](../bench/wasm64)): <!-- WASM64 -->
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
