# LeanUI performance

LeanUI is measured with the [js-framework-benchmark](https://github.com/krausest/js-framework-benchmark)
keyed operations, against a hand-written vanilla JavaScript implementation, in Chromium (with
traces), in release Chrome and Firefox, and natively. This page gives the results, the method,
and what was learned getting there.

Measured at commit `93b8470` (2026-10-18); sections that compare two builds name the build they
compare against. All numbers except those of "The photo editor" (a cloud VM and GitHub's runners,
named there): an Apple M4 Max (10 performance and 4 efficiency cores), macOS 26, headless
browsers, medians. Each browser measurement loads a fresh page, does the operation's
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
- **The photo editor** ([below](#the-photo-editor); a cloud VM and GitHub's runners, CI machines to
  be re-measured on the reference Mac): on its 19 image operations Lean (wasm) takes
  0.61–0.73× the time of the same algorithms in plain JavaScript in Chromium (0.51–0.61× on
  GitHub's runners), byte-identical; its slider previews reach the screen in 25–134 ms at any
  image size, and full-resolution work runs in frame-sized slices.
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
(Chromium 141 headless, software canvas: `chrome://gpu` reports "Software only") and from
GitHub's `ubuntu-24.04` runners (Chromium 151 and Playwright's Firefox 153): the operations at
`eb0414f` (cloud VM, 2026-10-19) and `ceb6393` (runners, 2026-10-20), the editor and the video lab
at `5c7314c` (cloud VM) and `54181cf` (runners, CI run 39353984688), both 2026-10-20 (UTC). Every
table names its raw data in [`bench/editor/`](../bench/editor). **Absolute times are a CI-class
machine's, to be re-measured on the reference Mac**; the comparable figures are the ratios, taken
in the same browser process on the same input.

### Summary

- **Lean against JavaScript, same algorithms:** all 19 operations give byte-identical results in
  Lean (wasm) and in plain JavaScript. Every run compares the 16 operations that produce an image
  by checksum, the histogram by its total and the two PNG encoders by file size; the histogram's
  and the PNG files' bytes are pinned by the Lean core's goldens, which `ops.js` reproduces
  (`bench/editor/check-goldens.mjs`, also run every time). In Chromium, Lean takes
  **0.61–0.73× the time** of the JavaScript (geometric mean over the 19 operations at 1, 4 and
  12 MP, two runs on the cloud VM; total time 0.69–0.76×), and 0.51–0.61× on GitHub's runner.
  Lean is slower on the histogram (1.2–1.7×) and the box downscale (1.1–1.2×), about even on the
  blurs, the unsharp mask and the bilinear resize (0.8–1.1×), and faster on compositing
  (0.26–0.32×: an integer division by a constant against JavaScript's floating-point one), edges
  and emboss (0.59–0.73×), row copies (flip vertically 0.2–0.4×) and PNG encoding (level 1
  0.48–0.54×, stored 0.45–0.82×).
  The lookup-table adjustment's ratio is anywhere from 0.4× to 1.7×, because JavaScript's time for
  it varies fourfold from run to run while Lean's stays put. Some of Lean's wins are
  implementation choices the plain port does not make (below), so "same algorithm" means the same
  arithmetic, not the same code.
- **The canvas's built-ins**, where there is one, are faster overall (Lean ÷ canvas 1.10–1.35×):
  Skia's blur is 2–9× faster than Lean's direct Gaussian, and its resampling 3–12× faster; Lean
  wins the lookup-table adjustment, rotations and flips, and ties or wins the colour matrix. Its
  PNG files are 3.9–4.8× smaller (Lean's encoder at level 1 against `toBlob`), though `toBlob` is
  2.8–3.6× faster.
- **Playwright's Firefox** (on the runner) gives Lean ÷ JS 2.2–2.8×: its Lean runs about 5× slower
  than Chromium's on the same machine, its JavaScript about as fast. That build runs any wasm
  several times slower than release Firefox (see "Findings about measuring"), so this says more
  about the build than about Lean in Firefox.
- **Interactive at every size:** a slider previewing a point operation (brightness, saturation)
  reaches the screen 25–35 ms after the input, and a blur or sharpen preview 105–134 ms, about the
  same at 1, 4 and 12 MP, because previews run on a preview image of at most 1280 px on a side (on
  GitHub's runner: 13–18 ms and 55–91 ms). A brush move costs 1.2 ms (1 MP) to 10 ms (12 MP) of
  script, at most 18 ms, and reaches the screen with the next frame (17 ms median, 21 ms longest).
- **Long work does not freeze the page:** applying an operation at full resolution, rotating and
  exporting run as jobs, a slice of rows per animation frame. At 12 MP the longest frame during
  them is 67–100 ms, except one frame of 600 ms in a blur (most likely wasm memory growing), while a blur
  takes 3.3 s and an export 1.8 s.
- **Memory:** 16 MiB of wasm memory at load, 57 MiB with a 12 MP image open, 1.23 GiB after 50 brush
  strokes on it (the undo history's 1 GiB budget then holds 23 entries, 22 undoable steps); wasm
  memory never shrinks.
- **Download:** 292 KB with brotli (wasm 266 KB, glue 15 KB, runtime 9.5 KB).
- **Video** (the [video lab](../examples/Video.lean), the same filters on every frame of a 30 fps
  video): every filter keeps up at 640×360, except blur at 27 fps. At 1280×720 the colour filters
  and edge detection keep up, emboss runs at 19 fps, and sharpen and blur at 6–8 fps. At
  1920×1080, grabbing and drawing alone keep up and the colour filters reach 19–22 fps.

### Each operation: Lean (wasm) against plain JavaScript and the canvas

[`examples/EditorBench.lean`](../examples/EditorBench.lean) runs one operation of the editor's
core at a time, synchronously and at full resolution, on a generated test image;
[`bench/editor/ops.js`](../bench/editor/ops.js) implements every operation in plain JavaScript
(typed arrays, straightforward loops, no SIMD, workers or WebGL), with the same integer arithmetic,
so the outputs are byte-identical. [`tests/browser/editor-bench.mjs`](../tests/browser/editor-bench.mjs)
times both in the same page: Lean as the synchronous `input` event that runs the command (update,
a tiny view and diff included), JavaScript as the call, the canvas built-in as the draw plus a
`getImageData` of the whole result (the draw alone is only recorded: the canvas rasterises later).
The tables give MPix/s, input megapixels per second from the median time (higher is better): in
each cell Lean · JavaScript · canvas built-in, "–" where there is no built-in or the time is under
the timer's resolution. `node bench/editor/mpix-table.mjs <file.json>` prints them from the raw
timings that `tests/browser/editor-bench.mjs` writes.

**Cloud VM, Chromium 141** (`bench/editor/results-chromium.json`, medians of 5 runs, 3 for an
operation whose warm-up took over 1.5 s):

| MPix/s: Lean · JS · canvas | 1 MP (1152×864) | 4 MP (2304×1728) | 12 MP (4000×3000) |
|---|--:|--:|--:|
| brightness, contrast, gamma (lookup table) | 74.8 · 29.9 · 13.7 | 83.6 · 32.1 · 42.2 | 91.6 · 48.7 · 48.5 |
| saturation and hue (colour matrix) | 63.8 · 26.5 · 15.2 | 66.0 · 52.3 · 65.9 | 67.9 · 51.5 · 67.2 |
| Gaussian blur, radius 2 | 11.6 · 10.4 · 33.9 | 10.7 · 11.2 · 24.0 | 11.5 · 10.3 · 27.0 |
| Gaussian blur, radius 8 | 4.0 · 4.2 · 34.4 | 4.5 · 3.8 · 25.5 | 4.3 · 3.8 · 28.1 |
| unsharp mask | 9.9 · 9.4 · – | 9.3 · 8.7 · – | 10.1 · 8.0 · – |
| emboss (3×3) | 26.0 · 18.8 · – | 26.4 · 18.8 · – | 24.8 · 17.7 · – |
| edges (Sobel) | 37.1 · 24.3 · – | 38.2 · 24.2 · – | 38.1 · 22.6 · – |
| rotate 90° | 92.2 · 83.6 · 51.0 | 59.3 · 51.0 · 30.3 | 69.7 · 37.3 · 33.6 |
| rotate 180° | 111 · 106 · 91.3 | 140 · 101 · 103 | 136 · 101 · 102 |
| flip horizontally | 114 · 103 · 88.1 | 115 · 63.6 · 73.1 | 136 · 104 · 102 |
| flip vertically | 829 · 243 · 60.3 | 766 · 269 · 93.5 | 750 · 313 · 105 |
| resize to 50% (bilinear) | 120 · 123 · 369 | 120 · 117 · 346 | 123 · 122 · 404 |
| downscale to 1/8 (box) | 124 · 153 · 1106 | 134 · 153 · 1475 | 134 · 154 · 1667 |
| composite, normal at 60% | 54.1 · 15.0 · 129 | 51.7 · 15.2 · 130 | 51.5 · 14.0 · 118 |
| composite, overlay at 60% | 42.7 · 12.7 · 112 | 45.0 · 11.7 · 117 | 45.4 · 12.5 · 115 |
| histogram | 126 · 158 · – | 85.1 · 146 · – | 129 · 154 · – |
| PNG, stored | 45.0 · 37.0 · – | 42.9 · 19.4 · – | 43.7 · 30.0 · – |
| PNG, level 1 (filters, LZ77, fixed Huffman) | 22.0 · 11.6 · 60.7 | 20.5 · 11.0 · 74.4 | 23.8 · 11.7 · 68.6 |
| crop | 1659 · 1106 · 498 | 2844 · 1284 · 492 | 3750 · 1132 · 545 |
| show on a canvas (`putImageData`) | 829 · 1106 · – | 1076 · 1206 · – | 1062 · 1154 · – |
| *Lean ÷ JS time, geometric mean* | 0.68× (19 operations) | 0.64× (19 operations) | 0.63× (19 operations) |

| size | Lean ÷ JS (geometric mean, 19 operations) | total time Lean ÷ JS | Lean ÷ canvas (14) | wasm memory after |
|---|--:|--:|--:|--:|
| 1 MP (1152×864) | 0.68× (second run: 0.73×) | 0.75× (0.76×) | 1.10× (1.35×) | 19 MiB |
| 4 MP (2304×1728) | 0.64× (0.72×) | 0.71× (0.76×) | 1.26× (1.29×) | 64 MiB |
| 12 MP (4000×3000) | 0.63× (0.61×) | 0.69× (0.73×) | 1.28× (1.22×) | 186 MiB |

A second run of the same build minutes later (`bench/editor/results-chromium-2.json`) moved 12 of
Lean's 54 timings over 2 ms by more than 10% (at most 1.5×, the histogram at 4 MP), and
JavaScript's by up to 4.2× (the lookup table at 1 MP: 33 ms, then 8 ms; Lean 13 ms both times).
The ranges in the summary span both runs.

**GitHub's runner, Chromium 151** (CI run 39344001445 at `ceb6393`, whose merge with `main` is
`a1328be`; `bench/editor/results-ci-chromium.json`, medians of 3 runs):

| MPix/s: Lean · JS · canvas | 1 MP (1152×864) | 4 MP (2304×1728) | 12 MP (4000×3000) |
|---|--:|--:|--:|
| brightness, contrast, gamma (lookup table) | 114 · 108 · 66.8 | 132 · 188 · 69.0 | 139 · 186 · 69.0 |
| saturation and hue (colour matrix) | 106 · 82.3 · 80.3 | 110 · 49.3 · 82.3 | 113 · 49.9 · 81.7 |
| Gaussian blur, radius 2 | 18.5 · 8.5 · 59.2 | 18.6 · 16.0 · 55.0 | 18.7 · 16.0 · 49.1 |
| Gaussian blur, radius 8 | 7.1 · 6.2 · 61.8 | 7.1 · 6.2 · 55.3 | 7.1 · 6.2 · 54.2 |
| unsharp mask | 16.1 · 10.8 · – | 16.2 · 13.6 · – | 16.3 · 13.6 · – |
| emboss (3×3) | 37.6 · 17.6 · – | 38.0 · 17.4 · – | 38.0 · 27.8 · – |
| edges (Sobel) | 51.3 · 25.0 · – | 51.8 · 34.0 · – | 52.0 · 33.8 · – |
| rotate 90° | 221 · 158 · 105 | 219 · 159 · 99.5 | 197 · 158 · 85.9 |
| rotate 180° | 237 · 181 · 161 | 260 · 183 · 163 | 263 · 184 · 165 |
| flip horizontally | 243 · 175 · 163 | 254 · 179 · 159 | 261 · 184 · 163 |
| flip vertically | 1991 · 398 · 166 | 2342 · 452 · 161 | 2500 · 462 · 164 |
| resize to 50% (bilinear) | 184 · 114 · 585 | 205 · 192 · 622 | 209 · 104 · 649 |
| downscale to 1/8 (box) | 161 · 106 · 1991 | 173 · 225 · 2342 | 176 · 225 · 2609 |
| composite, normal at 60% | 88.9 · 22.2 · 226 | 89.1 · 22.1 · 225 | 91.3 · 22.1 · 231 |
| composite, overlay at 60% | 64.2 · 19.6 · 199 | 65.3 · 19.7 · 197 | 66.4 · 19.6 · 202 |
| histogram | 216 · 93.0 · – | 220 · 249 · – | 218 · 248 · – |
| PNG, stored | 69.1 · 40.0 · – | 69.6 · 49.3 · – | 69.5 · 48.6 · – |
| PNG, level 1 (filters, LZ77, fixed Huffman) | 31.2 · 9.9 · 97.6 | 32.7 · 19.8 · 117 | 33.3 · 19.6 · 113 |
| crop | 4977 · 1422 · 829 | 7963 · 1593 · 948 | 8571 · 1791 · 976 |
| show on a canvas (`putImageData`) | 2488 · 4977 · – | 2654 · 2654 · – | 3000 · 3333 · – |
| *Lean ÷ JS time, geometric mean* | 0.51× (19 operations) | 0.61× (19 operations) | 0.60× (19 operations) |

**GitHub's runner, Playwright's Firefox 153** (the same run; `bench/editor/results-ci-firefox.json`):

| MPix/s: Lean · JS · canvas | 1 MP (1152×864) | 4 MP (2304×1728) | 12 MP (4000×3000) |
|---|--:|--:|--:|
| brightness, contrast, gamma (lookup table) | 23.7 · 124 · 47.4 | 26.9 · 133 · 47.4 | 27.7 · 128 · 47.1 |
| saturation and hue (colour matrix) | 16.9 · 31.1 · 49.8 | 17.4 · 30.6 · 52.4 | 17.5 · 63.5 · 52.9 |
| Gaussian blur, radius 2 | 3.3 · 14.6 · 17.5 | 3.3 · 14.6 · 17.7 | 3.3 · 14.7 · 17.0 |
| Gaussian blur, radius 8 | 1.3 · 5.6 · 39.8 | 1.3 · 5.6 · 37.2 | 1.3 · 5.7 · 34.7 |
| unsharp mask | 2.8 · 9.8 · – | 2.8 · 9.6 · – | 2.8 · 9.8 · – |
| emboss (3×3) | 5.5 · 21.2 · – | 5.5 · 20.8 · – | 5.5 · 20.9 · – |
| edges (Sobel) | 10.2 · 13.5 · – | 10.2 · 13.1 · – | 10.3 · 13.6 · – |
| rotate 90° | 55.3 · 142 · 124 | 57.7 · 147 · 105 | 58.5 · 133 · 96.0 |
| rotate 180° | 58.5 · 142 · 142 | 60.3 · 166 · 147 | 61.5 · 148 · 150 |
| flip horizontally | 55.3 · 166 · 199 | 60.3 · 159 · 181 | 61.2 · 141 · 188 |
| flip vertically | – · 498 · 199 | 1991 · 442 · 181 | 2400 · 480 · 188 |
| resize to 50% (bilinear) | 30.2 · 142 · 995 | 31.1 · 159 · 664 | 31.7 · 160 · 750 |
| downscale to 1/8 (box) | 31.1 · 199 · – | 33.2 · 210 · 3981 | 33.4 · 214 · 6000 |
| composite, normal at 60% | 16.1 · 16.9 · 249 | 16.3 · 17.2 · 284 | 16.3 · 17.5 · 286 |
| composite, overlay at 60% | 11.6 · 15.1 · 249 | 11.6 · 15.4 · 234 | 11.6 · 15.5 · 250 |
| histogram | 31.1 · 199 · – | 31.1 · 199 · – | 31.5 · 207 · – |
| PNG, stored | 13.3 · 14.9 · – | 13.5 · 15.1 · – | 13.4 · 15.1 · – |
| PNG, level 1 (filters, LZ77, fixed Huffman) | 4.5 · 8.5 · 39.8 | 4.6 · 8.8 · 46.3 | 4.7 · 9.5 · 47.4 |
| crop | – · 995 · 995 | 3981 · 1991 · 1327 | 6000 · 1714 · 1333 |
| show on a canvas (`putImageData`) | 332 · 332 · – | 306 · 306 · – | 308 · 2000 · – |
| *Lean ÷ JS time, geometric mean* | 2.78× (17 operations) | 2.21× (19 operations) | 2.19× (19 operations) |

On the runner, Chromium gives the same picture as the cloud VM with Lean further ahead: Lean ÷ JS
0.51×, 0.61× and 0.60× (total time 0.56–0.70×), Lean ÷ canvas 1.19–1.29×. Playwright's Firefox
gives 2.78×, 2.21× and 2.19× (at 1 MP over 17 operations: flip vertically and crop take Lean
under its 1 ms timer; total time 2.81–2.91×) and Lean ÷ canvas 4.7–7.0×. Against Chromium on the
same runner, its Lean takes 4.95× the time (geometric mean over the operations and sizes, 1.0–7.1×)
and its JavaScript 1.22× (0.5–3.3×). Playwright's Firefox build runs wasm several times slower
than release Firefox ("Findings about measuring": about 8×), so its ratios say more about that
build than about Lean in Firefox; release Firefox, self-driven as in "Method", is still to be
measured on the reference Mac.

**What the Lean side does.** Lean's code is the obvious algorithm written for the compiler: pixel
loops are tail-recursive functions over a uniquely owned `ByteArray` (updated in place), with bounds
and the array's exclusivity checked once per row rather than per byte, pixels read and written as
32-bit words (a few `@[extern c inline]` primitives, whose Lean bodies are the specification), and
constants hoisted out of loops. Two of its choices go beyond the plain port: the blur adds the two
symmetric taps before multiplying and works on two channels per multiplication, and the PNG encoder
uses a slicing-by-4 CRC-32 and compares match lengths a word at a time. Before that pass (the first
version of the core, measured the same way; its raw timings are `bench/editor/results-chromium.json`
as of `3ca07a4`) Lean took 1.5× the JavaScript's time: the histogram's counters were a boxed `Array
UInt32` (6.3×), every byte store re-checked the array's reference count (rotations and lookup tables
2–2.7×), and Sobel ran in `Float` (3.9×).

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

**Allocations** ([`tests/browser/editor-allocs.mjs`](../tests/browser/editor-allocs.mjs), on builds
that count every `malloc` and `free`, `LEANUI_COUNT_ALLOCS=1`; raw counts in
[`bench/editor/allocs-chromium.md`](../bench/editor/allocs-chromium.md), at `5c7314c`): no
operation allocates per pixel. A run costs 43–224 allocations (its output image and temporaries,
plus about 40 for the event's update, view and diff), the same at 1 and 4 MP; the colour matrix
about 600 and the lookup-table adjustment about 3,900 (the floating-point setup of the matrix, the
256-entry table) and the histogram about 1,650, all independent of the size. PNG encoding
allocates in proportion to the image's bytes, about three objects per 5,552-byte Adler-32 block
(2,200 allocations at 1 MP, 8,660 at 4 MP), not per pixel. In the editor, a slider input costs
about 3,900 (blur radius) to 8,100 (brightness: its lookup table's setup, as in the adjust-lut run)
allocations, and a brush move about 1,000.

### The editor: input to pixels

[`tests/browser/editor-perf.mjs`](../tests/browser/editor-perf.mjs) drives the editor with
generated JPEGs (decoded by the browser, then handed to Lean). *To pixels* runs from the input to
the end of the next frame's rendering (a task queued from that frame's `requestAnimationFrame`
callback: after its style, layout and paint), timed in the page; in Chromium every slider input
and UI click is also traced, as in "Method" (the brush moves and opening a JPEG are timed in the
page only): *script* is the event's dispatch (Lean's update, view and diff, and the
buffer applied, `putImageData` included), *render* the main-thread frame work after it. Sliders:
medians of 8 inputs; the brush: 40 moves; opening a JPEG: one run per size. Cloud VM, Chromium 141
([`bench/editor/perf-chromium.json`](../bench/editor/perf-chromium.json)):

| | 1 MP | 4 MP | 12 MP |
|---|--:|--:|--:|
| open a JPEG (file chosen to canvas shown) | 171 ms | 357 ms | 613 ms |
| preview size | 1152×864 | 1280×960 | 1280×960 |
| slider: brightness (lookup table), to pixels (script + render) | 34 ms (29 + 4) | 25 ms (22 + 3) | 33 ms (30 + 5) |
| slider: saturation (colour matrix) | 27 ms (24 + 3) | 31 ms (27 + 4) | 35 ms (29 + 4) |
| slider: blur radius 6 and 7, alternating (on a half-size proxy where the preview radius is 2 px or more: not radius 6 at 12 MP) | 116 ms (110 + 3) | 110 ms (106 + 4) | 122 ms (118 + 4) |
| slider: sharpen | 126 ms (120 + 3) | 134 ms (130 + 4) | 105 ms (101 + 4) |
| brush: a move, script, median / longest | 1.2 / 1.9 ms | 7.7 / 14 ms | 10 / 18 ms |
| brush: a move, to pixels, median / longest | 17 / 18 ms | 17 / 21 ms | 17 / 21 ms |
| brush: stroke start (copies the layer once) | 13 ms | 25 ms | 63 ms |

On GitHub's Chromium 151 runner ([`perf-ci-chromium.json`](../bench/editor/perf-ci-chromium.json))
the sliders reach the screen in 13–18 ms for the point operations, 55–71 ms for the blur preview
and 64–91 ms for sharpen; a brush move costs 0.7–5 ms of script (at most 10 ms) and reaches the
screen with the next frame (17 ms). In Playwright's Firefox at 1 MP
([`perf-ci-firefox.json`](../bench/editor/perf-ci-firefox.json), no traces) they take 58–73 ms,
284 ms and 371 ms, and a brush move 6 ms of script.

A slider's preview costs one preview-sized operation, a composite of the layers' previews, a
histogram of every fourth row, and showing the result; the image's size matters only for opening
it and for the work below. Render is 3–5 ms: the canvas is filled during the script
(`putImageData`), and the frame's own work is small. A brush move's time to pixels is one frame
(16.7 ms at 60 Hz) whenever its script fits in the frame.

### Long work: frames stay short

Applying an operation to the full-resolution layer, rotating and exporting run as jobs: a slice of
rows per animation frame, sized by a per-operation cost and adapted to the frame time (about 25 ms
of work a frame), with a progress bar. Time from the click to the result, and the longest frame
meanwhile (cloud VM, the same file):

| | 1 MP | 4 MP | 12 MP |
|---|--:|--:|--:|
| apply brightness | 73 ms, 33 ms | 360 ms, 50 ms | 640 ms, 67 ms |
| apply blur radius 6 | 274 ms, 50 ms | 1,020 ms, 50 ms | 3,260 ms, 600 ms |
| edge detect | 90 ms, 33 ms | 270 ms, 83 ms | 593 ms, 83 ms |
| rotate 90° | 73 ms, 33 ms | 273 ms, 67 ms | 490 ms, 67 ms |
| export PNG (5.3 MB at 12 MP) | 246 ms, 67 ms | 718 ms, 117 ms | 1,809 ms, 100 ms |

The 600 ms frame is most likely wasm memory growing. In four more 12 MP blurs on fresh pages (a
probe, not in the committed data) the longest frame was 100–133 ms, and it was always the job's
first frame, where the memory grows from 102 to 148 MiB for the job's full-size buffers. In the
run above the page had already done the sliders, the brush and one job (apply brightness), so its
memory was larger and grew in a bigger step. The job's slices
themselves stay at a few frames. Before the work was sliced (`cc99a41`,
[`perf-chromium-before-slicing.json`](../bench/editor/perf-chromium-before-slicing.json)), the
same machine froze for 5.8 s exporting a 12 MP PNG (one frame; 6.2 s in all) and 1.0 s rotating
it. On GitHub's Chromium runner a 12 MP blur takes 1.5 s (longest frame 50 ms) and an export 0.9 s
(167 ms); in Playwright's Firefox at 1 MP every job's longest frame is 17–50 ms, and the export's
167 ms.

### UI scaling: layers and history

On a 1 MP image (the image's size changes only the compositing). Each row loads a fresh page,
builds the panel (10 or 100 layers, or 200 history steps of a layer's opacity), does one warm-up
action, then measures one: a click on another layer or history step (select, show or hide,
whose warm-up clicks another layer's checkbox twice, and jump), a second click on Undo, or a
second change of the opacity slider (a new step); medians of 5 runs. Cloud VM, traced Chromium
141 (`perf-chromium.json`):

| | script | render | to pixels |
|---|--:|--:|--:|
| select a layer, 10 layers | 0.6 ms | 3.9 ms | 13 ms |
| select a layer, 100 layers | 0.9 ms | 4.9 ms | 16 ms |
| show or hide a layer (recomposite), 10 layers | 7.7 ms | 5.5 ms | 16 ms |
| show or hide a layer (recomposite), 100 layers | 6.7 ms | 4.9 ms | 15 ms |
| jump in a 200-step history | 7.7 ms | 8.9 ms | 17 ms |
| undo, 200 steps | 6.6 ms | 5.0 ms | 12 ms |
| a new step when the history is full (drops the oldest) | 6.3 ms | 4.2 ms | 11 ms |

A click costs 4.5–17 ms of main-thread work (script plus render), the same with 100 layers as
with 10; *to pixels* adds the wait for the next frame. On GitHub's Chromium runner the same rows
cost 2.7–10 ms of work; in Playwright's Firefox (10 layers and the history), 1–21 ms of script.
The panels are keyed lists of memoised rows, so a click diffs only what changed. A layer nothing
was painted on is skipped when compositing, which keeps 100 mostly empty layers as cheap as 10;
100 layers of 1 MP take 429 MiB.

### Memory and download

Wasm memory is 16 MiB at load and grows on demand (it never shrinks). A 12 MP image takes 57 MiB
open (its pixels, its preview, the canvas). Each history step keeps the images it replaced (a brush
stroke copies the layer it paints on once, 48 MB at 12 MP); the history is trimmed to 200 steps or
1 GiB of replaced images, so 50 strokes on a 12 MP image leave 1.23 GiB of wasm memory and 23
history entries (22 undoable steps). Download (brotli 11, `5c7314c`): `app.wasm` 266 KB, `app.js` 15 KB, `leanui.js`
9.5 KB, the page 1.9 KB.

### What is interactive, where the main thread blocks, and what would move to a worker

- **Point operations and painting are interactive at any size:** previews reach the screen in
  25–35 ms, and a brush move's script fits in a frame even at 12 MP at the median (10 ms; the
  longest move took 18 ms and reached the screen in 21 ms), because only the preview and the
  stroke's rectangle are touched.
- **Neighbourhood filters preview at about 8–10 updates a second** (blur and sharpen, 105–134 ms
  per input at preview size). This is the clearest gap: a faster blur (a box-filter approximation
  is a few operations a pixel whatever the radius) or computing the preview in a worker while the
  page shows the last one would both help.
- **Full-resolution work does not freeze the page**, apart from one 600 ms frame in the 12 MP blur
  (the other 12 MP jobs' longest frames are 67–100 ms), but takes seconds at 12 MP (blur 3.3 s,
  export 1.8 s) and occupies the main thread: during a job the page stays responsive (the progress
  bar moves, the view zooms, the side panels scroll), but the view cannot be panned and edits are
  disabled until it finishes. This is what
  would move to a Web Worker: a second wasm instance with its own copy of the layer (no shared
  memory, since the page is not cross-origin isolated), receiving the pixels and returning the
  result as transferred `ArrayBuffer`s (a copy each way, tens of milliseconds at 12 MP, against
  seconds of work). The commands that would start and answer such work are effects like the ones
  the framework already has (`Cmd.readFile` returns bytes the same way).
- **Opening** a 12 MP JPEG takes 0.6 s from choosing the file to the canvas: the browser's
  decoding (`createImageBitmap`, off the main thread), reading the pixels back, copying them into
  wasm memory, and Lean's preview and first composite (not measured separately).

### Video: the filters on every frame

The [video lab](../examples/Video.lean) (`/editor/video/`) plays a video file in a `<video>`,
which the browser decodes. On each animation frame it asks for the frame the video shows
(`Cmd.grabFrame`: a WebCodecs `VideoFrame` copied into wasm memory as RGBA), runs one of the
editor's filters on it in Lean, draws it (`Cmd.drawBitmap`) and waits for the next animation
frame. A frame already filtered is not filtered again, and a filter slower than the video drops
frames rather than queueing them. The number below is **frames filtered and drawn per second**.
[`tests/browser/video.mjs`](../tests/browser/video.mjs) `--perf` makes each test video in the
page: an animated canvas encoded by `VideoEncoder` (VP8, 4 s, exactly 30 fps, a keyframe a second)
into a WebM file. It plays each video once on its own to see what the browser presents (first
row). It then plays the video in the lab for 3 s per filter, and times each grab (the request to
the reply, asynchronous) and the Lean side of each new frame (the bytes into wasm, the filter,
the view and the `putImageData`, synchronous).

Cloud VM, Chromium 141 (headless, software video decoding and canvas), `5c7314c`
([`bench/editor/video-chromium.json`](../bench/editor/video-chromium.json)): *CI machine, to be
re-measured on the reference Mac*.

| filter | 640×360: fps · grab · Lean (ms) | 1280×720 | 1920×1080 |
|---|--:|--:|--:|
| the video played alone | 30 | 30 | 29.7 |
| none (grab and draw) | 30 · 1.7 · 0.8 | 30 · 6.8 · 2.4 | 30.1 · 12.5 · 4.8 |
| vivid (contrast, saturation) | 30 · 1.8 · 4.5 | 29.6 · 6.4 · 17 | 19.1 · 12.1 · 34.3 |
| black and white | 29.7 · 2.2 · 5.4 | 29.9 · 5.8 · 16.4 | 18.8 · 12.1 · 34.3 |
| invert (a lookup table) | 30.3 · 1.7 · 3.8 | 29.9 · 6 · 13.1 | 22.3 · 11.9 · 26.5 |
| edge detect (Sobel) | 30 · 1.8 · 7.4 | 28.2 · 5.8 · 23.4 | 14 · 12.6 · 50 |
| emboss (3×3) | 30 · 1.8 · 10.4 | 19.2 · 5.9 · 39.3 | 9 · 12.4 · 86.7 |
| sharpen (unsharp mask, radius 2) | 29.4 · 1.7 · 25.8 | 8.2 · 6.3 · 106.5 | 4 · 12.6 · 223.4 |
| blur (Gaussian, radius 4) | 26.8 · 1.6 · 32.1 | 6.1 · 6.6 · 145.3 | 3.1 · 12.5 · 293.8 |

- **The frame rate follows the per-frame cost.** One frame costs a grab plus the Lean side, and
  the loop waits for an animation frame between frames. So a frame costing 45 ms (emboss at
  720p) takes three 16.7 ms animation frames, and the lab draws about 20 fps of a 30 fps video;
  the measurement is 19.2.
- **Moving the pixels is cheap.** Without a filter, a 1080p frame is grabbed in 12.5 ms (the
  asynchronous `VideoFrame` conversion to RGBA), then handed to Lean and drawn in 4.8 ms (8 MB
  copied into wasm memory, then `putImageData` from it). The frame reaches `update` unshared,
  so the colour filters write into it: a counting build (`LEANUI_COUNT_ALLOCS=1`) shows one
  frame-sized allocation per inverted frame, two for edges (its output) and blur (its
  temporary). Before `stepMsgs` handed messages over unshared, every in-place filter copied the
  frame first: 2.4–5.8 ms a frame at 1080p
  ([`video-chromium-before-unshared.json`](../bench/editor/video-chromium-before-unshared.json) at
  `fda2bf5` against [`video-chromium-after-unshared.json`](../bench/editor/video-chromium-after-unshared.json)
  at `e9150de`).
- **The filters cost what they cost in the editor** (the Lean side minus the copy, per pixel, at
  720p and 1080p): 10–16 ns for a lookup table and a colour matrix, 22–23 ns for edges, 40 ns
  for emboss, 105–155 ns for the unsharp mask and the blur. The neighbourhood filters are the
  gap, as in the editor's previews.
- **What would raise the rates**, none of it done: a box-filter blur, whose cost does not grow
  with the radius; filtering at preview size, as the editor's blur preview does; grabbing the
  next frame while the current one is filtered (this hides the grab); and filtering in a worker.
  The worker is the largest change, because frames would then be filtered in parallel.

**GitHub's runner** (`ubuntu-24.04`, the `bench` run at `54181cf`;
[`video-ci-chromium.json`](../bench/editor/video-ci-chromium.json),
[`video-ci-firefox.json`](../bench/editor/video-ci-firefox.json)), same measurement. Runners are
different machines from run to run, so compare the rows within a table.

| Chromium 151 | 640×360: fps · grab · Lean (ms) | 1280×720 | 1920×1080 |
|---|--:|--:|--:|
| the video played alone | 30 | 30 | 30 |
| none (grab and draw) | 30 · 1.2 · 0.2 | 30 · 3.9 · 0.5 | 30 · 6.9 · 1.2 |
| vivid (contrast, saturation) | 30 · 1.2 · 2.5 | 30 · 4 · 9 | 30 · 7.2 · 20.1 |
| black and white | 29.7 · 1.2 · 2.5 | 29.7 · 3.9 · 9.2 | 30 · 7.3 · 20.5 |
| invert (a lookup table) | 29.7 · 1.1 · 2.2 | 29.7 · 3.9 · 7.2 | 29.4 · 6.6 · 16 |
| edge detect (Sobel) | 29.7 · 1.2 · 5.1 | 29.3 · 3.8 · 16.9 | 21.3 · 7.3 · 36.5 |
| emboss (3×3) | 29.7 · 1.2 · 6.6 | 29.8 · 3.8 · 25.7 | 14.3 · 7.1 · 59.6 |
| sharpen (unsharp mask, radius 2) | 29.3 · 1.2 · 15.3 | 15.2 · 3.9 · 59.6 | 6.8 · 7.2 · 136.9 |
| blur (Gaussian, radius 4) | 29.7 · 1.2 · 20.4 | 11.3 · 4.7 · 82 | 5.1 · 6.7 · 185.6 |

On this runner every filter but blur and sharpen keeps up with the video at 720p (they reach 11 and
15 fps). At 1080p the colour filters do, edges and emboss reach 21 and 14 fps, and blur and
sharpen 5–7 fps.

| Playwright's Firefox 153 | 640×360: fps · grab · Lean (ms) | 1280×720 | 1920×1080 |
|---|--:|--:|--:|
| the video played alone | 24.8 | 25 | 24.9 |
| none (grab and draw) | 24.9 · 3 · 0 | 25 · 11 · 1 | 23.6 · 22 · 2 |
| vivid (contrast, saturation) | 24.6 · 3 · 15 | 14.8 · 11 · 55 | 6.7 · 23 · 122 |
| black and white | 24.1 · 3 · 15 | 14.3 · 12 · 56 | 6.7 · 22 · 124 |
| invert (a lookup table) | 24.7 · 3 · 11 | 19.7 · 11 · 38 | 9.3 · 23 · 83 |
| edge detect (Sobel) | 22.2 · 3 · 23 | 10.5 · 11 · 82 | 4.9 · 22 · 179 |
| emboss (3×3) | 20.2 · 3 · 45 | 5.2 · 12 · 176 | 2.4 · 23 · 396 |
| sharpen (unsharp mask, radius 2) | 11.1 · 3 · 87 | 2.8 · 12 · 341 | 1.3 · 23 · 770 |
| blur (Gaussian, radius 4) | 8.5 · 3 · 113 | 2.2 · 12 · 449 | 1 · 23 · 1018 |

Headless Firefox presents these 30 fps videos at 25 fps even with nothing else running (first
row), so 25 is its ceiling here. Its timer is coarsened to whole milliseconds. Its Lean side
takes 5–7× Chromium's on the same runner, which is the gap between Playwright's Firefox build
and Chromium for any wasm (see "Playwright's Firefox is not Firefox" above): release Firefox
would need its own measurement.

### Reproducing (the editor)

```bash
tools/build-app.sh EditorBenchApp editor-bench && tools/build-app.sh EditorApp editor
./.lake/build/bin/leanui serve dist --port 5331 &
node tests/browser/editor-bench.mjs http://127.0.0.1:5331/ chromium --sizes 1,4,12 --runs 5
node tests/browser/editor-perf.mjs http://127.0.0.1:5331/editor/index.html chromium --out perf.json
node bench/editor/check-goldens.mjs     # the JavaScript port against the Lean goldens
LEANUI_COUNT_ALLOCS=1 tools/build-app.sh EditorBenchApp editor-bench-allocs
LEANUI_COUNT_ALLOCS=1 tools/build-app.sh EditorApp editor-allocs
node tests/browser/editor-allocs.mjs http://127.0.0.1:5331/   # allocations per operation and event
tools/build-app.sh VideoApp editor/video
node tests/browser/video.mjs http://127.0.0.1:5331/editor/video/index.html chromium --perf --out video.json
```

CI runs them (the operations at 1, 4 and 12 MP, the editor and the video lab, in Chromium and
Firefox) on a pull request with the `bench` label and uploads the JSON as the
`bench` artifact; [`bench/editor/README.md`](../bench/editor/README.md)
has the details and caveats.

## lean-vir: the same Lean, interpreted

[lean-vir](https://github.com/ejgallego/lean-vir) runs Lean's own IR interpreter, compiled to
wasm32, in the browser. [`vir/`](../vir/README.md) builds the benchmarked apps for it from the same
Lean files, so a LeanUI program can be compared three ways on the same code: written by hand in
JavaScript, written in Lean and compiled to wasm64 (what the site and every app ship), and the same
Lean interpreted by lean-vir. The site does not use lean-vir; the race page and the harnesses do.

Measured at `9d84b5c` on a cloud VM (Linux, x86-64; headless Playwright Chromium 141 and release
Firefox 158.0.1): **CI-machine numbers, to be re-measured on the reference Mac**. The ratios carry
over better than the milliseconds (the VM's rendering is several times slower than the Mac's). The
JSON is in [`bench/race/ci/`](../bench/race/ci/).

### Summary

- **Keyed suite**: lean-vir's clicks cost **3.25×** LeanUI wasm64's CPU time in Chromium (script
  and rendering, geometric mean of the nine operations) and **4.65×** in release Firefox (script
  and layout). Rendering is the same work (the DOM is identical, and the harness checks it); the
  script alone, Lean's update, view and diff plus applying the commands, is **13.5×** in Chromium
  and **12.5×** in Firefox.
- **Life** (1,000 clicks, one generation each): **50×** LeanUI wasm64's script time in Chromium
  (30.9 against 0.62 ms per click) and **48×** in Firefox. Little DOM work per click, so this is
  mostly Lean's own work, interpreted.
- **All three agree**: after every keyed operation the three tables are the same, and after 1,000
  generations the three Life boards are the same board as the native reference (`4e6b3290`,
  145 alive), in both browsers.
- **Startup and size** (Chromium): lean-vir is ready 277 ms after navigation (LeanUI 167 ms) and
  downloads 272 KB with brotli (LeanUI 175 KB): lean-vir's interpreter and loader are 181 KB, the
  Bench app's IR 83 KB.
- **Memory** after 10,000 rows: about the same, 27 MB of array buffers (lean-vir's wasm memory is
  most of it; its loader does not expose the memory itself) against LeanUI's 27.75 MB of wasm memory.

What lean-vir gives in exchange: a build without Emscripten, Docker or the wasm64 runtime archives
(`vir/build.sh` rebuilds and packages both apps in about 20 seconds), one prebuilt
interpreter for every app, and pages that need no Memory64, so they run in Safari too. LeanUI
stays on the compiled wasm64 build.

### The race (`/race/`)

[`bench/race/`](../bench/race/) runs one app three ways side by side, each in its own iframe:
hand-written JavaScript, LeanUI on wasm64 and LeanUI on lean-vir. The page is the referee, in plain
JavaScript: it clicks each app's own buttons, times the clicks (the app's update and its DOM calls,
not the layout and paint that follow once per frame), and then reads what each app shows to check
that all three agree.

- **Life**: Conway's Game of Life on 1,000 cells (40 × 25, wrapping), one generation per click on
  Step ([`examples/Life.lean`](../examples/Life.lean), and
  [`bench/race/life-vanilla.html`](../bench/race/life-vanilla.html) by hand). Each app shows the
  generation, the live cells and a hash of its board. The panels take turns, 8 ms of clicks each
  per animation frame, so in the same time the faster ones get further: what you see moving is
  each one's speed.
- **Table**: the keyed operations below, in the three Bench apps, one panel at a time with each
  operation's warm-ups; the median of the runs counts. After each operation the referee compares
  the rows each app shows (ids, labels, the selected row).

`tests/browser/race.mjs` runs it in CI (Life to generation 100, against the native reference;
the table once) and fails if the three ever disagree; `--perf` gives the numbers below.

Life, 1,000 clicks, script time:

| | Chromium 141 | per click | Firefox 158 | per click |
|---|--:|--:|--:|--:|
| vanilla JavaScript | 70 ms | 0.07 ms | 71 ms | 0.07 ms |
| LeanUI, wasm64 | 621 ms | 0.62 ms | 758 ms | 0.76 ms |
| LeanUI, lean-vir | 30,883 ms | 30.9 ms | 36,510 ms | 36.5 ms |
| lean-vir ÷ wasm64 | **50×** | | **48×** | |

On Life, LeanUI wasm64 takes about 9× (Chromium) and 11× (Firefox) vanilla's script time: a click
does little DOM work (vanilla changes the class of the hundred or so cells that changed, through
references it keeps), so the framework's own work shows: computing the generation, rebuilding the
rows that changed (40 cells each, most rows change), diffing them and encoding the commands. In
the keyed suite the DOM work dominates, and LeanUI is 1.2–1.5× vanilla.

Table, median of 3 runs, script time per click (the synchronous click, as in the release-browser
results above):

| operation | Chromium: vanilla | wasm64 | lean-vir | Firefox: vanilla | wasm64 | lean-vir |
|---|--:|--:|--:|--:|--:|--:|
| create 1,000 rows | 10.2 ms | 22.8 | 346 | 12.1 ms | 17.7 | 423 |
| replace all 1,000 rows | 15.4 ms | 35.7 | 522 | 19.3 ms | 44.8 | 518 |
| update every 10th row | 0.50 ms | 5.50 | 60.5 | 0.68 ms | 4.30 | 54.5 |
| highlight a row | 0.20 ms | 3.00 | 16.9 | 0.24 ms | 3.82 | 17.8 |
| swap 2 rows | 0.30 ms | 4.00 | 75.1 | 0.82 ms | 6.00 | 121 |
| remove a row | 0.10 ms | 3.90 | 37.6 | 0.46 ms | 4.24 | 61.7 |
| create 10,000 rows | 68.0 ms | 123 | 3,188 | 94.4 ms | 158 | 3,938 |
| append 1,000 rows | 6.00 ms | 14.8 | 388 | 7.32 ms | 23.7 | 464 |
| clear 1,000 rows | 8.90 ms | 16.8 | 99.0 | 17.0 ms | 19.4 | 133 |
| *geometric mean: wasm64 ÷ vanilla, lean-vir ÷ wasm64* | | **5.4×** | **12.9×** | | **3.7×** | **13.6×** |

Script alone, wasm64 is several times vanilla (the keyed results add rendering, the same for both,
which brings it to 1.2–1.5×); lean-vir is about 13× wasm64 in both browsers. The page's own timer is
coarse for the smallest clicks (Chromium's `performance.now()` steps by 0.1 ms here).

### The keyed suite with lean-vir

The harnesses of [Results](#results) with a third implementation (`--impls leanui,vanilla,leanvir`):
the Bench app run by lean-vir, `dist/vir/bench` (the page is
[`vir/pages/bench.html`](../vir/pages/bench.html)). Same method, same machine as above.

#### Chromium 141, traced: CPU time per click (median of 7 fresh loads)

| operation | LeanUI total | script | render | vanilla total | script | render | lean-vir total | script | render | LeanUI ÷ vanilla | lean-vir ÷ vanilla | lean-vir ÷ LeanUI |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| create 1,000 rows | 138.95 ms | 17.03 | 121.30 | 128.43 ms | 8.49 | 116.22 | 517.50 ms | 430.85 | 86.65 | **1.08×** | **4.03×** | **3.72×** |
| replace all 1,000 rows | 141.34 ms | 38.63 | 100.44 | 153.62 ms | 18.59 | 135.35 | 697.30 ms | 571.82 | 134.18 | **0.92×** | **4.54×** | **4.93×** |
| update every 10th of 1,000 rows | 32.87 ms | 5.54 | 27.07 | 25.65 ms | 0.47 | 25.17 | 62.61 ms | 42.95 | 19.49 | **1.28×** | **2.44×** | **1.90×** |
| highlight a row (of 1,000) | 6.53 ms | 1.66 | 5.03 | 4.74 ms | 0.11 | 4.60 | 17.70 ms | 13.62 | 4.65 | **1.38×** | **3.73×** | **2.71×** |
| swap 2 of 1,000 rows | 34.22 ms | 3.76 | 30.35 | 29.45 ms | 0.18 | 29.29 | 106.09 ms | 70.15 | 32.02 | **1.16×** | **3.60×** | **3.10×** |
| remove one of 1,000 rows | 31.82 ms | 2.02 | 29.52 | 35.23 ms | 0.26 | 35.01 | 83.91 ms | 55.18 | 32.74 | **0.90×** | **2.38×** | **2.64×** |
| create 10,000 rows | 1694.62 ms | 218.07 | 1507.61 | 1241.01 ms | 91.47 | 1156.88 | 4818.93 ms | 3912.04 | 890.51 | **1.37×** | **3.88×** | **2.84×** |
| append 1,000 rows to 1,000 | 186.10 ms | 42.15 | 139.37 | 118.25 ms | 8.00 | 110.29 | 563.90 ms | 424.93 | 131.88 | **1.57×** | **4.77×** | **3.03×** |
| clear 1,000 rows | 16.23 ms | 14.68 | 1.40 | 11.16 ms | 9.83 | 1.26 | 98.21 ms | 96.91 | 1.23 | **1.45×** | **8.80×** | **6.05×** |

Geometric mean of the ratios: **1.21×** (LeanUI ÷ vanilla), **3.95×** (lean-vir ÷ vanilla), **3.25×** (lean-vir ÷ LeanUI).

Script alone (the click's `EventDispatch`), lean-vir takes 6.6× (clear) to 27× (remove a row)
LeanUI's time, **13.5×** as a geometric mean; rendering, the same DOM, is the same work.

#### Firefox 158 (release, no automation): script and layout per click (median of 5 fresh loads)

| operation | LeanUI layout | script | vanilla layout | script | lean-vir layout | script | LeanUI ÷ vanilla | lean-vir ÷ vanilla | lean-vir ÷ LeanUI |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| create 1,000 rows | 71.24 ms | 16.50 | 56.40 ms | 8.42 | 550.48 ms | 495.76 | **1.26×** | **9.76×** | **7.73×** |
| replace all 1,000 rows | 122.06 ms | 45.34 | 76.04 ms | 28.12 | 643.08 ms | 560.62 | **1.61×** | **8.46×** | **5.27×** |
| update every 10th of 1,000 rows | 16.60 ms | 3.72 | 10.32 ms | 0.64 | 59.56 ms | 48.68 | **1.61×** | **5.77×** | **3.59×** |
| highlight a row (of 1,000) | 2.76 ms | 2.00 | 0.94 ms | 0.24 | 16.68 ms | 16.08 | **2.94×** | **17.74×** | **6.04×** |
| swap 2 of 1,000 rows | 29.76 ms | 3.72 | 27.88 ms | 0.70 | 107.78 ms | 80.82 | **1.07×** | **3.87×** | **3.62×** |
| remove one of 1,000 rows | 32.02 ms | 2.76 | 26.04 ms | 0.52 | 81.44 ms | 42.54 | **1.23×** | **3.13×** | **2.54×** |
| create 10,000 rows | 1139.40 ms | 530.14 | 839.98 ms | 224.64 | 4645.24 ms | 4068.74 | **1.36×** | **5.53×** | **4.08×** |
| append 1,000 rows to 1,000 | 102.38 ms | 37.38 | 74.00 ms | 8.60 | 530.92 ms | 458.98 | **1.38×** | **7.17×** | **5.19×** |
| clear 1,000 rows | 19.44 ms | 19.00 | 12.48 ms | 12.02 | 115.64 ms | 115.20 | **1.56×** | **9.27×** | **5.95×** |

Geometric mean: **1.49×** (LeanUI ÷ vanilla), **6.94×** (lean-vir ÷ vanilla), **4.65×** (lean-vir ÷
LeanUI); script alone, lean-vir ÷ LeanUI is **12.5×**. Ready after navigation: LeanUI 157 ms,
vanilla 32 ms, lean-vir 366 ms.

#### Memory (Chromium, after a full GC)

| after | LeanUI JS heap | LeanUI wasm memory | vanilla JS heap | lean-vir JS heap | lean-vir array buffers | DOM nodes |
|---|--:|--:|--:|--:|--:|--:|
| load | 1.46 MB | 16 MB | 1.01 MB | 1.78 MB | 7.05 MB | 47 |
| creating 1,000 rows | 1.94 MB | 16 MB | 1.19 MB | 2.22 MB | 9.18 MB | 11057 |
| 5 updates of every 10th row | 1.95 MB | 16 MB | 1.21 MB | 2.28 MB | 9.18 MB | 11057 |
| 5 create/clear cycles | 1.65 MB | 16 MB | 1.06 MB | 1.98 MB | 9.68 MB | 57 |
| creating 10,000 rows | 5.58 MB | 27.75 MB | 2.54 MB | 5.86 MB | 26.99 MB | 110057 |

#### Startup and size (Chromium)

| | LeanUI | vanilla | lean-vir |
|---|--:|--:|--:|
| ready after navigation | 166.5 ms | 18 ms | 277.4 ms |
| of which wasm instantiation + Lean init + first render | 126 ms | | 252.2 ms |
| transferred (uncompressed) | 1302.18 KB | 5.94 KB | 1719.25 KB |
| brotli | 175.02 KB | 2.06 KB | 272 KB |

lean-vir's loader does not expose its wasm memory, so its column is Chromium's count of
`ArrayBuffer` memory, which includes the wasm memory (for LeanUI it is within 0.1 MB of the wasm
memory). Its transferred bytes count `runtime.js` twice: the page imports it, and lean-vir's loader
fetches it again to check its hash.

### Reproducing (lean-vir)

```bash
tools/build-app.sh BenchApp bench && tools/build-app.sh LifeApp life   # the wasm64 builds
vir/build.sh                                                            # dist/vir/{bench,life} (Lean 4.35, vir/README.md)
bench/race/build.sh                                                     # dist/race
./.lake/build/bin/leanui serve dist --port 5331 &                       # the race at http://127.0.0.1:5331/race/
node tests/browser/race.mjs http://127.0.0.1:5331/ chromium --perf --out race-chromium.json
node tests/browser/selfbench.mjs <firefox-binary> firefox --race life --json race-life-firefox.json
node tests/browser/selfbench.mjs <firefox-binary> firefox --race table --runs 3 --json race-table-firefox.json
node tests/browser/bench.mjs --runs 7 --impls leanui,vanilla,leanvir --json keyed-chromium.json
node tests/browser/selfbench.mjs <firefox-binary> firefox --runs 5 --impls leanui,vanilla,leanvir --json keyed-firefox.json
node tools/bench-tables.mjs keyed-chromium.json keyed-firefox.json      # the keyed tables above
```

CI runs the keyed suite with lean-vir and the race (`--perf`, Chromium and Playwright's Firefox) on
a pull request with the `bench` label, next to the editor's benchmarks.

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
