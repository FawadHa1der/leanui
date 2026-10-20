# Execution strategies for Lean 4 in WebAssembly: interpreting IR (lean-vir) vs AOT (Lean -> C -> wasm) vs direct wasm codegen vs hybrids

Research date: 2026-10-20. "Measured" means a number someone timed. Numbers marked **[measured here]** come from a microbenchmark I ran in this session: Lean 4.34.0 (x86-64 Linux, release build), `leanc -O3`, a 4-core Intel Xeon at 2.80 GHz, and wall-clock timing with `IO.monoNanosNow` inside the program. Everything else is cited. Inferences are labeled as such.

Versions and commits checked: lean-vir `81de859` (2026-10-20, toolchain `leanprover/lean4:v4.35.0`), its SDK release for Lean 4.35 (wasm built 2026-10-13), lean-fir `167c2a4` (2026-10-12), Lean `master` `src/library/ir_interpreter.cpp` and `src/include/lean/lean.h` (fetched 2026-10-20), and LeanUI `docs/BENCHMARKS.md` at `93b8470` (2026-10-18).

## Q1. How fast is Lean's IR interpreter compared with compiled code, and how does the overhead change between allocation-heavy code and tight array loops?

### Takeaway
Lean's IR interpreter is a tree-walker over the compiler's IR objects, written "for simplicity instead of performance". On native x86-64 with Lean 4.34, I measured it at about **22–29× slower than compiled code on a build-and-diff of a virtual DOM tree**, but **55–200× slower on byte-array pixel kernels**. Every primitive operation (`ByteArray.get!`, `UInt32` and `Nat` arithmetic, `Float` operations) becomes a hash-looked-up, boxed call into native code. In LeanUI's terms, a 12 MP pixel operation that now takes 0.1–1 s in compiled wasm would take tens of seconds to minutes interpreted, so interpretation does not work for the pixel hot paths. For tree diffing it is borderline at best.

### Cited Findings
**Design of the interpreter (primary source, Lean `master`)**
- The header comment says: "Even with a JIT compiler, we still have a need for a simpler interpreter on platforms LLVM JIT does not support (i.e. WebAssembly). Because this is mostly an edge case, we strive for simplicity instead of performance and thus reuse the existing compiler IR instead of inventing something like a new bytecode format." — [lean4 ir_interpreter.cpp](https://github.com/leanprover/lean4/blob/master/src/library/ir_interpreter.cpp)
- It keeps a "homogeneous stack of `value`s", and it calls native code through "the 'boxed' versions of native functions, which have a (relatively) homogeneous ABI that we can use without runtime code generation". — [lean4 ir_interpreter.cpp](https://github.com/leanprover/lean4/blob/master/src/library/ir_interpreter.cpp)
- Mechanism, from the source:
  - Each full application (`FAp`) calls `call(fn, args)`, which runs `lookup_symbol(fn)`, a `m_symbol_cache.find(fn)` hash lookup keyed by the function's `Name`.
  - For native targets, `call` then boxes every argument (`box_t`), calls through `curry(...)` and unboxes the result.
  - The body loop is `while (true) switch (fn_body_tag(b))` over IR `fn_body` objects. Self tail calls become a jump that also calls `check_system()`.
  - Source: [lean4 ir_interpreter.cpp](https://github.com/leanprover/lean4/blob/master/src/library/ir_interpreter.cpp)
- In `lean.h`, `lean_box_uint64`, `lean_box_usize` and `lean_box_float` always heap-allocate a constructor object. `lean_box_uint32` heap-allocates when `sizeof(void*) == 4` (32-bit targets such as wasm32). So in the interpreter, each `Float`, `UInt64` or `USize` argument and result of a native call costs an allocation, and on wasm32 so does each `UInt32`. — [lean4 lean.h](https://github.com/leanprover/lean4/blob/master/src/include/lean/lean.h)
- `box_t` throws "not implemented yet" for `IRType.Struct` and `IRType.Union`. — [lean4 ir_interpreter.cpp](https://github.com/leanprover/lean4/blob/master/src/library/ir_interpreter.cpp)

**Statements and measurements from the Lean developers**
- Sebastian Ullrich (Zulip, 2023-03-30): "20x is definitely possible AFAIR" for compiled vs interpreted. He also said "only" around 10% of the mathlib4 build is spent in the interpreter, and that selective precompilation made "a full rebuild … 2% wall clock and 3.5% task clock faster". That run "precompiled 453 modules into 35MB of shared libraries". — [Zulip: Status of precompilation](https://leanprover-community.github.io/archive/stream/270676-lean4/topic/Status.20of.20precompilation.html)
- Ullrich (Zulip, 2021-01-09): to compare the interpreter with the compiler, use `-Dinterpreter.prefer_native=false` with `--run`, "otherwise stdlib code won't be interpreted". In the same thread a user reported compiling made a hash-map benchmark "about 5x faster"; the baseline mode is not stated precisely. — [Zulip: simple performance testing](https://leanprover-community.github.io/archive/stream/270676-lean4/topic/simple.20performance.20testing.html)
- Upstream is actively speeding up the interpreter. Draft PR #15444, "perf: faster interpreter" by Henrik Böving (opened about 2026-10-02, unmerged as of 2026-10-20), has commits "call hot funs directly", "return a ref" and "a cache". It reports `interpreted/iterators` wall-clock −32.21% and instructions −44.79%. Lean's benchmark suite has an `interpreted/` category. — [lean4 PR #15444](https://github.com/leanprover/lean4/pull/15444)
- Mathlib-scale interpretation cost from an Oct 2026 issue on a different project: "interpretation 522 s (26 %)" of build categories across 584 modules. Taken from a search snippet; I did not fetch it. — [sp1-lean issue #42](https://github.com/dtumad/sp1-lean/issues/42)

**[measured here] Native x86-64, Lean 4.34.0, compiled (`leanc -O3`) vs `lean --run` (interpreter)**
- Workloads:
  - **vdom**: build two 1,000-row × 10-cell trees (11,001 nodes each, with `String` fields and `Array` children) 10 times, then diff them recursively into an `Array Patch`. In total about 220k nodes are built and 110k node pairs diffed.
  - **lut**: `ByteArray.set!`/`get!` lookup table over 4,000,000 bytes.
  - **blur3**: a 3-tap `UInt32` horizontal blur into a fresh buffer.
  - **gamma**: `Float` multiply per byte.
- Timings. Compiled values are medians of 5 runs. The default `--run` column is 2 runs: user code interpreted, stdlib called natively. The `prefer_native=false` column is 1 run with stdlib IR also interpreted, which is closest to lean-vir's closure interpretation.

| workload | compiled | `lean --run` (default) | ratio | `prefer_native=false` | ratio |
|---|--:|--:|--:|--:|--:|
| vdom build+diff | 27.1 ms | 597–664 ms | 22–25× | 780 ms | 29× |
| lut, 4 MB | 33.2 ms (8.3 ns/B) | 1,813–2,435 ms | 55–73× | 2,201 ms | 66× |
| blur3 (UInt32), 4 MB | 52.0 ms (13 ns/B) | 5,227–5,543 ms | 100–107× | 5,225 ms | 100× |
| gamma (Float), 4 MB | 29.2 ms (7.3 ns/B) | 4,137–4,313 ms | 142–148× | 5,809 ms | 199× |

- Caveat on the gamma row: my first version took 400–800 ms compiled because a `Float` literal (`255.0`) was rebuilt through `OfScientific` on every iteration. After hoisting it into a top-level constant, compiled time fell to 29 ms. This is an Lean-codegen pitfall, not an interpreter effect.

**LeanUI's compiled numbers, for scale (LeanUI repo, wasm64 via Emscripten, Chromium 141 on a cloud VM)**
- At 12 MP: lookup-table adjustment 91.6 MPix/s, Gaussian blur radius 2 at 11.5 MPix/s, radius 8 at 4.3 MPix/s.
- A full-resolution blur takes 3.3 s.
- Natively, creating 1,000 rows costs 0.63 ms and selecting a row 0.08 ms (update, view, diff, encoding).
- Source: [LeanUI docs/BENCHMARKS.md](file:///home/user/leanui/docs/BENCHMARKS.md)

**lean-vir**
- No published speed ratio. Its docs tell readers to compare the `fib` and `sort` rows against "the host Lean IR baseline", but no recorded numbers are committed. — [lean-vir docs/development/PERFORMANCE.md](https://github.com/ejgallego/lean-vir/blob/main/docs/development/PERFORMANCE.md)
- An internal, explicitly non-official lean-fir note (2026-09-16) compares the same Verso-content rendering consumer: "pooled content-phase medians of 1,308.5 ms for VIR versus 835.7 ms for FIR (29.6% paired reduction)". It includes JS↔Lean conversion and React element building, so it is not a pure execution ratio. The lean-fir README asks readers not to cite it as a reference implementation. — [lean-fir docs/package-build-client-map.md](https://github.com/ejgallego/lean-fir/blob/main/docs/package-build-client-map.md)

### Inferences
- **Why the overhead differs by workload:**
  - In allocation-heavy code (tree build and diff), compiled code already spends much of its time in `lean_alloc`, RC and string comparison. The interpreter calls those same native routines, so its relative overhead is smaller: about 20–30×.
  - Scalar loops have almost no native work to hide behind. Every `+`, `get!` and compare costs a `Name`-hashed lookup plus boxing plus an indirect call, which gives about 55–200×.
  - Float-heavy and (on wasm32) `UInt32`/`UInt64`/`USize`-heavy kernels pay heap allocation per boxed operand, which explains why gamma is the worst case.
- **Inside wasm the ratio is likely the same or worse:**
  - lean-vir compiles the unmodified upstream interpreter to wasm32, so `UInt32` boxing also allocates there. On x86-64 it does not.
  - Interpreter-style code tends to lose more to wasm than straight-line compiled code does (see Q2: Pyodide is 3–5× slower than native CPython, while compiled C is 1–2.5× slower).
  - LeanUI compiles to wasm64 instead, where the `UInt32` box is free.
- **Extrapolation to LeanUI (estimate, not measured):**
  - A 12 MP RGBA lookup-table pass is 48 M bytes. At 0.45–0.6 µs per byte interpreted, that is roughly 20–30 s on a native host, against about 0.13 s for LeanUI's compiled wasm.
  - The radius-2 blur (≈1 s compiled) would take on the order of a minute or more.
  - For the keyed-table "create 1,000 rows" case, a 20–30× slowdown of the Lean-side work (0.63 ms natively; a few ms in wasm) would put it in the tens of ms, which blows a 16 ms frame.
- Upstream interpreter speedups such as PR #15444 (about 30–45% on an interpreted benchmark) are welcome but leave the order of magnitude unchanged.

### Gaps
- No measured lean-vir-in-browser vs compiled-wasm ratio exists for the same Lean function. Building a lean-vir `.irpkg` needs the Lean v4.35.0 toolchain, which was not installed here. The lean-vir harness (`npm run bench`, `fib`/`sort` rows vs the host IR baseline) could produce it.
- My microbenchmark is native x86-64, not wasm, and its interpreted rows have only 1–2 runs. Treat the ratios as ±15%.
- I found no published Lean benchmark that reports interpreted vs compiled time for the same program. The `interpreted/` category on speed.lean-lang.org has no paired compiled rows that I could find.

## Q2. What does general data say about interpreter vs AOT overhead in WebAssembly: interpreters compiled to wasm, no computed goto, and tail-call dispatch?

### Takeaway
Compiled C loses about 1.5× (up to 2.5×) when it goes to wasm. Interpreters compiled to wasm lose more: CPython in Pyodide is 3–5× slower than native CPython. Wasm has no computed goto. Tail-call dispatch, which helps natively, gives inconsistent results in wasm engines: anywhere from a 12% gain to a 4.6× loss. None of this changes the order of magnitude of the gap between an interpreter and an AOT build.

### Cited Findings
- On SPEC CPU, wasm ran about 45% slower in Firefox and 55% slower in Chrome on average than native, with peak slowdowns of 2.08× and 2.5× (Jangda et al., USENIX ATC 2019). — [USENIX ATC'19 "Not So Fast"](https://usenix.org/conference/atc19/presentation/jangda)
- The Pyodide roadmap says: "Across benchmarks Pyodide is currently around 3x to 5x slower than native Python", while "C code compiled to WebAssembly typically runs between near native speed and 2x to 2.5x times slower". — [Pyodide roadmap](https://pyodide.org/en/latest/project/roadmap.html)
- In the Pyodide 0.17 release, benchmarks ranged from near native to 3–5× slower, measured on Firefox 87 (2021). — [Mozilla Hacks, Pyodide 0.17](https://hacks.mozilla.org/2021/04/pyodide-spin-out-and-0-17-release/)
- CPython dispatch in wasm (Hood Chatham, 2023-05-30): with Emscripten, "tail calls have a 12% performance benefit" over switch. Natively, computed goto beats switch by about 20% under gcc and 10% under clang. — [discuss.python.org](https://discuss.python.org/t/interpreter-dispatch-and-performance-on-webassembly/27246)
- Andy Wingo (2026-04-07), reporting Matt Keeter's results: tail-calling vs switch interpreters in wasm were "1.2× slower on Firefox, 3.7× slower on Chrome, and 4.6× slower in wasmtime". Wingo's own measurements:
  - Wasmtime: switch 4.3× vs hand-written assembly, tail-calling 6.5×.
  - Wastrel: switch 2.4×, tail-calling 2.3×.
  - He argues the slowdowns are engine "accident[s]" (register allocation for parameters), not inherent to wasm.
  - Source: [wingolog: the value of a performance oracle](https://wingolog.org/archives/2026/04/07/the-value-of-a-performance-oracle)
- Wasm tail calls and WasmGC became Baseline (in all three major engines) on 2024-12-11. — [web.dev](https://web.dev/blog/wasmgc-wasm-tail-call-optimizations-baseline)
- Blazor/.NET follows the same pattern. Without AOT, apps run on "a .NET IL interpreter implemented in WebAssembly with partial JIT runtime support, informally referred to as the Jiterpreter". AOT "can yield dramatic improvements for apps that execute CPU-intensive tasks", while "most AOT-compiled apps are about twice the size of their IL-compiled versions" (page updated 2026-10-13). — [Microsoft Learn: Blazor WebAssembly AOT](https://learn.microsoft.com/en-us/aspnet/core/blazor/webassembly-build-tools-and-aot)

### Inferences
- Lean's IR interpreter is not a bytecode loop. It is a recursive C++ tree-walker that switches on IR node tags, so the dispatch-technique literature (computed goto, tail-call threading) applies only weakly. The dominant costs are per-call `Name` hash lookups, boxing and indirect native calls (Q1), and dispatch tricks would not remove them.
- The Pyodide and Jangda gaps suggest that interpreter-style code in wasm loses roughly 1.5–3× more than compiled code against native. So the native 22–200× interpreter/compiled ratio from Q1 is a floor for the ratio in wasm, not a ceiling.

### Gaps
- I found no published measurement of Lean's IR interpreter running in wasm against the same interpreter natively.
- I found no recent figures for QuickJS or Ruby (ruby.wasm) against native. The Lua data point I have is weval's (Q4).

## Q3. Direct wasm code generation from functional IRs: precedents, build and maintenance cost, Lean-specific projects, and whether WasmGC fits Lean's refcounted runtime

### Takeaway
Direct wasm backends exist and can be fast:
- wasm_of_ocaml has reported 2×–8× speedups over js_of_ocaml.
- GHC's wasm backend reuses its own runtime system.
- Hoot targets WasmGC.

Each one is a multi-year effort by a dedicated team, built for a language with a **tracing** GC. Lean's semantics depend on reference counts: `isShared`, reset/reuse and destructive `Array`/`ByteArray` updates. WasmGC exposes no counts, so a Lean-to-WasmGC backend would lose in-place updates, which are what make Lean's pixel loops viable. A practical direct-to-wasm Lean backend would keep linear-memory RC and Lean's C runtime, at which point it competes with Lean → C → clang mainly on toolchain weight and code size, not on speed. The only Lean-specific attempt found (lean-fir) is an explicitly non-public research workspace.

### Cited Findings
**OCaml**
- wasm_of_ocaml uses WasmGC: "no custom collector is shipped, and JS interop works through shared GC'd references". It requires the tail-call and exception-handling extensions, WasmGC in Chrome 119+, Firefox 120+ and Safari 18.2+, and Binaryen 119+.
- "Jane Street has reported 2x-8x speedups" over js_of_ocaml.
- Started as a fork of js_of_ocaml by Jérôme Vouillon with major contributions from Hugo Heuzard. Since 6.0.1 it shares a repository and release cycle with js_of_ocaml.
- Number unboxing (6.3) "keeps them in Wasm locals instead of allocating heap boxes".
- Source (2026-04-16): [OCaml.org backstage: wasm_of_ocaml since 6.1](https://ocaml.org/backstage/2026-04-16-wasm-of-ocaml-what-changed-since-6-1)
- Early result (2023): "Compiled programs typically run around 10-20% faster compared to the js_of_ocaml equivalent." — [OCaml Discuss update](https://discuss.ocaml.org/t/an-update-from-the-ocaml-wasm-organization/13114)

**GHC**
- GHC's wasm backend (merged 2022) uses GHC's own RTS for garbage collection in linear memory; Tweag called the RTS "way more robust, feature-complete and performant than asterius's legacy JavaScript runtime". — [Tweag: wasm backend merged in GHC](https://tweag.io/blog/2022-11-22-wasm-backend-merged-in-ghc/)
- The GHC 9.6 user guide describes the backend as a tech preview. — [GHC user guide: wasm](https://downloads.haskell.org/ghc/9.6.2/docs/users_guide/wasm.html)

**Scheme (Hoot) and WasmGC trade-offs**
- Hoot relies on WasmGC instead of shipping a collector, and tree-shakes to keep binaries small. Its explicit-stack strategy for delimited continuations "adds significant runtime overhead, in terms of both time and space". — [Spritely: Hoot v0.4.0](https://www.spritely.institute/news/guile-hoot-v040-released.html)
- V8 (2023-11-01) compared porting to WasmGC with bringing your own GC in linear memory:
  - WasmGC fannkuch binary was 2.3K against 6.1–9.6K for C/Rust; `dlmalloc` alone is about 6K.
  - "only WasmGC can handle stack references without overhead".
  - WasmGC lets the host collect cycles that cross into JS.
  - The post does not discuss reference counting.
  - Source: [v8.dev: WasmGC porting](https://v8.dev/blog/wasm-gc-porting)

**Reference counting (Koka and Lean)**
- Koka uses Perceus RC with reuse, which enables "functional but in-place" (FBIP) programming. Koka 2.3.2 (2021) added "initial wasm support (use `--target=wasm`…)" through Emscripten, so it follows the linear-memory C route rather than WasmGC. — [Koka book](https://koka-lang.github.io/koka/doc/book.html); [Perceus paper](https://www.microsoft.com/en-us/research/publication/perceus-garbage-free-reference-counting-with-reuse/)
- Lean's IR, as interpreted, contains RC-dependent instructions: `Reset` ("release fields if unique reference"), `Reuse` ("reuse dead allocation if possible"), `IsShared`, `Set`/`USet`/`SSet` ("set … field of unique reference"), `Inc`, `Dec` and `Del`. — [lean4 ir_interpreter.cpp](https://github.com/leanprover/lean4/blob/master/src/library/ir_interpreter.cpp)

**Lean-specific projects**
- lean2wasm (Reservoir) is described by its author as "a tool to compile Lean4 code to WASM. Right now this is really just for me to test things out", and it requires emcc (the C route). — [Reservoir: lean2wasm](https://reservoir.lean-lang.org/@T-Brick/lean2wasm)
- lean-fir (ejgallego, Lean 4.34.x) has two "LCNF-to-WebAssembly paths":
  - a "FIR-native symbolic path" (Fir.Wasm lowering, "zero-import resident runtime", monotone arena);
  - a "compiler-native C path" (Lean's `LCNF.emitC` → Emscripten/LLVM, linking pinned `libleanrt`, `libInit`, `libStd`).
  - The README warns it is an "Internal, non-official research workspace — not for external use … Do not depend on its code or artifacts, cite it as a reference implementation".
  - Source: [lean-fir README](https://github.com/ejgallego/lean-fir); [lean-fir docs/wasm-artifact-generation.md](https://github.com/ejgallego/lean-fir/blob/main/docs/wasm-artifact-generation.md)
- lean-vir's browser benchmark catalog compares five backends on lean-zip raw DEFLATE: `vir` (interpreted), `fir-native`, `fir-emscripten`, the browser's `CompressionStream` and `fflate`. It states "Timing values are not a candidate gate and are not publication evidence on an uncontrolled host." — [lean-vir benchmarks/browser/docs/LEAN_ZIP_INTEGRATION.md](https://github.com/ejgallego/lean-vir/blob/main/benchmarks/browser/docs/LEAN_ZIP_INTEGRATION.md)
- In lean-fir's own lean-zip work, level-6 compression medians fell from 391.71 ms to 54.20 ms over a series of runtime and helper optimizations. This shows how much a young backend's speed depends on hand-tuning runtime primitives (`Nat.mul`, `Nat.sub`, `USize.ofNat` helpers). — [lean-fir integration/lean-zip/README.md](https://github.com/ejgallego/lean-fir/blob/main/integration/lean-zip/README.md)

### Inferences
- **WasmGC fit:**
  - The WasmGC MVP gives references with no count and no uniqueness query. My understanding of the spec is that it has no refcount or "is unique" operation; I found no source that says this explicitly.
  - A Lean backend on WasmGC would therefore have to treat every object as shared. Every `Array.set!` or `ByteArray.set!` would copy, turning an O(n) pixel pass into O(n²). The alternative is to keep a linear-memory RC heap for arrays and similar objects, which gives up WasmGC's benefits.
  - This is the same structural reason Koka (Perceus) uses the C/Emscripten route.
  - WasmGC suits tracing-GC languages (OCaml, Scheme, Java, Kotlin, Dart), not Lean.
- **Linear-memory direct backend:**
  - It would reimplement or link Lean's runtime (allocator, RC, `Nat`/bignum, strings, thunks, tasks, IO), which `lean.h` and the C runtime already provide for the C route.
  - Its realistic advantages over Lean → C → clang are lighter tooling (no Emscripten or clang), faster builds and possibly smaller modules.
  - Peak speed is unlikely to beat LLVM `-O3` on Lean's C. LeanUI already measures its compiled Lean at 0.61–0.73× the time of equivalent JS on pixel ops.
- **Maintenance cost (estimate):** precedents took years, each built by a small dedicated team: wasm_of_ocaml (two core developers, building on js_of_ocaml's infrastructure), GHC's wasm backend (tech preview for years) and Hoot (Spritely). For Lean, the backend would also have to follow LCNF changes each release.

### Gaps
- I found no measured runtime or size comparison between FIR-native, FIR-Emscripten and VIR on the same workload that is published as evidence; the lean-vir catalog explicitly disclaims its timings.
- I found no primary source on GHC wasm backend speed or size against native.
- I found no Grain data. I did not research whether Grain moved from linear-memory RC to WasmGC.

## Q4. Hybrid designs: an interpreter plus compiled runtime and primitives, JIT-to-wasm, and a precompileModules analogue

### Takeaway
lean-vir is already a hybrid: the Lean runtime, a stage0 C subset and `@[extern]` primitives are compiled into its wasm, and only the reachable IR closure is interpreted. It also lets a client compile hand-written C providers into the runtime, with Lean fallbacks. Because every crossing from interpreted code into native code is a boxed call, a hybrid helps only when natives are **coarse-grained**: one call per image or per tree diff, not one per pixel or per node. Specializing an interpreter by partial evaluation (weval) or generating wasm at runtime (the .NET Jiterpreter) yields about 2–3×, not the 20–200× gap.

### Cited Findings
**lean-vir's own hybrid structure**
- lean-vir "compiles the unmodified `third_party/lean4-src/src/library/ir_interpreter.cpp` against the pinned Lean headers". It links "upstream runtime, utility and kernel sources plus pinned stage0 C modules". "Native lookup is closed: `dlsym` accepts only the generated native registry". It uses "Lean's ordinary allocator" because `LEAN_MIMALLOC` is disabled. — [lean-vir docs/reference/UPSTREAM_BOUNDARY.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/UPSTREAM_BOUNDARY.md)
- "The upstream interpreter invokes native functions through homogeneous boxed calls." `IRType.struct` and `IRType.union` "remain explicit package-generation errors". — [lean-vir UPSTREAM_BOUNDARY.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/UPSTREAM_BOUNDARY.md)
- Client-native externs: "VIR can compile project-owned C or C++ providers into a browser runtime … The client keeps a normal Lean reference body and an explicit fallback". Providers implement "the raw C ABI named by `@[extern]`; VIR generates only the boxed adapter used by the interpreter." — [lean-vir docs/reference/CLIENT_NATIVE_EXTERNS.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/CLIENT_NATIVE_EXTERNS.md)
- lean-vir's own JS↔wasm boundary: every value crossing is converted (JS checks → lower fields → allocate Lean objects → execute → lift → construct JS values). The docs show a JSON report example ("Bool -> Bool x 10000", `wasm` medianMs 185.0 vs `lower` 8.36). It illustrates the report format and should not be read as a recorded measurement. — [lean-vir docs/development/PERFORMANCE.md](https://github.com/ejgallego/lean-vir/blob/main/docs/development/PERFORMANCE.md); [lean-vir benchmarks/NATIVE_CODECS.md](https://github.com/ejgallego/lean-vir/blob/main/benchmarks/NATIVE_CODECS.md)

**Lean's native precompilation**
- Precompiling to shared libraries (mathlib, 2023) helped only modestly overall: 2% wall clock, because only about 10% of the build was interpretation. It produced 35 MB of shared libraries for 453 modules, and the PR needed 85 s of native compilation. — [Zulip: Status of precompilation](https://leanprover-community.github.io/archive/stream/270676-lean4/topic/Status.20of.20precompilation.html)
- The interpreter prefers native code when the symbol exists ("Whenever possible, we try to switch to native code by checking for the mangled symbol via dlsym"). It defaults to `LEAN_DEFAULT_INTERPRETER_PREFER_NATIVE true`. — [lean4 ir_interpreter.cpp](https://github.com/leanprover/lean4/blob/master/src/library/ir_interpreter.cpp)

**Partial evaluation (weval)**
- weval specializes an interpreter compiled to wasm with its bytecode (first Futamura projection). Results:
  - SpiderMonkey: 2.17× over interpreter+ICs on Octane, 2.93× on Richards.
  - PUC-Rio Lua: 1.84× on "trivial interpreter-heavy benchmarks", with about three hours of porting effort (+173/−57 lines).
  - On wasm, "2.53× over the generic interpreter … versus 5.37× on native" for baseline-like configurations.
  - The SpiderMonkey module grew from 8 MiB to 52 MiB after AOT-compiling Octane and an IC corpus.
  - Ahead-of-time only (Wizer snapshot); "run-time specialization is future work".
  - Source: [Fallin & Bernstein, arXiv 2411.10559](https://arxiv.org/html/2411.10559v1)

**Runtime wasm generation (Jiterpreter)**
- The .NET Jiterpreter compiles hot interpreter traces into wasm at runtime, one module per trace. "Trace compilation is synchronous", and because browsers limit synchronously compiled modules to about 4 KB, traces stop early near that size. Each trace imports the heap and function table; the doc notes "Function pointers also have considerably higher overhead in WebAssembly". It disables itself after repeated compile errors or a byte cap. — [dotnet/runtime jiterpreter.md](https://github.com/dotnet/runtime/blob/main/docs/design/mono/jiterpreter.md)

### Inferences
- **Granularity:**
  - For LeanUI's pixel kernels, a hybrid works only if each whole kernel (LUT, blur, composite, PNG filter and deflate) is native. Two ways to get there: hand-port the kernels to C as lean-vir client providers, or (not documented by lean-vir) compile Lean-authored kernels through EmitC into the runtime.
  - The second way recreates the AOT toolchain inside the "interpreter" build, so the hybrid's maintenance cost converges on the AOT path's.
  - For vdom diffing, the hot code is the app's own `view` plus the framework's diff. The diff could be native, but `view` and `update` are app code and would stay interpreted. Allocation-heavy code ran 22–29× slower interpreted in Q1.
- **weval-style specialization:**
  - weval assumes a bytecode loop with a program counter. Lean's interpreter walks heap-allocated IR objects and recurses through C++, so applying weval would need either a bytecode redesign or careful annotation (not demonstrated).
  - Even then, precedents show 2–3×, which leaves a 10–100× gap to compiled code, at the cost of a large code-size increase.
- **JIT-to-wasm (estimate):** it is feasible in principle: emit a wasm module per hot Lean function from IR at runtime and instantiate it asynchronously. In practice it amounts to building a direct wasm backend (Q3) plus a runtime linker into a shared memory and table, which costs more to maintain than either pure option.
- **Useful complement (inference):** an interpreter is valuable for live and editable code, such as lean-vir's editor widgets "use live environments, including unsaved code". That makes it a good fit for a development or preview mode, or for user scripting inside a LeanUI app, while shipped hot paths stay AOT.

### Gaps
- lean-vir does not document whether Lean-authored functions can be AOT-compiled (EmitC) into its runtime as natives. I found only hand-written C providers.
- I found no Lean-specific JIT-to-wasm experiment.

## Q5. Size and startup: interpreter plus serialized IR vs compiled wasm

### Takeaway
lean-vir's interpreter wasm alone is **793 KB raw, about 148 KB brotli**, plus about 227 KB of raw JS runtime, before any application IR. LeanUI's entire compiled site wasm is **194 KB brotli** and its large editor wasm **266 KB brotli** (2.29 MB raw). So switching to an interpreter can save at most roughly 50–120 KB brotli of code, minus whatever the serialized IR package costs. That does not offset a 20–200× execution slowdown. Startup cost shifts from wasm compilation to IR decoding and object materialization, which nobody has published measurements for.

### Cited Findings
**[measured here] lean-vir SDK for Lean 4.35** (`lean-vir-sdk.tar.gz`, 1,286,987 bytes, from the GitHub release resolved by `lake exe vir_fetch_sdk`)
- `wasm/vir-upstream.wasm`: 793,324 B raw, 190,656 B gzip -9, 148,322 B brotli q11.
- Debug companion `vir-upstream.dev.wasm`: 4,080,563 B.
- JS runtime files: 227,313 B total, raw.
- Source: [lean-vir releases](https://github.com/ejgallego/lean-vir/releases)

**[measured here] LeanUI build outputs** (sizes of the files in `dist/`; brotli q11 computed with Node's zlib)

| artifact | raw | brotli | code section | functions |
|---|--:|--:|--:|--:|
| `dist/editor/app.wasm` | 2,294,416 B | 265,723 B | 2,228,951 B | 1,947 |
| `dist/site/app.wasm` | 1,524,702 B | 194,441 B | — | — |
| `dist/editor/video/app.wasm` | 1,352,637 B | 179,477 B | — | — |

- Source: LeanUI `dist/`

**LeanUI startup and download (documented)**
- Startup is "ready 25 ms after navigation … of which 20.3 ms is compiling and instantiating the wasm, initializing Lean and the first render; 168.36 KB over the wire with brotli" (keyed-table app).
- The editor downloads 292 KB with brotli (wasm 266 KB).
- 16 MB of wasm memory at load.
- Source: [LeanUI docs/BENCHMARKS.md](file:///home/user/leanui/docs/BENCHMARKS.md)

**lean-vir's own packaging and startup notes**
- lean-vir measures package-load, initializer and export-slot resolution separately ("A separate package-load row uses a fresh Wasm instance for each load"). The default memory is "4 MiB initial memory and a 1 MiB stack". — [lean-vir PERFORMANCE.md](https://github.com/ejgallego/lean-vir/blob/main/docs/development/PERFORMANCE.md); [lean-vir docs/HARNESS.md](https://github.com/ejgallego/lean-vir/blob/main/docs/HARNESS.md)
- The browser decoder materializes Lean objects for every declaration ("Decoded Lean objects are runtime-owned, not views into the package bytes"). — [lean-vir docs/reference/IRPKG_FORMAT.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/IRPKG_FORMAT.md)
- One small fixture package (26 callable signatures): whole-package offline gzip 3,325 bytes; manifest JSON 17,712 B (2,171 B gzip). — [lean-vir benchmarks/NATIVE_CODECS.md](https://github.com/ejgallego/lean-vir/blob/main/benchmarks/NATIVE_CODECS.md)

**Precedents on interpreter vs AOT size**
- .NET: AOT apps are "about twice the size of their IL-compiled versions" because "more code is required to represent high-level .NET IL instructions in native WebAssembly". — [Microsoft Learn](https://learn.microsoft.com/en-us/aspnet/core/blazor/webassembly-build-tools-and-aot)
- weval's AOT specialization increased SpiderMonkey's module from 8 MiB to 52 MiB. — [arXiv 2411.10559](https://arxiv.org/html/2411.10559v1)

### Inferences
- The size win from interpretation exists only when the application's own compiled code is large compared with the runtime and stdlib. In LeanUI the fixed costs (Lean runtime, `Init`/`Std` closure, dlmalloc, Emscripten glue) are shared by both strategies. The interpreter wasm *also* contains the Lean runtime plus stage0 C, so its 148 KB brotli is a floor comparable to the whole of LeanUI's 179–266 KB compiled apps.
- **IR vs wasm code size (estimate, not measured):**
  - Lean IR serialized as a tree of constructor tags, names, variable indices and type tags is likely the same order of size as the wasm it replaces. It is probably smaller for code that `-O3` inlines heavily and larger for small functions.
  - The irpkg also carries a manifest and initializer tables.
  - Every decoded declaration becomes live Lean heap objects in wasm memory, which costs startup time and memory.
- **Startup:**
  - Compiled wasm can be streaming-compiled and cached by browsers. IR packages must be fetched, decoded into Lean objects and indexed (`name_hash_map`), and their initializers run in the interpreter.
  - For small packages this is likely cheap. For an app of the editor's size it is unknown and should be measured before relying on it.

### Gaps
- I have no measured `.irpkg` size for a LeanUI-sized app, and no measured lean-vir time to first call in a browser for a large package. Building one needs the Lean v4.35 toolchain and lean-vir's `vir_irpkg`.
- I have no breakdown of LeanUI's 2.23 MB code section into runtime, `Init`/`Std` and app shares. A name-section or twiggy-style analysis would answer it.

## Q6. Which strategy is most durable given Lean's compiler evolution (LCNF, IR changes) and wasm standards?

### Takeaway
**Lean → C → wasm (AOT) is the most durable.** It rides on Lean's primary, officially supported backend: since Lean 4.30 the C emitter runs directly on the new LCNF pipeline. It also uses mature wasm features: linear memory, exception handling, and memory64 for LeanUI. The IR interpreter is upstream-maintained and actively optimized, so it will not disappear soon. However, lean-vir couples itself to Lean's internal IR data structures and constructor layouts, so it needs a toolchain-matched SDK every release and cannot run IR features the interpreter lacks (unboxed structs and unions). A direct Lean-to-wasm backend is the least durable: it would have to track LCNF changes as well as the runtime ABI, and no supported precedent exists.

### Cited Findings
- Lean 4.30.0 release notes:
  - #12781 "ports the C emission pass from IR to LCNF", described as the final step of the IR/LCNF conversion.
  - #12665 ports expand reset/reuse to LCNF, with "roughly 15% decrease in binary size".
  - #12705 ports ground-expression extraction.
  - Source: [Lean 4.30.0 release notes](https://lean-lang.org/doc/reference/4.35.0/releases/v4.30.0/)
- The interpreter still consumes `Lean.IR` (λRC IR). Its code refers to `Lean.IR.ToIR.lowerParam` for parameter ownership, which implies IR is now produced from LCNF mainly for interpretation. — [lean4 ir_interpreter.cpp](https://github.com/leanprover/lean4/blob/master/src/library/ir_interpreter.cpp)
- An upstream interpreter performance PR is in flight (draft, October 2026). — [lean4 PR #15444](https://github.com/leanprover/lean4/pull/15444)
- lean-vir's coupling to the toolchain:
  - It pins `leanprover/lean4:v4.35.0` and fetches "Lean-aligned" SDK releases. "Use the Lean toolchain selected by your VIR dependency." — [lean-vir README](https://github.com/ejgallego/lean-vir); [lean-vir tools/VirFetchSdk.lean](https://github.com/ejgallego/lean-vir/blob/main/tools/VirFetchSdk.lean)
  - Its decoder reconstructs IR in "Lean's actual constructor layout" and "the codec covers their current constructor set". It is on package format 11.
  - "New catalog entries require matching runtime bytes".
  - Proof-bearing extern ABIs need "an independently checked interpreter/wrapper match".
  - Source: [lean-vir UPSTREAM_BOUNDARY.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/UPSTREAM_BOUNDARY.md)
- lean-vir's support policy: only the runtime, package workflow, low-level object API and minimal JS/Lean interop are "officially supported". DOM helpers, React/JSX and editor integrations are experimental. — [lean-vir README](https://github.com/ejgallego/lean-vir)
- LeanUI's own AOT maintenance: it builds against "the QED64 wasm64 fork of Lean 4.34.0" plus a 9-line CMake patch for a single-threaded runtime, with compile flags `-O3 -m64 -fwasm-exceptions -sWASM_LEGACY_EXCEPTIONS=1`. — [LeanUI docs/TOOLCHAIN.md](file:///home/user/leanui/docs/TOOLCHAIN.md); [LeanUI toolchain/fork.lock](file:///home/user/leanui/toolchain/fork.lock)
- Wasm standards: WasmGC and tail calls have been Baseline since 2024-12-11. wasm_of_ocaml notes that stack switching "is not yet in stable browser releases (Chrome/V8 has it behind a flag)", and that browsers use the legacy exception-handling proposal while newer runtimes need `exnref`. — [web.dev](https://web.dev/blog/wasmgc-wasm-tail-call-optimizations-baseline); [OCaml.org backstage](https://ocaml.org/backstage/2026-04-16-wasm-of-ocaml-what-changed-since-6-1)

### Inferences
- **AOT C path:** durability risk sits in the toolchain, not in Lean's semantics. That covers the wasm64 fork, Emscripten versions and the legacy-to-`exnref` exception-handling migration. Lean's C backend and `lean.h` are first-class upstream artifacts, so per-release breakage is limited to the runtime build. The EmitC → LCNF move in 4.30 was transparent to C consumers.
- **IR interpreter path:**
  - The interpreter's C++ is upstream and benefits automatically from upstream speedups.
  - But lean-vir's `.irpkg` codec, native registry and boxed-wrapper inventory are lean-vir's own, and they must track IR changes on every release.
  - If upstream starts emitting `IRType.struct`/`union` (unboxed structures) or later replaces λRC IR with direct LCNF interpretation, lean-vir needs non-trivial porting.
  - It is a single-maintainer research project (8 stars, Apache-2.0, 348 commits as of 2026-10-20).
- **Direct wasm path:** lowest durability. It must track LCNF (which changed substantially through 4.30) and the runtime ABI, with no upstream owner. lean-fir disclaims external use. WasmGC, the standards direction for managed languages, does not suit Lean's RC semantics (Q3), so a direct backend cannot ride that standardization.
- **Overall recommendation (inference):**
  - Keep AOT (Lean → C → wasm) as LeanUI's production execution strategy.
  - Treat lean-vir as a possible complement for scenarios where compiling is impossible or too slow: live editing and preview of app code, user-supplied scripts, widgets over unsaved code.
  - For any such use, keep pixel kernels and the vdom diff native, as runtime primitives called once per frame or image.
  - lean-vir is not viable as a replacement for LeanUI's hot paths.

### Gaps
- I found no upstream statement on whether `Lean.IR` will be kept long-term now that EmitC consumes LCNF, or whether an LCNF interpreter will replace it.
- I found no data on the cost, in maintainer time per Lean release, of keeping lean-vir's codec and native registry current.
