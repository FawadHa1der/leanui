# WebAssembly platform and toolchain choices for a browser Lean runtime (lean-vir / LeanUI), as of 20 Oct 2026

Scope: wasm32 vs Memory64 (wasm64), and Emscripten vs wasi-sdk/WASI vs plain clang, for running a Lean 4 runtime or IR interpreter in browsers. Research date: 2026-10-20. Primary sources were read directly where possible: WebAssembly `features.json` from the website repo's main branch, Emscripten `ChangeLog.md` and `settings.js` on main, the wasi-sdk/wasi-libc READMEs on main, V8 source on main, LLVM source and release notes, Lean 4 `lean.h`, `ci.yml` and `CMakeLists.txt` on master, and the lean-vir repo at commit 81de859 (2026-10-20). Items marked **[secondary]** come from search snippets or aggregators. Items marked **[unverified]** come from general knowledge and were not re-checked.

---

## 1. Memory64 standardization and shipping status per engine

### Takeaway
Memory64 is standard: it is phase 5 and part of Wasm 3.0 (Sept 2025). It ships by default in Chrome/Edge (133+), Firefox (134+), Node (24+), Deno (2.2+), Wasmtime (30+) and WAMR. **No stable Safari ships it as of Oct 20, 2026.** It is only in Safari Technology Preview 251 (Aug 26, 2026) and STP 252 (Sep 11, 2026), and iOS Safari (so every iOS browser) lacks it. Memory64 was **not** an Interop 2026 focus area (JSPI was).

### Cited Findings
- **Spec status:** Wasm 3.0 was announced 2025-09-17 by Andreas Rossberg. It includes 64-bit address space (memory64), multiple memories, GC, typed references, tail calls, exception handling, relaxed SIMD, a deterministic profile, custom annotations and JS string builtins. "On the web, a 64-bit memory is capped at 16 GB." The post says Wasm 3.0 "is already shipping in most major web browsers" without naming them — [Wasm 3.0 announcement](https://webassembly.org/news/2025-09-17-wasm-3.0/)
- `features.json` lists memory64 as phase 5. Multi-memory, GC, tail call, exnref EH, JSPI, JS string builtins and branch hinting are also phase 5. Legacy EH is "inactive". Threads are phase 4, wide arithmetic phase 4, custom page sizes phase 3, stack switching phase 3, memory control phase 1, shared-everything threads phase 1 and component model phase 1 — [WebAssembly/website features.json](https://github.com/WebAssembly/website/blob/main/features.json) (data behind [webassembly.org/features](https://webassembly.org/features/))
- **Per-engine Memory64 (features.json, main branch, read 2026-10-20):**
  - Chrome 133 and Firefox 134.
  - Safari: `["flag", "Supported in Safari Technical Preview 251"]`.
  - Node.js 24.0, Deno 2.2, Wasmtime 30.
  - GraalWasm: flag `--wasm.Memory64=true`. wasm2c: flag `--enable-memory64`.
  - Wasmi 0.41, Wizard 25.
  - wazero, WasmEdge and Owi: not supported.
  - Wasmer: no memory64 entry at all.
  - Source: [features.json](https://github.com/WebAssembly/website/blob/main/features.json)
- The SpiderMonkey team (Jan 15, 2025) described Memory64 as "finally released in both Firefox 134 and Chrome 133" — [SpiderMonkey blog](https://spidermonkey.dev/blog/2025/01/15/is-memory64-actually-worth-using.html) (quoted via search snippet) **[secondary for the exact quote]**
- **Safari Technology Preview 251** (Aug 26, 2026) lists "Added support for WebAssembly Memory64." It also added `traceStack` on `WebAssembly.Exception` / `Exception.stack`, and Web Inspector source-map mapping for Wasm byte offsets — [WebKit: STP 251 release notes](https://webkit.org/blog/18194/release-notes-for-safari-technology-preview-251/)
- **Safari Technology Preview 252** (Sep 11, 2026) lists "Added support for WebAssembly memory64 together with multiple memories." — [WebKit: STP 252 release notes](https://webkit.org/blog/18304/release-notes-for-safari-technology-preview-252/)
- **Safari 27.0** (WebKit features post dated Sep 17, 2026):
  - Its Wasm items are JSPI support and a `WebAssembly.Memory`/`Module` cloning/transfer fix. Memory64 is not mentioned in the first 100k characters of the post; the tail was not read — [WebKit Features for Safari 27.0](https://webkit.org/blog/18325/webkit-features-for-safari-27-0/)
  - Safari 27 stable release date: Sep 14, 2026 — [browsercalendar.com](https://browsercalendar.com/browsers/safari) **[secondary]**
- caniuse (read 2026-10-20):
  - Memory64 is **not supported** in Safari 27 or 27.1-TP, and not in Safari on iOS 27.0–27.2.
  - Supported: Chrome 133+, Edge 133+, Firefox 134+, Opera 118+, Chrome for Android (155), Firefox for Android (158) and Samsung Internet 29+.
  - Opera Mobile (80): not supported.
  - Global usage: 73.55%.
  - Source: [caniuse wf-wasm-memory64](https://caniuse.com/wf-wasm-memory64)
  - Note: caniuse marks "27.1-TP" unsupported, while WebKit's STP notes say support was added. This conflicts, or caniuse lags behind STP.
- **Interop 2026** (announced Feb 12, 2026): the new-feature focus areas include "JavaScript Promise Integration for Wasm". The post lists no Memory64 item — [Mozilla Hacks: Launching Interop 2026](https://hacks.mozilla.org/2026/02/launching-interop-2026/)
- WAMR's README lists Memory64 (and shared memory, tail call, GC, exception handling) among supported post-MVP features. The latest tag is WAMR-2.4.5 — [WAMR README](https://github.com/bytecodealliance/wasm-micro-runtime)
- The Emscripten 3.1.72 changelog (Nov 19, 2024) says "The `MEMORY64` setting is no longer experimental" — [Emscripten ChangeLog](https://github.com/emscripten-core/emscripten/blob/main/ChangeLog.md)
- Unity Web: "Use WebAssembly64 only if your application requires more than 4 GB of memory". Builds are "limited to 16 GB by the WebAssembly JavaScript API specification". Wasm64 "can increase code size and runtime overhead" — [Unity Manual: wasm-64bit-support](https://docs.unity3d.com/Manual/wasm-64bit-support.html)

### Inferences
- Shipping in STP usually precedes stable Safari by one or more releases. Memory64 plausibly reaches stable Safari in a 27.x point release (WebKit has shipped Wasm features in x.2/x.4 releases: features.json shows exnref EH in Safari 18.4 and JS string builtins in 26.2) or in Safari 28 (~Sept 2027). This is speculative.
- Until then, a Memory64-only build excludes all iOS browsers and all macOS Safari users. Older iOS devices that cannot update stay excluded for years after stable support lands.
- Bun embeds JavaScriptCore, so it most likely lacks Memory64 until JSC enables it by default. I did not verify this.
- Chrome on Android and Firefox on Android share engines with desktop. Their Memory64 support should match desktop versions 133 and 134. caniuse tracks only recent mobile versions, which is why its table starts at 155 and 158.
- Release dates (general knowledge, not re-verified): Chrome 133 ≈ early Feb 2025, Firefox 134 ≈ early Jan 2025, Node 24.0 ≈ May 2025, Wasmtime 30 ≈ Feb 2025.

### Gaps
- No Apple statement on when Memory64 reaches stable Safari or iOS. The full Safari 27.0 release notes were not read beyond the WebKit features post.
- Bun's and Wasmer's Memory64 status are unconfirmed. features.json has no Wasmer memory64 entry.
- Whether STP's Memory64 is on by default or behind a flag: features.json encodes it as `flag`, while WebKit's notes say "Added support". This is ambiguous.

---

## 2. Performance of Memory64 vs wasm32 (bounds checks, memory limits, code size, pointer size)

### Takeaway
wasm32 on 64-bit hosts gets bounds checks almost for free through a 4 GiB+ virtual reservation with guard pages. Memory64 needs some per-access check. SpiderMonkey reports Memory64 slowdowns of **10% to over 100%** (Jan 2025). V8 on main now uses a cheaper hybrid: a compare against a 16 GiB constant plus a 16 GiB guard reservation (`wasm_memory64_trap_handling`, default on for x64/arm64/riscv64/loong64). The overhead is lower but not zero, and V8 has published no public benchmark. Browser Memory64 is capped at 16 GiB, versus 4 GiB for wasm32. Every vendor's guidance is the same: use Memory64 only if you need more than 4 GiB.

### Cited Findings
- **SpiderMonkey** (Ben Visness, Jan 15, 2025):
  - Memory64 workloads are slower by "from just 10% to over 100%".
  - Each check costs a compare, a branch and an extra load of the memory size, and it enlarges machine code.
  - wasm32 avoids checks by reserving 4 GB (plus 32 MiB + 64 KiB of guard pages for offsets).
  - Explicit checks are still used on 32-bit devices and resource-constrained phones.
  - "The only reason to use Memory64 is if you actually need more than 4GB of memory."
  - The JS API caps memories at 16 GB.
  - Source: [SpiderMonkey blog](https://spidermonkey.dev/blog/2025/01/15/is-memory64-actually-worth-using.html)
- **V8 (source on main, read 2026-10-20):**
  - Flag: `DEFINE_BOOL(wasm_memory64_trap_handling, true, "Use trap handling for Wasm memory64 bounds checks")` on ARM64/X64/RISCV64/LOONG64; read-only false on other architectures — [V8 flag-definitions.h](https://chromium.googlesource.com/v8/v8.git/+/refs/heads/main/src/flags/flag-definitions.h)
  - Reservation: with guard regions, memory64 reserves `wasm::kMaxMemory64Size`, plus one extra page on ARM64 "to simplify bounds checking". 32-bit memories reserve `kFullGuardSize32` (≥ 4 GB) — [V8 backing-store.cc](https://chromium.googlesource.com/v8/v8.git/+/refs/heads/main/src/objects/backing-store.cc)
  - Generated check: Liftoff compares the index against the constant `kMaxMemory64Size - end_offset` ("such that at runtime `index + end_offset` will be < `max_mem_size`, where the trap handler can handle out-of-bound accesses"). Without trap handling it loads the memory size from the instance for an explicit check — [V8 liftoff-compiler.cc](https://chromium.googlesource.com/v8/v8.git/+/refs/heads/main/src/wasm/baseline/liftoff-compiler.cc)
- **Academic** (Döllerer & Engelke, TUM, VMIL '24, Oct 20, 2024):
  - Software bounds checks for 64-bit Wasm cost **109.8%** run time over no checks.
  - "64-bit guard pages" (test/jne plus a memory access) cost **76–142%**.
  - Two-level guard pages reduce the overhead to **12.7%** on average (maximum 17.3%).
  - x86-64 memory protection keys were "not practical".
  - Their survey notes that most runtimes emit software checks for memory64, that SpiderMonkey, Wasm3 and WasmEdge always emit software checks even for 32-bit, and that "the V8 team is currently evaluating alternative methods".
  - This is a research prototype, not a shipping engine.
  - Source: [ACM DOI 10.1145/3689490.3690400](https://dl.acm.org/doi/10.1145/3689490.3690400) / [PDF](https://home.cit.tum.de/~engelke/pubs/2410-vmil.pdf)
- **IISWC 2022 "Leaps and bounds":** forced explicit bounds checks in V8 (32-bit) cost 20% (Cholesky) to 220% (gemm) on PolyBench, and up to 650% in some cases — [Szewczyk et al., IISWC 2022](https://tom-spink.com/papers/iiswc22leaps.pdf) **[secondary — from search snippet, not re-read]**
- **Memory limits:**
  - Wasm 3.0 caps 64-bit memory at 16 GB on the web — [Wasm 3.0 announcement](https://webassembly.org/news/2025-09-17-wasm-3.0/). Unity also cites the 16 GB JS API cap — [Unity](https://docs.unity3d.com/Manual/wasm-64bit-support.html)
  - Emscripten's default `MAXIMUM_MEMORY` is 2 GB. Going to 4 GB on wasm32 requires opting in, because pointers must be treated as unsigned in JS — [Emscripten settings.js](https://github.com/emscripten-core/emscripten/blob/main/src/settings.js)
- **Code size:** Unity says wasm64 "can increase code size and runtime overhead", but gives no figures — [Unity](https://docs.unity3d.com/Manual/wasm-64bit-support.html)
- **Pointer-size effects for Lean objects:**
  - The Lean object header is 8 bytes on all platforms (`int m_rc; unsigned m_cs_sz:16; m_other:8; m_tag:8`).
  - Constructor fields are `lean_object * m_objs[]` (pointer-sized).
  - Arrays and strings carry `size_t m_size; size_t m_capacity`.
  - Source: [lean.h](https://github.com/leanprover/lean4/blob/master/src/include/lean/lean.h)

### Inferences
- For Lean's pointer-heavy heap (cons cells, constructors, closures, arrays of boxed objects), wasm32 roughly halves the payload of each pointer field. For example, a 2-field constructor is 16 bytes on wasm32 versus 24 bytes on wasm64. That means a smaller working set and better cache behaviour, on top of the bounds-check advantage.
- With V8's hybrid scheme, the Memory64 penalty in Chrome is probably well below SpiderMonkey's Jan-2025 range. Firefox and the coming Safari implementation have no published numbers. Memory64 remains the slower option in every engine and in every case.
- The 16 GiB browser cap means Memory64 buys at most 4× the wasm32 ceiling. That headroom matters only for whole-elaborator / Mathlib-scale workloads, not for an IR interpreter running app code.

### Gaps
- No public V8 or Chrome benchmark of Memory64 vs wasm32 after `wasm_memory64_trap_handling`, and no date for when that flag became default (it was not found via search).
- No current SpiderMonkey or JSC Memory64 bounds-check strategy write-up beyond Jan 2025.
- No measured code-size delta (wasm32 vs wasm64) for a Lean runtime build. lean-vir publishes no size figures.

---

## 3. What a Lean runtime needs from 64-bit; is wasm32 feasible, and what breaks?

### Takeaway
The Lean C runtime is written to be word-size portable: `lean.h` branches on `sizeof(void*)`. Lean shipped wasm32 (Emscripten) and i386 builds in CI until those jobs were commented out, and lean-vir **already runs Lean's real IR interpreter in `wasm32-wasip1` today**. So wasm32 is demonstrably feasible for an IR interpreter. The costs are:
- smaller unboxed ranges (small Nat < 2³¹, small Int 30-bit, UInt32 heap-boxed);
- `USize` / `System.Platform.numBits` semantics differ from a 64-bit host;
- `.olean` files are word-size specific;
- the full compiler or elaborator on large libraries hits the 2–4 GiB heap ceiling.

### Cited Findings
- **`lean.h`, word-size handling:**
  - `LEAN_CASSERT(sizeof(size_t) == sizeof(void*))`.
  - `LEAN_MAX_SMALL_NAT (SIZE_MAX >> 1)`, which is 2³¹−1 on 32-bit.
  - `LEAN_MAX_SMALL_INT (sizeof(void*) == 8 ? INT_MAX : (INT_MAX >> 1))`.
  - `lean_box_uint32` allocates a heap constructor when `sizeof(void*) == 4` but uses a scalar box on 64-bit.
  - `lean_box_uint64`, `lean_box_usize` and `lean_box_float` always heap-allocate.
  - Source: [lean.h](https://github.com/leanprover/lean4/blob/master/src/include/lean/lean.h)
- **Lean CI (master, read 2026-10-20):**
  - The "Linux 32bit" job is commented out with the note "Started running out of memory building expensive modules, a 2GB heap is just not that much even before fragmentation". Its options include "Use 32bit on stage0 and stage1 to keep oleans compatible" and `-DUSE_GMP=OFF -DMMAP=OFF`.
  - The "Web Assembly" job is also commented out. It used the Emscripten CMake toolchain and "Build a native 32bit binary in stage0 and use it to compile the oleans and the wasm build" (`-DLEAN_INSTALL_SUFFIX=-linux_wasm32`). It ran only "a few selected tests because wasm is slow".
  - Source: [lean4 ci.yml](https://github.com/leanprover/lean4/blob/master/.github/workflows/ci.yml)
- **Lean `src/CMakeLists.txt`** still has an Emscripten branch with `EMSCRIPTEN_SETTINGS "-s ALLOW_MEMORY_GROWTH=1 -fwasm-exceptions -pthread -flto"` and `-D LEAN_EMSCRIPTEN`, and links with `-s MAIN_MODULE=1 ... -s EXPORT_ALL=1` — [lean4 src/CMakeLists.txt](https://github.com/leanprover/lean4/blob/master/src/CMakeLists.txt)
- A Sept-2026 user report says the upstream Emscripten build fails (`lean_uv_event_loop_alive` stub type mismatch) and that the CI Web Assembly job is entirely commented out, so nothing exercises that path — [leanprover/lean4#15181](https://github.com/leanprover/lean4/issues/15181) **[secondary — via search snippet]**. A related report says the Emscripten branch appends `-pthread` unconditionally — [lean4#15186 via cauli/lean4-wasm-in-browser#3](https://github.com/cauli/lean4-wasm-in-browser/issues/3) **[secondary]**
- A 2023 Zulip thread: the wasm32 build relied on a 32-bit stage0 (`-m32`) because "wasm also uses a 32 bit ABI" — [Zulip: wasm build](https://leanprover-community.github.io/archive/stream/270676-lean4/topic/wasm.20build.html) **[secondary, historical]**
- **lean-vir build and runtime (commit 81de859, 2026-10-20):**
  - "runs selected Lean 4 declarations in the browser through Lean's real IR interpreter compiled to `wasm32-wasip1`" (upstream `src/library/ir_interpreter.cpp`) — [lean-vir README](https://github.com/ejgallego/lean-vir)
  - Build script: `target="${WASI_TARGET:-wasm32-wasip1}"`, `-O3`, `--initial-memory=4194304` (4 MiB), `-z stack-size=1048576` (1 MiB), `--no-entry --gc-sections --export-memory`. It uses Lean's non-mimalloc allocator path because the pinned source does not vendor mimalloc. Default wasi-sdk is 33 (`install-wasi-sdk.sh`) — [lean-vir scripts/build-upstream-probe.sh](https://github.com/ejgallego/lean-vir/blob/main/scripts/build-upstream-probe.sh)
  - ABI: "The current build is explicitly guarded to wasm32… Enabling wasm64 must separately qualify the Lean/JavaScript pointer ABI and relax the target guard" — [lean-vir docs/reference/OBJECT_ABI.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/OBJECT_ABI.md)
  - `USize` inputs "must be in `0..2^32 - 1` for the supported wasm32 runtime". Top-level `Float`, `Float32`, `UInt64` need compiler-generated `_boxed` companions at the wasm32 boundary — [lean-vir docs/guides/JS_API.md](https://github.com/ejgallego/lean-vir/blob/main/docs/guides/JS_API.md), [GENERATE_PACKAGE.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/GENERATE_PACKAGE.md)
  - The fixtures doc notes that "machine-word width can differ between a 64-bit host and Wasm32", so expected results may legitimately differ — [lean-vir docs/development/EXAMPLES_AND_FIXTURES.md](https://github.com/ejgallego/lean-vir/blob/main/docs/development/EXAMPLES_AND_FIXTURES.md)
  - Native C++ exceptions are unsupported: they trap, and the SDK retires the instance. Lazy-init `*_once_cold` providers are replaced with single-threaded versions — [lean-vir wasm/upstream_shim/README.md](https://github.com/ejgallego/lean-vir/blob/main/wasm/upstream_shim/README.md), [UPSTREAM_BOUNDARY.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/UPSTREAM_BOUNDARY.md)
- **Lean's RC design:** in-place (destructive) updates happen when a value's reference count is 1, which is central to array performance — ["Counting Immutable Beans", Ullrich & de Moura, IFL 2019](https://arxiv.org/abs/1908.05647)

### Inferences
- **What breaks or changes on wasm32:**
  - Code that relies on `USize` being 64-bit, such as hash mixing via `USize` or `USize.size` constants, behaves differently. Compile-time evaluation on a 64-bit host can bake in 64-bit values, so this is a real semantic hazard.
  - Numbers in [2³¹, 2⁶³) become big Nats, which costs allocations. Without GMP this uses Lean's own mpn path (`USE_GMP=OFF` was the 32-bit CI config).
  - `UInt32` stored in polymorphic positions becomes a heap allocation.
  - `.olean` files from a 64-bit toolchain cannot be loaded by a wasm32 Lean frontend. This matters only if the browser runtime must import `.olean`s (full elaborator). lean-vir sidesteps it with its own `.irpkg` format.
- **What works:** lean-vir's existence shows the C runtime, the IR interpreter and generated stage0 C (`Init/Prelude.c`, `Lean/Expr.c`) compile and run on wasm32 with wasi-sdk.
- A full Lean frontend in the browser (elaborating with Mathlib) would likely exceed 4 GiB. Upstream's own 32-bit job died at a 2 GB heap. That is the one scenario where Memory64 is justified.
- Lean's `sizeof(void*)` branches mean a single source tree builds for both widths, so keeping a wasm64 build as a secondary configuration is cheap at the C level. The JS boundary (BigInt vs Number for `USize`/pointers) is where the work is.

### Gaps
- No Lean core team statement in 2025–2026 on the future of 32-bit or Emscripten support.
- No measurement of the wasm32 boxing / big-Nat overhead on real Lean workloads.
- Whether Lean's compiler constant-folds `USize.size` / `System.Platform.numBits` at compile time in current versions was not verified.

---

## 4. Toolchains: Emscripten vs wasi-sdk/WASI vs plain clang

### Takeaway
- **Emscripten** (6.0.13, Oct 19, 2026; releases every 1–3 weeks) has the most mature Memory64 support. It is the only toolchain with first-class wasm64 and browser glue: FS, pthreads, JSPI, embind and ESM output. It still **defaults to legacy EH**, and it deprecated its "wasm64-lowered-to-wasm32" mode (`MEMORY64=2`) on Oct 19, 2026.
- **wasi-sdk** (latest tag wasi-sdk-34; lean-vir pins 33) is **wasm32-only** and has no plans for wasm64-wasip1. Any wasm64 would only arrive as `wasm64-wasip2`, after a component-model issue is resolved. It gives a small, JS-free core module and needs a hand-written loader, which is what lean-vir does.
- **Plain clang** (`--target=wasm32-unknown-unknown`) gives the smallest output but no libc.
- LLVM main still defaults `-wasm-use-legacy-eh=true` for both toolchains.

### Cited Findings
- **Emscripten releases:** 6.0.13 (10/19/26), 6.0.12 (10/08/26), … 6.0.5 (07/29/26, the LeanUI version), 6.0.0 (06/04/26), 5.0.0 (01/24/26), 4.0.0 (01/14/25) — [Emscripten ChangeLog](https://github.com/emscripten-core/emscripten/blob/main/ChangeLog.md)
- **Emscripten Memory64:**
  - Non-experimental since 3.1.72 (Nov 2024).
  - 6.0.0 makes `-m64` an alias for `-sMEMORY64` / `--target=wasm64`.
  - 6.0.1 (Jun 22, 2026): "The `-sUSE_PTHREADS` and `-sMEMORY64` flags have been deprecated in favor of the more standard `-pthread` and `-m64` (or `--target=wasm64`) flags."
  - 6.0.11: OpenMP gains Wasm64 support.
  - 6.0.13 (Oct 19, 2026): "`MEMORY64=2` was marked as deprecated."
  - Source: [Emscripten ChangeLog](https://github.com/emscripten-core/emscripten/blob/main/ChangeLog.md)
  - settings.js: `MEMORY64` "0 means the default wasm32, 1 is the full end-to-end wasm64 mode, and 2 is wasm64 for clang/lld but lowered to wasm32 in Binaryen (such that it can run on wasm32 engines, while internally using i64 pointers)… [deprecated]" — [Emscripten settings.js](https://github.com/emscripten-core/emscripten/blob/main/src/settings.js)
- **Emscripten EH:**
  - `var WASM_LEGACY_EXCEPTIONS = true;` is still the default on main — [settings.js](https://github.com/emscripten-core/emscripten/blob/main/src/settings.js)
  - 4.0.0 added `-sWASM_LEGACY_EXCEPTIONS`, defaulting to true "given that major web browsers do not support the new proposal by default yet".
  - 4.0.2: standard EH (`-sWASM_LEGACY_EXCEPTIONS=0`) uses the LLVM backend rather than Binaryen's translator.
  - 6.0.7: `-fwasm-exceptions` links the Wasm EH runtime independently of C++.
  - `SUPPORT_LONGJMP` defaults to `wasm` when `-fwasm-exceptions` is used.
  - Source: [ChangeLog](https://github.com/emscripten-core/emscripten/blob/main/ChangeLog.md), [settings.js](https://github.com/emscripten-core/emscripten/blob/main/src/settings.js)
- **Emscripten platform floor and other changes:**
  - 6.0.0 raised the minimum engines to Chrome 85, Firefox 79 and Safari 14.1, and removed babel transpilation.
  - 6.0.7 raised the Safari minimum to 15.0.
  - 6.0.8: `JSPI` "no longer considered experimental"; `WASM_BIGINT` deprecated (always on).
  - 6.0.10: `WASM=0` / `WASM=2` (wasm2js) deprecated.
  - 6.0.2/6.0.3: `GROWABLE_ARRAYBUFFERS` default toggled to 1, then reverted to 0 over Web API compatibility issues.
  - Libraries are tracked to LLVM 22.1.8 (libc++) and 23.1.3 (compiler-rt), with musl 1.2.6.
  - Source: [ChangeLog](https://github.com/emscripten-core/emscripten/blob/main/ChangeLog.md)
- **wasi-sdk:**
  - Default target `wasm32-wasip1`. Targets: `wasm32-wasip1`, `wasm32-wasip2` (component model), `wasm32-wasip3` (async component model), `wasm32-wasip1-threads` (experimental threads).
  - "64-bit linear memories (a "wasm64" target) are not supported at this time. Supporting this will require resolving WebAssembly/component-model#22 first at which point it will be possible to add a `wasm64-wasip2` target. There are no plans to add support for `wasm64-wasi{,-threads,p1,p1-threads}` at this time."
  - Source: [wasi-sdk README](https://github.com/WebAssembly/wasi-sdk/blob/main/README.md)
  - Latest git tag: `wasi-sdk-34` — [wasi-sdk repo tags](https://github.com/WebAssembly/wasi-sdk)
- **wasi-libc** builds `wasm32-wasip1`, `wasm32-wasip2`, `wasm32-wasip1-threads` and `wasm32-wasip3`, with no wasm64 triple upstream. wasm64 sysroots exist only in forks — [wasi-libc README](https://github.com/WebAssembly/wasi-libc), [trcrsired/wasi-libc fork](https://github.com/trcrsired/wasi-libc) **[secondary for the fork]**
- **wasi-sdk C++ exceptions:**
  - "From wasi-sdk-33 and onwards" there is a dual sysroot (exceptions on and off). Exceptions are disabled by default.
  - Enabling them needs `-fwasm-exceptions -mllvm -wasm-use-legacy-eh=false` plus `-lunwind`. "Precompiled libraries for wasi-sdk are all built with the standard exception-handling proposal."
  - Requires LLVM 22+. Limitations: no shared libraries, and an LTO issue.
  - Source: [wasi-sdk CppExceptions.md](https://github.com/WebAssembly/wasi-sdk/blob/main/CppExceptions.md)
- **wasi-sdk setjmp/longjmp:** `-mllvm -wasm-enable-sjlj -lsetjmp -mllvm -wasm-use-legacy-eh=false`. Built on Wasm EH; Clang 20+ (wasi-sdk-26+) can emit either EH flavour — [wasi-sdk SetjmpLongjmp.md](https://github.com/WebAssembly/wasi-sdk/blob/main/SetjmpLongjmp.md)
- **LLVM:**
  - Main: `WasmUseLegacyEH` defaults to true: "Currently set to true by default because not all major web browsers turn on the new standard proposal by default, but will later change to false" — [LLVM WebAssemblyTargetMachine.cpp](https://github.com/llvm/llvm-project/blob/main/llvm/lib/Target/WebAssembly/WebAssemblyTargetMachine.cpp)
  - LLVM 20: the "generic" CPU enables bulk-memory and nontrapping-fptoint; a new `lime1` CPU was added; standardized EH support was added, with legacy still the default — [LLVM 20 release notes](https://github.com/llvm/llvm-project/blob/release/20.x/llvm/docs/ReleaseNotes.md)
  - The `bleeding-edge` CPU adds exception-handling, gc, multimemory, tail-call and wide-arithmetic — [clang Targets/WebAssembly.cpp](https://github.com/llvm/llvm-project/blob/main/clang/lib/Basic/Targets/WebAssembly.cpp)
  - LLVM 22 renamed `wasm32-wasi` to `wasm32-wasip1` — [LLVM 22 release notes](https://github.com/llvm/llvm-project/blob/release/22.x/llvm/docs/ReleaseNotes.md)
  - Latest tag: llvmorg-23.1.4 — [llvm-project tags](https://github.com/llvm/llvm-project)
- **jco / browser WASI P2:**
  - `jco transpile` turns a component into core modules plus JS glue.
  - The `@bytecodealliance/preview2-shim` browser support is described as "experimental, and not currently suitable for production applications".
  - Source: [Bytecode Alliance: five ways of looking at jco](https://bytecodealliance.org/articles/five-ways-of-looking-at-jco-part-1), [preview2-shim package](https://www.socket.dev/npm/package/@bytecodealliance/preview2-shim)
  - **[secondary; the 2026 status was not re-verified]**
  - features.json still lists the component model as phase 1 — [features.json](https://github.com/WebAssembly/website/blob/main/features.json)
- **lean-vir's browser integration** is a hand-written JS factory. It supplies stubbed `wasi_snapshot_preview1` imports (`args_get`, `clock_time_get`, … → `wasiUnavailable`; `fd_*` → `wasiBadDescriptor`) plus its own `vir_*` host imports, and calls the exports directly. No Emscripten glue — [lean-vir web/src/runtime/factory-core.js](https://github.com/ejgallego/lean-vir/blob/main/web/src/runtime/factory-core.js)
- Emscripten's `STANDALONE_WASM` emits WASI-style imports so the wasm can run in Wasmtime or Wasmer without the JS — [settings.js](https://github.com/emscripten-core/emscripten/blob/main/src/settings.js)

### Inferences
- **Smallest and most portable for a small interpreter:** wasi-sdk `wasm32-wasip1` core module plus a hand-written loader that stubs the few WASI calls. You get one `.wasm` that runs in every browser, in Node/Deno/Bun, and in Wasmtime/WAMR. You avoid Emscripten's JS runtime, and you control every import and export.
- Plain `clang --target=wasm32-unknown-unknown` is smaller still but loses libc and libc++. Lean's runtime is C++ (`std::` containers, mutexes, etc.), so practically you need wasi-libc / libc++ anyway. wasi-sdk is effectively "plain clang plus a maintained sysroot".
- **Emscripten is the right choice if** you need wasm64 today, pthreads with a proxying model, its virtual FS, libuv emulation (Lean's upstream Emscripten path uses `-pthread`), or JSPI/Asyncify integration with JS library functions. Its output is tightly coupled to its JS glue, and that glue breaks across versions: 6.x removed or deprecated many settings within months.
- **Durability:** WASI preview 1 is effectively frozen, which makes it stable for a core module. P2/P3 and components target server runtimes; browser support goes through jco transpilation and remains experimental. For a browser-first runtime, treat WASI as "a libc ABI convention", not as a platform to depend on.
- **wasm64 path dependency:** going wasm64 means Emscripten, or plain clang `--target=wasm64-unknown-unknown` with a custom libc (support for that triple in LLVM is general knowledge, not re-verified here). wasi-sdk will not get there before wasip2 components gain 64-bit support.

### Gaps
- wasi-sdk-34 release date and notes were not fetched (the API was blocked; only the tag list was seen).
- No head-to-head size comparison (Emscripten vs wasi-sdk) for the same Lean runtime build.
- No 2026 primary source on jco browser maturity.

---

## 5. Other Wasm features relevant to a Lean runtime, and their durability

### Takeaway
- **Universal today** (Chrome, Firefox and stable Safari): standard exnref EH, legacy EH, tail calls, WasmGC, typed function refs, threads/atomics, SIMD, and (since Safari 27, Sept 2026) JSPI.
- **Not yet in stable Safari:** Memory64, multi-memory and relaxed SIMD.
- **Toolchains lag:** both LLVM and Emscripten still emit legacy EH by default, even though legacy EH is formally "inactive" and exnref is the Wasm 3.0 standard.
- **WasmGC is not a good fit** for a Lean runtime that keeps Lean's RC-based in-place updates.

### Cited Findings
- **Exception handling (features.json):**
  - exnref ("Exception Handling with exnref", phase 5): Chrome 137, Firefox 131, Safari 18.4, Node 24.15, Deno 2.3.2, Wasmtime 47, Wasmer 6.0.
  - Legacy EH ("inactive"): Chrome 95, Firefox 100, Safari 15.2, Node 17.0.
  - Source: [features.json](https://github.com/WebAssembly/website/blob/main/features.json)
  - Legacy-EH deprecation is still under discussion. One participant worries browsers may never fully remove it — [WebAssembly/exception-handling#280](https://github.com/WebAssembly/exception-handling/issues/280) **[secondary — via search snippet]**
- **Tail calls:** Chrome 112, Firefox 121, Safari 18.2, Node 20, Wasmtime 22 — [features.json](https://github.com/WebAssembly/website/blob/main/features.json)
- **Multi-memory:** Chrome 120, Firefox 125, Node 22, Wasmtime 15; no stable Safari entry (STP 252 only) — [features.json](https://github.com/WebAssembly/website/blob/main/features.json), [STP 252](https://webkit.org/blog/18304/release-notes-for-safari-technology-preview-252/)
- **WasmGC:** Chrome 119, Firefox 120, Safari 18.2, Node 22, Wasmtime 47. Typed function references: Chrome 119, Firefox 120, Safari 18 — [features.json](https://github.com/WebAssembly/website/blob/main/features.json)
- **JSPI:**
  - Chrome 137, Firefox 153, Safari 27, Node 26.0, Deno 2.3.2 — [features.json](https://github.com/WebAssembly/website/blob/main/features.json)
  - Safari 27.0 adds JSPI — [WebKit Features for Safari 27.0](https://webkit.org/blog/18325/webkit-features-for-safari-27-0/)
  - Interop 2026 focus area — [Mozilla Hacks](https://hacks.mozilla.org/2026/02/launching-interop-2026/)
  - Emscripten JSPI non-experimental since 6.0.8 — [ChangeLog](https://github.com/emscripten-core/emscripten/blob/main/ChangeLog.md)
- **Threads:** Chrome 74, Firefox 79, Safari 14.1. Shared-everything threads is only phase 1 — [features.json](https://github.com/WebAssembly/website/blob/main/features.json)
  - Sharing a `WebAssembly.Memory` between workers requires a secure context and cross-origin isolation (the COOP/COEP headers), the same as for `SharedArrayBuffer`. Atomic instructions themselves are always allowed — [MDN SharedArrayBuffer](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/SharedArrayBuffer)
- **Other feature status:**
  - JS String Builtins: Chrome 130, Firefox 134, Safari 26.2.
  - Relaxed SIMD: Safari behind a JSC flag.
  - Stack switching (phase 3): Chrome flag only.
  - Custom page sizes (phase 3) and memory control (phase 1) are not shipped in browsers.
  - Wide arithmetic (phase 4) is behind flags.
  - Source: [features.json](https://github.com/WebAssembly/website/blob/main/features.json)
- Wasm 3.0 explicitly includes memory64, multi-memory, GC, typed refs, tail calls, exception handling and relaxed SIMD — [Wasm 3.0 announcement](https://webassembly.org/news/2025-09-17-wasm-3.0/)
- Lean's performance model depends on exact reference counts to perform in-place updates when RC = 1 — ["Counting Immutable Beans"](https://arxiv.org/abs/1908.05647)
- Lean upstream's Emscripten config uses `-fwasm-exceptions -pthread` — [lean4 src/CMakeLists.txt](https://github.com/leanprover/lean4/blob/master/src/CMakeLists.txt)
- lean-vir builds without C++ exceptions or threads: C++ throws trap, and lazy-init is single-threaded — [lean-vir upstream_shim README](https://github.com/ejgallego/lean-vir/blob/main/wasm/upstream_shim/README.md)

### Inferences
- **Exceptions:** since Safari 18.4, exnref works in all three engines. A new build should emit standard EH explicitly: `-sWASM_LEGACY_EXCEPTIONS=0` in Emscripten, or `-mllvm -wasm-use-legacy-eh=false` in wasi-sdk/clang, where wasi-sdk's prebuilt libs already use standard EH. That is the durable choice. Legacy EH works everywhere today but is the deprecated encoding, and LeanUI currently uses it.
  - Better still, avoid C++ exceptions in the hot path, as lean-vir does. Lean's IR has no exceptions (errors are `EStateM` values). Only runtime panics and internal C++ errors throw.
- **Tail calls** are universal (Safari 18.2+). They are safe to use for a threaded or `musttail` interpreter dispatch loop, and for interpreting Lean IR tail calls without stack growth.
- **JSPI** is the durable way to let synchronous Lean `IO` code await JS promises (fetch, timers, UI events) without Asyncify's code-size and speed tax. As of Sept 2026 it works in all three engines and is an Interop 2026 area. Older Safari (< 27) and older iOS devices still lack it, so a fallback (callback-style host API) is needed for a few years.
- **Threads:** avoid as a baseline. They force COOP/COEP on the embedding page, which conflicts with embedding in third-party sites, docs and iframes. Lean's runtime works single-threaded (Task/`IO.asTask` would need emulation).
- **WasmGC:** a WasmGC Lean backend would be a new compiler backend, not a port of the C runtime. It would lose RC=1 in-place mutation (no refcount observation in WasmGC), changing Array/String performance asymptotically unless reimplemented (for example, linear-memory arrays). Not durable value for a lean-vir-style IR interpreter. It might suit a future "Lean-to-Wasm compiler" producing small binaries that share the JS GC.
- **Multi-memory:** not usable cross-browser until Safari ships it (STP 252 only). It is not needed for a single-runtime design.

### Gaps
- No V8 or Mozilla announcement of a removal date for legacy EH.
- No published evaluation of Lean or RC-based functional runtimes on WasmGC.
- Firefox 153 (JSPI) release date not verified.

---

## 6. Overall: the most forward-facing and durable combination for a browser-first Lean runtime (2026–2028)

### Takeaway
For a browser-first Lean runtime or IR interpreter (lean-vir style), the most durable baseline is:
- **wasm32**, built with **wasi-sdk/clang (`wasm32-wasip1` core module)**;
- a **hand-written ES-module loader** that stubs WASI;
- **standard (exnref) EH or no C++ EH**, **tail calls**, and **JSPI** for async host calls, with a fallback;
- **no threads**;
- 64-bit-clean C/JS code, so that an **optional Emscripten wasm64 build** can be added later for >4 GiB workloads once Safari ships Memory64.

The current LeanUI configuration (Emscripten 6.0.5, Memory64, legacy EH, growth to 4 GiB) has two non-durable choices: Memory64 (no stable Safari or iOS) and legacy EH. Its 4 GiB growth cap means Memory64 currently buys nothing that wasm32 cannot address.

### Cited Findings
- Vendor guidance converges on "Memory64 only if you need >4 GB" — [SpiderMonkey](https://spidermonkey.dev/blog/2025/01/15/is-memory64-actually-worth-using.html), [Unity](https://docs.unity3d.com/Manual/wasm-64bit-support.html)
- Safari stable lacks Memory64; it is STP-only since Aug/Sep 2026 — [STP 251](https://webkit.org/blog/18194/release-notes-for-safari-technology-preview-251/), [caniuse](https://caniuse.com/wf-wasm-memory64)
- Emscripten deprecated `MEMORY64=2`, the mode that ran wasm64-compiled code on wasm32 engines, on Oct 19, 2026 — [Emscripten ChangeLog](https://github.com/emscripten-core/emscripten/blob/main/ChangeLog.md)
- wasi-sdk has no wasm64 and no near-term plan — [wasi-sdk README](https://github.com/WebAssembly/wasi-sdk/blob/main/README.md)
- lean-vir already ships wasm32-wasip1 with a custom loader, and its ABI doc says wasm64 would need separate pointer-ABI qualification — [lean-vir README](https://github.com/ejgallego/lean-vir), [OBJECT_ABI.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/OBJECT_ABI.md)
- Upstream Lean's own 32-bit job was dropped because a 2 GB heap was too small for building expensive modules — [lean4 ci.yml](https://github.com/leanprover/lean4/blob/master/.github/workflows/ci.yml)
- Legacy EH is "inactive" while exnref is phase 5 and supported by all three browsers — [features.json](https://github.com/WebAssembly/website/blob/main/features.json)

### Inferences

Trade-off matrix (judgement, built from the findings above):

| Choice | Reach (Oct 2026) | Perf / size | Durability risk |
|---|---|---|---|
| wasm32 + wasi-sdk core module + own loader (lean-vir today) | All browsers incl. iOS/Safari, Node/Deno/Bun, Wasmtime/WAMR | Best: free bounds checks, 4-byte pointers, no JS glue | Low. WASI p1 is frozen but only lightly used; you maintain the loader. 4 GiB ceiling. |
| wasm32 + Emscripten | All browsers | Good, plus Emscripten JS glue | Medium: frequent setting deprecations in 6.x; legacy EH default must be overridden. |
| wasm64 + Emscripten (LeanUI today) | Chrome/Edge/Firefox desktop and Android; **not Safari/iOS** | Slower memory access (10–100%+ in SpiderMonkey's 2025 measurements; V8 now mitigated); larger pointers | Medium-high until Safari stable ships; `MEMORY64=2` fallback deprecated. |
| wasm64 + wasi-sdk | Not possible (no target) | n/a | n/a until `wasm64-wasip2` exists. |
| WasmGC backend | All browsers (Safari 18.2+) | Smaller binaries, JS-GC interop | New compiler backend; loses RC in-place updates. Research-grade for Lean. |

- **Recommended stance for 2026–2028:**
  1. Make wasm32 the primary artifact for every browser, including Safari/iOS. That removes the need for LeanUI's server-rendering fallback.
  2. Keep runtime and loader code word-size generic, with `uintptr_t` handles and a BigInt/Number abstraction for `USize`.
  3. Emit standard EH (or none) and tail calls. Use JSPI behind feature detection.
  4. Revisit wasm64 only for workloads that genuinely exceed about 3–4 GiB (full elaborator with large libraries). Do that once stable Safari and iOS ship Memory64; plausibly 2027, which is speculative.
- If LeanUI stays on Emscripten, low-cost durability fixes are:
  - switch to `-sWASM_LEGACY_EXCEPTIONS=0`;
  - use `-m64` instead of the deprecated `-sMEMORY64`, or drop to wasm32;
  - do not adopt `MEMORY64=2` as a Safari fallback.

### Gaps
- No public numbers compare a Lean runtime's speed or size across wasm32 and wasm64 or across toolchains. That would be the decisive measurement: lean-vir's benchmark harness (VIR vs FIR/Emscripten) could be extended to produce it.
- No timeline for stable Safari Memory64 or for legacy EH removal.
