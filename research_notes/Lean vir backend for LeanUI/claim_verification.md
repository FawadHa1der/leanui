# Claim verification: adversarial fact-check of the lean-vir research notes (as of 2026-10-20)

Scope and method:
- I re-checked the claims that a recommendation on three questions would rest on: (a) replacing LeanUI's Lean → C → Emscripten wasm64 backend with lean-vir, (b) adding lean-vir to LeanUI's benchmarks, and (c) the most durable wasm64 or wasm32 route for lean-vir.
- The claims come from the six notes in this folder: `lean_vir_project.md`, `upstream_lean_direction.md`, `wasm_platform_toolchains.md`, `execution_strategies_performance.md`, `leanui_integration_benchmarks.md` and `wasm64_port_feasibility.md`.
- Each claim was checked against primary sources, not the note's own citation:
  - git history: a treeless clone of `leanprover/lean4` master at `d2fb7694` (2026-10-20 13:53 UTC) with tags v4.15.0, v4.16.0-rc1, v4.29.0, v4.30.0-rc1, v4.30.0, v4.35.0 and v4.36.0-rc1; a bare clone of `ejgallego/lean-vir` with all branches; the `cauli/lean4` branches;
  - raw upstream files: `lean.h`, `EmitC.lean`, stage0 C, `ci.yml`, the Emscripten ChangeLog and `settings.js`, the wasi-sdk README, MDN browser-compat-data, `features.json`, WebKit preference and option files on main and on the Safari 27 branch, and V8 `flag-definitions.h`;
  - Apple's release-notes JSON, the Zulip archive pages and the FRO roadmap pages.
- The GitHub REST API and GitHub MCP were blocked for `leanprover/lean4` in this session, so PR state comes from git history plus the GitHub web pages.
- Verdicts are **CONFIRMED**, **CORRECTED** (with the correct value), **NUANCED** (true but misleading as stated) or **UNVERIFIABLE**.
- My own measurements are on a 4-vCPU Intel Xeon @ 2.80 GHz cloud VM with load average about 1.2. **CI machine, to be re-measured on the reference Mac.**
- Scratch directory: `/tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/claim-verification/`.

## Q1. Do the load-bearing claims survive an attempt to refute them? (claim-by-claim verdicts)

### Takeaway
Most hard facts hold. These are the PR dates and states, Emscripten and wasi-sdk statements, Chrome and Firefox versions, the SpiderMonkey and V8 facts, FRO quotes, the lean-vir size, maintainer, license and contract number, and the roadmap wording.

Six claims need correcting or qualifying:
1. **Safari:** Memory64 is off in stable Safari 27.0 and missing from the Safari 27.2 beta notes (Oct 13, 2026). But **WebKit trunk now ships it as a "stable" preference, on by default**, so `features.json`'s "flag" entry is stale.
2. **Third-party slowdowns:** the current README says **110–160× (median 108×), 7–9× and ~240×**, not 120–170×, ~10× and ~230×.
3. **Commit count:** 348 is the count on `main`; "482" counts all branches (475 in my clone).
4. **lean-vir CI:** **CI on `main` is red at the cited HEAD `81de859`.**
5. **Safari evidence:** a third-party report does show lean-vir running correctly in desktop Safari, which one note said was missing.
6. **Henrik Böving's "usually 10x":** it is an off-hand reply, not a measurement.

### Cited Findings

**Browsers and engines**

- **C1. Stable Safari / iOS Safari has no Memory64 (Oct 2026): CONFIRMED, with an important addition.**
  - Safari 27.0 was "Released September 14, 2026 — 27.0 (20625.1.29)". Its WebAssembly items are JSPI and Memory/Module cloning; Memory64 is absent. — [Safari 27 Release Notes](https://developer.apple.com/documentation/safari-release-notes/safari-27-release-notes)
  - On the Safari 27.0 source branch, JSC has `v(Bool, useWasmMemory64, false, … "Allow the Memory64 proposal for WebAssembly. This feature is currently only supported in the IPInt tier.")`. — [WebKit safari-7625.1.29.18-branch OptionsList.h](https://github.com/WebKit/WebKit/blob/safari-7625.1.29.18-branch/Source/JavaScriptCore/runtime/OptionsList.h)
  - The newest Safari notes are "Safari 27.2 Beta Release Notes — Released October 13, 2026 — 27.2 beta (20625.2.8)", for iOS/iPadOS/visionOS/macOS 27.2 beta. They have **no WebAssembly section at all**, so no Memory64. Apple has no "Safari 27.1" release-notes page (404). — [Safari 27.2 Beta Release Notes](https://developer.apple.com/documentation/safari-release-notes/safari-27_2-release-notes)
  - **Addition:** WebKit `main` now defines `WasmMemory64Enabled` with `status: stable` and `defaultValue: true` (jscOptionName `useWasmMemory64`). So trunk and Technology Preview builds have Memory64 on by default. The `features.json` entry `["flag", "Supported in Safari Technical Preview 251"]` lags this. — [WebKit main UnifiedWebPreferences.yaml](https://github.com/WebKit/WebKit/blob/main/Source/WTF/Scripts/Preferences/UnifiedWebPreferences.yaml); [features.json](https://github.com/WebAssembly/website/blob/main/features.json)
  - caniuse (read 2026-10-20) marks Safari "27" and "27.1 - TP" and iOS "27.0" and "27.1 - 27.2" as not supported; global usage is 73.55%. — [caniuse wf-wasm-memory64](https://caniuse.com/wf-wasm-memory64)
  - MDN BCD has `"safari": {"version_added": "preview"}` with `safari_ios` mirrored. — [MDN BCD webassembly/memory64.json](https://github.com/mdn/browser-compat-data/blob/main/webassembly/memory64.json)
  - Search snippets of WebKit Bugzilla show JSC Memory64 landing tier by tier: IPInt (Dec 2025), OMG `memory.grow`/`memory.size` (Apr 2026), SIMD (Jul 2026), multi-memory (Aug 2026). — [WebKit Bugzilla search results, e.g. bug 300538](https://bugs.webkit.org/show_bug.cgi?id=300538) (secondary, snippets only)
- **C2. Chrome 133, Firefox 134, Node 24.0 for Memory64: CONFIRMED.** — [MDN BCD](https://github.com/mdn/browser-compat-data/blob/main/webassembly/memory64.json); [features.json](https://github.com/WebAssembly/website/blob/main/features.json); [SpiderMonkey blog](https://spidermonkey.dev/blog/2025/01/15/is-memory64-actually-worth-using.html) ("has finally been released in both Firefox 134 and Chrome 133")
- **C3. Emscripten Memory64 flags: CONFIRMED.**
  - 6.0.13 (10/19/26): "`MEMORY64=2` was marked as deprecated. (#27952)".
  - 6.0.1 (06/22/26): "The `-sUSE_PTHREADS` and `-sMEMORY64` flags have been deprecated in favor of the more standard `-pthread` and `-m64` (or `--target=wasm64`) flags. (#27025)".
  - 6.0.0 (06/04/26): "The `-m64` compiler flag is now honored, and works as an alias for `-sMEMORY64` and/or `--target=wasm64`. (#26765)".
  - 3.1.72 (11/19/24): "The `MEMORY64` setting is no longer experimental".
  - `settings.js` marks `MEMORY64` `[deprecated]` and says "Nowadays we recommend using the more standard `-m64` or `--target=wasm64` flags".
  - Nuance: these are deprecations, not removals. LeanUI already compiles with `-m64`.
  - Sources: [Emscripten ChangeLog](https://github.com/emscripten-core/emscripten/blob/main/ChangeLog.md); [settings.js](https://github.com/emscripten-core/emscripten/blob/main/src/settings.js); [LeanUI TOOLCHAIN.md](/home/user/leanui/docs/TOOLCHAIN.md)
- **C4. wasi-sdk has no wasm64: CONFIRMED verbatim.** "64-bit linear memories (a "wasm64" target) are not supported at this time. Supporting this will require resolving WebAssembly/component-model#22 first at which point it will be possible to add a `wasm64-wasip2` target. There are no plans to add support for `wasm64-wasi{,-threads,p1,p1-threads}` at this time." — [wasi-sdk README](https://github.com/WebAssembly/wasi-sdk/blob/main/README.md)
- **C5. SpiderMonkey's Memory64 overhead: CONFIRMED.**
  - Quotes: "it can range from just 10% to over 100%"; "The only reason to use Memory64 is if you actually need more than 4GB of memory"; the JS API "constrains memories to a maximum size of 16GB". Ben Visness, 2025-01-15.
  - The post does not say which benchmarks produced the range.
  - Source: [SpiderMonkey blog](https://spidermonkey.dev/blog/2025/01/15/is-memory64-actually-worth-using.html)
- **C6. V8 Memory64 trap handling: CONFIRMED.**
  - `DEFINE_BOOL(wasm_memory64_trap_handling, true, "Use trap handling for Wasm memory64 bounds checks")` under `V8_TARGET_ARCH_ARM64 || X64 || RISCV64 || LOONG64`, read-only false elsewhere.
  - When the default flipped was not found.
  - Source: [V8 flag-definitions.h (main)](https://chromium.googlesource.com/v8/v8.git/+/refs/heads/main/src/flags/flag-definitions.h)
- **C20. LeanUI's own Memory64 cost: CONFIRMED.**
  - An allocation-heavy C workload took 13.5 ms as wasm32 vs 14.4 ms as wasm64 in Firefox 158 (1.07×), and 12.5 vs 14.2 ms in Chrome 155 (1.14×).
  - Source: [LeanUI docs/BENCHMARKS.md lines 472-474](/home/user/leanui/docs/BENCHMARKS.md)

**Upstream Lean**

- **C7. PR #6424: CONFIRMED.**
  - Commit `9a53c88e`, "chore: temporarily disable Web Assembly build in CI (#6424)", Kim Morrison, 2024-12-20.
  - It is an ancestor of `v4.16.0-rc1` but not of `v4.15.0`, so 4.15.0 was the last release that still had the wasm build.
  - Source: [PR #6424](https://github.com/leanprover/lean4/pull/6424) (git history of master and tags)
- **C8. The FRO statements on wasm: CONFIRMED, with nuances.**
  - Kim Morrison, Oct 14 2025: "WASM is no longer supported." It replies to Alexander Städing, who could find no release notes about WebAssembly support disappearing after v4.16. — [Zulip: wasm build](https://leanprover-community.github.io/archive/stream/270676-lean4/topic/wasm.20build.html)
  - Markus Himmel, Nov 28 2025: "we ran into an Emscripten limitation which would have taken a lot of engineering effort to overcome". Then: "The problem was that the build used `EXPORT_ALL` and we exceeded the limit of 10000 exported symbols". He corrected this on Dec 03 2025: "Sorry, that was a typo on my end. It's 100k."
  - Markus Himmel on a return: "this is a very high bar".
  - Sebastian Ullrich, Nov 28 2025: "The interpreter will use exported symbols to jump into native code."
  - Source for the last three: [Zulip: what is lean.js](https://leanprover-community.github.io/archive/stream/113488-general/topic/what.20is.20lean.2Ejs.html)
  - The FRO team page lists Kim Morrison as Senior Research Software Engineer and Julia Markus Himmel as Senior Tech Lead. — [Lean FRO team](https://lean-lang.org/fro/team/)
- **C9. LCNF compiler and C emission from LCNF since 4.30: CONFIRMED.**
  - `652ca9f5`, "refactor: port EmitC to LCNF (#12781)", Henrik Böving, merged 2026-03-11. First in `v4.30.0-rc1`, not in `v4.29.0`. `v4.30.0` is tagged 2026-05-26.
  - At v4.35.0, `LCNF/Main.lean` lines 211-212 still run `let irDecls ← IR.toIR decls` / `discard <| IR.compile irDecls`, so λRC IR is still produced and stored for the interpreter.
  - Sources: [PR #12781](https://github.com/leanprover/lean4/pull/12781); [LCNF/Main.lean @ v4.35.0](https://github.com/leanprover/lean4/blob/v4.35.0/src/Lean/Compiler/LCNF/Main.lean)
- **C10. Status of the interpreter changes: CONFIRMED, with an addition.**
  - **#15493** "perf: make variable access in IR interpreter branch free" (Böving) merged 2026-10-05. It is in `v4.36.0-rc1` (tagged 2026-10-14), not `v4.35.0`. Commit message: "makes the IR interpreter resize its stack frames correctly upon function entry". That fits the new `DeclInfo.maxJp/maxVar` frame-size fields at v4.36.0-rc1 (absent at v4.35.0), but I did not inspect the PR diff. — [PR #15493](https://github.com/leanprover/lean4/pull/15493); [IR/Basic.lean @ v4.36.0-rc1](https://github.com/leanprover/lean4/blob/v4.36.0-rc1/src/Lean/Compiler/IR/Basic.lean)
  - **#15444** "perf: faster interpreter" (hargoniX = Böving) is still an open draft, not on master at `d2fb7694`.
    - Bot results: `interpreted/iterators` instructions −44.79% and wall-clock −32.21% (Oct 3).
    - **Addition:** its "return a ref" idea landed separately as #15520 "perf: return a pointer into the ir cache", merged 2026-10-06.
    - Sources: [PR #15444](https://github.com/leanprover/lean4/pull/15444); [PR #15520](https://github.com/leanprover/lean4/pull/15520)
  - **#15557** "perf: bytecode interpreter" (Rob23oba, opened Oct 8 2026) is an open draft with "No description provided."
    - It has 28 commits, including "remove IR".
    - Bot results: `size/all/.ir` −141MiB (−37.93%), `size/libleanshared.so` +29MiB (+12.72%), `size/all/.c` lines +925.3k (+7.39%), build instructions −6.13%.
    - There are no maintainer comments; reviewers will be requested only when it leaves draft.
    - Source: [PR #15557](https://github.com/leanprover/lean4/pull/15557)
- **C18. `LEAN_SCALAR_PTR_LITERAL` is gated on `LEAN_EMSCRIPTEN` (v4.35.0 and v4.36.0-rc1): CONFIRMED, with an addition.**
  - At v4.35.0 (lines 3501-3505) and v4.36.0-rc1 (lines 3724-3727), the two-32-bit-halves form is chosen only `#ifdef LEAN_EMSCRIPTEN`.
  - **Addition:** the macro arrived with #12082 "feat: use static initializers where possible" (Böving, 2026-01-26), which statically initialises about 68% of 152,524 closed terms, including `Name` literals. That is after upstream stopped testing any 32-bit target. `EmitC.lean` line 432 emits it, and stage0 `Init/Prelude.c` uses it from line 1008 (`l_Lean_choiceKind___closed__1_value`).
  - Sources: [lean.h @ v4.35.0](https://github.com/leanprover/lean4/blob/v4.35.0/src/include/lean/lean.h); [lean.h @ v4.36.0-rc1](https://github.com/leanprover/lean4/blob/v4.36.0-rc1/src/include/lean/lean.h); [PR #12082](https://github.com/leanprover/lean4/pull/12082); [LCNF/EmitC.lean @ v4.35.0](https://github.com/leanprover/lean4/blob/v4.35.0/src/Lean/Compiler/LCNF/EmitC.lean); [stage0 Init/Prelude.c @ v4.35.0](https://github.com/leanprover/lean4/blob/v4.35.0/stage0/stdlib/Init/Prelude.c)
- **C19. Upstream's 32-bit and wasm CI jobs are disabled: CONFIRMED.**
  - `8ea6465e` "chore: CI: disable Linux 32bit (#7924)", Ullrich, 2025-04-12.
  - At v4.35.0, `ci.yml` has both "Linux 32bit" (line 421) and "Web Assembly" (line 432, `-m32` stage0, `-linux_wasm32`) commented out.
  - Sources: [PR #7924](https://github.com/leanprover/lean4/pull/7924); [ci.yml @ v4.35.0](https://github.com/leanprover/lean4/blob/v4.35.0/.github/workflows/ci.yml)

**lean-vir and related projects**

- **C11. lean-vir runtime size: CONFIRMED.**
  - I re-measured the SDK `wasm/vir-upstream.wasm` (sha256 `0b46452bf58183e4…`, SDK commit `225218e`, Lean 4.35.0): **793,324 B raw**, **148,322 B brotli q11** (= 148.3 kB = 144.8 KiB), 190,656 B with GNU `gzip -9` and 192,589 B with Node zlib level 9.
  - It has 87 exports (86 functions plus memory) and 14 imports.
  - Source: [lean-vir releases](https://github.com/ejgallego/lean-vir/releases); local file `/tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/vir/sdk/x/lean-vir-sdk/wasm/vir-upstream.wasm`
- **C12. Commits, maintainer, license and contract number: CONFIRMED, with corrections.**
  - `main` at `81de859` (2026-10-20 11:50 +0200, unchanged at time of check) has **348 commits**: 342 by Emilio J. Gallego Arias under three name/e-mail spellings, plus 6 by "Codex", the first on 2026-05-18.
  - All branches together hold 475 commits in my bare clone. The "482 commits" in `wasm64_port_feasibility.md` is an all-refs count, not `main`.
  - `NOTICE`: "Copyright (c) 2026 Lean FRO LLC… Released under Apache 2.0… Author: Emilio J. Gallego Arias".
  - FRO team page title: "Senior Research Software Engineer".
  - `vir-resources/compatibility.json` = `{"leanRevision": "eb6cafb7…", "virVersion": 7}`.
  - Sources: [lean-vir commits](https://github.com/ejgallego/lean-vir/commits/main); [NOTICE](https://github.com/ejgallego/lean-vir/blob/main/NOTICE); [compatibility.json](https://github.com/ejgallego/lean-vir/blob/main/vir-resources/compatibility.json); [Lean FRO team](https://lean-lang.org/fro/team/)
  - **Contract churn:** release titles show the compatibility/contract number moving 2 → 3 (Oct 7) → 6 (Oct 11) → 7 (Oct 19). That is four contract versions in 12 days. — [lean-vir releases](https://github.com/ejgallego/lean-vir/releases)
- **C13. lean-vir CI health: NOT STATED in the notes; current status is RED.**
  - The CI run on `main` for `81de859` ("feat: generate JSON-safe codecs for typed Lean values", Oct 20) failed in job `build-demo` with "Process completed with exit code 1". The step log was not visible.
  - The annotations note that `ubuntu-latest` moved to Ubuntu 26 on Oct 19, 2026, which is a possible, unconfirmed cause.
  - The last green `main` run was Oct 13 ("feat: support Lean 4.35.0 stable (#264)"). The 4.36.0-rc1 branch's CI also failed on Oct 20.
  - Sources: [lean-vir CI run 39403572375](https://github.com/ejgallego/lean-vir/actions/runs/39403572375); [CI runs on main](https://github.com/ejgallego/lean-vir/actions/workflows/ci.yml?query=branch%3Amain)
- **C14. lean-fir status: CONFIRMED, with a correction to its version.**
  - README: "Internal, non-official research workspace — not for external use… Do not depend on its code or artifacts, cite it as a reference implementation". It contains "a small-step interpreter for final impure LCNF" and "two executable LCNF-to-WebAssembly paths".
  - HEAD is `167c2a4` (2026-10-12).
  - The README says "pinned to Lean 4.34.0-rc2", but `lean-toolchain` says `leanprover/lean4:v4.34.1`, so the README is stale.
  - Source: [lean-fir](https://github.com/ejgallego/lean-fir)
- **C21. "No documented Safari testing" for lean-vir: CORRECTED.**
  - A third-party report ran lean-vir (Lean 4.34, lean-vir `cdba5ca`) in "the current Chrome, Firefox and Safari" inside module Workers in October 2026. All "121 of 121 points in each browser" matched independent checksums.
  - Limits stated there: "desktop browsers only, not a phone".
  - Source: [lean-math-in-the-browser REPORT.md §4.6, §4.10](https://github.com/joelcanary/lean-math-in-the-browser/blob/main/docs/REPORT.md)
  - lean-vir's newest binary feature is `extended-const`: Safari 17.4, Chrome 114, Firefox 112. — [features.json](https://github.com/WebAssembly/website/blob/main/features.json)

**Interpreter slowdown figures**

- **C15. Henrik Böving's "usually 10x": CONFIRMED as a quote, NUANCED as evidence.**
  - It is the whole of his reply (Dec 03 2025) to TongKe Xue's question "if we just went "all interpreter, no native code" how bad would the performance hit be? (10x? 100x?)". He gives no workload or measurement.
  - Source: [Zulip: what is lean.js](https://leanprover-community.github.io/archive/stream/113488-general/topic/what.20is.20lean.2Ejs.html)
- **C16. Sebastian Ullrich's "20x": CONFIRMED, NUANCED.**
  - Quote: "20x is definitely possible AFAIR" (2023-03-30), replying to Böving: "What speedup do we usually experienced with something purely compiled vs something purely interpreted?" It is a recollection with no workload, and it predates the LCNF compiler.
  - The "2% wall clock" precompilation result applied to a hard-coded set (`Aesop.*`, `Mathlib.Tactic.*`, `Mathlib.Mathport.Rename`).
  - Source: [Zulip: Status of precompilation](https://leanprover-community.github.io/archive/stream/270676-lean4/topic/Status.20of.20precompilation.html)
- **C17. Third-party "120–170×, ~10×, ~230×": CORRECTED.**
  - The current README says: "Loops and arrays run about 110–160× slower through lean-vir than compiled natively (median 108× over all measurable cases); where big-integer arithmetic dominates, the gap falls to about 7–9×". It also says multiplication is "~240× slower".
  - Measured on Lean v4.34.0 with lean-vir pinned at `cdba5ca`.
  - Source: [joelcanary/lean-math-in-the-browser README](https://github.com/joelcanary/lean-math-in-the-browser)

**Roadmaps**

- **C22. FRO roadmap browser statements: CONFIRMED.**
  - Year 4 Part 1 (Sep 2026–Feb 2027): "the Workbench, our zero-install web environment, is in beta testing with external users". There are no matches for browser, WebAssembly/wasm, interpreter or Lean Online Platform.
  - Its compiler section says "We will **not** invest in debugger infrastructure at this time".
  - Source: [FRO roadmap Y4-1](https://lean-lang.org/fro/roadmap/y4-1/)
  - Year 3: "We will also release an MVP for the Lean Online Platform as a web-only UI solution with secure sandboxing". — [FRO roadmap Y3](https://lean-lang.org/fro/roadmap/y3/)
  - A web search found no FRO announcement of in-browser Lean execution in 2026. — [search results incl. lean-math-in-the-browser](https://github.com/joelcanary/lean-math-in-the-browser)

### Inferences
- For decision (a), the facts that matter hold. lean-vir is a wasm32-wasip1, single-maintainer, FRO-copyright proof of concept with no compatibility promises. Upstream does not support wasm. LeanUI's path rests on Lean's main C backend.
- What changes is the time dimension of the Safari argument. Memory64 is on by default in WebKit trunk, so "Safari will never run LeanUI's wasm64" is too pessimistic. "Not before a 2027 Safari release" is the defensible statement (inference). Safari 27.0 supported Memory64 only in its in-place interpreter tier, so first-release JSC Memory64 performance is an open question to measure.
- For decision (b), the red CI and four contract bumps in 12 days argue for pinning an exact lean-vir commit and its matching runtime resource in any LeanUI benchmark harness.

### Gaps
- When WebKit flipped `WasmMemory64Enabled` to stable and default-on, and which Safari release will carry it. No Apple statement was found, and the Safari 27.2 beta notes are silent.
- Why lean-vir's `build-demo` CI job failed on `81de859`. The step log was not accessible through the web page.
- When V8's `wasm_memory64_trap_handling` became the default.
- PR descriptions and comments were read through the GitHub web UI only, because the REST API was blocked for `leanprover/lean4`.

## Q2. Contradiction 1: is wasm32 or wasm64 the durable target? Does a wasm32 interpreter need 32-bit oleans or a 32-bit stage0, and does recent upstream still work on 32-bit?

### Takeaway
**For lean-vir, wasm32 needs neither 32-bit oleans nor a 32-bit stage0 binary.** lean-vir's generator is a native 64-bit Lean program. It reads the host's ordinary 64-bit `.olean`/`.ir` module data, extracts `Lean.IR.Decl`s and writes a width-independent `.irpkg`. The only 32-bit artefacts are C/C++ sources compiled for wasm32: runtime, interpreter and about 20 stage0 C files. That is the same portable C every platform compiles.

The "32-bit stage0 and 32-bit oleans that nobody builds" argument in `upstream_lean_direction.md` is correct only for **running the full Lean frontend in the browser** (QED64 or cauli style), which loads `.olean`s.

Recent upstream still works on 32-bit:
- lean-vir's wasm32 runtime builds and tests green from unmodified v4.35.0 sources;
- cauli's wasm32 full-frontend fork tracks 4.33.1;
- upstream's code generator still deliberately keeps `USize` folding valid for both widths.

But 32-bit is untested upstream, and at least one width bug has slipped in: `LEAN_SCALAR_PTR_LITERAL` is keyed on Emscripten, not on pointer width. **wasm32 is the more durable target for a lean-vir backend.** The LP64 argument favours wasm64 only for olean-loading, whole-frontend builds.

### Cited Findings
**How lean-vir gets its IR (no 32-bit oleans)**
- The generator imports compiled modules with Lean's own readers. `CachedImports.lean` is described as "Lean 4.35.0's `importModulesCore` at exported level, with interpretation IR". It calls `readModuleDataParts (arts.oleanParts …)` and `readModuleDataParts arts.irParts`, then `finalizeImport`. It is built by Lake as `.lake/build/bin/vir_irpkg`, a host executable. — [Vir/Compiler/CachedImports.lean @ 81de859](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/Vir/Compiler/CachedImports.lean); [docs/reference/GENERATE_PACKAGE.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/reference/GENERATE_PACKAGE.md)
- The browser "does not load raw Lean module artifacts or construct a normal compiler `Environment`". — [UPSTREAM_BOUNDARY.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/reference/UPSTREAM_BOUNDARY.md)
- Width-dependent layout is resolved at run time, not baked into the IR:
  - the interpreter reads scalar fields at `sizeof(void*)*num_obj_fields` (`get_bool_field`, ir_interpreter.cpp line 86-87);
  - EmitC emits `sizeof(void*)*2 + 8`-style sizes plus the `LEAN_SCALAR_PTR_LITERAL` macro.
  - Sources: [ir_interpreter.cpp @ v4.35.0](https://github.com/leanprover/lean4/blob/v4.35.0/src/library/ir_interpreter.cpp); [stage0 Init/Prelude.c @ v4.35.0 line 1008](https://github.com/leanprover/lean4/blob/v4.35.0/stage0/stdlib/Init/Prelude.c)
- Empirical check: the same `fixtures-basic.irpkg` (857 decls) gave identical checksums on wasm32-wasip1, wasm32-emscripten and wasm64-emscripten builds. This comes from the other researcher's run, which I did not repeat. — [wasm64_port_feasibility.md §1](wasm64_port_feasibility.md)
- lean-vir itself documents only *semantic* width differences: "machine-word width can differ between a 64-bit host and Wasm32", so fixtures may declare distinct `host` and `wasm` expected values. — [EXAMPLES_AND_FIXTURES.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/development/EXAMPLES_AND_FIXTURES.md)

**Why upstream's old wasm32 build did need a 32-bit stage0**
- Alexander Bentkamp, Sep 09 2023: "The idea is to build a native 32 bit binary in stage0… we then use the native 32bit binary to build 32bit oleans and a wasm binary. That way, we can avoid building the oleans using the wasm binary, which would be much slower." On Dec 02 2023 he described the native 32-bit build as being for compiling "32-bit oleans for loading from wasm". — [Zulip: wasm build](https://leanprover-community.github.io/archive/stream/270676-lean4/topic/wasm.20build.html)
- The commented-out upstream job: "Build a native 32bit binary in stage0 and use it to compile the oleans and the wasm build". — [ci.yml @ v4.35.0](https://github.com/leanprover/lean4/blob/v4.35.0/.github/workflows/ci.yml)
- The olean header stores `size_t base_addr` (`static_assert(sizeof(olean_header) == 5 + 1 + 1 + 33 + 40 + sizeof(size_t))`), so oleans are pointer-width specific. — [module.cpp @ v4.35.0](https://github.com/leanprover/lean4/blob/v4.35.0/src/library/module.cpp)

**Does recent upstream code still work on 32-bit?**
- **Upstream codegen keeps both widths in mind (new evidence):**
  - #13974 (2026-06-08) folds `USize` relations "by evaluating them both in the `UInt32` and `UInt64` world and applying the fold if both worlds agree".
  - #13991 (2026-06-11) does the same for `USize` arithmetic.
  - #15277 (2026-09-27, in v4.36.0-rc1) relaxes this "in order for a `USize` literal to be interpreted the same on both platform widths", with a Lean proof over `System.Platform.numBits = 32 ∨ 64`.
  - Sources: [PR #13974](https://github.com/leanprover/lean4/pull/13974); [PR #13991](https://github.com/leanprover/lean4/pull/13991); [PR #15277](https://github.com/leanprover/lean4/pull/15277)
- **lean-vir:**
  - CI on `main` was green on 2026-10-13 for "feat: support Lean 4.35.0 stable (#264)".
  - The other researcher's from-source wasm32-wasip1 build of 81de859 passed 21/21 "pure" runtime tests.
  - lean-vir has had a "test: cover wasm32 target semantics (#136)" suite since 2026-08-21.
  - Sources: [CI runs on main](https://github.com/ejgallego/lean-vir/actions/workflows/ci.yml?query=branch%3Amain); [wasm64_port_feasibility.md §3](wasm64_port_feasibility.md); [commit d32d057](https://github.com/ejgallego/lean-vir/commit/d32d057)
- **cauli's wasm32 full-frontend fork:**
  - `reinstate-wasm` was last pushed 2026-09-06 ("Emscripten: native wasm exceptions, accept same-source oleans").
  - Branch `wasm-upstream-4.33.1` was last pushed 2026-09-10.
  - It still builds a native i386 stage for 32-bit oleans: commit `9601121` "fix: install i386 OpenSSL for browser Mathlib build", 2026-08-01.
  - Sources: [cauli/lean4 reinstate-wasm](https://github.com/cauli/lean4/commits/reinstate-wasm); [commit 63689d5](https://github.com/cauli/lean4/commit/63689d5); [commit 9601121](https://github.com/cauli/lean4/commit/9601121)
- **A 32-bit regression upstream did not catch:**
  - The static-literal macro from #12082 (Jan 2026) picks the 32-bit layout only under `LEAN_EMSCRIPTEN`. A non-Emscripten 32-bit target such as wasm32-wasip1 (lean-vir) gets the 64-bit arm, truncated into one 4-byte slot.
  - The other researcher's wasi-sdk test read `stored-hash=0x0000000044332211` instead of `0x8877665544332211`. They found no such literal linked into the 81de859 binary.
  - The files lean-vir compiles contain these literals. I counted Prelude.c 16, Init/Data/Array/Basic.c 22, Init/Meta/Defs.c 82, Lean/Level.c 21 and Lean/Expr.c 113 in the v4.35.0 sources; `wasm64_port_feasibility.md` omitted Array/Basic.c.
  - Sources: [lean.h @ v4.35.0](https://github.com/leanprover/lean4/blob/v4.35.0/src/include/lean/lean.h); [PR #12082](https://github.com/leanprover/lean4/pull/12082); [wasm64_port_feasibility.md §1](wasm64_port_feasibility.md)

**Durability inputs for the browser target**
- wasi-sdk has "no plans" for wasm64 p1. Emscripten deprecated `MEMORY64=2`, the wasm64-on-wasm32-engines mode, on 2026-10-19. Stable Safari and iOS lack Memory64 (Q1, C1, C3, C4).
- On a 64-bit host, wasm32 boxes `UInt32` on the heap: `lean_box_uint32` does `if (sizeof(void*) == 4) { … lean_alloc_ctor(0, 0, sizeof(uint32_t)) …`. That is a real wasm32 performance cost for UInt32-heavy kernels, not a correctness issue. — [lean.h @ v4.35.0 lines 3095-3098](https://github.com/leanprover/lean4/blob/v4.35.0/src/include/lean/lean.h)

### Inferences
- **Resolution:** both notes are right about different things.
  - `upstream_lean_direction.md`'s "wasm32 needs 32-bit stage0/oleans nobody builds" applies to an in-browser **frontend**. QED64 needs LP64 for that reason, and cauli's wasm32 fork pays for it with an i386 build.
  - It does **not** apply to lean-vir, which loads no oleans in the browser.
  - `wasm_platform_toolchains.md` and `wasm64_port_feasibility.md` are right that wasm32 is the durable lean-vir target through at least 2027: reach, toolchain and performance (the other note measured wasm64 at 1.1–1.35× slower).
- **The residual wasm32 risk** is "upstream does not test 32-bit, so width bugs can land silently" (the #12082 macro is the proof). The mitigation is lean-vir's own wasm32 CI, plus reporting the macro's `UINTPTR_MAX` fix upstream. The fix is QED64's patch 0003; the upstream PR would be about one line (an inference about effort).
- For LeanUI's **AOT** path the LP64-match argument is also weak. EmitC output is width-portable and Emscripten defines `LEAN_EMSCRIPTEN`. LeanUI is on wasm64 because its QED64 runtime archives are wasm64, not because generated C needs LP64.

### Gaps
- I did not rebuild lean-vir to confirm the latent scalar-literal bug or its absence from the linked binary. I rely on the other researcher's test plus my source counts.
- No upstream maintainer statement on whether 32-bit (non-Emscripten) remains an intended target. The width-agnostic `USize` folding implies it does; the disabled CI implies it is untested.

## Q3. Contradiction 2: why the interpreter-slowdown figures diverge (10×, 20×, 22–254×, 110–160×)

### Takeaway
The figures measure different things:
1. **Informal remarks**: Böving's "usually 10x" and Ullrich's "20x… AFAIR", neither tied to a workload.
2. **Native interpreter vs native compiled code**, which depends strongly on workload:
   - about 22–49× for allocation-, string- and HashMap-heavy UI work;
   - about 100–140× for call-heavy recursion;
   - 55–254× for scalar and byte loops.
3. **Browser lean-vir vs native compiled code**: 110–160× for loops and arrays, 7–10× when bignum work dominates.

Running the interpreter as wasm32 in V8 adds only about 1.3–1.5× on top of the native interpreter in my measurement. Workload type and the choice of baseline drive most of the spread, not the browser.

The lean-vir author's own five-backend comparison against a **Lean → C → Emscripten** module (LeanUI's route) puts the interpreter at **69–108× slower on loop and array workloads** and about 10× on bignum workloads in Node.

### Cited Findings
**My decomposition (one workload, four execution modes)**
- Workload: `fib(25)` three times, as three separate un-CSE-able calls, using the same definition as lean-vir's `fixtures-basic` `fib`. Lean v4.35.0 (`eb6cafb7`); **CI machine, to be re-measured on the reference Mac**.

| Mode | Median per sample | vs compiled |
|---|--:|--:|
| `leanc -O3` compiled, native | 2.83–2.90 ms | 1× |
| `lean --run` (interpreter, stdlib native) | 293 ms | ≈101–104× |
| `lean --run -Dinterpreter.prefer_native=false` (lean-vir's setting) | 396 ms | ≈136–140× |
| lean-vir wasm32-wasip1 interpreter, Node 22.22 (V8 12.4) | 514 ms | ≈177–182× |
| lean-vir wasm32-wasip1, Chromium 141 (other researcher's run, same package) | 581–593 ms | ≈200–210× |
| lean-vir wasm32-wasip1, Playwright Firefox 142 (other researcher's run) | 3,018 ms | not representative |

  - The wasm interpreter costs 1.30× the native interpreter in Node and 1.47–1.50× in Chromium (both with `prefer_native=false`).
  - Sources: `/tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/claim-verification/fibbench/Fib.lean` and `vir-fib.mjs`, which ran the unmodified 81de859 JS with the 81de859 wasm32 build and `fixtures-basic.irpkg` from `gap-research/wasm64-port`; [wasm64-port bench-browsers.jsonl](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/artifacts/bench-browsers.jsonl)
  - LeanUI's docs say Playwright's Firefox "runs wasm about 8× slower than release Firefox 158, for any wasm". — [docs/BENCHMARKS.md line 466](/home/user/leanui/docs/BENCHMARKS.md)
- **Pitfall found while measuring.** My first version computed `fib m + fib m + fib m`. LCNF's CSE merged the three calls, which made both the compiled and the interpreted timings 3× too fast (compiled 0.99–1.08 ms, interpreted 99 ms). Benchmarks that repeat a pure call need opaque inputs. The earlier `interp-bench/Bench.lean` already does this (`fib (27 + seed % 1 + b % 1)`), so its numbers are not affected. — `/tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/interp-bench/Bench.lean` line 58

**How the published and measured figures line up**
- **Native interpreter vs compiled, both earlier notes (Lean 4.34):**
  - vdom build+diff: 22–29×
  - js-framework-style rows (UInt64 LCG, strings, `mixHash`, `Std.HashMap`): 35–49×
  - `fib 27`: 119–125×
  - byte and pixel loops: 55–254×
  - My 4.35 fib (101–140×) agrees with the `fib 27` row.
  - Sources: [execution_strategies_performance.md Q1](execution_strategies_performance.md); [leanui_integration_benchmarks.md §3](leanui_integration_benchmarks.md)
- **Browser lean-vir vs native compiled (third party; Lean 4.34; lean-vir `cdba5ca`):** "about 110–160× slower… (median 108× over all measurable cases); where big-integer arithmetic dominates, the gap falls to about 7–9×". — [lean-math-in-the-browser README](https://github.com/joelcanary/lean-math-in-the-browser)
- **The lean-vir author's own five-backend Node campaign (2026-09-29, Lean 4.34.1):**
  - Setup: Node 24.21.0 / V8 13.6 on a Ryzen AI 9 HX 370, load uncontrolled. The "C/Wasm" backend is "Emscripten 5.0.3, the exact 4.34.1 unthreaded Lean runtime, Init/Std and libuv archives, `-O3` and LTO" (1,330,189 B).
  - Medians in ms, with ratios I computed:

| workload | Native | VIR | C/Wasm | VIR ÷ C/Wasm | C/Wasm ÷ Native |
|---|--:|--:|--:|--:|--:|
| Tunnell 1,000,003 | 10.26 | 751.76 | 9.43 | 79.7× | 0.92 |
| Collatz 100,000 | 43.34 | 5,565.76 | 63.12 | 88.2× | 1.46 |
| prime sieve 10⁶ | 10.56 | 1,337.39 | 12.41 | 107.7× | 1.18 |
| Mertens 10⁶ | 36.82 | 4,055.87 | 58.54 | 69.3× | 1.59 |
| Life 100 | 34.59 | 3,489.37 | 33.53 | 104.1× | 0.97 |
| partitions 3,000 | 14.87 | 149.49 | 15.20 | 9.8× | 1.02 |
| Miller–Rabin 127 bits | 0.636 | 3.339 | 1.402 | 2.4× | 2.20 |
| fib, decimal 10,000 | 1.826 | 2.732 | 5.811 | 0.47× | 3.18 |

  - Sources: [FIR-UPDATE-20260929.md (ejgallego/lean-math-in-the-browser, branch research/vir-fir-report)](https://github.com/ejgallego/lean-math-in-the-browser/blob/research/vir-fir-report/docs/FIR-UPDATE-20260929.md); [EVALUATION-4341-20260928.md](https://github.com/ejgallego/lean-math-in-the-browser/blob/research/vir-fir-report/docs/EVALUATION-4341-20260928.md)
- **Why bignum work narrows the gap:** both sides spend their time in native `mpn`/`mpz` code. lean-vir and Emscripten builds lack GMP, so their bignums are slow everywhere ("multiplication itself is ~240× slower because lean-vir's runtime uses Lean's portable big-number fallback"). — [lean-math-in-the-browser README](https://github.com/joelcanary/lean-math-in-the-browser)
- **wasm32 boxing:** on wasm32 `lean_box_uint32` heap-allocates. Every interpreted native call boxes its arguments ("always call the 'boxed' versions of native functions"). UInt32-heavy LeanUI kernels (`pushU32`, pixel ops) therefore pay an allocation per operand in lean-vir. Native x86-64 host measurements do not show this cost. — [lean.h @ v4.35.0](https://github.com/leanprover/lean4/blob/v4.35.0/src/include/lean/lean.h); [ir_interpreter.cpp @ v4.35.0](https://github.com/leanprover/lean4/blob/v4.35.0/src/library/ir_interpreter.cpp)
- **The developer remarks:**
  - Böving: "usually 10x", in reply to "(10x? 100x?)".
  - Ullrich: "20x is definitely possible AFAIR", in 2023, and also: "only" around 10% of the mathlib4 build is spent in the interpreter.
  - In normal Lean (`prefer_native` true) interpreted meta-code spends much of its time in natively compiled Lean libraries and the runtime, which shrinks the ratio.
  - Sources: [Zulip: what is lean.js](https://leanprover-community.github.io/archive/stream/113488-general/topic/what.20is.20lean.2Ejs.html); [Zulip: Status of precompilation](https://leanprover-community.github.io/archive/stream/270676-lean4/topic/Status.20of.20precompilation.html)

### Inferences
**Explaining the spread, roughly in order of size:**
1. **Workload mix.**
   - Allocation- and string-heavy code (22–49×) hides interpreter overhead behind native allocator, RC and string work.
   - Call-heavy and scalar code (100–250×) does not: every operation is a symbol lookup, boxing and an indirect call.
   - Bignum-dominated code (7–10×) spends nearly all its time in native code.
2. **Baseline.** The 10× and 20× remarks are informal, about mixed meta-code with a native stdlib. The 100×+ figures interpret the stdlib too (`prefer_native=false`, as lean-vir does) or use tight loops.
3. **wasm vs native interpreter.** About 1.3–1.5× in V8 on this workload. That is smaller than `execution_strategies_performance.md`'s assumed "1.5–3× floor", but it confirms that the native ratios are a floor for the browser.
4. **32-bit boxing.** This matters only for UInt32-heavy code, so it hits LeanUI's buffer encoding and pixel kernels but not fib.
5. **Measurement artefacts.** CSE can make results 3× off, as can Lean version (4.34 vs 4.35), machine load and 1–2-sample runs. Treat every single ratio as ±15–20%.

**For LeanUI:**
- The C/Wasm column is LeanUI's route, minus the 1.07–1.14× Memory64 cost.
- For LeanUI-style loop, array, diff and encode code, the best current estimate is that lean-vir would be **about 70–110× slower than today's compiled wasm**. For string-, HashMap- or DOM-dominated update paths it would be **about 25–50×**.
- That supports `execution_strategies_performance.md`'s conclusion: lean-vir is not a replacement for hot paths. It also supports measuring create-1k and select-row before assuming the keyed suite stays usable.

### Gaps
- No lean-vir measurement exists on a LeanUI-shaped package (update/view/diff/encode IR). My fib is a call-heavy microbenchmark.
- No Safari or JSC timings of lean-vir from this machine. The third-party Safari numbers cover arithmetic and call cost only.
- The author's five-backend data comes from one host with uncontrolled load, on a research branch, and is not reproduced. Its C/Wasm build is wasm32 Emscripten 5.0.3, not LeanUI's wasm64 Emscripten 6.0.5.

## Q4. Contradiction 3: size, version and count discrepancies between the notes

### Takeaway
Every numeric discrepancy has a mundane cause: different compressors, different artefacts, different commits or branches, or a stale README. None changes a conclusion. The ones worth fixing in a report are the third-party slowdown figures, the commit count, the manifest version and lean-fir's pinned version.

### Cited Findings
| Item | Values in the notes | Verified value and cause | Source |
|---|---|---|---|
| runtime.wasm gzip | 190,656 / 190,685 / 192,589 B | All correct. GNU `gzip -9` gives 190,656; Python gzip gives 190,685; Node zlib level 9 gives 192,589. Raw 793,324 and brotli q11 148,322 agree everywhere. "148 KB" and "about 145 KiB" are the same number in kB and KiB. | local re-measurement of the SDK wasm, sha256 `0b46452b…`; [lean-vir releases](https://github.com/ejgallego/lean-vir/releases) |
| From-source wasm32 build | 793,420 B (wasm64 note) vs 793,324 B (SDK) | Different build commits (81de859 vs SDK 225218e) of the same runtime; within 96 B. | [wasm64_port_feasibility.md §3](wasm64_port_feasibility.md) |
| JS runtime size | 129,504 B / 227,313 B / 128,020 B | Three artefacts: `runtime.js` in the `.virres` pack; all JS files in the SDK tarball; the hosted `browser-packages-*.js` bundle. | [lean_vir_project.md §2](lean_vir_project.md); [execution_strategies_performance.md Q5](execution_strategies_performance.md); [leanui_integration_benchmarks.md §3](leanui_integration_benchmarks.md) |
| Export count | 87 exports vs 85 functions | 87 = 86 functions + `memory` (`WebAssembly.Module.exports`, my count). "85" counts functions common to the wasm32 and wasm64 builds. | local count on the SDK wasm |
| Commit count | 348 vs 482 | 348 on `main` (342 Gallego Arias + 6 Codex). Today all branches together hold 475; 482 was an all-refs count at another moment. | [lean-vir commits](https://github.com/ejgallego/lean-vir/commits/main) |
| Manifest version | 13 (upstream note) vs 12 | SDK 4.35 metadata (commit 225218e, Oct 13) says `"manifestVersion": 12`; HEAD 81de859 has `INTERFACE_MANIFEST_VERSION = 13`. Both correct for their commit. `packageFormatVersion` 11 in both. | [web/src/runtime/interface-manifest.js @ 81de859](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/web/src/runtime/interface-manifest.js) |
| Third-party slowdowns | 120–170×, ~10×, ~230× | Current README: 110–160× (median 108×), 7–9×, ~240×. The note's figures are stale or from the ejgallego fork's older README. | [lean-math-in-the-browser](https://github.com/joelcanary/lean-math-in-the-browser) |
| lean-fir Lean version | "4.34.x" / "4.34.0-rc2" | `lean-toolchain` = v4.34.1 (HEAD 167c2a4, 2026-10-12); the README's "4.34.0-rc2" is stale. | [lean-fir](https://github.com/ejgallego/lean-fir) |
| Safari 27 date | Sep 14 (secondary) vs Sep 17 (WebKit post) | Apple: "Released September 14, 2026 — 27.0 (20625.1.29)". The WebKit features post came three days later. | [Safari 27 Release Notes](https://developer.apple.com/documentation/safari-release-notes/safari-27-release-notes) |
| Markus Himmel export limit | "100k" | The first message said "10000", corrected the same week to "It's 100k". | [Zulip: what is lean.js](https://leanprover-community.github.io/archive/stream/113488-general/topic/what.20is.20lean.2Ejs.html) |
| Release packs | 1,011,875–1,120,065 B vs 1,026,112 B | Different resources. 1,026,112 B is the compat-7 `ab3614c1` pack (published Oct 19); the listed sizes are compat 2/3/6 packs. | [lean-vir releases](https://github.com/ejgallego/lean-vir/releases) |
| "VIR adopts each Lean release within days" | — | Mostly true: 4.31 +5 days, 4.32 +10, 4.33 +4, 4.34 +8, 4.35 +1, 4.36.0-rc1 branch +6. But 4.30.0 (released 2026-05-26) was adopted 2026-06-15, +20 days. | [lean_vir_project.md §5](lean_vir_project.md); [upstream_lean_direction.md](upstream_lean_direction.md) release index; tag dates from git |

### Inferences
- No discrepancy undermines a recommendation. The report should quote the brotli figure (148,322 B) as the transfer-size number, and "348 commits on main" for activity.

### Gaps
- I could not determine which README revision produced "120–170×". The ejgallego fork of lean-math-in-the-browser was not diffed.

## Q5. What the notes missed that changes the picture

### Takeaway
Five things the notes did not have change the picture:
1. **WebKit trunk has Memory64 on by default ("stable")**, although Safari 27.0 shipped it off, interpreter-tier only, and 27.2 beta does not list it.
2. **The lean-vir author has measured VIR against a Lean → C → Emscripten module** (69–108× slower on loops and arrays) and against his compiled FIR backend (within about 1–3× of native on several workloads), in a public research branch.
3. **lean-vir already absorbed Lean 4.36.0-rc1's IR change without a format bump**, which weakens the "IR churn will break .irpkg" argument for small changes.
4. **lean-vir's CI on `main` is red** at the commit every note cites.
5. **Upstream's codegen explicitly preserves 32/64-bit portability**, which supports wasm32 for lean-vir.

### Cited Findings
- **Safari Memory64 on WebKit trunk:**
  - `WasmMemory64Enabled: status: stable … defaultValue: true` on WebKit `main`, against `useWasmMemory64` default `false`, "only supported in the IPInt tier", on the Safari 27.0 branch.
  - Safari 27.2 beta (Oct 13, 2026) has no WebAssembly entries.
  - Sources: [WebKit main UnifiedWebPreferences.yaml](https://github.com/WebKit/WebKit/blob/main/Source/WTF/Scripts/Preferences/UnifiedWebPreferences.yaml); [WebKit safari-7625.1.29.18-branch OptionsList.h](https://github.com/WebKit/WebKit/blob/safari-7625.1.29.18-branch/Source/JavaScriptCore/runtime/OptionsList.h); [Safari 27.2 Beta Release Notes](https://developer.apple.com/documentation/safari-release-notes/safari-27_2-release-notes)
- **The author's VIR vs FIR vs C/Wasm data (Sept 2026):**
  - "In his Node measurements, Tunnell, Collatz, the sieve and Life run within about 1–3× of native Lean instead of 100× and more". FIR "is not public".
  - In the author's own table, FIR is 9.37× C/Wasm on Mertens and 52.8× C/Wasm on 127-bit Miller–Rabin. So the Lean → C → Emscripten route beats FIR everywhere except decimal fib.
  - Sources: [lean-math-in-the-browser REPORT.md, update of 3 Oct 2026](https://github.com/joelcanary/lean-math-in-the-browser/blob/main/docs/REPORT.md); [FIR-UPDATE-20260929.md](https://github.com/ejgallego/lean-math-in-the-browser/blob/research/vir-fir-report/docs/FIR-UPDATE-20260929.md)
- **4.36.0-rc1 absorbed without a format change:**
  - lean-vir branch `feat/lean-436-rc1` (`dd90fb0` "feat: support Lean 4.36.0-rc1", 2026-10-20) moves the toolchain to v4.36.0-rc1 and `leanRevision` to `c9afcddf…`, keeping `virVersion: 7`.
  - It changes 36 files, +450/−101. The decoder now reconstructs `DeclInfo` "frame bounds from every variable and join-point identifier… Bounds… are not duplicated in the wire format; the interpreter receives `sorryDep? = none`, `maxJp` and `maxVar` in the pinned compiler's field order".
  - It landed 6 days after the rc1 tag.
  - Sources: [lean-vir branch feat/lean-436-rc1](https://github.com/ejgallego/lean-vir/tree/feat/lean-436-rc1); [IRPKG_FORMAT.md diff on that branch](https://github.com/ejgallego/lean-vir/blob/feat/lean-436-rc1/docs/reference/IRPKG_FORMAT.md)
- **Other new lean-vir data points:**
  - lean-vir `main` at `e92d95d` made "small calls about 27 % cheaper and starting the runtime about 18 % faster; long computations do not change".
  - Starting the runtime in Chrome takes "55 ms at full CPU speed" from worker creation to first answer.
  - A small call costs about 2 µs, about 1.9 µs in Safari.
  - Source: [lean-math-in-the-browser REPORT.md](https://github.com/joelcanary/lean-math-in-the-browser/blob/main/docs/REPORT.md)
- **Red CI:** `main` at `81de859` failed CI in `build-demo` on 2026-10-20. — [run 39403572375](https://github.com/ejgallego/lean-vir/actions/runs/39403572375)
- **Width-portable codegen:** #13974, #13991 and #15277 (Jun–Sep 2026) check `USize` folds in both the 32- and 64-bit worlds. — [PR #15277](https://github.com/leanprover/lean4/pull/15277)
- **Bytecode draft #15557 shifts weight from `.ir` to native code:** `.ir` −37.93%, `libleanshared.so` +12.72%, `.c` lines +7.39%. — [PR #15557](https://github.com/leanprover/lean4/pull/15557)
- **lean-fir** contains "a small-step interpreter for final impure LCNF", by the same FRO engineer. — [lean-fir README](https://github.com/ejgallego/lean-fir)
- **Not found:** no new lean-vir release beyond the compat-7 runtime resource of Oct 19 and tag `4.35` (Oct 13); no FRO announcement on in-browser execution; no Safari release with Memory64. — [lean-vir releases](https://github.com/ejgallego/lean-vir/releases); [FRO roadmap Y4-1](https://lean-lang.org/fro/roadmap/y4-1/)

### Inferences
**(a) Replace LeanUI's backend with lean-vir?**
- The author's own data strengthens the case against. The interpreter is about 70–110× slower than an Emscripten Lean → C module on loop and array code.
- The Safari argument for switching weakens over time: WebKit trunk already enables Memory64. The likely state in 2027 is "LeanUI's wasm64 runs in Safari", although Safari's first Memory64 tiers may be slow (inference).
- Keep the server-driven fallback until a stable Safari ships it.

**(b) Add lean-vir to LeanUI's benchmarks?**
- Still worthwhile, and cheaper than the notes imply: lean-vir runs in desktop Safari, so a three-engine comparison is possible.
- Pin an exact lean-vir commit and runtime resource; contract churn and the red CI are the operational risks.
- Include a call-cost probe and a UInt32-heavy kernel to capture the wasm32 boxing cost.

**(c) Durable route:**
- wasm32-wasip1 lean-vir stays the durable lean-vir route. There is no 32-bit olean or stage0 burden.
- Small IR changes have been absorbed without a wire-format bump.
- The one structural threat is #15557-style bytecode that moves interpretable code out of `.ir`/olean IR. lean-vir's extract-IR-from-oleans design would then need rework. That PR is a community draft with no maintainer engagement (inference on impact).
- A wasm64 lean-vir remains Emscripten-only and has no Safari reach until a stable Safari ships Memory64.

### Gaps
- Whether #15557's bytecode would be stored in `.ir`/oleans, in which case lean-vir could re-target it, or compiled into C/shared libraries. Its description is empty.
- FIR is not public, so its numbers cannot be reproduced. Whether the FRO intends FIR or VIR as a deliverable is unstated.
- Exact Safari Memory64 ship version and date. Performance of JSC Memory64 outside the IPInt tier in shipping Safari.
