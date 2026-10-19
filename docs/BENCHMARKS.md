# LeanUI performance

LeanUI is measured with the [js-framework-benchmark](https://github.com/krausest/js-framework-benchmark)
keyed operations, against a hand-written vanilla JavaScript implementation, in Chromium (with
traces), in release Chrome and Firefox, and natively. This page gives the results, the method,
and what was learned getting there.

Measured at commit `93b8470` (2026-10-18); sections that compare two builds name the build they
compare against. All numbers: an Apple M4 Max (10 performance and 4 efficiency cores), macOS 26,
headless browsers, medians. Each browser measurement loads a fresh page, does the operation's
warm-up clicks, busy-waits 30 ms (so the click does not land on an efficiency core; see below)
and times one click.

## Summary

- **Against hand-written JavaScript**, LeanUI's keyed-suite CPU time is **1.19×** vanilla's in
  Chromium (geometric mean over the nine operations, script and rendering), **1.43×** in
  release Chrome (1.22× without "highlight a row", a 0.5 ms operation that Chrome's 0.1 ms timer
  steps distort) and **1.50×** in release Firefox (script and layout). Rendering work is about
  the same for both (identical DOM; creating 10,000 rows renders 9% longer for LeanUI); the
  difference is script: Lean's update, view and diff in wasm, and applying the command buffer.
- **The create path** (template cloning, cheaper encoding, a faster applier, fewer allocations;
  `3db6ac9` → `93b8470`) took creating 1,000 rows from 7.10 to 3.81 ms of script in Chromium and
  from 1.90 to 0.63 ms natively; no operation got slower in the Chromium A/B, and release Firefox's
  small clicks moved within its timer noise (see "The create path").
- **The photo editor** ([below](#the-photo-editor)): on its 19 image operations Lean (wasm) takes
  0.71–0.73× the time of the same algorithms in plain JavaScript, byte-identical; its sliders
  preview in 20–130 ms at any image size, and full-resolution work runs in frame-sized slices.
- **Natively**, selecting a row costs Lean 0.08 ms (update, view, diff, encoding), and creating
  1,000 rows 0.63 ms.
- **Memory**: 16 MB of wasm memory at load,
  27.75 MB after creating 10,000 rows (wasm memory never shrinks);
  the JavaScript heap stays within 3.01 MB of vanilla's.
- **Startup**: ready 25 ms after navigation (vanilla
  4.7 ms), of which 20.3 ms is
  compiling and instantiating the wasm, initializing Lean and the first render;
  168.36 KB over the wire with brotli.

## Results

### Chromium 151, traced: CPU time per click (median of 9 fresh loads)

| operation | LeanUI total | script | render | vanilla total | script | render | LeanUI ÷ vanilla |
|---|--:|--:|--:|--:|--:|--:|--:|
| create 1,000 rows | 19.67 ms | 3.77 | 15.88 | 17.84 ms | 1.90 | 15.93 | **1.10×** |
| replace all 1,000 rows | 21.62 ms | 6.46 | 15.16 | 18.30 ms | 3.26 | 15.06 | **1.18×** |
| update every 10th of 1,000 rows | 3.29 ms | 0.81 | 2.49 | 2.76 ms | 0.08 | 2.68 | **1.19×** |
| highlight a row (of 1,000) | 1.00 ms | 0.34 | 0.66 | 0.74 ms | 0.03 | 0.72 | **1.35×** |
| swap 2 of 1,000 rows | 3.90 ms | 0.78 | 3.12 | 3.42 ms | 0.05 | 3.37 | **1.14×** |
| remove one of 1,000 rows | 4.56 ms | 0.53 | 4.03 | 4.27 ms | 0.05 | 4.23 | **1.07×** |
| create 10,000 rows | 186.13 ms | 32.41 | 154.01 | 157.65 ms | 16.82 | 140.83 | **1.18×** |
| append 1,000 rows to 1,000 | 22.10 ms | 5.77 | 16.35 | 18.24 ms | 1.79 | 16.46 | **1.21×** |
| clear 1,000 rows | 2.61 ms | 2.41 | 0.20 | 1.96 ms | 1.74 | 0.21 | **1.33×** |

Geometric mean of the ratios: **1.19×**.

### Firefox 158 (release, no automation): script and layout per click (median of 9 fresh loads)

| operation | LeanUI layout | script | vanilla layout | script | LeanUI ÷ vanilla |
|---|--:|--:|--:|--:|--:|
| create 1,000 rows | 14.20 ms | 5.26 | 12.36 ms | 2.46 | **1.15×** |
| replace all 1,000 rows | 18.26 ms | 10.78 | 12.28 ms | 4.12 | **1.49×** |
| update every 10th of 1,000 rows | 2.86 ms | 1.08 | 2.26 ms | 0.12 | **1.27×** |
| highlight a row (of 1,000) | 1.14 ms | 0.84 | 0.20 ms | 0.04 | **5.70×** |
| swap 2 of 1,000 rows | 6.38 ms | 1.12 | 5.44 ms | 0.10 | **1.17×** |
| remove one of 1,000 rows | 6.28 ms | 0.74 | 5.62 ms | 0.06 | **1.12×** |
| create 10,000 rows | 121.14 ms | 39.34 | 103.44 ms | 21.72 | **1.17×** |
| append 1,000 rows to 1,000 | 16.90 ms | 7.82 | 12.46 ms | 2.10 | **1.36×** |
| clear 1,000 rows | 3.72 ms | 3.60 | 2.48 ms | 2.34 | **1.50×** |

Geometric mean: **1.50×**. Ready after navigation: LeanUI 16.54 ms, vanilla 2.2 ms.

### Chrome 155 (release, no automation): script and layout per click (median of 9 fresh loads)

| operation | LeanUI layout | script | vanilla layout | script | LeanUI ÷ vanilla |
|---|--:|--:|--:|--:|--:|
| create 1,000 rows | 15.60 ms | 3.50 | 15.20 ms | 1.90 | **1.03×** |
| replace all 1,000 rows | 16.60 ms | 6.20 | 14.20 ms | 3.20 | **1.17×** |
| update every 10th of 1,000 rows | 2.30 ms | 0.80 | 1.70 ms | 0.00 | **1.35×** |
| highlight a row (of 1,000) | 0.50 ms | 0.30 | 0.10 ms | 0.00 | **5.00×** |
| swap 2 of 1,000 rows | 2.50 ms | 0.80 | 2.00 ms | 0.00 | **1.25×** |
| remove one of 1,000 rows | 2.40 ms | 0.50 | 1.90 ms | 0.00 | **1.26×** |
| create 10,000 rows | 132.40 ms | 28.00 | 119.50 ms | 14.70 | **1.11×** |
| append 1,000 rows to 1,000 | 17.50 ms | 4.40 | 14.80 ms | 1.70 | **1.18×** |
| clear 1,000 rows | 2.80 ms | 2.70 | 1.90 ms | 1.80 | **1.47×** |

Geometric mean: **1.43×**. Ready after navigation: LeanUI 8.2 ms, vanilla 2.6 ms.

### Memory (Chromium, after a full GC)

| after | LeanUI JS heap | LeanUI wasm memory | vanilla JS heap | DOM nodes |
|---|--:|--:|--:|--:|
| load | 1.5 MB | 16 MB | 1.06 MB | 47 |
| creating 1,000 rows | 1.97 MB | 16 MB | 1.24 MB | 11057 |
| 5 updates of every 10th row | 1.98 MB | 16 MB | 1.26 MB | 11057 |
| 5 create/clear cycles | 1.68 MB | 16 MB | 1.11 MB | 57 |
| creating 10,000 rows | 5.61 MB | 27.75 MB | 2.6 MB | 110057 |

DOM nodes are LeanUI's page, as the DevTools protocol counts them. From the first rows on they
include the runtime's template, a detached copy of one row (10 nodes;
[`docs/PROTOCOL.md`](PROTOCOL.md), section 7): before templates the same sequences gave 11047,
47 and 110047 (at `9a4c9c6`). Vanilla's page, whose markup differs, has 76 nodes at load and
11076 with 1,000 rows.

### Startup and size (Chromium)

| | LeanUI | vanilla |
|---|--:|--:|
| ready after navigation | 25 ms | 4.7 ms |
| of which wasm instantiation + Lean init + first render | 20.3 ms | |
| transferred (uncompressed) | 1220.33 KB | 5.94 KB |
| brotli | 168.36 KB | 2.06 KB |

### Native Lean (update, view, diff, encoding; no DOM)

| operation | lazy rows | eager rows | command words |
|---|--:|--:|--:|
| create 1,000 rows | 0.63 ms | 0.63 ms | 36000 |
| replace all 1,000 rows | 1.03 ms | 1.02 ms | 58999 |
| update every 10th of 1,000 rows | 0.19 ms | 0.51 ms | 400 |
| highlight a row (of 1,000) | 0.08 ms | 0.45 ms | 8 |
| swap 2 of 1,000 rows | 0.24 ms | 0.61 ms | 8 |
| remove one of 1,000 rows | 0.14 ms | 0.52 ms | 22 |
| create 10,000 rows | 6.76 ms | 6.71 ms | 359996 |
| append 1,000 rows to 1,000 | 0.82 ms | 1.14 ms | 36999 |
| clear 1,000 rows | 0.28 ms | 0.26 ms | 22000 |

Each time is the median of seven runs of `leanui-perf`.

## The create path

Four pieces of work on creating rows landed between `3db6ac9` and `93b8470`: template cloning
("What template cloning changed" below), cheaper encoding (inline C stores, allocation-free
interning: "What made encoding cheap"), a faster applier (`className` for an HTML `class`, one
`replaceChildren()` per emptied list: "The runtime alone"), and fewer allocations (`keyedLazy`,
shared constants, state-passing mount, clone and release: "Allocations"). Measured A/B, the two
commits in one quiet session. Native: median of seven alternating runs of `leanui-perf`, lazy
rows. Chromium 151 traced, LeanUI only: three alternating rounds of nine fresh loads, the median
of the three rounds' medians.

| operation | native before | after | Chromium script before | after | Chromium total before | after |
|---|--:|--:|--:|--:|--:|--:|
| create 1,000 rows | 1.899 ms | 0.632 ms (−67%) | 7.10 ms | 3.81 ms (−46%) | 22.52 ms | 19.59 ms (−13%) |
| replace all 1,000 rows | 2.607 | 1.026 (−61%) | 9.95 | 6.26 (−37%) | 24.84 | 21.17 (−15%) |
| update every 10th of 1,000 rows | 0.235 | 0.191 (−19%) | 0.83 | 0.79 (−5%) | 3.33 | 3.30 (−1%) |
| highlight a row (of 1,000) | 0.117 | 0.080 (−32%) | 0.38 | 0.36 (−5%) | 1.05 | 1.04 (−1%) |
| swap 2 of 1,000 rows | 0.326 | 0.240 (−26%) | 0.86 | 0.79 (−8%) | 3.99 | 3.93 (−2%) |
| remove one of 1,000 rows | 0.207 | 0.144 (−31%) | 0.57 | 0.52 (−9%) | 4.64 | 4.56 (−2%) |
| create 10,000 rows | 19.826 | 6.764 (−66%) | 59.76 | 32.70 (−45%) | 229.32 | 188.17 (−18%) |
| append 1,000 rows to 1,000 | 2.190 | 0.823 (−62%) | 7.74 | 5.89 (−24%) | 23.84 | 22.35 (−6%) |
| clear 1,000 rows | 0.492 | 0.285 (−42%) | 2.93 | 2.44 (−17%) | 3.15 | 2.65 (−16%) |

A created row now writes about 36 command words instead of 122: create 1,000 rows 122,000 →
36,000, replace 144,999 → 58,999, create 10,000 rows 1,220,000 → 359,996, append 122,999 →
36,999; the other operations write as many words as before. Natively, eager rows gain as much
on create and replace (create 1,000 rows 1.889 → 0.628 ms), 55% on append and 9 to 15% on the
small updates. Rendering is unchanged within ±2.1% except for create 10,000 rows (169.21 →
155.28 ms, −8.2%), so in total CPU time creating and replacing rows gain 13 to 18%, append 6%,
clear 16%.

Select and update every 10th did not get slower: their script went from 0.38 to 0.36 ms and from
0.83 to 0.79 ms, and natively they take 32% and 19% less. The 8–14% and 2–6% higher fresh-page
figures measured during the state-passing work ("State passing in mount, clone and release")
were against `492772a`, which already had templates, the encoding and applier work and most of
the allocation work; "Heap history" explains why such a click moves on a fresh page when its own
code does not change.

In release Firefox 158 (selfbench, LeanUI only, three alternating rounds of fifteen fresh loads,
the median of the rounds' medians), the small clicks moved within the noise of its timer: select
0.72 → 0.80 ms script (rounds 0.60–0.74 against 0.68–0.86), update every 10th 1.28 → 1.22, swap
1.26 → 1.18. The Results table's Firefox "highlight a row" (1.14 ms with layout) is higher than
at `9a4c9c6` (0.78 ms) mostly between sessions: in this A/B the `3db6ac9` build itself measured
0.94 ms with layout, the final one 1.06 (raw: `work/bench/final3/ff-*.json`).

## Where LeanUI's time goes

Sampled CPU profiles of the synchronous click in Chromium, on a build with function names
(`tools/build-app.sh BenchApp bench-prof --debug`, `tests/browser/profile.mjs`; the create
profile also samples the clear that precedes each click):

| | create 1,000 rows (3.72 ms per click) | select a row (0.18 ms per click) |
|---|--:|--:|
| Lean, in wasm | 48% | 74% |
| the browser's DOM work | 24% | 2% |
| LeanUI's JavaScript runtime (applying commands, events) | 15% | 3% |
| other (engine, GC) | 13% | 21% |

- **Creating rows** costs most in copying the template (`cloneNode`, 16.5%) and attaching the
  copies (`appendChild`, 4.3%), in the runtime's walk that binds each copy's handles (`clone`,
  8.3%) and its dispatch loop (`apply`, 4.6%), in Lean's side of the clone (`cloneWalk` 5.7%,
  `TplShape.matches` 4.6%, which checks that a row has the template's shape, `cloneAttrs` 2.2%),
  and in the allocator (`free` 6.0%, `lean_dec_ref_cold` 3.7%, `malloc` 3.6%; part of it, with
  `freeNodeS` 2.9% and `releaseS` 2.0%, frees the previous rows during the setup's clear, as does
  that clear's `replaceChildren`, 3.2%). `createElement` and `setAttribute` are no longer among
  the top functions (none of them takes more than 0.2%).
- **Small updates** are dominated by allocation: building the new view (per row, the keyed lazy
  node, its key and its dependencies; a select allocates 4,107 small objects in all, 6,054 times
  in wasm) and freeing the old one is about a quarter of the time (`free` 10.9%,
  `lean_dec_ref_cold` 7.6%, `malloc` 5.7%), followed by `patchNode` (7.4%), the view itself
  (`Bench.view`, 5.6%), comparing (`sameF` 3.8%, `Dep` equality 3.0%) and the cached sizes
  (`Node.size`, 3.7%). The DOM work is 2%.
- **The runtime alone** ([`tests/browser/apply-bench.mjs`](../tests/browser/apply-bench.mjs)
  replays the app's recorded buffers through `Runtime.apply`, with no Lean): the
  create-1,000-rows buffer is 6,000 commands (`CLONE` 1,000, `SET_TEXT` 2,000, `SET_LISTENER`
  2,000, `APPEND_CHILD` 1,000; 36,000 words), and applying it on a fresh page costs 1.745 ms in
  Chromium 151 and 2.260 ms in Playwright's Firefox (median of 25; create 10,000 rows 15.985 and
  24.060 ms, clear 1,000 rows 1.225 and 2.820 ms). Before templates, when that buffer was 30,000
  commands, it cost 2.2–2.4 ms in Chromium 151 and 3.4–3.5 ms in Playwright's Firefox, three
  quarters of it in the DOM calls themselves (Chromium: `appendChild` about a third, the class
  writes a fifth, `createElement` a sixth), and the dispatch loop ran at 2–5 ns per command once
  optimized. On that buffer (the applier work, against `0a415c1`), two changes took about a
  tenth off the apply: on a hot page in Chromium, 2.38 → 2.18 and 2.55 → 2.28 ms in two sessions
  (ratios 0.92 and 0.89); in Playwright's Firefox, on fresh pages, 3.66–3.76 → 3.38–3.52 ms
  (0.92–0.94). On fresh pages in Chromium the old runtime's figure depends on the session (2.4 or
  2.9 ms, see "The JIT state of a fresh page" below), so the fresh ratio ranged from 0.80 to
  0.91. Writing `class` through `className` saved 7–9% of that apply, folding a list's removals
  into one `replaceChildren()` 4–5% of a clear's. End to end in traced Chromium (the applier work
  against `0a415c1`, before templates), the create-1,000-rows click's script went down 2–7%
  (7.1 → 6.6, 6.9 → 6.5 and 6.6 → 6.5 ms in three sessions), replace 3–4%, clear 2–4%, append
  unchanged; release Firefox within noise. Caching attribute strings, cloning elements from a
  per-tag prototype (within noise in Chromium, 2–4% in Firefox), building rows in a
  `DocumentFragment` and skipping repeated `delegate` calls did not pay. A clone now brings its
  classes from the template, so the benchmark's create buffers have no `SET_ATTR`, and the
  `className` gain applies to classes written by `SET_ATTR`: subtrees mounted node by node, a
  copy whose class differs from its template's, and class changes (select's `danger`); the clear
  buffer is the same as before.
- **Next steps.** Two that this list first named are done: writing the command buffer a word
  at a time ("What made encoding cheap") and cloning repeated subtrees from templates ("What
  template cloning changed"). What the profiles and counts still point at:
  - the view's array literals: in `Bench.row`'s generated C, four single-child arrays start from
    one shared empty array and two attribute arrays from constants, so five pushes per row copy
    an array (`lean_copy_expand_array` under `Bench.row`: 83 of the 3,114 samples of a native
    create-and-clear loop, taken during the state-passing work, just before `43e20b3` was
    committed; the binary is not recorded);
  - one pair per element with children while mounting (6 of the 21 small objects that mounting
    a row allocates, see "Allocations");
  - growing the command buffer: in the same native sample `memmove` is 5% (158 samples), but
    most of it is the benchmark's own label building (88, `lean_string_append` in `Bench.build`)
    and turning ids into strings (22); copying texts into the buffer is 24, and growing its byte
    arrays (`lean_copy_sarray`, in the `Buf` writers of `LeanUI/Patch.lean` and in Diff's
    `pushHandles`) 23;
  - the fresh-page cost of a click that mostly compares, such as "highlight a row", which depends
    on where earlier clicks left the objects it reads ("Heap history" below);
  - as before, not building the view of rows whose model did not change (4,003 of a select's
    4,107 small objects are the view).

### Allocations

Every allocation is countable: `leanui-perf allocs` counts the *small objects* (constructors,
thunks: what Lean's heartbeat counter counts) of each benchmark operation natively, by phase, and
`tests/browser/allocs.mjs` counts every `malloc` and `free` of one click in a wasm build linked
with `tools/alloc-count.c`. Both are exact and deterministic, so two builds compare without noise.
Creating a benchmark row (at commit `93b8470`, as since `43e20b3`) takes 41 small objects natively
and 62 allocations in wasm (small objects included); before mounting, cloning and releasing were
rewritten in state-passing style (below; at `492772a`, templates and inline encoding already in)
it took 67 and 89 (at `5c6d926`, before templates and inline encoding: 123 and 154):

| phase (`leanui-perf allocs`, create 1,000 rows) | small objects per created row, before | after |
|---|--:|--:|
| update (building the rows) | 2 | 2 |
| view (the keyed lazy row: node, key, dependencies) | 4 | 4 |
| rendering the row (10 nodes, 2 handlers) | 14 | 14 |
| mounting and encoding it (`CLONE`, what the clone still needs, the list diff around it) | 47 | 21 |
| **the whole update** | **67.07** | **41.07** |

The 21 that remain are the row's 11 mounted nodes (10, and the lazy row), its 2 slots (`some h`)
and listener-table entries, and one pair per element with children (6). The rest of wasm's
allocations are arrays (children, listener tables), strings and closures. `leanui-perf
allocs-nodes` gives the cost of mounting one node of each shape: an element costs 2 small objects
(its `Node` and the pair it is returned in; 5 before), an attribute nothing (1 before), a listener
2 (its slot and its table entry, as before), a text child 1 (2 before); a benchmark row mounted
node by node 20 (60 before), 1,000 rows, all but the first two cloned, 21,087 (47,103 before).

| operation (per created row, or per click) | small objects (native), before | after | wasm allocations, before | after |
|---|--:|--:|--:|--:|
| create 1,000 rows | 67.07 / row | 41.07 | 88.94 / row | 61.94 |
| replace all 1,000 rows | 95.08 / row | 44.08 | 116.98 / row | 64.98 |
| append 1,000 rows to 1,000 | 82.08 / row | 50.08 | 105.94 / row | 72.94 |
| create 10,000 rows | 67.01 / row | 41.01 | 88.85 / row | 61.85 |
| clear 1,000 rows | 20,066 | 65 | 20,085 (59,086 frees) | 84 (39,085) |
| swap 2 of 1,000 rows | 17,057 | 12,063 | 18,982 | 13,986 |
| remove one of 1,000 rows | 10,088 | 8,069 | 11,947 | 9,936 |
| highlight a row; update every 10th | 4,107; 11,966 | the same | 6,054; 15,156 | the same |

#### State passing in mount, clone and release

`DiffM` is `StateM`. In Lean 4.34's generated code every call that is not inlined returns its
result and the state as a freshly allocated pair, so a loop whose body makes such a call costs one
pair per iteration. The loop itself, `for` or `while`, costs nothing per iteration: one whose body
updates the state inline allocates the same two or three objects for 0 or 1,000 iterations, and
calling a `@[noinline]` update from the same loop adds exactly one per iteration
(`testLoopPairs` in `leanui-tests` pins this). The paths that run once per created or removed
node are now plain functions on `DiffState` that return the state, or one pair at the
end: `releaseS`, `mountS` (`mountElem`, `mountKids`, `mountCandidate`, `mountShape`), `cloneOf`
(`cloneWalk`, `cloneKids`, `cloneAttrs`), `mountAppend` for a list that grows, and `placeMid` for
the middle of a keyed list. What the compiler needs from such code, each costing an allocation
when it is missing (the allocation lane found most of these on the code before templates):

- one small `@[noinline]` function per state update (`emitSetText`, `takeSlot`, ...): when two
  branches update the state differently and meet again inside one function, the compiler passes
  the fields to the join point and builds a new cell; no inline helper that returns a pair;
- what an update hands out is read first by a separate pure `peek` (`peekNode`, `peekSlotAt`,
  `handleAt`), never returned together with the state;
- an element's listener table is computed purely, from the slots its listeners will take
  (`listenersOf`), so setting its attributes and listeners is a pass that returns only the state;
- texts and childless elements are built inside their parent's loop: only an element with
  children costs a pair, the one it is returned in;
- a clone's handles are read from the free list during the walk and taken after it, and `CLONE`
  writes them straight from the free list: no array of handles per clone;
- shared constants for an empty listener table and empty children (`noListeners`, `noKids`: a
  `#[]` in an argument position is allocated where it is written; `testSharedEmpty` pins both),
  `getD` rather than `get?`, keys checked for uniqueness unboxed (`uniqueKeys` took `Option`s),
  `attrsKey` as a plain loop (`findSome?` allocated per element).

The command buffers are byte for byte what they were: the corpora `leanui-props --long --only
corpus` writes for four seeds (every buffer of 1,280 sessions and of 32 template scenarios, with
templates and without) are identical to those of the build before, and every suite passes,
natively and in Chromium and Firefox; the nesting limit is unchanged (1,050 levels in Chromium,
1,700 in Firefox).

Measured A/B against `492772a` (after: the code of `43e20b3`, which `93b8470` changes only in
comments) on the same machine and session. Native: median of seven alternating runs of
`leanui-perf`, lazy rows (min–max). Chromium 151 traced script time: median of three alternating
rounds of nine fresh loads each (the three rounds' medians):

| operation | native before | after | Chromium script before | after |
|---|--:|--:|--:|--:|
| create 1,000 rows | 0.83 ms (0.82–1.00) | 0.62 ms (0.61–0.63) | 4.11 ms (4.02–4.15) | 3.82 ms (3.74–3.87) |
| replace all 1,000 rows | 1.39 (1.37–1.53) | 1.01 (0.99–1.02) | 7.10 (7.09–7.12) | 6.36 (6.35–6.43) |
| append 1,000 rows to 1,000 | 1.09 (1.07–1.14) | 0.81 (0.80–0.81) | 6.32 (6.14–6.37) | 5.95 (5.84–5.98) |
| create 10,000 rows | 8.87 (8.66–8.99) | 6.74 (6.67–6.82) | 36.58 (36.22–36.61) | 33.10 (32.98–33.14) |
| clear 1,000 rows | 0.39 (0.38–0.40) | 0.28 (0.27–0.29) | 2.79 (2.77–2.81) | 2.45 (2.41–2.46) |
| swap 2 of 1,000 rows | 0.28 (0.27–0.29) | 0.24 (0.24–0.24) | | |
| remove one of 1,000 rows | 0.16 (0.16–0.17) | 0.14 (0.14–0.15) | | |
| update every 10th of 1,000 rows | 0.19 (0.19–0.20) | 0.19 (0.19–0.19) | 0.84 (0.83–0.85) | 0.87 (0.87–0.88) |
| highlight a row (of 1,000) | 0.080 (0.078–0.083) | 0.079 (0.078–0.080) | 0.37 (0.37–0.37) | 0.41 (0.41–0.42) |

Three earlier sessions against `195e344` (two of them without `placeMid`; `Buf.handles` still
allocated once per clone) gave the same picture for the creates: create 1,000 rows −6 to −11%,
replace −10 to −11%, create 10,000 rows −8 to −10%, append −6 to −8%. On one page clicked over and over (hot: the mean
of 800 selects, 200 updates and 80 creates; median of three rounds), create 1,000 rows went from
3.45 to 3.07 ms, select stayed at 0.155 ms and update every 10th at 0.44 ms. Rendering is
unchanged, so in script plus rendering the creates gain 1.5 to 4%, clear 12%.

The fresh-page "highlight a row" and "update every 10th" figures came out 8–14% and 2–6% higher
in every session (six), although almost none of the code they run changed. The one change they
run is the key check in `patchNode`'s element case (`attrsKey`, now a call of `attrsKeyFrom`
instead of an inlined loop): 4 or 5 times per select (the three elements above the rows and the
one or two rows whose class changes) and 303 times per update every 10th (three elements in each
of 100 rows), each over at most two attributes, far too little work to explain the difference.
The rest compiles to the same C: `sameF`, `kidsSameF`, `patchC`, `patchSame`, `rebind`,
`unchanged`, `patchAttrs` (but for the name of the empty table it starts from, now
`noListeners`) and the branch of `patchKidsC` they take (its append, removal and keyed-middle
branches changed); `sameF`, `patchSame` and `Dep` equality also compile to wasm functions of the
same size. Both clicks allocate exactly as often, natively they take the same time, and on hot
pages they are within 1%. On a fresh page they are dominated by first
touches of the memory they read, the 1,000 rows' keys and dependencies that the create made
(a sampled profile of the measured click over 60 fresh pages puts the extra time in comparing
them), and where those objects lie depends on everything allocated before them; see
"Heap history" below. Against `3db6ac9`, before any of the create path, neither click is slower
(0.38 → 0.36 and 0.83 → 0.79 ms of script; "The create path").

## What made the diff fast

The first working diff spent 1.65 ms re-rendering 1,000 unchanged rows natively, almost all of it
allocating and freeing. Five changes took it to 0.06 ms by `9a4c9c6` (this section's figures are
from before the create path); each is tested by the randomized list tests and the property
suites against an independent reference model.

1. **Change tracking.** `patch` reports whether a node changed. An unchanged node is returned as
   the *same* object, so unchanged parents are not rebuilt either.
2. **A pure check before any monadic work.** Every monadic step in Lean's state monad that is
   not inlined returns a freshly allocated pair. `sameF` decides, without allocating, that a
   subtree needs no command; the subtree then only has its listener slots re-pointed, with one
   state update for a whole run of unchanged siblings. Subtree sizes are cached in the mounted
   nodes so the check only runs on subtrees within its budget, which keeps the total work linear at
   any depth (patching a 100,000-level chain went from 294 ms to 21 ms, the cost of mounting it).
3. **Exact lazy rows.** Freeing the discarded view was the largest remaining cost (about 27
   objects per benchmark row). `lazy` with exact dependencies (`Dep`, compared structurally,
   never hashed) and its own key skips both building and diffing a row: selecting a row went from
   0.47 ms (eager rows, with the pure check) to 0.12 ms.
4. **No hidden copies.** The diff state is taken out of the runtime state before diffing, so its
   slot table is updated in place instead of being copied on every update; elements without
   listeners or children share one empty array.
5. **Cheap strings.** The UTF-16 length of an ASCII string is read from the string object
   (byte size equals length) instead of walking it.

## What template cloning changed

Before templates a benchmark row was 30 commands and 122 words: a `CREATE_ELEMENT` or
`CREATE_TEXT` per node, a `SET_ATTR` per attribute, its two listeners and an `APPEND_CHILD` per
node. Now Lean mounts the first row of a shape node by node, builds the second as a prototype and
sends `TEMPLATE`, and every later row is a `CLONE` of it followed by what differs
([`docs/PROTOCOL.md`](PROTOCOL.md), section 7). After the warm-up every row of the measured click
is a clone: the create-1,000-rows buffer is `CLONE` 1,000, `SET_TEXT` 2,000 (id and label),
`SET_LISTENER` 2,000 and `APPEND_CHILD` 1,000, 36,000 words instead of 122,000. The classes come
with the copy, so there is no `SET_ATTR`, and the only names are the two events. In the browser
a row is one `cloneNode(true)` and a walk that binds the copy's ten handles; the runtime keeps
each template as a detached copy of its prototype (the 10 extra DOM nodes under "Memory").

The A/B in "The create path" is all four pieces together. Templates alone were measured by the
integration review at `195e344` (the templates, encoding, applier and allocation lanes merged,
before state passing), with templates turned off in a scratch edit and as committed, Chromium
151 traced script, the median of three alternating rounds of nine fresh loads: create 1,000
rows 5.48 → 4.16 ms (−24%), create 10,000 rows 51.96 → 37.69 ms (−27%), replace all 1,000 rows
8.67 → 7.21 ms (−17%). These figures are from the review's own run, not from this page's final
measurements (raw: `work/lanes/integration-review/browser-ab/{notpl,head}.{1,2,3}.json`). The
hand-written reference clones a template
row too; with both cloning, its create-1,000-rows script is 1.90 ms against LeanUI's 3.77
(Results). The rest of LeanUI's is Lean's update, view and diff, and finishing each copy (the
profile under "Where LeanUI's time goes").

## What made encoding cheap

Before templates, creating 1,000 rows wrote 122,000 words and 10,000 strings into the command
buffer and named a tag, attribute or event 18,000 times (with templates: 36,000 words, 2,000
strings and 2,000 event names). Two changes in `LeanUI/Patch.lean`, with no change to the protocol:

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
  10,000 rows (dlmalloc: 34 MB; both before the create path, after which dlmalloc's figure is
  27.75 MB). LeanUI builds with dlmalloc.
- **The JIT state of a fresh page.** Each measured click comes after a few warm-up clicks on a
  fresh page, so `Runtime.apply` runs in whatever state the engine has reached by then, and that
  state is not the same from one session to the next. In Chromium, before templates, the old
  runtime applied the create-1,000-rows buffer replayed on fresh pages in 2.85–2.95 ms (against
  2.4–2.55 ms on a hot page) in some sessions and in 2.44 ms (against 2.38) in another, with the
  same files and command; within one run the samples stay close together (2.84–3.14 ms), and
  making V8 optimize synchronously (`--js-flags=--no-concurrent-recompilation`) changes nothing.
  Small code changes move the fresh figure by several percent too. `apply-bench` measures on
  fresh pages by default, as the benchmark runs, and interleaves the variants so that a run's
  ratio is fair; for a figure that holds across sessions use `--mode hot` (the steady state), and
  believe a fresh-page difference only when it holds in more than one session. A forced GC (`gc()`) right before a
  measurement deoptimized the apply loop once in Chromium (18 ns per command instead of 2):
  measure after the warm-up, not right after a GC.
- **Heap history.** A click that mostly compares (highlight a row: 0.34–0.36 ms of script on a
  fresh page at `93b8470`, about 0.15 ms on a hot one during the state-passing work) depends on
  where the objects it reads were allocated, and so on what every earlier click allocated and
  freed. Changing what creating rows allocates (the click itself runs almost the same code, see
  "State passing in mount, clone and release") moved the fresh-page "highlight a row" by −3 to
  +14% depending on the build and the warm-up sequence (the standard one; `#run #clear` before
  it; `#runlots #clear` before it), which also reorders the builds. Believe a fresh-page
  difference in such an operation only when its own code changed, or when it holds on a hot page
  too. Measured against `3db6ac9`, before the create path, the same click went from 0.38 to 0.36
  ms of script (update every 10th: 0.83 to 0.79) in the final A/B; the +8–14% seen during the
  state-passing work was against `492772a`.
- **Fresh loads, not warm pages.** Chrome's optimizing tier changes nothing measurable for
  LeanUI after the first second (a 12-second warm-up probe stays flat once the core scheduling
  effect is removed).

## The photo editor

[LeanUI Photo](../examples/Editor.lean) is a layered photo editor whose pixel work is all Lean
([`examples/Editor/*.lean`](../examples/Editor)), compiled to wasm64: a complex, highly
interactive client-side app. This section measures it in two ways: each image operation against a
straightforward JavaScript implementation of the same algorithm (and against the canvas's built-in
operations where they exist), and the editor itself (input to pixels, long work, UI scaling,
memory).

**Machine.** Unlike the rest of this page, these numbers come from a 4-core x86-64 cloud VM
(Chromium 141 headless, software canvas: `chrome://gpu` reports "Software only"), measured at
`6a3d76c` (2026-10-19), and from GitHub's runners for Firefox. **Absolute times are a CI-class
machine's, to be re-measured on the reference Mac**; the comparable figures are the ratios, taken
in the same browser process on the same input.

### Summary

- **Lean against JavaScript, same algorithms:** all 19 operations give byte-identical results in
  Lean (wasm) and in plain JavaScript (checked by checksum on every run), and Lean takes **0.71–0.73×
  the time** of the JavaScript (geometric mean over the 19 operations at 1, 4 and 12 MP; total time
  0.73–0.80×). Lean is slower on the lookup-table adjustment (1.2–1.6×) and the histogram (1.3–1.4×),
  even with resampling (1.0–1.1×), and faster on compositing (0.26–0.30×: an integer division by a
  constant against JavaScript's floating-point one), emboss and edges (0.4–0.7×), row copies
  (0.4×) and PNG encoding (0.53×). Some of Lean's wins are implementation choices the plain port
  does not make (below), so "same algorithm" means the same arithmetic, not the same code.
- **The canvas's built-ins**, where there is one, are faster overall (Lean ÷ canvas 1.32–1.41×):
  Skia's blur is 3–8× faster than Lean's direct Gaussian, and its resampling 3–12× faster; Lean
  wins brightness/contrast, rotations and flips, and PNG output is 4.8× smaller (Lean's encoder at
  level 1 against `toBlob`), though `toBlob` is 3.4× faster.
- **Interactive at every size:** a slider previewing a point operation (brightness, saturation)
  costs 22–41 ms from input to pixels, and a blur or sharpen preview 95–127 ms, the same at 1, 4
  and 12 MP, because previews run on a preview image of at most 1280 px on a side. A brush move
  costs 1.5 ms (1 MP) to 10 ms (12 MP), at frame rate.
- **Long work does not freeze the page:** applying an operation at full resolution, rotating and
  exporting run as jobs, a slice of rows per animation frame. At 12 MP the longest frame during
  them is 50–117 ms (export: 317 ms), while a blur takes 3.1 s, an export 1.7 s.
- **Memory:** 16 MB at load, 57 MB with a 12 MP image open, 1.26 GB after 50 brush strokes on it
  (the undo history's 1 GiB budget then holds 23 steps); wasm memory never shrinks.
- **Download:** 288 KB with brotli (wasm 264 KB, glue 15 KB, runtime 9 KB).

### Each operation: Lean (wasm) against plain JavaScript and the canvas

[`examples/EditorBench.lean`](../examples/EditorBench.lean) runs one operation of the editor's
core at a time, synchronously and at full resolution, on a generated test image;
[`bench/editor/ops.js`](../bench/editor/ops.js) implements every operation in plain JavaScript
(typed arrays, straightforward loops, no SIMD, workers or WebGL), with the same integer arithmetic,
so the outputs are byte-identical. [`tests/browser/editor-bench.mjs`](../tests/browser/editor-bench.mjs)
times both in the same page: Lean as the synchronous `input` event that runs the command (update,
a tiny view and diff included), JavaScript as the call, the canvas built-in as the draw plus a
`getImageData` of the whole result (the draw alone is only recorded: the canvas rasterises later).
Medians of 5 runs (3 for operations over 1.5 s), Chromium 141, 12 MP (4000×3000):

| operation | Lean | JavaScript | canvas built-in | Lean ÷ JS | Lean ÷ canvas |
|---|--:|--:|--:|--:|--:|
| brightness, contrast, gamma (lookup table) | 134 ms | 112 ms | 270 ms | 1.19× | 0.49× |
| saturation and hue (colour matrix) | 180 ms | 252 ms | 203 ms | 0.71× | 0.89× |
| Gaussian blur, radius 2 | 1,201 ms | 1,183 ms | 445 ms | 1.01× | 2.70× |
| Gaussian blur, radius 8 | 3,360 ms | 3,161 ms | 434 ms | 1.06× | 7.74× |
| unsharp mask | 1,374 ms | 1,489 ms | – | 0.92× | – |
| emboss (3×3) | 510 ms | 714 ms | – | 0.71× | – |
| edges (Sobel) | 343 ms | 542 ms | – | 0.63× | – |
| rotate 90° | 220 ms | 228 ms | 405 ms | 0.96× | 0.54× |
| rotate 180° | 93 ms | 114 ms | 120 ms | 0.82× | 0.78× |
| flip horizontally | 94 ms | 120 ms | 130 ms | 0.79× | 0.72× |
| flip vertically | 16 ms | 41 ms | 123 ms | 0.40× | 0.13× |
| resize to 50% (bilinear) | 111 ms | 104 ms | 32 ms | 1.07× | 3.50× |
| downscale to 1/8 (box) | 99 ms | 88 ms | 8.3 ms | 1.13× | 11.95× |
| composite, normal at 60% | 237 ms | 924 ms | 101 ms | 0.26× | 2.35× |
| composite, overlay at 60% | 289 ms | 1,026 ms | 102 ms | 0.28× | 2.83× |
| histogram | 99 ms | 78 ms | – | 1.27× | – |
| PNG, stored | 289 ms | 357 ms | – | 0.81× | – |
| PNG, level 1 (filters, LZ77, fixed Huffman) | 556 ms | 1,019 ms | 165 ms | 0.55× | 3.37× |
| crop | 3.7 ms | 11 ms | 28 ms | 0.34× | 0.13× |
| show on a canvas (`putImageData`, from wasm memory in Lean) | 12 ms | 11 ms | – | 1.10× | – |

| size | Lean ÷ JS (geometric mean, 19 operations) | total time Lean ÷ JS | Lean ÷ canvas (14) | wasm memory after |
|---|--:|--:|--:|--:|
| 1 MP (1152×864) | 0.73× | 0.73× | 1.41× | 19 MB |
| 4 MP (2304×1728) | 0.72× | 0.76× | 1.34× | 64 MB |
| 12 MP (4000×3000) | 0.71× | 0.80× | 1.32× | 186 MB |

Firefox (Playwright's build on GitHub's runners, which runs wasm several times slower than
release Firefox, see "Findings about measuring"): see the `editor-bench` artifact of a CI run with
the `bench` label; the ratios are summarised below once measured.

**What the Lean side does.** Lean's code is the obvious algorithm written for the compiler: pixel
loops are tail-recursive functions over a uniquely owned `ByteArray` (updated in place), with
bounds and the array's exclusivity checked once per row rather than per byte, pixels read and
written as 32-bit words (a few `@[extern c inline]` primitives, whose Lean bodies are the
specification), and constants hoisted out of loops. Two of its choices go beyond the plain port:
the blur adds the two symmetric taps before multiplying and works on two channels per
multiplication, and the PNG encoder uses a slicing-by-4 CRC-32 and compares match lengths a word
at a time. Before that pass (the first version of the core, measured the same way) Lean took
1.5× the JavaScript's time: the histogram's counters were a boxed `Array UInt32` (6.3×), every byte
store re-checked the array's reference count (rotations and lookup tables 2–2.7×), and Sobel ran
in `Float` (3.9×).

**Findings.**

- *Decimal literals and `Float.ofNat` in a loop are expensive in Lean 4.34.* A literal like `0.5`
  compiles to a call of `Float.ofScientific` per iteration, and `Float.ofNat` parses the constant
  2^53 from a string on every call: the first test-image generator took 69 s for 12 MP in wasm, the
  brush 8× longer than it should. Top-level `Float` constants and `UInt64.toFloat` avoid both.
- *JavaScript pays for fresh typed arrays.* Each run writes into a new 48 MB array, and touching its
  pages costs about 30 ms at 12 MP; wasm memory, once grown, is reused. That is most of Lean's
  advantage on copies (flip vertically, crop).
- *Showing pixels costs the same as in JavaScript:* `Cmd.putImage` hands the browser a view of wasm
  memory, and `putImageData` from it is as fast as from a JavaScript array.

### The editor: input to pixels

[`tests/browser/editor-perf.mjs`](../tests/browser/editor-perf.mjs) drives the editor with
generated JPEGs (decoded by the browser, then handed to Lean). *Script* is the synchronous event
(Lean's update, view, diff and the buffer applied, `putImageData` included); *frame* runs to the
next animation frame after it. Medians of 8 inputs; Chromium 141:

| | 1 MP | 4 MP | 12 MP |
|---|--:|--:|--:|
| open a JPEG (file chosen to canvas shown) | 199 ms | 397 ms | 716 ms |
| preview size | 1152×864 | 1280×960 | 1280×960 |
| slider: brightness (lookup table), frame | 22 ms | 27 ms | 32 ms |
| slider: saturation (colour matrix), frame | 33 ms | 41 ms | 32 ms |
| slider: blur radius 6 (a half-size proxy), frame | 100 ms | 113 ms | 113 ms |
| slider: sharpen, frame | 107 ms | 127 ms | 96 ms |
| brush: a move, median / longest | 1.5 / 3.5 ms | 7.4 / 13 ms | 10 / 17 ms |
| brush: stroke start (copies the layer once) | 13 ms | 24 ms | 60 ms |

A slider's preview costs one preview-sized operation, a composite of the layers' previews, a
histogram of every fourth row, and showing the result; the image's size matters only for opening
it and for the work below.

### Long work: frames stay short

Applying an operation to the full-resolution layer, rotating and exporting run as jobs: a slice of
rows per animation frame, sized by a per-operation cost and adapted to the frame time (about 25 ms
of work a frame), with a progress bar. Time from the click to the result, and the longest frame
meanwhile:

| | 1 MP | 4 MP | 12 MP |
|---|--:|--:|--:|
| apply brightness | 72 ms, 17 ms | 326 ms, 50 ms | 594 ms, 67 ms |
| apply blur radius 6 | 389 ms, 50 ms | 1,044 ms, 50 ms | 3,089 ms, 117 ms |
| edge detect | 70 ms, 17 ms | 322 ms, 67 ms | 696 ms, 50 ms |
| rotate 90° | 58 ms, 17 ms | 348 ms, 50 ms | 738 ms, 50 ms |
| export PNG (5.2 MB at 12 MP) | 254 ms, 100 ms | 909 ms, 217 ms | 1,668 ms, 317 ms |

Before the work was sliced, the same machine froze for 6.0 s exporting a 12 MP PNG and 1.3 s
rotating it.

### UI scaling: layers and history

On a 1 MP image (the image's size changes only the compositing):

| | script | frame |
|---|--:|--:|
| select a layer, 10 layers | 0.5 ms | 13 ms |
| select a layer, 100 layers | 0.7 ms | 14 ms |
| show or hide a layer (recomposite), 10 layers | 7.0 ms | 14 ms |
| show or hide a layer (recomposite), 100 layers | 6.4 ms | 11 ms |
| jump in a 200-step history | 7.4 ms | 13 ms |
| undo, 200 steps | 6.5 ms | 13 ms |
| a new step when the history is full (drops the oldest) | 6.4 ms | 13 ms |

*Frame* here is mostly the wait for the next animation frame (the script is 0.5–7 ms). The panels
are keyed lists of memoised rows, so a click diffs only what changed. A layer nothing
was painted on is skipped when compositing, which keeps 100 mostly empty layers as cheap as 10;
100 layers of 1 MP take 429 MB.

### Memory and download

Wasm memory is 16 MB at load and grows on demand (it never shrinks). A 12 MP image takes 57 MB
open (its pixels, its preview, the canvas). Each history step keeps the images it replaced (a brush
stroke copies the layer it paints on once, 48 MB at 12 MP); the history is trimmed to 200 steps or
1 GiB of replaced images, so 50 strokes on a 12 MP image leave 1.26 GB of wasm memory and 23
undoable steps. Download (brotli 11): `app.wasm` 264 KB, `app.js` 15 KB, `leanui.js` 8.8 KB, the
page 1.9 KB.

### What is interactive, where the main thread blocks, and what would move to a worker

- **Point operations and painting are interactive at any size:** previews cost 20–40 ms, and a
  brush move stays under a frame even at 12 MP, because only the preview and the stroke's
  rectangle are touched.
- **Neighbourhood filters preview at about 8–10 updates a second** (blur and sharpen, 95–127 ms per
  input at preview size). This is the clearest gap: a faster blur (a box-filter approximation is
  a few operations a pixel whatever the radius) or computing the preview in a worker while the
  page shows the last one would both help.
- **Full-resolution work never freezes the page** but takes seconds at 12 MP (blur 3.1 s, export
  1.7 s) and occupies the main thread: during a job the page stays responsive (the progress bar
  moves, the panels work) but other edits wait. This is what would move to a Web Worker: a second
  wasm instance with its own copy of the layer (no shared memory, since the page is not
  cross-origin isolated), receiving the pixels and returning the result as transferred
  `ArrayBuffer`s (a copy each way, tens of milliseconds at 12 MP, against seconds of work). The
  commands that would start and answer such work are effects like the ones the framework already
  has (`Cmd.readFile` returns bytes the same way).
- **Opening** a 12 MP JPEG takes 0.7 s from choosing the file to the canvas: the browser's
  decoding (`createImageBitmap`, off the main thread), reading the pixels back, copying them into
  wasm memory, and Lean's preview and first composite (not measured separately).

### Reproducing (the editor)

```bash
tools/build-app.sh EditorBenchApp editor-bench && tools/build-app.sh EditorApp editor
./.lake/build/bin/leanui serve dist --port 5331 &
node tests/browser/editor-bench.mjs http://127.0.0.1:5331/ chromium --sizes 1,4,12 --runs 5
node tests/browser/editor-perf.mjs http://127.0.0.1:5331/editor/index.html chromium --out perf.json
node bench/editor/check-goldens.mjs     # the JavaScript port against the Lean goldens
```

CI runs both (Chromium at 1, 4 and 12 MP; Firefox at 1 MP) on a pull request with the `bench`
label and uploads the JSON as the `editor-bench` artifact; [`bench/editor/README.md`](../bench/editor/README.md)
has the details and caveats.

## Method

**The apps.** [`examples/Bench.lean`](../examples/Bench.lean) is the standard benchmark app: the same
buttons, ids, table structure and class names, keyed rows (`keyedLazy`: keyed by id, lazy on label and
selection), and labels from a 64-bit LCG instead of `Math.random`; LeanUI creates the rows from
a template of its own ([`docs/PROTOCOL.md`](PROTOCOL.md), section 7).
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
node tests/browser/bench.mjs --runs 9 --json out.json   # Chromium traces, memory, startup
node tests/browser/selfbench.mjs /Applications/Firefox.app/Contents/MacOS/firefox firefox --runs 9 --json firefox.json
node tests/browser/selfbench.mjs "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" chromium --runs 9 --json chrome.json
./.lake/build/bin/leanui-perf > native.txt              # native, lazy and eager rows (the Results
                                                        # take the per-operation median of seven runs)
node tools/bench-tables.mjs out.json firefox.json chrome.json native.txt   # the Results tables; with --readme first, the README's
./.lake/build/bin/leanui-perf allocs                    # small objects per operation, by phase
./.lake/build/bin/leanui-perf allocs-nodes              # small objects to mount one node of each shape
LEANUI_COUNT_ALLOCS=1 LEANUI_PAGE=examples/bench.html tools/build-app.sh BenchApp bench-allocs
node tests/browser/allocs.mjs dist/bench-allocs [dist/other-allocs]   # every malloc/free per click
LEANUI_PAGE=examples/bench.html tools/build-app.sh BenchApp bench-prof --debug
node tests/browser/profile.mjs dist/bench-prof --op create1k   # where the script time goes
node tests/browser/apply-bench.mjs --variants dist/bench-base/leanui.js,runtime/leanui.js --engines chromium,firefox
                                                        # the JS runtime alone, A/B (the reference first;
                                                        # both runtimes must know TEMPLATE and CLONE)
node tests/browser/bench.mjs --impls leanui --leanui-dir dist/<build> --cpu-only   # A/B of builds
bench/wasm64/build.sh && node tests/browser/wasm64.mjs <browser-binary> <firefox|chromium>
```

Run browser measurements one at a time on an otherwise idle machine.
