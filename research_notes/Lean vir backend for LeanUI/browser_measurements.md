# lean-vir in real browsers vs compiled Lean wasm: first-hand measurements

Research date 2026-10-20. Every number here is an **own measurement** unless a source says otherwise.

**Machine.** A 4-vCPU cloud VM (Intel Xeon @ 2.80 GHz, 15 GB RAM). **All browser timings below are from this CI machine, to be re-measured on the reference Mac.** Read them as ratios, not as absolute speeds. Another researcher ran builds on the same machine during the runs (load average 1.0–3.4). Native timings of the same binary moved by up to ~1.8× between quiet and loaded moments. To spread that load evenly, I interleaved the implementations round by round.

**Versions.**
- lean-vir `81de859a3ba1cb5da8bc5f128af025dd5a40b343` (2026-10-20), Lean `v4.35.0` (`eb6cafb`).
- VIR runtime: the pinned resource `ab3614c1…`. Its `runtime.wasm` has SHA-256 `0b46452b…`, byte-identical to the SDK release's `vir-upstream.wasm` built 2026-10-13.
- Browsers: Chromium 141.0.7390.37 (Playwright headless shell), Playwright's Firefox 142.0.1, and release Firefox 158.0.1, which a self-driving page runs headless with no automation attached.

**Abbreviations.**
- `GR/` stands for `file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/`. It holds every script, build and raw JSON result. Links below spell it out in full.
- `VIR@` stands for `https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/`.

## 1. Can lean-vir at 81de859 be packaged and run in headless Chromium and Firefox, and what did it take?

### Takeaway
Yes. With Lean v4.35.0 from elan and the documented three-step application workflow, a benchmark module packaged in about a minute. That covers `@[vir_export]`, a resource library with `include_vir_assets`, and a `publish` exe. Lake downloaded the pinned interpreter by itself, with no WASI SDK and no npm. The module ran unmodified in Chromium 141, Playwright's Firefox 142 and release Firefox 158, and its checksums were identical to native Lean everywhere. Getting there took three source workarounds, all forced by the packager's fixed extern catalog: no `Float.toUInt8`, `ByteArray.uset` or `ByteArray.usize`.

### Cited Findings
**The VIR workflow and runtime acquisition.**
- VIR's README says an application needs three changes: `@[vir_export]`, a resource library that calls `include_vir_assets`, and a `needs := #[`+Mod:virResourcePack]` entry. "Lake … downloads the matching prebuilt interpreter", and "No producer paths, packaging scripts or Wasm build are needed" — [VIR@README.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/README.md)
- The runtime is pinned by content in `vir-resources/runtime.json`. It points at the release asset `resource-ab3614c1…/ab3614c1….virres`, with compatibility `{leanRevision eb6cafb…, virVersion 7}` — [VIR@vir-resources/runtime.json](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/vir-resources/runtime.json)
- Commit 81de859 moved the descriptor contract to manifest 13 and resource compatibility 7 ("Regenerate packages and use a matching runtime/SDK pair"). ABI 4 and package format 11 are unchanged — [lean-vir commit 81de859](https://github.com/ejgallego/lean-vir/commit/81de859a3ba1cb5da8bc5f128af025dd5a40b343)
- The runtime build defaults are `-O3`, 4 MiB initial linear memory and a 1 MiB stack — [VIR@scripts/build-upstream-probe.sh](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/scripts/build-upstream-probe.sh)

**What I did (own measurement).**
- I installed Lean v4.35.0 with elan in 52 s. The project at [GR/vbench](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/vbench) requires a local clone of lean-vir at 81de859.
- The first `lake build VBenchResources publish` built lean-vir's Lean libraries (104 jobs) in about 1 minute. Later package generations took 2–8 s.
- `lake exe publish` wrote a self-contained site, [GR/site-vir](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/site-vir), containing `runtime.js`, `runtime.wasm`, manifests and 17 `.irpkg` members.
- JS calls the program with `createProgram(...)` followed by `program.call(...)`. Pages are served with COOP/COEP headers, so `crossOriginIsolated` is true and timers are fine-grained.

**Packager rejections hit by the benchmark** (exact tool output, own measurement):
- `missing native extern registrations: ByteArray.usize …, ByteArray.uset …, Float.toUInt8 (via … BenchCore.gammaK …)`.
- Workaround for the Float kernel: `w.toUInt32.toUInt8`, which `Float.toUInt32` and `UInt32.toUInt8` support. I applied this to **all** implementations so the code stays identical.
- The `uget`/`uset` brightness kernel was kept out of the main VIR package (see §7).
- Source: [GR/vbench/VBench/Core.lean](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/vbench/VBench/Core.lean)

**The extern catalog.** VIR's native-extern catalog is an explicit allowlist: 229 single entries plus grouped lists.
- `ByteArray` gets `uget`, `set`, `copySlice` and others, but not `uset` or `usize`.
- `Float` gets `toUInt32` and `toUInt64` but no `toUInt8` or `toInt64`.
- Each group is commented as "measured" for its wasm size cost before admission. For example, `log2` is noted as costing "3,019 raw bytes".
- Source: [VIR@Vir/Compiler/NativeExterns.lean](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/Vir/Compiler/NativeExterns.lean)

**Integer results at the JS boundary.** "`Nat`, `Int`, and `UInt64` results are JavaScript `bigint`", and `USize` "follows the Wasm execution target", which is wasm32 — [VIR@docs/guides/JS_API.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/guides/JS_API.md)

**Inputs held in Lean across calls.** I kept the 4 MB image Lean-side with `JSL ByteArray` handles (`LeanRef.toJSL`/`fromJSL` in `RuntimeM`), as the opaque-state guide shows — [VIR@docs/guides/OPAQUE_LEAN_STATE.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/guides/OPAQUE_LEAN_STATE.md)

**Firefox.**
- Release Firefox cannot be driven by Playwright. I drove it with a self-posting page: [GR/harness/drive-release-ff.mjs](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/harness/drive-release-ff.mjs)
- Firefox 158.0.1 came from Mozilla's `firefox-latest-ssl` redirect — [download.mozilla.org](https://download-installer.cdn.mozilla.net/pub/firefox/releases/158.0.1/linux-x86_64/en-US/firefox-158.0.1.tar.xz)

### Inferences
- For a self-contained module, the "no WASI SDK, no npm" claim held in practice: elan plus Lake was enough.
- The real friction is the fixed extern allowlist. Any primitive missing from it (`Float.toUInt8`, `ByteArray.uset`) means either a source rewrite or an upstream catalog request. The comments show the catalog grows only after a measured size review.

### Gaps
- I did not build VIR's runtime from source, so wasi-sdk 33 and `npm run setup` were not exercised. Every result uses the prebuilt pinned runtime.
- I did not test Safari/WebKit.

## 2. Which compiled baselines, which workloads, and does the correctness gate hold?

### Takeaway
I compared four implementations of the same Lean source:
- **VIR**: Lean 4.35 IR interpreted on wasm32.
- **wasm32**: Lean 4.35 → C → Emscripten 6.0.5, single-threaded, with Lean 4.35's runtime/Init/Std built for wasm32. This is the apples-to-apples baseline.
- **wasm64**: LeanUI's production path. Lean 4.34 → C → Emscripten 6.0.5 `-m64`, linked against LeanUI's QED64 archives.
- **native**: `leanc -O3`, Lean 4.35.

Every implementation produced identical checksums on every workload in every browser, including a full FNV-1a hash of each 4 MB kernel output. lean-vir's own browser catalog also runs on its hosted build (VIR against FIR's Lean→C→Emscripten route), and I ran it as a cross-check (§3).

### Cited Findings
**Workloads.** All are in [GR/vbench/VBench/Core.lean](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/vbench/VBench/Core.lean), ported to the module system from the earlier host-only `interp-bench/Bench.lean` and `vir/ibench/Bench.lean`. One call each:
- `vdom`: build two 1,000-row × 10-cell `VNode` trees (String fields, `Array` children) and diff them. 22,002 nodes.
- `rows`: 1,000 js-framework-benchmark labels from a UInt64 LCG, `String.hash`/`mixHash`, and a `Std.HashMap UInt64 Nat`.
- `fib 27` on `Nat`.
- `lut`: a `ByteArray.get!`/`set!` lookup-table pass over 4,000,000 bytes.
- `blur3`: a 3-tap `UInt32` blur into a fresh 4 MB buffer.
- `gamma`: a per-byte `Float` multiply.
- `bright` (`uget`/`uset` with a `USize` index): compiled implementations only.

Every timed kernel receives a shared input, so copy-on-write happens once per call in every implementation. Timed calls return a 1,024-point sampled checksum. A separate, untimed call returns a full FNV-1a hash of the output.

**Baseline builds.**

| implementation | Lean | compiled path (exact) | build script |
|---|---|---|---|
| VIR | 4.35.0 | IR in `.irpkg`, interpreted by the pinned `runtime.wasm` (wasm32-wasip1, upstream C++ interpreter) | [vbench/lakefile.lean](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/vbench/lakefile.lean) |
| wasm32 | 4.35.0 | `lean -c` → `emcc 6.0.5 -O3 -fwasm-exceptions -sWASM_LEGACY_EXCEPTIONS=1` (wasm32), no `-pthread`, no LTO. Linked with Lean v4.35.0's `libleanrt`/`libInit`/`libStd`/`libuv`, built for Emscripten from the tag's `stage0` (FIR's recipe) | [build-wasm32-runtime.sh](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/build-wasm32-runtime.sh), [build-wasm32.sh](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/build-wasm32.sh) |
| wasm64 | 4.34.0 | LeanUI's `tools/build-app.sh` flags (`-O3 -m64`, dlmalloc, 16 MiB initial memory, 1 MiB stack), linked against `/home/user/leanui/.toolchain/wasm64` (QED64 fork, mounted read-only) in image `qed64-toolchain:emsdk-6.0.5` | [build-wasm64.sh](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/build-wasm64.sh) |
| native | 4.35.0 | `leanc -O3 -DNDEBUG` with the same C driver ([csrc/shim.c](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/csrc/shim.c)) | [native/](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/native) |

- **Shared C driver.** All compiled builds hold the Lean input in C and call `runtime_initialize_<module>`, as LeanUI's shim does. Using `initialize_<module>` instead pulled in meta initializers and grew `app.wasm` from 663 KB to 1.66 MB — [LeanUI runtime/leanui_wasm.c](/home/user/leanui/runtime/leanui_wasm.c); own measurement.
- **The FIR recipe.** FIR's compiler-native path builds "the pinned Lean runtime, Init, and Std archives for Emscripten" with `emcmake cmake -S stage0/src -DSTAGE=0 …` plus `leanmake … C_ONLY=1` — [lean-fir integration/lcnf-c-wasm/setup-emscripten.sh](https://github.com/ejgallego/lean-fir/blob/167c2a4f9b15886888099c6cb902105c8ba72a27/integration/lcnf-c-wasm/setup-emscripten.sh)
- **Two patches needed on v4.35.0's stage0.**
  - Upstream `stage0/src/CMakeLists.txt` hard-codes `-pthread -flto` for Emscripten. I replaced it with LeanUI's single-threaded flags.
  - A stub signature mismatch, `lean_uv_os_get_group()` versus `(uint64_t gid)`, had to be fixed. It is the same fix FIR carries for 4.33.
  - The stage0 `lean.h` is byte-identical to the v4.35.0 release's. The wasm32 link warns about one unrelated signature mismatch (`lean_io_create_tempdir`, stage0 Init versus runtime).
  - Patch: [lean4-435-research.patch](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/lean4-435-research.patch). The build took 5 minutes.
- **Correctness gate.** Sampled checksums matched across all implementations and browsers, for example vdom `30020761263` and rows `16432152575524727762`. The full output hashes matched native exactly in Chromium, release Firefox and Playwright Firefox: lut `3828281086536877445`, blur3 `15712878678377243176`, gamma `14880593507454744517`, input `13956273453028049189` — [GR/results/full](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/results/full)

**lean-vir's own benchmark tooling.**
- `npm run bench` compares VIR in Node "against the host Lean IR baseline", meaning the native interpreter, not compiled code. It needs `npm run setup`, which runs the Lean source fetch, the WASI SDK and the Wasm build — [VIR@docs/development/PERFORMANCE.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/development/PERFORMANCE.md); [VIR@package.json](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/package.json)
- The browser catalog builds artifacts from exact catalogued FIR/VIR/Lean commits. "Performance collection remains an explicit controlled-machine step" — [VIR@benchmarks/browser/README.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/benchmarks/browser/README.md)
- Its hosted Pages build at `https://ejgallego.github.io/lean-vir/benchmarks/` exposes `__benchmarkApp.getController().runStudy(...)`, the same API the repo's smoke test uses. I drove it from Playwright — [VIR@benchmarks/browser/test/example-package-smoke.mjs](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/benchmarks/browser/test/example-package-smoke.mjs); [GR/harness/hosted.mjs](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/harness/hosted.mjs)
- Issue #263, "Qualify a PrettyM browser baseline on the released runtime", is open in milestone 0.1.2 with no comments and no results. It scopes out a FIR comparison and startup, and sets a two-warm-up, eight-round protocol — [lean-vir issue #263](https://github.com/ejgallego/lean-vir/issues/263)

### Inferences
- **wasm32 is the right baseline for "what interpretation costs".** It uses the same Lean version, pointer width and Emscripten as the others.
- **wasm64 is the right baseline for "what LeanUI would lose".** It is LeanUI's production path, so for LeanUI the decision-relevant ratio is VIR/wasm64. On vdom and rows it is smaller than VIR/wasm32 because LeanUI's wasm64 build is itself 1.5–3× slower than wasm32 on allocation-heavy code (§3).

### Gaps
- My wasm32 runtime comes from v4.35.0's `stage0` C, not from a stage1 build of the release's own Init/Std. One link warning shows they differ slightly. The checksums show the benchmark is unaffected, but stage0 code may not match the release's compiled Init/Std.
- I ran FIR's own compiled path only through lean-vir's hosted catalog (§3), not on my workloads. Building lean-fir would need Lean 4.34.1 and emsdk 5.0.3.

## 3. Interpreted vs compiled: steady-state ratios inside Chromium and Firefox

### Takeaway
Inside the same browser, VIR runs the same Lean code:
- **27–30× slower** than compiled wasm32 on the virtual-DOM build+diff;
- **42–43×** on string/HashMap row creation;
- **86–95×** on a ByteArray lookup-table pass;
- **133–153×** on a UInt32 blur;
- **169–217×** on a Float per-byte kernel;
- **117–178×** on `fib`.

Against LeanUI's actual wasm64 build the ratios are 9–22× (vdom), 18–28× (rows), 42–62× (lut), 113–114× (blur3) and 176–211× (gamma). VIR in the browser is also about **1.6–3.5× slower than the same Lean interpreter running natively**, so the earlier native-host ratios understated the browser gap. lean-vir's own hosted harness confirms the order of magnitude: on lean-zip compression, VIR is 18–320× slower than FIR's Lean→C→Emscripten route.

### Cited Findings
**Main table (own measurement).** Median of per-load medians; parentheses give the range of per-load medians.
- Samples: compiled builds 3 fresh loads × 15 samples. VIR 3 loads × 5 samples in Chromium and release Firefox, and 2 loads × 3 samples in Playwright Firefox, after 2 unmeasured calls.
- Fast compiled operations were batched so each sample is at least 10 ms.
- Native is `leanc -O3` (Lean 4.35): the median over 12 runs × 15 samples at varying co-tenant load. The quietest runs were vdom 1.87, rows 0.19, fib 2.25, lut 15.4, blur3 38.4 and gamma 16.0 ms.
- Sources: [GR/results/full](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/results/full); aggregation [GR/harness/aggregate.py](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/harness/aggregate.py)

*Chromium 141 (CI machine, to be re-measured on the reference Mac)*

| workload | native | wasm32 | wasm64 (LeanUI path) | VIR | VIR/wasm32 | VIR/wasm64 |
|---|--:|--:|--:|--:|--:|--:|
| vdom build+diff (1,000 rows) | 2.51 ms | 3.65 (3.50–3.90) | 12.4 (5.28–12.8) | 108.8 (105.1–126.5) | **30×** | **8.8×** (21× vs the 5.28 load) |
| rows (1,000; strings, hash, HashMap) | 0.262 | 0.461 (0.450–0.518) | 1.07 (0.62–1.11) | 19.3 (18.6–20.0) | **42×** | **18×** |
| fib 27 | 2.78 | 2.93 (2.87–3.16) | 3.12 (2.90–4.68) | 521 (474–624) | **178×** | **167×** |
| lut, 4 MB | 19.7 | 39.7 (37.1–44.3) | 60.7 (57.9–61.8) | 3,778 (3,678–3,935) | **95×** | **62×** |
| blur3 (UInt32), 4 MB | 43.6 | 72.2 (67.9–91.0) | 96.7 (92.5–137.9) | 11,061 (10,564–11,233) | **153×** | **114×** |
| gamma (Float), 4 MB | 20.5 | 41.1 (40.1–53.7) | 50.8 (49.2–55.4) | 8,924 (8,456–9,106) | **217×** | **176×** |

*Release Firefox 158 (no automation; CI machine, to be re-measured on the reference Mac)*

| workload | wasm32 | wasm64 | VIR | VIR/wasm32 | VIR/wasm64 |
|---|--:|--:|--:|--:|--:|
| vdom | 6.79 (6.74–9.56) | 8.33 (5.85–9.86) | 181 (129–239) | **27×** | **22×** |
| rows | 0.730 (0.589–1.08) | 1.12 (0.91–1.43) | 31.2 (20.9–46.7) | **43×** | **28×** |
| fib 27 | 6.36 (5.81–7.41) | 8.70 (7.74–9.08) | 743 (702–754) | **117×** | **85×** |
| lut | 58.7 (47.9–64.8) | 121 (93–130) | 5,062 (4,551–5,412) | **86×** | **42×** |
| blur3 | 100 (81–121) | 119 (108–134) | 13,386 (12,456–13,780) | **133×** | **113×** |
| gamma | 62.3 (46.4–63.5) | 50.0 (49.8–62.4) | 10,532 (10,355–10,641) | **169×** | **211×** |

*Playwright's Firefox 142.* Ratios VIR/wasm32: vdom 28×, rows 52×, fib 191×, lut 127×, blur3 156×, gamma 249×. Absolute times are 4–10× those of release Firefox for both VIR and compiled code: wasm32 vdom 29.7 ms against 6.79, VIR lut 23.9 s against 5.06 s. This matches LeanUI's own finding that "Playwright's Firefox is not Firefox" for wasm — [LeanUI docs/BENCHMARKS.md, "Findings about measuring"](/home/user/leanui/docs/BENCHMARKS.md); own measurement.

**VIR against the same interpreter natively (own measurement).** `lake env lean -Dinterpreter.prefer_native=false --run NativeInterp.lean`, Lean 4.35, quiet machine, 3–5 runs.
- Native interpreter times: vdom 67.3 ms, rows 8.80, fib 294, lut 2,076, blur3 5,435, gamma 4,777, bright 4,760.
- VIR in Chromium is 1.6× (vdom), 2.2× (rows), 1.8× (fib), 1.8× (lut), 2.0× (blur3) and 1.9× (gamma) slower than that. In release Firefox it is 2.2–3.5× slower.
- Against native compiled code, the native interpreter is 27× (vdom), 34× (rows), 106× (fib), 105× (lut), 125× (blur3) and 233× (gamma) slower.
- Sources: [GR/vbench/NativeInterp.lean](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/vbench/NativeInterp.lean); [GR/results/native](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/results/native)

**Compiled wasm against native (own measurement).**
- wasm32 in Chromium is 1.06–2.0× native. wasm64 (LeanUI's path) is 1.1–5.0× native.
- LeanUI's wasm64 is slower than wasm32 on vdom (12.4 against 3.65 ms in two of three loads; 5.3 ms in the third) and on rows (1.07 against 0.46 ms).

**lean-vir's own hosted catalog (own run, Chromium 141).** Source commit `273d0d6` of the catalog; 3 runs of the `suite` study, each with 1 warm-up and 3 samples per cell; every backend passed exact native-oracle parity.
- lean-zip raw DEFLATE, VIR ÷ `fir-emscripten` (FIR's Lean `emitC` → Emscripten route), per cell over the 3 runs:
  - repeated-1k: L1 18–31×, L6 23–36×
  - structured-16k: L1 100–125× (12× once, when FIR had a 6.9 ms outlier), L6 266–320×, L10 78–82×
  - random-4k: L1 99–159×, L6 137–175×
- VIR ÷ `fir-native` (FIR's direct wasm codegen) was 1.7–29×.
- VIR medians were, for example, 15 ms (repeated-1k L1) and 794–859 ms (structured-16k L10). FIR-emscripten took 0.5–11 ms.
- The catalog marks such numbers "Interactive measurements from this machine are diagnostic only."
- Sources: [GR/results/hosted](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/results/hosted); [hosted catalog](https://ejgallego.github.io/lean-vir/benchmarks/)
- prettyM differential suite on the same page (45 scenarios, 2 warm-ups, 9 samples; pooled medians of per-call `totalMs`):
  - VIR "Format" 0.072 ms, VIR JSON 0.572 ms, FIR "llvm" (Emscripten) 0.063 ms, FIR "native" 0.087 ms, JS 0.0021 ms.
  - For these tiny, boundary-dominated calls VIR-Format is only about 1.1× the Emscripten route in total time, and 2.3× in `executeMs`.
  - Source: [GR/results/hosted/prettyM-suite.json](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/results/hosted/prettyM-suite.json)

**Earlier host-only figures, for comparison.** `lean --run` against `leanc` (Lean 4.34) gave 22–29× on vdom, 55–73× on lut, 100–107× on blur3 and 142–199× on gamma — [execution_strategies_performance.md](/home/user/leanui/research_notes/Lean%20vir%20backend%20for%20LeanUI/execution_strategies_performance.md)

### Inferences
- **The browser ratios are larger than the host-only ones.** VIR-in-browser against compiled-wasm comes out at 27–30× on tree code and 86–217× on byte, UInt32 and Float kernels, against 22–29× and 55–199× on the host. The interpreter loses more going to wasm (1.6–3.5×) than compiled code does (1.1–3×), which is what the earlier note predicted: the native ratios were a floor.
- **Reasons the interpreter loses more in wasm (consistent with the earlier source reading; not separately profiled here):**
  - On wasm32 the interpreter heap-boxes `UInt32`, `UInt64` and `Float` values at every native call.
  - It cannot use computed-goto dispatch.
- **Size of the gap against LeanUI's real build.** It is about an order of magnitude on tree work (9–22×) and two orders on pixel work (42–211×). A 12 MP RGBA lookup-table pass (48 MB) would take about 45–60 s in VIR on this machine, against well under a second compiled.
- **The prettyM result does not contradict this.** Workloads dominated by small calls and boundary conversion barely see the interpreter. Any compute loop does.

### Gaps
- VIR timings have 3 × 5 samples per browser (2 × 3 in Playwright Firefox). The per-load spread on VIR was within about ±20% in Chromium but reached −33%/+50% in release Firefox (rows 20.9–46.7 ms around 31.2), under co-tenant load.
- Not measured: Safari, and Chrome stable as opposed to the Chromium headless shell.
- No CPU profile of the steady-state interpreter, so the "boxing versus dispatch" split is inferred, not measured.

## 4. LeanUI's own keyed-benchmark operations (Lean side) under VIR vs LeanUI's wasm64 build

### Takeaway
I ran LeanUI's real framework code: the `Bench` app's `update`, `view`, diff and command encoding, with no DOM. VIR is **12–55× slower** than LeanUI's production wasm64 build.
- Creating 1,000 rows takes **350 ms in Chromium and 415 ms in release Firefox** under VIR, against 11 ms and 7.6 ms compiled.
- Replacing them takes 534–578 ms.
- Even selecting a row costs 16–24 ms of Lean work before any DOM is touched.

Only select in release Firefox (15.7 ms) stays under a 16 ms frame, and that is before any DOM work. Every other operation exceeds the frame budget in both browsers.

### Cited Findings
**Method.** `LeanUIOps` mirrors `tests/Perf.lean`: `stepMsgs Bench.program #[msg]` on a state taken out of a ref uniquely, as `LeanUI.start` does.
- Built three ways: VIR with Lean 4.35 (§7 changes), native `leanc -O3` with Lean 4.35, and wasm64 with Lean 4.34 and LeanUI's archives.
- Each sample is one operation after an untimed setup operation. Each browser had 3 loads × 10 samples (create10k: 3 × 3). Native: 6 runs × 10.
- Command-word checksums were identical across native, wasm64 and VIR. Example: create 1,000 = 36,000 words.
- Sources: [GR/leanui435/ops/LeanUIOps.lean](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/leanui435/ops/LeanUIOps.lean); [GR/results/ops](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/results/ops); [GR/harness/ops_agg.py](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/harness/ops_agg.py); [LeanUI tests/Perf.lean](/home/user/leanui/tests/Perf.lean)

*CI machine, to be re-measured on the reference Mac. Medians of per-load medians.*

| operation | native | Chromium wasm64 | Chromium VIR | ratio | release FF wasm64 | release FF VIR | ratio |
|---|--:|--:|--:|--:|--:|--:|--:|
| create 1,000 rows | 1.9–2.5 ms | 11.1 | 350 | **32×** | 7.6 | 415 | **55×** |
| replace 1,000 | 4.0–8.4 | 18.5 | 534 | **29×** | 24.8 | 578 | **23×** |
| update every 10th | 0.63–0.88 | 2.7 | 42.5 | **16×** | 5.1 | 54.6 | **11×** |
| select row | 0.25–0.28 | 2.0 | 23.6 | **12×** | 1.22 | 15.7 | **13×** |
| swap rows | 0.54–0.91 | 3.6 | 110 | **31×** | 3.5 | 79.8 | **23×** |
| remove row | 0.56–1.33 | 4.1 | 46.5 | **11×** | 3.6 | 48.3 | **14×** |
| clear 1,000 | 0.9–2.2 | 5.2 | 105 | **20×** | 3.9 | 93.8 | **24×** |
| create 10,000 | 30–44 | 72.9 | 3,698 | **51×** | 87.7 | 4,261 | **49×** |

(Native ranges span the quiet and loaded runs.)
- LeanUI's own reference numbers, from the reference Mac: natively "selecting a row costs Lean 0.08 ms … and creating 1,000 rows 0.63 ms", and in Chromium create-1,000 takes "3.81 ms of script" — [LeanUI docs/BENCHMARKS.md](/home/user/leanui/docs/BENCHMARKS.md)

### Inferences
- **Script time, worst case.** VIR's ratio on the full app (11–55×) sits between the vdom microbenchmark and the kernels. Applied to LeanUI's measured 3.81 ms of create script on the Mac, a VIR build would spend roughly 100–200 ms per create-1,000 click and over a second per create-10,000 click.
  - This is an upper bound: the applier's share of that 3.81 ms would not be multiplied.
- **What VIR is good for.** The interpreted path suits only Counter-sized apps and occasional light interactions. Even selecting a row costs 16–24 ms of Lean work, and removing one about 47 ms. It cannot replace wasm64 as LeanUI's main runtime. Its plausible role is a fallback where Memory64 is unavailable (Safari), as the integration note suggested.

### Gaps
- No DOM application or rendering was measured with VIR. That needs a `VirTransport` in `leanui.js`.
- No end-to-end click timings were taken.
- No Safari numbers, although Safari is the case VIR would serve.

## 5. Cold start: compile/instantiate, package load, first call vs warm call

### Takeaway
In Chromium, VIR is ready about **185 ms after the page script starts**, against 78 ms for compiled wasm32 and 103 ms for wasm64. Its first heavy call is also slow (vdom 168 ms against 16–18 ms compiled), so time to first useful result is about **3–4× compiled** (373 ms against 94–120 ms).
- VIR's wasm compile is cheap: a synchronous `new WebAssembly.Module` of 793 KB takes about 5 ms because Chromium compiles lazily.
- Most of VIR's startup is JavaScript: resource fetching, SHA-256 verification and package parsing in `runtime.js`, about 87 ms of self time.
- In release Firefox VIR is ready in 380 ms against 182–196 ms compiled.

### Cited Findings
**Method.** 10 cold loads per implementation and browser, each in a fresh browser process and context, interleaved, served from localhost with `Cache-Control: no-store`. "Ready" is measured from the harness's first script to the end of runtime creation and Lean initialization.
- Sources: [GR/results/cold](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/results/cold); [GR/harness/cold_agg.py](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/harness/cold_agg.py)

*Median [min–max] in ms, n = 10; CI machine, to be re-measured on the reference Mac*

| browser | impl | script start → ready | phases | first vdom call | warm vdom |
|---|---|--:|---|--:|--:|
| Chromium 141 | VIR | 184.5 [149–247] | app.json 16; `import(runtime.js)` 17; `createProgram` 154 [115–202], of which `new Module` + `new Instance` 5.5 [4.4–6.5] | 168 | 122 |
| | wasm32 | 78.2 [64–87] | load app.js 16; Emscripten factory 32 (`instantiateStreaming` 17.8); Lean init 28 | 15.8 | 4.3 |
| | wasm64 | 103.0 [87–124] | load app.js 20; factory 34 (`instantiateStreaming` 19.9); Lean init 47 | 18.1 | 6.9 |
| release Firefox 158 | VIR | 380 [271–547] | `createProgram` 263; sync compile + instantiate 24 | 245 | 170 |
| | wasm32 | 182 [152–228] | factory 101 (`instantiateStreaming` 94); Lean init 2.1 | 16.2 | 6.2 |
| | wasm64 | 196 [115–290] | factory 85 (`instantiateStreaming` 77); Lean init 2.0 | 20.7 | 9.8 |
| Playwright Firefox 142 | VIR | 435 [312–597] | sync compile 49 | 765 | 786 |
| | wasm32 | 163 [117–182] | `instantiateStreaming` 114 | 24 | 28 |

**Startup CPU profile in Chromium** (CDP sampling at 50 µs, 3 startup-only loads):
- `runtime.js` self time was 86.5–89.8 ms. The top functions were the resource fetch helper (about 20 ms) and `crypto.subtle.digest` SHA-256 verification (about 18 ms).
- Wasm (package installation and initializers) took only 13.5–18.5 ms. Browser-internal "(program)" took 80–96 ms.
- For comparison, `app.wasm` execution was 37–67 ms at wasm32 and wasm64 startup.
- Sources: [GR/results/prof](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/results/prof); [GR/harness/cpuprof.mjs](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/harness/cpuprof.mjs)

**VIR's loader behaviour.**
- Resources are fetched with `cache: "no-cache"`, and every member is SHA-256-verified before the wasm is instantiated.
- In my runs `runtime.js` was requested twice per load: once as the ES-module import, once as a verified payload.
- The facade "verifies every declared byte length and SHA-256", then "parses every member before Wasm instantiation".
- Sources: [VIR@web/src/resource-program.js](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/web/src/resource-program.js); [VIR@docs/guides/JS_API.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/guides/JS_API.md); own measurement (Resource Timing).

**Compile strategy differs by engine.** Chromium compiles lazily, so it reports a small compile and pays on first execution: Lean init 28–47 ms for compiled builds, and the first VIR call. Firefox compiles eagerly in `instantiateStreaming` (77–114 ms) and then initializes Lean in 2–3 ms. Own measurement.

**LeanUI's reference.** The production Bench page is "ready 25 ms after navigation …, of which 20.3 ms is compiling and instantiating the wasm, initializing Lean and the first render" on the reference Mac — [LeanUI docs/BENCHMARKS.md](/home/user/leanui/docs/BENCHMARKS.md)

### Inferences
- **Startup.** For a LeanUI-sized app in Chromium on this machine, VIR is ready about 80–105 ms later than compiled code, and its first vdom result arrives about 250 ms later. That covers integrity hashing, package parsing and a slow first call; the interpreter wasm itself is not the cost.
- **Startup is not the blocker.** It is tolerable compared with the steady-state slowdowns of §3–4.

### Gaps
- Startup was measured with the small benchmark package (17 members, 141 KB of IR), not LeanUI's 29-member, 662 KB Bench package. The LeanUI ops page's `createProgram` took 220–259 ms in Chromium and 294–363 ms in release Firefox (3 loads each), which suggests package size matters, but that was not cold-measured 10×.
- Network effects (latency, HTTP caching) were not measured: everything was served from localhost with caching disabled.

## 6. Download size and peak wasm memory

### Takeaway
- **Download.** VIR's fixed runtime cost is about **181 KB with brotli** (`runtime.wasm` 148 KB + `runtime.js` 32 KB), plus the app's IR packages. That makes a VIR app larger over the wire than the compiled build of the same code:
  - benchmark module: 205 KB against 112–116 KB (brotli);
  - LeanUI keyed-ops app: 266 KB against 165 KB.
- **Memory.** Comparable to wasm32 (26.5 against 24.3 MiB after the 4 MB pixel workloads). LeanUI's wasm64 build used the most (42.7 MiB).

### Cited Findings
**Download sizes** (raw / gzip -9 / brotli q11, bytes). Sources: [GR/harness/sizes.mjs](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/harness/sizes.mjs); own measurement.

| artifact | raw | gzip | brotli |
|---|--:|--:|--:|
| VIR `runtime.wasm` (pinned release) | 793,324 | 192,589 | 148,322 |
| VIR `runtime.js` (resource loader + runtime) | 129,504 | 36,898 | 32,327 |
| VIR benchmark program (17 `.irpkg` + set + manifests) | 141,115 | ≈28,200 | ≈24,100 |
| **VIR benchmark site, all fetched files** | 1,065,166 | 258,301 | 205,265 |
| wasm32 benchmark (`app.js` + `app.wasm`) | 733,605 | 149,747 | 115,541 |
| wasm64 benchmark (LeanUI path) | 722,836 | 144,092 | 111,756 |
| VIR LeanUI-ops site, all fetched files | 1,580,374 | 339,018 | 265,557 |
| … of which LeanUI-ops IR packages (29 members + set) | 650,587 | 107,046 | 82,733 |
| wasm64 LeanUI-ops (`app.js` + `app.wasm`, LeanUI path) | 1,276,278 | 234,218 | 165,108 |

- LeanUI's production Bench page transfers 1,220.33 KB uncompressed and 168.36 KB with brotli, including `leanui.js` and the page — [LeanUI docs/BENCHMARKS.md](/home/user/leanui/docs/BENCHMARKS.md)

**Wasm linear memory** (never shrinks, so the end value is the peak):
- At cold start: VIR 4.0 MiB, its build default. Compiled builds 16.0 MiB, LeanUI's `INITIAL_MEMORY`.
- After the full benchmark (4 MB image, three kernels, full checksums): VIR 26.5 MiB, wasm32 24.3 MiB, wasm64 42.7 MiB.
- After the LeanUI keyed ops, including create-10,000: VIR 27.5 MiB, wasm64 27.75 MiB.
- Sources: [GR/results/full](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/results/full); [GR/results/ops](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/results/ops)
- LeanUI's own figures: "16 MB of wasm memory at load, 27.75 MB after creating 10,000 rows" — [LeanUI docs/BENCHMARKS.md](/home/user/leanui/docs/BENCHMARKS.md)

### Inferences
- **Download.** VIR does not save bytes for LeanUI-sized apps. The interpreter alone (181 KB brotli) exceeds a whole compiled LeanUI app (about 110–165 KB brotli). IR packages compress well, about 8:1 with brotli, so the gap narrows only for very large apps, or for several apps sharing one cached runtime.
- **Memory.** VIR (wasm32) does not use less memory than compiled wasm32 code. It does use less than LeanUI's wasm64 build on pointer-heavy data: on the vdom-plus-kernels run, wasm64's heap ended 1.6× larger than VIR's (42.7 against 26.5 MiB).

### Gaps
- The JS heap was not compared reliably, because `performance.memory` is Chromium-only and coarse.
- Memory was not measured under LeanUI's real DOM workload.

## 7. LeanUI framework on VIR: `.irpkg` size and which externs/primitives the packager rejects

### Takeaway
A scratch copy of LeanUI moved to Lean 4.35 compiled with **no source changes**. The framework can then be packaged for VIR after two fixes to the core:
- `@[expose]` on `LeanUI.pushU32` and `LeanUI.appendUtf8`;
- a `vir_extern_fallback` for both in the entry module.

The Bench app's package is 29 members and **662 KB raw / 84 KB brotli** of IR, with `LeanUI.Diff` alone 266 KB. The photo-editor benchmark is rejected for 7 more primitives:
- 3 LeanUI inline-C helpers: `Editor.get32`, `set32`, `histAdd`;
- 4 missing catalog externs: `ByteArray.uset`, `ByteArray.usize`, `Float.toUInt8`, `Float.toInt64`.

Fallbacks for `uset`/`usize` package but run in quadratic time.

### Cited Findings
**Setup.** A `git archive` copy of LeanUI `7766c28` with `lean-toolchain` set to v4.35.0. `lake build LeanUI` succeeded unchanged. I added a Lean-side VIR host, `LeanUIVir.Host`, which collects flushes in an `IO.Ref` instead of the wasm64 host's `leanui_host_flush` C extern, plus per-app entry modules exporting `start`/`event`/`drain` with `JSL` handles — [GR/leanui435/vir](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/leanui435/vir)

**Rejections** (exact tool output, `lake build +LeanUIVir.<App>Program:vir`):
- **Counter and Bench:** `missing IR declarations after loading imported module IR: LeanUI.pushU32 … LeanUI.appendUtf8 (via … LeanUI.execCmd … LeanUI.Buf.fetchCmd …)`.
  - These are `@[extern c inline …]` defs in `LeanUI/Patch.lean`.
  - The first `vir_extern_fallback LeanUI.pushU32, LeanUI.appendUtf8` attempt failed with "extern `LeanUI.pushU32` has no transparent Lean definition body". The module system hides the body unless the def is `@[expose]`.
  - With `expose` added in the scratch copy ([diff](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/leanui435-Patch.diff)), both apps packaged.
- **EditorBench, beyond those two:**
  - missing IR: `Editor.get32`, `Editor.set32`, `Editor.histAdd`, which are inline-C pixel and histogram helpers;
  - missing native extern registrations: `ByteArray.usize` (via `Editor.Image.checksum`), `ByteArray.uset` (via `Editor.Png.filterRows`), `Float.toUInt8` (via `Editor.sobelRow`) and `Float.toInt64` (via `Editor.Adjust.fixedMatrix`).
- Report: [GR/leanui435/.lake/build/vir/programs/LeanUIVir/EditorBenchProgram.virprogram.report.md](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/leanui435/.lake/build/vir/programs/LeanUIVir/EditorBenchProgram.virprogram.report.md)
- **The documented fallback rules:** `vir_extern_fallback` "accepts only extern definitions with transparent kernel bodies. It rejects opaque/bodyless declarations …" — [VIR@docs/guides/PACKAGES.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/guides/PACKAGES.md)

**Package sizes** (module-set members in dependency order; raw / gzip / brotli):
- Counter: 30 members, 787 declarations (690 Lean IR, 97 native externs), 627,710 / 104,301 / 80,526 B.
- Bench: 29 members, 905 declarations (804 Lean IR, 101 native externs), 661,707 / 108,619 / 83,777 B.
- Largest members (bytes): `LeanUI.Diff` 265,564; `LeanUI.App` 102,908; `Bench` 55,417; `LeanUI.Patch` 49,651; `LeanUI.Effect` 38,575; `LeanUI.Keyed` 29,348; `LeanUI.Html` about 13,000.
- Init members are small. The largest are `Init.Data.OfScientific` (12,965) and the Float model (`…Operations.Div` 12,993).
- Source: [GR/leanui435/.lake/build/vir/module-sets/LeanUIVir](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/leanui435/.lake/build/vir/module-sets/LeanUIVir)

**The `uset`/`usize` fallback.** `vir_extern_fallback ByteArray.uset, ByteArray.usize` packaged the brightness kernel (3 members, 42 declarations). Its run time grows quadratically in Chromium (median of 3 runs):
- 4,000 bytes: 41.5 ms
- 8,000 bytes: 136 ms
- 16,000 bytes: 541 ms

The ordinary `get!`/`set!` lut pass runs at about 0.95 µs/byte in VIR — [GR/vbench/VBench/BrightFB.lean](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/vbench/VBench/BrightFB.lean); own measurement.

**A compiled-path problem on 4.35, not a VIR one.** Natively compiling the Editor modules' C on Lean 4.35 failed with `call to undeclared function 'lean_copy_byte_array'` from `Editor.set32`'s inline C. Moving LeanUI's compiled path to 4.35 would need that helper renamed (the compiler suggests `lean_copy_sarray`). Own measurement.

### Inferences
- **Fix for `uset`/`usize`.** The fallback is quadratic because `ByteArray.uset`'s Lean body goes through `⟨bs.uset …⟩`. That plausibly copies the whole array into an `Array UInt8` and back on every write: 2× the size gives 3.3–4.3× the time. This is an inference from the timings, not a profile. So for LeanUI's editor the fallback route is unusable, and `uset`/`usize` need real catalog entries.
- **Cost of a LeanUI VIR port.** The core framework needs only the two `expose`+fallback changes, and the Counter/Bench integration-note estimate holds. The editor needs either catalog additions (`uset`, `usize`, `Float.toUInt8`, `Float.toInt64`) or C providers for `get32`/`set32`/`histAdd`. That makes it a per-app VIR runtime build with wasi-sdk, and it would still run 40–200× slower (§3).

### Gaps
- I did not run TodoMVC, Site, Pixels or Video through the packager. Their extra externs (storage, fetch, `putImage`, downloads) are unknown.
- The `@[expose]` change was made only in a scratch copy, and I did not check whether it affects LeanUI's compiled code size or proofs.

## 8. Method, repetitions and reliability

### Takeaway
Steady-state numbers are medians of 3 fresh loads (2 for Playwright Firefox), and every implementation ran in the same interleaved rounds. Cold numbers are medians of 10 fresh browser processes. Ratios between implementations measured in the same round are robust to the machine's co-tenant load. Absolute milliseconds are not, and must be re-measured on the reference Mac.

### Cited Findings
**Repetitions.**
- Compiled implementations: 15 samples per load after 2 unmeasured calls, with fast operations batched to at least 10 ms per sample.
- VIR: 5 samples per load (Chromium and release Firefox) or 3 (Playwright Firefox).
- LeanUI ops: 10 samples per load, 3 loads.
- Cold: 10 loads.
- Native compiled: 12 runs × 15 samples. Native interpreter: 3–5 runs.
- Sources: [GR/harness/campaign.sh](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/harness/campaign.sh), [GR/harness/bench.js](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/harness/bench.js), [GR/results/full/loadavg.txt](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/browser-measurements/results/full/loadavg.txt)

**Noise.**
- Load average during the runs was 1.0–3.4, mostly from another researcher's single-job builds. The same native binary measured vdom at 1.86–3.12 ms and lut at 15.4–28.9 ms across six back-to-back runs, depending on that load.
- Per-load medians for VIR stayed within about ±20% of the median in Chromium (fib 474–624 ms around 521). In release Firefox they spread from −33% to +50% (rows 20.9–46.7 ms around 31.2; vdom 129–239 ms around 181).

**Timers and isolation.** Pages were cross-origin isolated (COOP/COEP), and timing used `performance.now()` around each JS→wasm call. VIR's figures include JS↔Lean marshalling, which is tiny here because the arguments are scalars or handles.

### Inferences
- The headline ratios are stable to within roughly ±30–50% on this machine (the release-Firefox VIR spread):
  - tree code 27–30× vs wasm32;
  - string/HashMap code about 42×;
  - kernels 86–217×;
  - LeanUI ops 11–55× vs wasm64.
- The ratios against native depend on which native run is used, so prefer the in-browser ratios.

### Gaps
- No measurements on the reference Mac.
- No Safari.
- No raw per-sample arrays were kept for the compiled runs (per-load median, min, max and quartiles only), so these are not formal confidence intervals.
- Large build intermediates (the Lean v4.35.0 source checkout) were deleted after use. The patch and scripts listed above reproduce them.
