# lean-vir (Lean VIR): what it is, how it works, current status (as of 2026-10-20)

Method note: The main source is a full `git clone` of https://github.com/ejgallego/lean-vir at HEAD `81de859` (2026-10-20). I read the README, docs, build scripts, CI and git history. I could not use the GitHub REST API from this sandbox, so issue, PR and release listings come from the GitHub web UI via WebFetch. I downloaded the published runtime artifact and the hosted demo packages myself and measured their sizes on 2026-10-20 (raw, gzip -9, brotli q11 with Node zlib). The wasm target features and imports also come from my own inspection. Anything labeled "researcher measurement" is that kind of first-hand number. Secondary sources (awesome list, DeepWiki, lean-math-in-the-browser, Zulip mentions) are marked as such.

## 1. What is lean-vir, which IR does it interpret, how does a Lean program become runnable, and is there AOT/JIT?

### Takeaway
lean-vir ("Lean VIR") does not compile Lean to wasm. It runs Lean's real, unmodified C++ IR interpreter (`src/library/ir_interpreter.cpp`) compiled to `wasm32-wasip1`. That interpreter executes `Lean.IR.Decl` (λRC IR) declarations, which a Lean-side tool pulls out of compiled `.olean` modules. They ship as a custom binary `.irpkg` format, and the browser loads and runs them. There is no JIT and no AOT compilation of user code. The only native code is the fixed runtime: Lean's runtime, selected stage0 C for Init helpers, and generated boxed wrappers for a closed catalog of `@[extern]`s.

### Cited Findings
- README, verbatim: "Lean VIR runs selected Lean 4 declarations in the browser through Lean's real IR interpreter compiled to `wasm32-wasip1`. It packages compiled module IR; it is not a general Lean-to-Wasm compiler." — [README](https://github.com/ejgallego/lean-vir/blob/main/README.md)
- The GitHub "About" text is still "Lean 4 IR to wasm32-wasi proof of concept". The hosted landing page calls it "a proof of concept for selected declarations, not a general browser target." — [GitHub repo page](https://github.com/ejgallego/lean-vir); [hosted demo site](https://ejgallego.github.io/lean-vir/)
- "VIR compiles the unmodified `third_party/lean4-src/src/library/ir_interpreter.cpp` against the pinned Lean headers. The local shim supplies WASI policy and stubs for unsupported operations." Shim editing rule: "Keep the vanilla Lean interpreter source unmodified." — [UPSTREAM_BOUNDARY.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/UPSTREAM_BOUNDARY.md); [wasm/upstream_shim/README.md](https://github.com/ejgallego/lean-vir/blob/main/wasm/upstream_shim/README.md)
- The interpreter runs "over package-owned `Lean.IR.Decl` objects". `lean_ir_find_env_decl` is redirected to a package-backed declaration provider that returns `Option Decl` "in Lean's actual constructor layout". `IRType.struct` and `IRType.union` "remain explicit package-generation errors". "The browser reconstructs selected declarations from packages; it does not load raw Lean module artifacts or construct a normal compiler `Environment`." — [UPSTREAM_BOUNDARY.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/UPSTREAM_BOUNDARY.md)
- Producer side: a Lean executable, `vir_irpkg` (`tools/GeneratePackage.lean`), loads compiled modules through "a cached adapter of Lean's importer and ordinary `finalizeImport`". It reads "resolved root and transitive artifacts, including private data and full IR" that Lake supplies. Then it collects the transitive IR closure of the selected roots and emits `.irpkg`. "Non-module developments and source-file package loading are unsupported." — [GENERATE_PACKAGE.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/GENERATE_PACKAGE.md)
- The browser loads "descriptor-ordered sets of format-11 `.irpkg` members… It does not load `.olean` or Lean's raw `.ir` format in the browser." A multi-module build produces a `lean-vir-ir-package-set` v2 JSON descriptor that lists dependency `.irpkg` members, dependency-first, with the root last. Each member has its own SHA-256. — [JS_API.md](https://github.com/ejgallego/lean-vir/blob/main/docs/guides/JS_API.md); [IRPKG_FORMAT.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/IRPKG_FORMAT.md)
- Application workflow:
  - Mark functions with `@[vir_export]` (and `@[vir_startup]` for startup hooks).
  - Add a resource library that uses `include_vir_assets`, plus `needs := #[`+Mod:virResourcePack]` in `lakefile.lean`.
  - Lake prepares the program and "downloads the matching prebuilt interpreter". JS then calls `program.call("QuickstartApp.Program.greet", "world")`.
  - "No producer paths, packaging scripts or Wasm build are needed."
  — [README](https://github.com/ejgallego/lean-vir/blob/main/README.md); [quickstart lakefile](https://github.com/ejgallego/lean-vir/blob/main/examples/tutorials/quickstart/lakefile.lean)
- The interpreter is built with `-DLEAN_DEFAULT_INTERPRETER_PREFER_NATIVE=false`. Native lookup is "closed": `dlsym` accepts only a generated native registry plus package host-import trampolines. — [build-upstream-probe.sh](https://github.com/ejgallego/lean-vir/blob/main/scripts/build-upstream-probe.sh); [UPSTREAM_BOUNDARY.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/UPSTREAM_BOUNDARY.md)
- Some Lean-defined support code is compiled ahead of time into the runtime as native code: "pinned stage0 C modules" listed in `native-support-sources.txt`, plus compiler-generated raw bodies such as `ByteArray.extract`. This is a fixed part of the runtime, not user code. — [wasm/upstream_shim/README.md](https://github.com/ejgallego/lean-vir/blob/main/wasm/upstream_shim/README.md)
- History: the first commit (2026-05-18, authored by "Codex") took a different approach, a hand-written `runner.c`/`runner.wat` bytecode runner fed by a Python script scraping `trace.compiler.ir.result`. The same day it was replaced by "Run fib through upstream interpreter" and "Remove bootstrap wasm runners". — [commit 1494803](https://github.com/ejgallego/lean-vir/commit/1494803106aa21a3cfb50357eacbb269478ae479); [commit 3d8d55a](https://github.com/ejgallego/lean-vir/commit/3d8d55ab3713a8f7c2b0eefc869d6f1fc69eceda); [commit c5b2f50](https://github.com/ejgallego/lean-vir/commit/c5b2f50f96ffbf0203189f91d750983166c0b5e5)
- Since Lean v4.22.0 (2025-08-14), "The old compiler has been replaced by the new compiler (#8577)". — [Lean v4.22.0 release notes](https://lean-lang.org/doc/reference/stable/releases/v4.22.0/)
- Secondary: DeepWiki describes three parts: the upstream interpreter built for WASM, a binary `.irpkg` format holding serialized IR declarations, and a JS runtime (`vir-runtime.js`). The search tool says the page was indexed about 150 days before October 2026, so it may be stale. — [DeepWiki](https://deepwiki.com/ejgallego/lean-vir)

### Inferences
- On "which IR": VIR consumes the λRC `Lean.IR.Decl` IR that is stored in `.olean` files (it uses `Lean.IR.findEnvDecl`/`declMapExt`-style lookup and `IRType`). With Lean ≥4.22 that IR is produced by the new LCNF-based compiler, which lowers to `Lean.IR` (this lowering step comes from my knowledge of the Lean source, not from a fetched document). So VIR interprets the post-LCNF λRC IR, not LCNF itself, and it inherits whatever IR the toolchain emits.
- For LeanUI, VIR replaces the per-app "Lean → C → emcc → wasm64" step. Each app becomes a fixed, shared interpreter wasm plus a per-app `.irpkg` (data, not code). That removes the Emscripten/C compile from app builds, at the cost of interpretation speed (see §7).

### Gaps
- I did not read `tools/GeneratePackage.lean` line by line. The details of closure extraction (for example how `@[implemented_by]` and `@[export]` are handled) come from the docs only.
- No document states the IR's exact provenance (`toIR` from LCNF). That is my inference from Lean's architecture.

## 2. What is in the runtime, and what does "under 200 KiB" measure and include?

### Takeaway
The runtime is Lean's own C/C++ runtime and interpreter, compiled for WASI and not reimplemented. It includes Lean's portable `mpn`/`mpz` bignums (no GMP), `utf8.cpp` and `object.cpp`, without mimalloc, plus a VIR shim. The "under 200 KiB" figure appears only in an awesome-list entry, and it matches the gzip-compressed wasm alone. The current release `runtime.wasm` is 793,324 B raw (774.7 KiB), about 186–188 KiB gzip and about 145 KiB brotli. That excludes the 129.5 KB JS runtime and every program's `.irpkg`, which carries the IR closure of the Init/Std/Lean code the app uses and can be MBs.

### Cited Findings
- The build compiles these upstream runtime sources:
  - `alloc.cpp`, `apply.cpp`, `exception.cpp`, `hash.cpp`, `mpn.cpp`, `mpz.cpp`, `object.cpp`, `object_ref.cpp`, `platform.cpp`, `utf8.cpp`
  - support sources `util/name.cpp`, `util/kvmap.cpp`, `kernel/level.cpp`, `kernel/expr.cpp`, `kernel/expr_eq_fn.cpp`
  - stage0 `Lean/Data/KVMap.c`, `Lean/Level.c`, `Lean/Expr.c`
  - a manifest-selected set of stage0 `Init` C files
  — [build-upstream-probe.sh](https://github.com/ejgallego/lean-vir/blob/main/scripts/build-upstream-probe.sh)
- "Its generated `lean/config.h` leaves `LEAN_MIMALLOC` disabled because the pinned source checkout lacks vendored mimalloc sources for a WASI rebuild; Lean's ordinary allocator is used." — [UPSTREAM_BOUNDARY.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/UPSTREAM_BOUNDARY.md)
- Bignums: no GMP. lean-math-in-the-browser reports that in the browser, F(10⁶) multiplication is "~230× slower" because "lean-vir uses a portable big-number fallback instead of GMP". This is secondary and pinned to a Sept-2026 commit on Lean 4.34. — [lean-math-in-the-browser](https://github.com/ejgallego/lean-math-in-the-browser)
- Size claim origin: the awesome-lean-programming entry reads "Runs Lean in the browser via Lean's IR interpreter compiled to WebAssembly, with a runtime under 200 KiB (early, Lean FRO)." I found no "200 KiB" claim in the repo's current docs or README history. — [nozaq/awesome-lean-programming](https://github.com/nozaq/awesome-lean-programming); also mirrored at [leangineer.com/awesome](https://leangineer.com/awesome/)
- Repo's own size measurements (2026-08-08), for the stripped release Wasm: control 650,910 B raw / 148,103 B gzip, rising to 665,872 B raw / 152,245 B gzip after string-frontier additions. The re-measurement after catalog consolidation was "657,138 bytes raw, 150,091 bytes with deterministic gzip". — [commit d2dbb50 (#116)](https://github.com/ejgallego/lean-vir/commit/d2dbb50d7c2736df840820ae2cb0ca7b8b45b4da)
- Researcher measurement (2026-10-20), current published runtime bundle `resource-ab3614c1…` (Lean 4.35.0, compatibility `virVersion` 7, referenced by `vir-resources/compatibility.json`). The `.virres` pack is 1,026,112 B. Its contents:
  - `runtime.wasm`: 793,324 B raw; 190,685 B with Python gzip -9 (192,589 B with Node zlib level 9); 148,322 B brotli q11
  - `runtime.js`: 129,504 B raw; about 36.8 KB gzip; 32,327 B brotli
  - license files: about 102 KB
  The hosted demo serves a byte-identical-size `vir-upstream.wasm` (793,324 B). — [release asset](https://github.com/ejgallego/lean-vir/releases/download/resource-ab3614c15934e54b9fa85b0891e6da56d239d09d04c7a2f3177980b2cec6a1d7/ab3614c15934e54b9fa85b0891e6da56d239d09d04c7a2f3177980b2cec6a1d7.virres); [compatibility.json](https://github.com/ejgallego/lean-vir/blob/main/vir-resources/compatibility.json); [runtime.json](https://github.com/ejgallego/lean-vir/blob/main/vir-resources/runtime.json); [hosted wasm](https://ejgallego.github.io/lean-vir/vir-upstream.wasm)
- Release notes list runtime pack sizes over October 2026:
  - Lean 4.34.0: 1,116,900 and 1,120,065 B
  - Lean 4.35.0-rc4: 1,114,116 B, then 1,016,086 B
  - Lean 4.36.0-rc1: 1,011,875 B
  — [GitHub releases page](https://github.com/ejgallego/lean-vir/releases)
- Researcher measurement: `.irpkg` program sizes served by the hosted demo (all report `leanprover/lean4:4.35.0`):

  | Package | Raw | gzip -9 |
  | --- | ---: | ---: |
  | `local-fib` | 1,577 B | 724 B |
  | `local-mergesort` | 7,505 B | 1,887 B |
  | `local-quickstart` | 10,839 B | 2,093 B |
  | `pretty-printer` | 98,381 B | 11,533 B |
  | `fixtures-boundary` | 246,927 B | 27,400 B |
  | `fixtures-basic` | 371,083 B | 38,499 B |
  | `native-infoview` | 803,516 B | 101,405 B |
  | `fixtures-lean` | 937,232 B | 122,568 B |
  | `demo-host` (React/Tamagotchi demos) | 1,458,652 B | 176,838 B |

  — [hosted demo site](https://ejgallego.github.io/lean-vir/) (files such as https://ejgallego.github.io/lean-vir/demo-host.irpkg)
- The lean-zip probe (2026-08-11) gives another example: the full `deflateRaw` closure needed 667 IR declarations and 136 registered native externs. It came to "1,176,305 bytes across [36] members" plus a 4,279-byte descriptor. — [commit 9f69f13 (#125)](https://github.com/ejgallego/lean-vir/commit/9f69f1348da15274090d9074bbeded1eafc6b27a) (doc later removed in [54132c7](https://github.com/ejgallego/lean-vir/commit/54132c774f411b1fb4e141a64a039c5e4a2afa10))
- Strings: Lean runtime strings (UTF-8). At the boundary, "Strings cross UTF-16/UTF-8; byte results copy into JS-owned storage. No zero-copy…" — [NATIVE_CODECS.md](https://github.com/ejgallego/lean-vir/blob/main/benchmarks/NATIVE_CODECS.md)
- Tasks/threads: "`Task.pure`, `Task.get` and `Task.map` support only the exercised synchronous, already-resolved mode. There is no task scheduler or general blocking-IO implementation."
- Thunks: "`Thunk.mk`/`Thunk.get` wrappers can link, but the native forcing path cannot apply an interpreter closure."
- Lazy-constant `*_once_cold` providers are reimplemented as single-threaded versions without atomics.
- `lean_io_eprintln` "consumes and discards its string; no stderr sink is installed".
- Heartbeats, cancellation, tracing and options are inert.
  — all from [UPSTREAM_BOUNDARY.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/UPSTREAM_BOUNDARY.md)

### Inferences
- "Under 200 KiB" is accurate only for the gzip/brotli-compressed interpreter wasm. Raw it is about 775 KiB, and it has grown about 20% since August (657 KB → 793 KB raw). The full first-load payload is wasm, `runtime.js` and the app's `.irpkg`. For a nontrivial UI app that uses Lean/Std data structures, that is roughly 230 KB gzip of fixed runtime plus tens to hundreds of KB gzip of IR. The `demo-host` React demo package alone is about 177 KB gzip. IR is shipped as data, uncompressed in the `.irpkg` format.
- Lean code in Init/Std is not "in the runtime" except for natively provided externs. It travels inside each program's `.irpkg` as IR, so per-app size grows with the Lean library surface the app reaches, much as an Emscripten build's code size does.

### Gaps
- I found no first-party statement of what "runtime size" the project itself promises. The 200 KiB figure is secondary (awesome list).
- No breakdown of the current wasm by component (interpreter vs mpz vs stage0 Init C). The repo has a `size/` report page on the hosted site, but I did not read it.

## 3. Which WebAssembly target, toolchain and features, and which hosts?

### Takeaway
The target is `wasm32-wasip1`, one 32-bit linear memory with no Memory64, built with wasi-sdk 33 clang at `-O3`, `--gc-sections`, and stripped for release. The binary uses only baseline post-MVP features: bulk-memory, multivalue, reference-types, sign-ext and similar. It does not use wasm exceptions, tail calls, SIMD or threads. The primary host is the browser, through a bundled JS runtime that supplies its own WASI stubs. A Node entry exists, and WASI engines are used only for benchmarking.

### Cited Findings
- `target="${WASI_TARGET:-wasm32-wasip1}"`, `wasm_opt_level="${VIR_WASM_OPT_LEVEL:--O3}"`, initial memory 4,194,304 B, stack 1,048,576 B.
- Link flags: `--no-entry --gc-sections --export-memory`.
- The release profile strips with `llvm-objcopy --strip-all`, and a "dev" companion `vir-upstream.dev.wasm` is "optimized, unstripped". I found no `wasm-opt` invocation.
  — [build-upstream-probe.sh](https://github.com/ejgallego/lean-vir/blob/main/scripts/build-upstream-probe.sh); [JS_API.md](https://github.com/ejgallego/lean-vir/blob/main/docs/guides/JS_API.md)
- Toolchain: `install-wasi-sdk.sh` downloads `wasi-sdk-33.0` from WebAssembly/wasi-sdk releases, with a pinned SHA-256 for x86_64-linux. — [install-wasi-sdk.sh](https://github.com/ejgallego/lean-vir/blob/main/scripts/install-wasi-sdk.sh)
- Researcher inspection of the current `runtime.wasm`:
  - `target_features` custom section: `+bulk-memory +bulk-memory-opt +call-indirect-overlong +extended-const +multivalue +mutable-globals +nontrapping-fptoint +reference-types +sign-ext`. There is no exception-handling, tail-call, simd128, atomics/threads or memory64.
  - One memory with flags 0x0 (32-bit, non-shared), minimum 64 pages (4 MiB).
  - 14 imports: 13 `wasi_snapshot_preview1` functions (`args_*`, `environ_*`, `clock_time_get`, `fd_close`, `fd_fdstat_get`, `fd_prestat_*`, `fd_read`, `fd_seek`, `fd_write`, `proc_exit`) plus `env.vir_js_call_objects`.
  - 87 exports (`vir_*` object/package/call ABI plus `memory`).
  - `runtime.js` defines its own frozen `wasi_snapshot_preview1` stub object rather than depending on a WASI polyfill.
  — [release asset](https://github.com/ejgallego/lean-vir/releases/download/resource-ab3614c15934e54b9fa85b0891e6da56d239d09d04c7a2f3177980b2cec6a1d7/ab3614c15934e54b9fa85b0891e6da56d239d09d04c7a2f3177980b2cec6a1d7.virres)
- C++ exceptions: "Unsupported C++ exception throwing and assertion-violation paths trap; the SDK retires the instance." "Any exception escaping an exported Wasm function retires that instance… Recovery creates a fresh factory runtime." — [UPSTREAM_BOUNDARY.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/UPSTREAM_BOUNDARY.md)
- Hosts:
  - Browser `vir-runtime.js`, plus `vir-runtime-node.js`. The Node entry "provides only environment-neutral JavaScript value operations and console bindings. It deliberately has no built-in DOM model."
  - `npm run bench:engines` is "a WASI command-module comparison across available engines" (`install-wasm-engines.sh` installs wasmtime, wasmer and wasmedge).
  — [HOST_BINDINGS.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/HOST_BINDINGS.md); [PERFORMANCE.md](https://github.com/ejgallego/lean-vir/blob/main/docs/development/PERFORMANCE.md); [install-wasm-engines.sh](https://github.com/ejgallego/lean-vir/blob/main/scripts/install-wasm-engines.sh)
- The repo has a WIT file (`interfaces/lean-vir.wit`, `package lean:vir; world runner { export runtime; }`) with `load-package`, `interface-manifest` and `call` (byte payloads). — [lean-vir.wit](https://github.com/ejgallego/lean-vir/blob/main/interfaces/lean-vir.wit)
- Browser tests run under Chromium ("Set `CHROMIUM` to an alternate Chrome/Chromium executable"). — [benchmarks/browser/README.md](https://github.com/ejgallego/lean-vir/blob/main/benchmarks/browser/README.md)
- Secondary: a static site using lean-vir passes a strict CSP that adds only `'wasm-unsafe-eval'`. — [lean-math-in-the-browser](https://github.com/ejgallego/lean-math-in-the-browser)

### Inferences
- For LeanUI, moving to VIR would drop the Memory64 requirement and the Emscripten dependency entirely. The wasm needs only widely deployed features. The limits that come with that are a 4 GiB address space, no threads, and traps on C++ exceptions.
- The wasm is a stable, prebuilt, cacheable artifact (content-addressed resource IDs), shared by all apps on the same VIR/Lean version.

### Gaps
- No documented browser support matrix (Firefox/Safari testing). CI evidence points to Chromium only.
- I could not tell whether the WIT interface is built or used anywhere (it looks vestigial or experimental).
- I did not verify whether `-fno-exceptions` is passed. The docs say exception paths trap.

## 4. How does it interact with JavaScript, and how are `@[extern]` implementations handled?

### Takeaway
Interop is synchronous and object-ABI based. JS calls `@[vir_export]` Lean functions by full name, and values are converted by manifest-driven descriptors. Lean calls JS through `@[vir_js "target"]` host imports, at most 128, IR arity ≤ 6, synchronous only. JS values are carried as opaque `Js α` references (externref table) and Lean values as opaque `JSL` handles, with Lean closures convertible to JS functions. Promises can be held but not awaited inside Lean. `@[extern]` C functions must come from VIR's closed native catalog, which is compiled into the shared runtime. Otherwise an app needs a Lean fallback body (`vir_extern_fallback`) or a custom-built runtime that includes the app's C provider via a manifest.

### Cited Findings
- Official scope: "Explicit host bindings, calling Lean from JavaScript, JavaScript values with preserved identity, Lean-backed `JSL` values, and Lean callbacks"; automatic conversion of arrays of supported element types. "DOM, canvas, React, JSX, ProofWidgets, Infoview, editor/RPC integration and UI lifecycle adapters are experimental", as is automatic conversion of records and custom inductives. — [SUPPORT.md](https://github.com/ejgallego/lean-vir/blob/main/docs/SUPPORT.md)
- Two JS entry layers:
  - `createProgram` (resource bundle `runtime.js`) exposes only `status`, `call`, `callWith`, `dispose`, and "does not … accept custom `hostBindings`".
  - The SDK `createVirRuntime`/`createVirRuntimeFactory` exposes direct call, host-binding and object APIs.
  - `vir.callTimed` reports `marshalMs/executeMs/decodeMs/hostMs/totalMs`.
  - `callWith` can select an experimental `json-safe-v1` representation.
  — [JS_API.md](https://github.com/ejgallego/lean-vir/blob/main/docs/guides/JS_API.md)
- Numeric mapping: "Nat, Int and UInt64 results use bigint; wasm32 USize results use Number." — [RESOURCE_BUNDLES.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/RESOURCE_BUNDLES.md)
- Host imports: "JavaScript host imports execute synchronously and are limited to 128 imported declarations with IR arity at most 6." "Native Promises may cross as exact `Js` values… Suspending a Lean call on a Promise still needs a later JSPI-shaped boundary." Custom `@[vir_js]` declarations should use `Unit`, `Js α` resources, nullable resources and callbacks. "Raw Lean scalars, structures, arrays, lists, options, and products are rejected unless the declaration is an explicit conversion target." "Nested callbacks are rejected." — [JS_API.md](https://github.com/ejgallego/lean-vir/blob/main/docs/guides/JS_API.md)
- Example custom target: `@[vir_js "demo.bumpNat"] opaque jsBumpNat (n : @& Lean.Vir.Js Nat) : Lean.Vir.RuntimeM (Lean.Vir.Js Nat)`, bound with `hostBindings: { "demo.bumpNat": (n) => n + 1n }`. "Bindings execute synchronously. Returning a Promise is allowed only as an exact `Js` resource result; VIR roots the Promise object without awaiting it." — [HOST_BINDINGS.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/HOST_BINDINGS.md)
- Lean-owned state in JS: "`JSL α` already lets JavaScript retain a Lean value without decoding it. Use it when Lean owns the model and its transformations." — [OPAQUE_LEAN_STATE.md](https://github.com/ejgallego/lean-vir/blob/main/docs/guides/OPAQUE_LEAN_STATE.md)
- Callback mechanics: converted Lean functions use "retained-object cells, weak finalizer and terminal tracking"; `vir_closure_apply_objects` applies them. Host exceptions are captured out-of-band; a pure-import failure traps and retires the instance. — [UPSTREAM_BOUNDARY.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/UPSTREAM_BOUNDARY.md)
- Experimental UI layer: VIR "binds native React values and operations for Lean-authored components". `Js Node` is an actual React node and "There is no VIR node graph or props protocol". It also ships DOM (`Vir.Browser`), JSX and ProofWidgets/Infoview bindings. — [REACT.md](https://github.com/ejgallego/lean-vir/blob/main/docs/guides/REACT.md); [JS_API.md](https://github.com/ejgallego/lean-vir/blob/main/docs/guides/JS_API.md)
- `@[extern]` handling:
  - `NativeExternSpec` entries in `Vir/Compiler/NativeExterns.lean` select supported natives; Lean's own `_boxed` adapters are generated for the interpreter's homogeneous boxed calls.
  - Three ownership exceptions are handwritten.
  - "An `@[extern]` declaration alone does not prove provider availability."
  - The 2026-08-08 consolidation reports a "resolved 223-entry catalog". The current file has about 234 `name :=` lines (researcher count, approximate).
  - Unsupported proof-bearing natives are listed, e.g. `Char.ofNatAux`, `Nat.divExact`, `String.get'`, `UInt16.ofNatLT`.
  — [UPSTREAM_BOUNDARY.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/UPSTREAM_BOUNDARY.md); [commit d2dbb50](https://github.com/ejgallego/lean-vir/commit/d2dbb50d7c2736df840820ae2cb0ca7b8b45b4da); [NativeExterns.lean](https://github.com/ejgallego/lean-vir/blob/main/Vir/Compiler/NativeExterns.lean)
- Client C externs: "VIR can compile project-owned C or C++ providers into a browser runtime" via `lean-vir-native-externs.json`, with `vir_extern_fallback` keeping a Lean reference body. However, "The resulting Wasm runtime is specific to that manifest and must be deployed with packages generated under the same selection". This needs a Wasm build (`VIR_NATIVE_EXTERN_MANIFEST=… npm run build:demo`). — [CLIENT_NATIVE_EXTERNS.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/CLIENT_NATIVE_EXTERNS.md)
- Unsupported requested exports fail at package generation "instead of being omitted silently". — [JS_API.md](https://github.com/ejgallego/lean-vir/blob/main/docs/guides/JS_API.md)

### Inferences
- LeanUI's existing wasm64 runtime fork and any custom `@[extern]` C (DOM glue, event loop) would not carry over. Each extern would need a `@[vir_js]` JS binding, a Lean fallback body, or a client-native-extern runtime build. The last option brings back a WASI-SDK build step and a per-app runtime, losing the shared prebuilt-wasm advantage.
- The ABI is synchronous: no Promise suspension, no Tasks. So a LeanUI event loop must be JS-driven, re-entering Lean per event, and Lean-side "await" is impossible today.
- VIR's own experimental React/DOM layer overlaps LeanUI's domain. LeanUI would most plausibly use only the officially supported core (runtime, packages, object API, minimal interop) and keep its own UI layer.

### Gaps
- I have not verified how `IO.println`/stdout behaves (only `eprintln` is documented as discarded). WASI `fd_write` is stubbed in JS.
- No measured per-call boundary cost published for realistic UI payloads. NATIVE_CODECS.md explicitly refuses to claim application speedups.

## 5. Which Lean versions does it target, and how does it stay in sync with upstream?

### Takeaway
VIR pins exactly one Lean toolchain per revision (now `v4.35.0`) and has followed every Lean release since `v4.30.0-rc2` (May 2026), typically within days. Runtime and program compatibility is keyed to the exact Lean git hash plus a `virVersion` contract number, with no backward compatibility. Release tags mirror Lean versions (`4.35`, `4.35-rc4`). PRs for Lean 4.36.0-rc1 and a nightly are open.

### Cited Findings
- `lean-toolchain` history (researcher, `git log`):

  | Date | Toolchain |
  | --- | --- |
  | 2026-05-18 | v4.30.0-rc2 |
  | 2026-06-15 | v4.30.0 |
  | 2026-06-18 | v4.31.0 |
  | 2026-07-08 | v4.32.0-rc1 |
  | 2026-07-23 | v4.32.0 |
  | 2026-08-04 | v4.33.0-rc2 |
  | 2026-08-14 | v4.33.0 |
  | 2026-09-22 | v4.34.0 |
  | 2026-10-09 | v4.35.0-rc4 |
  | 2026-10-13 | v4.35.0 |

  — [lean-toolchain](https://github.com/ejgallego/lean-vir/blob/main/lean-toolchain); [commit 225218e (#264)](https://github.com/ejgallego/lean-vir/commit/225218e18a3ae554acc571a93aab484453d857a6)
- Open PRs: #266 "feat: support Lean 4.36.0-rc1" and #267 "feat: support Lean nightly 2026-10-13" (both 2026-10-15). Pre-release runtime resources are published for both. — [PR list](https://github.com/ejgallego/lean-vir/pulls); [releases](https://github.com/ejgallego/lean-vir/releases)
- `fetch-lean-source.sh` shallow-clones `leanprover/lean4` at the exact tag from `lean-toolchain`. The interpreter and runtime are compiled from that checkout. — [fetch-lean-source.sh](https://github.com/ejgallego/lean-vir/blob/main/scripts/fetch-lean-source.sh)
- Compatibility record: `{"leanRevision": "eb6cafb7290e8bd5f2937522d8d804f58f02bafc", "virVersion": 7}`. `leanRevision` is `Lean.githash`. `virVersion` is "one combined contract for the client-facing JavaScript API, runtime ABI and accepted program formats". `ResourceSet.validate` "requires equal Lean revision and VIR compatibility version". — [compatibility.json](https://github.com/ejgallego/lean-vir/blob/main/vir-resources/compatibility.json); [RESOURCE_BUNDLES.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/RESOURCE_BUNDLES.md)
- Release tags derive from the toolchain: `v4.35.0` → `4.35`, rc suffix retained (`releaseTagFromToolchain`). SDK acquisition: "Lean `v4.35.0` selects tag `4.35`… That GitHub release must exist." — [release-tag.mjs](https://github.com/ejgallego/lean-vir/blob/main/scripts/release-tag.mjs); [PACKAGES.md](https://github.com/ejgallego/lean-vir/blob/main/docs/guides/PACKAGES.md)
- Sync mechanisms:
  - `npm run check:ir-codec-tags` (IR constructor tag agreement).
  - `check:native-externs`, which resolves every catalog entry through Lean's IR/extern metadata.
  - `test:constructor-providers`, which compares native Lean and Wasm metadata.
  - The `CachedImports` adapter: "On toolchain changes, compare it with the new upstream implementation, update the source link, and run the import-cache equivalence tests."
  - A staged "Catalog Migration Roadmap" for upgrades.
  — [ci.yml](https://github.com/ejgallego/lean-vir/blob/main/.github/workflows/ci.yml); [GENERATE_PACKAGE.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/GENERATE_PACKAGE.md); [HARNESS.md](https://github.com/ejgallego/lean-vir/blob/main/docs/HARNESS.md)
- Policy: "VIR maintains the current contracts without legacy APIs or backward compatibility layers." "Mixing old JavaScript with new Wasm, or the reverse, is unsupported and has undefined behavior." — [SUPPORT.md](https://github.com/ejgallego/lean-vir/blob/main/docs/SUPPORT.md); [JS_API.md](https://github.com/ejgallego/lean-vir/blob/main/docs/guides/JS_API.md)
- Open issues on upstream coupling include #240 "Maintain the pinned shared importer across Lean upgrades" and #239 "Assess upstream HTML parser after Lean 4.36 adoption". — [issues](https://github.com/ejgallego/lean-vir/issues?q=is%3Aissue)
- VIR migrated to Lean's module system on 2026-09-07. Package generation now requires module inputs ("Non-module developments… are unsupported"). — [commit 57c95a2 (#166)](https://github.com/ejgallego/lean-vir/commit/57c95a21895a8ddde5098a00ccd47b634fce1b64); [GENERATE_PACKAGE.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/GENERATE_PACKAGE.md)

### Inferences
- Because VIR reuses the upstream interpreter and runtime sources verbatim, IR-format changes upstream are absorbed by recompiling, plus updating the `.irpkg` codec and extern catalog. That is less fragile than a reimplemented interpreter. The trade-off is that a LeanUI app must use exactly VIR's pinned Lean revision, and LeanUI must track VIR's cadence. So far that has meant a new compatible runtime within days of each Lean release.
- LeanUI sources would need to be Lean `module` files.

### Gaps
- No stated long-term support or maintenance-line policy beyond "zero-or-one maintenance-line workflow" (AGENTS.md / HARNESS.md backports). I did not read the backport policy in detail.

## 6. Maturity: activity, contributors, Lean FRO involvement, license, issues, limitations, roadmap, tests, demos and users

### Takeaway
lean-vir is a five-month-old (since 2026-05-18), very active, essentially single-maintainer project. It is written by Emilio J. Gallego Arias, a Senior Research Software Engineer at the Lean FRO, under Lean FRO copyright and Apache-2.0, with heavy AI-agent-assisted development. It lives on his personal GitHub, still self-describes as a proof of concept, has few users (8 stars), and does not appear in the Lean FRO's published roadmap. Test and CI infrastructure is extensive, and the explicit limitations list is long.

### Cited Findings
- Commits (researcher, `git log` on 2026-10-20):
  - 348 total from 2026-05-18 to 2026-10-20.
  - By month: May 101, Jun 40, Jul 53, Aug 80, Sep 36, Oct 38.
  - Authors: Emilio Jesús/Jesus Gallego Arias 342 (two spellings, e-mail `emilio@lean-fro.org` on recent commits) and "Codex" 6 (the first six bootstrap commits).
  — [commit history](https://github.com/ejgallego/lean-vir/commits/main)
- GitHub page: 8 stars, 2 forks, 12 open issues, 5 open / 232 closed PRs. The one non-owner contribution visible is open PR #197 "feat: adopt upstream HTML syntax" by Vtec234 (milestone 0.2.0). A fork exists at Vtec234/lean-vir. — [repo](https://github.com/ejgallego/lean-vir); [pulls](https://github.com/ejgallego/lean-vir/pulls); [Vtec234 fork](https://github.com/Vtec234/lean-vir)
- Agent-driven workflow: `AGENTS.md` ("This repository is a proof of concept for running Lean 4's real IR interpreter in `wasm32-wasip1`") and a mailbox protocol for parallel agents (`docs/development/MAILBOX_PROTOCOL.md`, `scripts/mailbox.mjs`). Recent commits include "docs: quiet agent coordination by default" and open PR #269 "docs: describe agent wake-ups without naming one runtime". — [AGENTS.md](https://github.com/ejgallego/lean-vir/blob/main/AGENTS.md); [pulls](https://github.com/ejgallego/lean-vir/pulls)
- Licensing: "Copyright (c) 2026 Lean FRO LLC… Released under Apache 2.0… Author: Emilio J. Gallego Arias". The license moved to Apache 2 on 2026-05-19 and Lean FRO headers were applied the same day. "Generated Wasm can contain Lean 4 object code and retains its upstream notices." — [NOTICE](https://github.com/ejgallego/lean-vir/blob/main/NOTICE); [README](https://github.com/ejgallego/lean-vir/blob/main/README.md); [commit 622bb45](https://github.com/ejgallego/lean-vir/commit/622bb45bfcae30a563e17e29fab1d929080cedbc); [commit 16f3b25](https://github.com/ejgallego/lean-vir/commit/16f3b25e694d3739708dc7a9bd346584ff9f2005)
- Emilio Jesús Gallego Arias is listed on the Lean FRO team page as "Senior Research Software Engineer". — [Lean FRO team](https://lean-lang.org/fro/team/)
- The Lean FRO Year 4 Part 1 roadmap (Sept 2026–Feb 2027) does not mention WebAssembly, wasm, browser, VIR or the IR interpreter. It mentions Verso web output, a "zero-install web environment" (Workbench) in beta, and code-generator improvements. — [FRO roadmap Y4-1](https://lean-lang.org/fro/roadmap/y4-1)
- Secondary label: the awesome list tags it "(early, Lean FRO)". — [awesome-lean-programming](https://github.com/nozaq/awesome-lean-programming)
- Releases: stable-ish tags `4.35` (2026-10-13, marked Latest) and `4.35-rc4`, plus content-addressed `resource-<sha256>` runtime pre-releases (Lean 4.34, 4.35, 4.36.0-rc1, nightly). As of 2026-09 a downstream user reported "Building the browser runtime needs a `GITHUB_TOKEN` because lean-vir has no release yet". Prebuilt runtime downloads via Lake came in [commit e92d95d (#210)](https://github.com/ejgallego/lean-vir/commit/e92d95db62b14db88669394791f6f981161d5674) (2026-10-02). — [releases](https://github.com/ejgallego/lean-vir/releases); [lean-math-in-the-browser](https://github.com/ejgallego/lean-math-in-the-browser)
- Open issues (sample, 2026-10):
  - #263 "Qualify a PrettyM browser baseline on the released runtime"
  - #252 "Choose one external spelling for the anonymous Lean Name"
  - #244 "Track current Lake duplicate builds through shared facets"
  - #242 "Make full Lean export names the sole public call key"
  - #240, #239 (upstream sync, see §5)
  - #228 "Qualify generated JSON-safe codecs in Verso Cast"
  - #159 "Use numeric constructor tags at the JS/Lean value boundary"
  — [issues](https://github.com/ejgallego/lean-vir/issues?q=is%3Aissue)
- Support statement: "Supported means documented, maintained and tested for the stated workflow and pinned Lean/VIR versions. It does not promise arbitrary Lean programs, every host environment, or compatibility across revisions." — [SUPPORT.md](https://github.com/ejgallego/lean-vir/blob/main/docs/SUPPORT.md)
- Other documented limitations:
  - no task scheduler or blocking IO;
  - no native thunk forcing;
  - several unsupported proof-bearing natives;
  - inert heartbeats, cancellation and tracing ("Clients needing interruption must own a worker/process boundary");
  - `Lean.PrettyPrinter.ppExpr` unsupported (needs Meta/Environment tasks);
  - one complete package set per runtime instance ("Individual member unload, version solving, remote resolution and hot replacement of one member are not implemented").
  — [UPSTREAM_BOUNDARY.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/UPSTREAM_BOUNDARY.md)
- Tests and CI:
  - The CI workflow runs dozens of npm suites (runtime, interface, packages, bindings, native constructor providers, resource roots, Pages and browser tests, quickstart browser test, infoview browser test, Lake facets).
  - The release workflow builds the SDK and runtime pack on tags and checks the tag against `lean-toolchain`.
  - Large fixture set under `fixtures/` and `tests/`.
  — [ci.yml](https://github.com/ejgallego/lean-vir/blob/main/.github/workflows/ci.yml); [release-sdk.yml](https://github.com/ejgallego/lean-vir/blob/main/.github/workflows/release-sdk.yml)
- Demos: hosted site with merge sort, "experimental React Tamagotchi", `Format.pretty`, a package runner, a "Runnable surface" explorer, a "Wasm size" report, and a browser benchmark catalog ("JS, FIR, LLVM, and VIR under one differential suite"). — [hosted demo site](https://ejgallego.github.io/lean-vir/)
- Known workloads and users:
  - Benchmark catalog workloads come from `leanprover/verso-slides` (`VersoSlides/Pretty.lean` prettyM), `ejgallego/lean-zip`/`kim-em/lean-zip-common` (raw DEFLATE), and `ejgallego/illuminate` (animation player).
  - An external educational repo, lean-math-in-the-browser (by joelcanary, also forked to ejgallego), runs number theory in a Web Worker via lean-vir. It states it is not affiliated with the FRO or lean-vir.
  — [artifact-builds.json](https://github.com/ejgallego/lean-vir/blob/main/benchmarks/browser/artifact-builds.json); [lean-math-in-the-browser (ejgallego fork)](https://github.com/ejgallego/lean-math-in-the-browser); [joelcanary original](https://github.com/joelcanary/lean-math-in-the-browser)
- Community (secondhand): per the lean-math-in-the-browser README, a September 2026 Lean Zulip #general thread "DOM Manipulation in Lean" mentioned ProofWidgets4 and lean-vir. A lean-vir author there said its DOM bindings are expected to change while pure Lean code in Wasm is the more stable target. I could not access the thread directly. — [joelcanary/lean-math-in-the-browser](https://github.com/joelcanary/lean-math-in-the-browser)
- Sibling project: lean-vir's benchmark suite compares against `ejgallego/lean-fir`. Its README says "Internal, non-official research workspace — not for external use". It describes FIR as "executable semantics and compiler-correctness proofs for Lean's `Lean.Compiler.LCNF` pipeline" with "two executable LCNF-to-WebAssembly paths: FIR's symbolic backend and Lean's direct C emitter followed by an optimized LLVM WebAssembly backend". lean-vir's benchmark docs describe the latter as an "Emscripten module". — [lean-fir README](https://github.com/ejgallego/lean-fir); [ARTIFACT_SETS.md](https://github.com/ejgallego/lean-vir/blob/main/benchmarks/browser/docs/ARTIFACT_SETS.md); [ARTIFACT_BUILDS.md](https://github.com/ejgallego/lean-vir/blob/main/benchmarks/browser/docs/ARTIFACT_BUILDS.md)

### Inferences
- "Lean FRO" here means FRO-employed author and FRO copyright, not a roadmap-level FRO product. It is best described as an FRO staff research project. Bus factor is about 1 human plus agents, and the contract churns fast (virVersion reached 7 by October; "no backward compatibility"). That suits experimentation but carries integration risk for a framework like LeanUI that would depend on its ABI.
- The FRO author is benchmarking interpreter (VIR) against compiled LCNF→wasm (FIR native, and FIR's LCNF→C→LLVM/Emscripten path, which is architecturally close to LeanUI's current pipeline). So the FRO side is actively studying both approaches, and the comparison data in that suite would be directly relevant to LeanUI's decision once published.

### Gaps
- No first-party statement on whether VIR will become an official FRO deliverable or move to the `leanprover` org.
- Issue page 2 (6 more issues) and closed-PR details were not inspected.
- No Zulip thread text was accessible directly.

## 7. Published performance numbers

### Takeaway
The project publishes benchmark tooling but no qualified headline numbers. Open issue #263 is still about qualifying a baseline. The available data points are secondary or diagnostic:
- about 120–170× slower than native Lean for loop/array code;
- about 10× slower for bignum-heavy work, with bignum multiplication alone about 230× slower (no GMP);
- multi-second runs for DEFLATE of 32–64 KiB inputs;
- large cold-vs-warm gaps (about 680 ms cold vs 0.05 ms warm on one probe).

### Cited Findings
- Secondary (lean-math-in-the-browser, Lean 4.34, one pinned lean-vir commit, Sept 2026):
  - Loops and arrays are "about 120–170× slower through lean-vir than compiled natively".
  - For big-integer-dominated work the gap "falls to about 10×".
  - F(10⁶): natively "3 ms to compute and 9.3 s to print in decimal". In the browser, multiplication is "~230× slower" because of the non-GMP fallback.
  - A 46 s computation was run in a Worker to avoid freezing the page.
  — [lean-math-in-the-browser](https://github.com/ejgallego/lean-math-in-the-browser)
- Repo diagnostic (lean-zip probe, 2026-08-11, single samples, "attribution evidence rather than a stable benchmark"):

  | Level | 32 KiB repeated text | 64 KiB heterogeneous |
  | --- | ---: | ---: |
  | 5 | 1,541.99 ms | 4,049.72 ms |
  | 6 | 1,442.66 ms | 6,288.37 ms |
  | 9 | 2,405.34 ms | 11,057.98 ms |
  | 10 | 2,463.08 ms | 11,012.17 ms |

  — [commit 9f69f13](https://github.com/ejgallego/lean-vir/commit/9f69f1348da15274090d9074bbeded1eafc6b27a)
- Cold vs warm: "one synthetic reference measured 679.92 ms on the cold call and 0.051 ms on the following call in the same runtime". A client-native acceptance run of 101 compression outputs "completed in 41.76 seconds". These are "diagnostic timings, not stable throughput results". — [commit 9f69f13](https://github.com/ejgallego/lean-vir/commit/9f69f1348da15274090d9074bbeded1eafc6b27a) (doc removed in [54132c7](https://github.com/ejgallego/lean-vir/commit/54132c774f411b1fb4e141a64a039c5e4a2afa10))
- Benchmark tooling:
  - `npm run bench` compares against "the host Lean IR baseline". For "pure interpreter cost, compare the `fib` and `sort` rows".
  - The browser catalog "compares five `Std.Format.prettyM` backends" (JS, VIR string-ABI, VIR direct-Format, FIR native, LLVM/Emscripten) and records startup profiles and memory.
  - No result tables are committed. The doc's `base-bool` JSON (0.0185 ms/call) is labeled as a schema example.
  — [PERFORMANCE.md](https://github.com/ejgallego/lean-vir/blob/main/docs/development/PERFORMANCE.md); [benchmarks/browser/README.md](https://github.com/ejgallego/lean-vir/blob/main/benchmarks/browser/README.md)
- Native codec work explicitly avoids speedup claims: "Sharing has no new timing or application/startup speedup claim." — [NATIVE_CODECS.md](https://github.com/ejgallego/lean-vir/blob/main/benchmarks/NATIVE_CODECS.md)
- Startup-related engineering: a recent commit "perf: minimize runtime JavaScript and startup downloads (#256)" (2026-10-09). Each package generation uses a fresh `WebAssembly.Instance`, while the compiled `WebAssembly.Module` "may be reused". — [commit history](https://github.com/ejgallego/lean-vir/commits/main); [UPSTREAM_BOUNDARY.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/UPSTREAM_BOUNDARY.md)
- Open issue #263 "Qualify a PrettyM browser baseline on the released runtime" (2026-10-12) and PR #265 "bench: add a checked public PrettyM screen" (2026-10-13) indicate qualified browser numbers are still in progress. — [issues](https://github.com/ejgallego/lean-vir/issues?q=is%3Aissue); [pulls](https://github.com/ejgallego/lean-vir/pulls)

### Inferences
- For LeanUI, compute-heavy Lean code inside an app (layout, diffing, parsing, big data structures) would likely run one to two orders of magnitude slower under VIR than under LeanUI's current compiled-C wasm64 path. Thin UI glue dominated by JS/DOM calls may be fine.
- The first call into a module pays lazy-initialization costs (about 0.7 s in one probe). Heavy initializers or large closures may hurt time-to-interactive. Reusing the compiled module and a persistent interpreter session helps for later calls.
- The best comparison data for LeanUI's decision would be the prettyM/lean-zip/illuminate VIR-vs-FIR-vs-LLVM(Emscripten) reports. They are generated by the hosted benchmark app but not committed as numbers.

### Gaps
- No published startup-time (instantiate plus package load) or memory numbers.
- No interpreter-vs-native ratio from the repo itself; the 120–170× figure is from a third-party educational repo on an older commit.
- I did not run the hosted benchmark app (it needs a browser and cross-origin isolation), so I collected none of its live numbers.
