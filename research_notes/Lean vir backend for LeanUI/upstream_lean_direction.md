# Upstream Lean 4 compiler and WebAssembly direction (as of 2026-10-20)

Scope notes for the report writer:
- "Official" means a Lean FRO / leanprover statement, a merged leanprover/lean4 change, or a release note. "Community" means a fork or third-party repo. "Inference" is labelled as such.
- Facts marked "(verified in source)" were read in the Lean source, either from raw files fetched from upstream tags (lean.h, IR/Basic.lean, ir_interpreter.cpp, CMakeLists.txt, module.cpp) or from the local checkout of the QED64 fork at `/home/user/leanui/.toolchain/lean4-fork` (commit 53cb11e, 2026-10-15, upstream v4.34.0 plus the wasm patches). The fork's wasm patches do not touch the compiler files cited.
- Release dates (official, from the reference manual's release index): 4.22.0 2025-08-14; 4.26.0 2025-12-13; 4.28.0 2026-02-17; 4.30.0 2026-05-26; 4.31.0 2026-06-13; 4.32.0 2026-07-13; 4.33.0 2026-08-10; 4.34.0 2026-09-14; 4.34.1 2026-09-24; 4.35.0 2026-10-12; 4.36.0-rc1 2026-10-14. Source: [Lean release index](https://lean-lang.org/doc/reference/latest/releases/)

## Q1. What changed in the Lean compiler in 2025-2026 (new code generator, C emission moved to LCNF, status of Lean.IR, role of the IR interpreter)?

### Takeaway
The LCNF-based compiler replaced the old compiler in 4.22.0 (2025-08-14). By 4.30.0 (2026-05-26) the IR-level passes, including C emission (EmitC), had been ported to LCNF. Lean.IR (λRC) is still kept, as of v4.34–v4.36-rc1: LCNF's impure phase is lowered to `Lean.IR.Decl` (`IR.toIR`) so that it can be stored for the C++ IR interpreter, which runs `#eval`, meta code and code that has not been compiled. Lean.IR is no longer on the path that emits C. The interpreter is under active FRO development (October 2026), and a draft PR proposes a bytecode interpreter that could change what IR is stored.

### Cited Findings
**New compiler rollout (official)**
- The Year 3 roadmap (Aug 2025–Jul 2026) says: "Following the deployment of the new code generator in June 2025…". Its mission objectives include "Deliver major compiler performance gains (new backend, significantly smaller binaries)", and it lists "The new code generator will include support for stack-allocated objects, ownership annotations" as a deliverable. — [Lean FRO Year 3 Roadmap](https://lean-lang.org/fro/roadmap/y3/)
- The highlights of Lean 4.22.0 (2025-08-14) say: "The old compiler has been replaced by the new compiler. This closes many long-standing issues, and lays the foundation for many future features and performance improvements." The switch PR is #8577. — [v4.22.0 release notes](https://lean-lang.org/doc/reference/latest/releases/v4.22.0/); [PR #8577](https://github.com/leanprover/lean4/pull/8577)
- In July 2025 the C++ IR interpreter and llvm.cpp were moved out of `src/library/compiler` into `src/library` (PRs #9265 and #9270, merged 2025-07-08 and 2025-07-09). This is consistent with deleting the old C++ compiler directory; `src/library/compiler` no longer exists at v4.34 (verified in source). — [PR #9265](https://github.com/leanprover/lean4/pull/9265); [PR #9270](https://github.com/leanprover/lean4/pull/9270)

**4.30.0: C emission and the remaining IR passes ported to LCNF (official)**
- From the v4.30.0 release notes (2026-05-26):
  - #12781 "ports the C emission pass from IR to LCNF", which allows end-to-end code generation on the new infrastructure.
  - #12665 ports expand reset/reuse from IR to LCNF and prevents exponential code generation (about 15% smaller binaries).
  - #12705 "ports the simple ground expression extraction pass from IR to LCNF".
  - The release also adds user-controllable borrow annotations (#12830, #12886, #12952, #13017) and RC coalescing (#13136).
  - The release highlights describe 4.30 as completing the new LCNF backend. This comes from a search-result summary of the highlights page and was not re-read verbatim.
  — [v4.30.0 release notes](https://lean-lang.org/doc/reference/latest/releases/v4.30.0/)
- (Verified in source, v4.34.0.) `src/Lean/Compiler/LCNF/EmitC.lean` carries the header "Copyright (c) 2026 Lean FRO, LLC … Authors: Henrik Böving". It maps the LCNF impure types directly to C types (`usize → size_t`, `object → lean_object*`, and so on). — [LCNF/EmitC.lean @ v4.34.0](https://github.com/leanprover/lean4/blob/v4.34.0/src/Lean/Compiler/LCNF/EmitC.lean)

**Lean.IR kept as the interpreter's input (verified in source)**
- The pipeline in `LCNF/Main.lean` (v4.34.0) runs `basePasses` (pure), then `monoPasses`, then `monoPassesNoLambda` and `impurePasses` (impure phase). After that it runs `profileitM … "compilation (IR)"` with `let irDecls ← IR.toIR decls; discard <| IR.compile irDecls`. — [LCNF/Main.lean @ v4.34.0](https://github.com/leanprover/lean4/blob/v4.34.0/src/Lean/Compiler/LCNF/Main.lean)
- `Lean.IR.compile` now only does `checkDecls`, `updateSorryDep`, `addDecls` and `inferMeta`. It stores the IR in the environment and emits nothing. `src/Lean/Compiler/IR/` at v4.34.0 contains Basic, Checker, CompilerM, EmitLLVM, EmitUtil, Format, LLVMBindings, Meta, NormIds, Sorry, ToIR, ToIRType and UnboxResult. There is no EmitC, ExplicitRC or ExpandResetReuse there any more; those now live in `LCNF/`. — [IR.lean @ v4.34.0](https://github.com/leanprover/lean4/blob/v4.34.0/src/Lean/Compiler/IR.lean)
- The header comment of `ir_interpreter.cpp` (upstream, still present at v4.36.0-rc1) explains why the interpreter exists: "Even with a JIT compiler, we still have a need for a simpler interpreter on platforms LLVM JIT does not support (i.e. WebAssembly)… we strive for simplicity instead of performance and thus reuse the existing compiler IR". It also says "The interpreted IR is taken directly from the elab_environment" and that it switches to native code "by checking for the mangled symbol via dlsym/GetProcAddress". — [ir_interpreter.cpp @ v4.36.0-rc1](https://github.com/leanprover/lean4/blob/v4.36.0-rc1/src/library/ir_interpreter.cpp)
- In 4.36.0-rc1, `Lean.IR` gained interpreter-oriented fields. `DeclInfo` now has `maxJp : Nat` and `maxVar : Nat`, `LocalContext` became a structure with separate `vars`/`jps` maps, and the interpreter reads frame sizes "from the `DeclInfo` the IR lowering computes for each declaration" (diff of upstream v4.35.0 and v4.36.0-rc1 files). This shows that Lean.IR is still being changed to serve the interpreter. — [IR/Basic.lean @ v4.36.0-rc1](https://github.com/leanprover/lean4/blob/v4.36.0-rc1/src/Lean/Compiler/IR/Basic.lean); [ir_interpreter.cpp @ v4.36.0-rc1](https://github.com/leanprover/lean4/blob/v4.36.0-rc1/src/library/ir_interpreter.cpp)

**Separate codegen process `leanir` and `.ir` artifacts (verified in source; marked experimental)**
- `src/LeanIR.lean` ("Copyright (c) 2025 Lean FRO… Authors: Sebastian Ullrich") is described as "Lean codegen as a separate process". It writes `.ir` module data that "provides full IR for `declMapExt` and `regularInitAttr`". The option `compiler.postponeCompile` is described as "Internal. Toggle experimental `leanir` separate compilation." (default false). Lake has `leanir`/`.ir` build actions. In 4.30, #13600 fixed a Lake bug where "the IR for a `meta import`'s transitive imports was not included". — [LeanIR.lean @ v4.34.0](https://github.com/leanprover/lean4/blob/v4.34.0/src/LeanIR.lean); [Compiler/Options.lean @ v4.34.0](https://github.com/leanprover/lean4/blob/v4.34.0/src/Lean/Compiler/Options.lean); [v4.30.0 release notes](https://lean-lang.org/doc/reference/latest/releases/v4.30.0/)

**IR interpreter: actively maintained and being sped up (official PRs)**
- Merged PRs:
  - #10345 "implement jumping to native `[export]` decls in the interpreter", 2025-09-11.
  - #10927 "used hashmaps for symbol lookup in the interpreter", 2025-10-23.
  - #12036 and #12095, January 2026.
  - #13757 "disable `interpreter.prefer_native` for further build stages as well", 2026-07-09.
  - #14749, a leak fix, 2026-08-13.
  - #15493 "make variable access in IR interpreter branch free" (hargoniX), 2026-10-05.
  - #15539, a race fix in the IR interpreter's debug code, 2026-10-07.
  — [#10345](https://github.com/leanprover/lean4/pull/10345); [#10927](https://github.com/leanprover/lean4/pull/10927); [#13757](https://github.com/leanprover/lean4/pull/13757); [#14749](https://github.com/leanprover/lean4/pull/14749); [#15493](https://github.com/leanprover/lean4/pull/15493); [#15539](https://github.com/leanprover/lean4/pull/15539)
- Open drafts as of 2026-10-20:
  - #15444 "perf: faster interpreter" by hargoniX (opened 2026-10-02). Its benchmarks show `interpreted/iterators` instructions −44.79%.
  - #15521 "experiment: abseil hashmap in ir interpreter".
  - #15693 "shard the interpreter's native symbol cache lock".
  — [#15444](https://github.com/leanprover/lean4/pull/15444); [#15521](https://github.com/leanprover/lean4/pull/15521); [#15693](https://github.com/leanprover/lean4/pull/15693)
- Draft PR #15557 "perf: bytecode interpreter" (Rob23oba, opened 2026-10-08) has no description. Its commit titles include "basic bytecode interpreter", "assembler, disassembler, arity inferred" and "remove IR". The leanprover-radar bot reported `size/all/.ir` −141 MiB (−37.93%), `libleanshared.so` +29 MiB, and build instructions −6.13%. No maintainer review was visible. — [PR #15557](https://github.com/leanprover/lean4/pull/15557)

**LLVM backend (EmitLLVM): kept but not used**
- `IR.lean` imports `LLVMBindings` and `EmitLLVM` with the comment "The following imports are not required by the compiler. They are here to ensure that there are no orphaned modules." (verified in source, v4.34.0). — [IR.lean @ v4.34.0](https://github.com/leanprover/lean4/blob/v4.34.0/src/Lean/Compiler/IR.lean)
- The "Linux LLVM" CI job is commented out in `ci.yml`. PR #13700 "chore: re-enable LLVM CI" (hargoniX) has been open since 2026-05-11. — [ci.yml](https://github.com/leanprover/lean4/blob/master/.github/workflows/ci.yml); [PR #13700](https://github.com/leanprover/lean4/pull/13700)
- The bundled LLVM toolchain is upgraded regularly: LLVM 22 (#13545, May 2026), LLVM 23 (#14531, merged 2026-08-28, in 4.35.0), 23.1.1 (#15212) and 23.1.3 (#15774, merged 2026-10-19). — [#13545](https://github.com/leanprover/lean4/pull/13545); [#14531](https://github.com/leanprover/lean4/pull/14531); [#15774](https://github.com/leanprover/lean4/pull/15774)

**What the FRO plans next for the compiler (official)**
- The Year 4 Part 1 roadmap (Sep 2026–Feb 2027) says: "Lean features a capable optimizing code generator, but essential improvements are still outstanding. Improvements include: better performance, stack-allocated objects, recursive join points, uniqueness annotations" (plus array-heavy programs). It adds: "In this period we will focus on the design, and start the implementation at the beginning of 2027." The roadmap does not mention LCNF vs IR, the interpreter or wasm. — [Year 4 Part 1 Roadmap](https://lean-lang.org/fro/roadmap/y4-1/)

### Inferences
- The C backend is now LCNF-native. Lean.IR survives only as a lowering target for the interpreter, the `.ir` artifacts and the dormant EmitLLVM. Its role has shrunk from "the backend IR" to "the interpreter's input format". That makes it the most likely layer to be redesigned next: the bytecode draft PR, with its "remove IR" commit and smaller `.ir` files, points that way, but it is a community draft, not an FRO commitment.
- The C emitter's output contract (C code against `lean.h`) is the production path for every native Lean binary, Lean itself included. Its implementation moved in 4.30 without any change in what it emits conceptually. It is the most exercised and therefore most durable codegen interface upstream has.

### Gaps
- No official statement was found on whether Lean.IR will be deprecated or replaced, or whether an LCNF-direct interpreter is planned. PR #15557 has no description, and it is unclear whether "remove IR" refers to Lean.IR or to some internal structure.
- No source states whether `leanir` separate compilation is on by default in 4.35/4.36 for module-system projects. As of v4.34 the option is "Internal", "experimental" and default false.

## Q2. Did upstream ever officially support Emscripten/WebAssembly? What happened, are there plans to bring it back, and what about wasm64/Memory64 vs wasm32?

### Takeaway
Yes. Upstream had an Emscripten build from 2021, and from late 2023 it shipped `linux_wasm32` release artifacts that ran under Node.js. The build was disabled "temporarily" on 2024-12-20 (PR #6424), so 4.15.0 was the last version with it. Core developers have since said that "WASM is no longer supported" (Kim Morrison, 2025-10-14) and that bringing it back is a "very high bar" (Markus Himmel, 2025-11-28). The cause was Emscripten's export limits combined with the interpreter's dlsym-over-exports design. There is no official plan to restore it. Upstream has never supported wasm64/Memory64, and `lean.h` still equates Emscripten with 32-bit. Upstream does merge small Emscripten and wasm64 correctness fixes from the community (at least five in 2026).

### Cited Findings
**History (official)**
- Issue #398 "Emscripten support" was opened by Leonardo de Moura on 2021-04-13 and is still open. — [Issue #398](https://github.com/leanprover/lean4/issues/398)
- PR #505 "feat: initial Emscripten support" (Wojciech Nawrocki) was merged on 2021-06-06. — [PR #505](https://github.com/leanprover/lean4/pull/505)
- On 2021-06-11 Wojciech Nawrocki (FRO/core) said on Zulip: "We recently added an Emscripten build which can run under Node.js", "A build that will be usable in the browser as a library is WIP", "there are no immediate plans for running the LSP server in browsers", and "A standalone/WASI build is not planned." — [Zulip: lol another WASM question](https://leanprover-community.github.io/archive/stream/270676-lean4/topic/lol.20another.20WASM.20question.html)
- PR #2599 "feat: Web Assembly Build" (Alexander Bentkamp) was merged on 2023-10-04, and PR #2855 "feat: release web assembly" on 2023-11-15. Both are official CI and release artifacts. — [PR #2599](https://github.com/leanprover/lean4/pull/2599); [PR #2855](https://github.com/leanprover/lean4/pull/2855)
- Sebastian Ullrich on Zulip:
  - 2023-09-12: "Our build process is very much Unix focused in various aspects, there is no intention to change that."
  - 2023-09-27: "we only care about 32 bit because of wasm".
  - 2024-08-05: on a core shared library for wasm, "no-one has really tried so far" ("didn't work on the first attempt, so we went with static linking").
  — [Zulip: wasm build](https://leanprover-community.github.io/archive/stream/270676-lean4/topic/wasm.20build.html)
- PR #4442 "chore: CI: fix Wasm release-ci" (Kha) was merged on 2024-06-13. — [PR #4442](https://github.com/leanprover/lean4/pull/4442)

**Removal (official)**
- PR #6424 "chore: temporarily disable Web Assembly build in CI" (kim-em) was merged on 2024-12-20 with no description. — [PR #6424](https://github.com/leanprover/lean4/pull/6424)
- On Zulip, Markus Himmel (FRO) said on 2025-11-28 that Lean had a wasm32 build through v4.15.0, hit an Emscripten limitation that would take major effort to fix, and "decided to drop the WebAssembly target for the time being". The code was left in the tree "in a broken state". — [Zulip: what is lean.js](https://leanprover-community.github.io/archive/stream/113488-general/topic/what.20is.20lean.2Ejs.html)
- The limit was the export count: `EXPORT_ALL` exceeded the 100k-export limit (Markus Himmel, 2025-12-03). Henrik Böving added that the server must be able to call any of the 100k+ functions via `#eval`. Sebastian Ullrich noted that the interpreter uses exported symbols to jump into native code, so exporting only a subset "would require designing a new heuristic". — [Zulip: what is lean.js](https://leanprover-community.github.io/archive/stream/113488-general/topic/what.20is.20lean.2Ejs.html)
- Kim Morrison wrote on Zulip on 2025-10-14: "WASM is no longer supported." — [Zulip: wasm build](https://leanprover-community.github.io/archive/stream/270676-lean4/topic/wasm.20build.html)
- PR #7924 "chore: CI: disable Linux 32bit" (Kha) was merged on 2025-04-12. The `ci.yml` comment says it "Started running out of memory building expensive modules". — [PR #7924](https://github.com/leanprover/lean4/pull/7924); [ci.yml](https://github.com/leanprover/lean4/blob/master/.github/workflows/ci.yml)
- In current `ci.yml` (master, fetched 2026-10-20), both the "Web Assembly" job and the "Linux 32bit" job are commented out. The Web Assembly job used `-DSTAGE0_LEAN_EXTRA_CXX_FLAGS='-m32'` and `-DLEAN_INSTALL_SUFFIX=-linux_wasm32` with `release: true` and nightly level, and its comment read "Build a native 32bit binary in stage0 and use it to compile the oleans and the wasm build". The active jobs are Linux release, RelWithAssert, fsanitize, tsanitize, macOS, macOS aarch64, Windows and Linux aarch64. — [ci.yml](https://github.com/leanprover/lean4/blob/master/.github/workflows/ci.yml)

**Conditions for a return (official opinion, not a plan)**
- Markus Himmel, 2025-11-28: a return depends on whether a use case is "important enough to justify the significant investment to bring it back and keep it running (this is a very high bar)". He said it "isn't insurmountable" but is "just not that high on the priority list", and added: "It would definitely be great to see a working build of a recent Lean that doesn't need the export_all." — [Zulip: what is lean.js](https://leanprover-community.github.io/archive/stream/113488-general/topic/what.20is.20lean.2Ejs.html)
- Henrik Böving, 2025-12-03: an interpreter-only build is "usually 10x" slower. On 2025-12-30 he said that core Lean code has roughly tripled since v4.15. — [Zulip: what is lean.js](https://leanprover-community.github.io/archive/stream/113488-general/topic/what.20is.20lean.2Ejs.html)
- Neither the Year 3 nor the Year 4 Part 1 roadmap mentions WebAssembly, wasm, Emscripten or platform support. — [Year 3](https://lean-lang.org/fro/roadmap/y3/); [Year 4 Part 1](https://lean-lang.org/fro/roadmap/y4-1/)

**Dormant code still in the tree (verified in source)**
- `src/CMakeLists.txt` at v4.35.0 still sets `EMSCRIPTEN_SETTINGS "-s ALLOW_MEMORY_GROWTH=1 -fwasm-exceptions -pthread -flto"`. It also still has the link line with `-s MAIN_MODULE=1 -s LINKABLE=1 -s EXPORT_ALL=1 -s ERROR_ON_UNDEFINED_SYMBOLS=0`, which is the configuration that hit the export limit. — [CMakeLists.txt @ v4.35.0](https://github.com/leanprover/lean4/blob/v4.35.0/src/CMakeLists.txt)
- `lean.h` at v4.36.0-rc1 still selects the two-32-bit-halves layout of `LEAN_SCALAR_PTR_LITERAL` under `#ifdef LEAN_EMSCRIPTEN`. In other words, upstream assumes Emscripten means wasm32, and a wasm64 build silently gets the wrong scalar layout unless patched (QED64 patch 0003 gates this on `UINTPTR_MAX` instead). — [lean.h @ v4.36.0-rc1](https://github.com/leanprover/lean4/blob/v4.36.0-rc1/src/include/lean/lean.h); [QED64 PATCHES.md](https://github.com/FawadHa1der/lean4/blob/qed64-wasm64/wasm64-build/PATCHES.md)
- The olean header stores `size_t base_addr`. Its packed size is asserted as `5+1+1+33+40+sizeof(size_t)`, so the olean format depends on pointer width, and a 32-bit target needs 32-bit oleans. Native base addresses are chosen as `hash % 0x7f0000000000` (47-bit) for mmap (verified in source). — [module.cpp @ v4.35.0](https://github.com/leanprover/lean4/blob/v4.35.0/src/library/module.cpp)

**Upstream merges of community Emscripten / wasm64 fixes in 2026 (official acceptance, no CI)**
- #13233 and #13234 (kjsdesigns), single-thread `unique_lock` stub and the `lean_uv_dns_get_info` stub signature, merged 2026-04-07. — [#13233](https://github.com/leanprover/lean4/pull/13233); [#13234](https://github.com/leanprover/lean4/pull/13234)
- #13952 (emberian), the kvmap extern parameter declared as `uint8`, merged 2026-06-09. — [#13952](https://github.com/leanprover/lean4/pull/13952)
- #14864 (FawadHa1der), "return unboxed uint8 from llvm_is_declaration", merged 2026-08-20. This is QED64 patch 0004. — [#14864](https://github.com/leanprover/lean4/pull/14864)
- #14886 (FawadHa1der), the `lean_kernel_diag_is_enabled` declaration (QED64 patch 0005). It was merged by Kha on 2026-08-25 with label `changelog-no`. The author wrote that the bug "is manifesting only for wasm64 output" and that "wasm64 is not supported at the moment". No maintainer policy comment was visible. — [#14886](https://github.com/leanprover/lean4/pull/14886)
- #14974 (mizchi), Emscripten UV stub signatures, closed on 2026-10-19 by algebraic-dev: "These changes are already on master, so I'm closing it." — [#14974](https://github.com/leanprover/lean4/pull/14974)
- Still open: #13298, which guards libuv symbols in io.cpp for Emscripten (from 2026-04-07), and issue #6817, "linux_wasm32 libleanrt.a seems to incorrectly refer to libuv symbols" (from 2025-01-28). — [#13298](https://github.com/leanprover/lean4/pull/13298); [#6817](https://github.com/leanprover/lean4/issues/6817)
- PR #14851 "feat: add experimental WebAssembly and ARM64 native backends" (cpehle) was opened and closed unmerged on 2026-08-20 with no maintainer discussion. It proposed a `lean --wasm=` backend that "emits relocatable wasm32 objects" plus a WASI runtime path. — [PR #14851](https://github.com/leanprover/lean4/pull/14851)

**Community: cauli "reinstate-wasm" (wasm32)**
- cauli/lean4 PR #1, "chore: reactivate WASM (Web Assembly) CI builds", is a draft opened on 2025-12-26 in cauli's fork. It was not proposed upstream.
  - It removed `-flto` (which "was causing the build to consume all the memory of the GH CI runner") and fixed stale stub signatures.
  - Later commits (mid-2026) pinned emsdk 4.0.22 after "emsdk 6 workers crashed at boot" and kept pthreads.
  - Commit a2720f8 switched to an "explicit export list instead of MAIN_MODULE=1/EXPORT_ALL" (MAIN_MODULE=2). It notes that "The previous EXPORT_ALL table had ~231k entries and blocked all DCE".
  - The last push was 2026-08-01. There are no reviews. It targets a 32-bit address space (wasm32).
  — [cauli/lean4 PR #1](https://github.com/cauli/lean4/pull/1)
- cauli/lean4-wasm-in-browser "runs the real Lean 4 compiler entirely in the browser via WebAssembly", with the "Lean binary [running] in a Web Worker".
  - It builds from "a custom Lean fork (`cauli/lean4` @ `reinstate-wasm`), tracking upstream master".
  - It is a "pthread build with shared memory" that needs COOP/COEP isolation, uses 32-bit oleans ("pointer-width compatible with wasm32"), and references "the 4.33 builds".
  - Sizes: full binary "48 MB + 101 MB", slim "3.4 MB + 70 MB". The Init import takes "~4 seconds".
  — [cauli/lean4-wasm-in-browser](https://github.com/cauli/lean4-wasm-in-browser)
- Zulip: Cauli found that #6424 removed wasm from v4.16.0-rc1 onward. His fork build was about 602 MB, and he ran a Lean program in a browser on 2026-01-12 (with `#eval` disabled). On 2026-01-05 Kim Morrison tested a community build on Node: "the wasm loads successfully", then hit a crash in `initialize_Lean`. Robin Arnez reported 201,107 exports (2025-12-30). — [Zulip: what is lean.js](https://leanprover-community.github.io/archive/stream/113488-general/topic/what.20is.20lean.2Ejs.html)

**Community: QED64 wasm64 fork (FawadHa1der/lean4, branch `qed64-wasm64`; read at 53cb11e, 2026-10-15)**
- What it is:
  - Lean 4 based on cauli/lean4 `reinstate-wasm` @ 5732b84, plus the QED64 patch series.
  - It runs "the compiler + language server … inside a browser tab", with Emscripten 6.0.5 and a 16 GiB memory maximum.
  - It brings in upstream releases by merge. The v4.34.0 import was "330 upstream commits".
  - LeanUI's `toolchain/fork.lock` pins this repo at commit 53cb11e (lean=4.34.0, emsdk 6.0.5).
  — [QED64 README](https://github.com/FawadHa1der/lean4/blob/qed64-wasm64/wasm64-build/README.md); [QED64 PATCHES.md](https://github.com/FawadHa1der/lean4/blob/qed64-wasm64/wasm64-build/PATCHES.md)
- How the wasm64 conversion works (PATCHES.md):
  - `-m64` end to end and `STAGE1_LEAN_PLATFORM_TARGET=wasm64-unknown-emscripten`.
  - stage0 becomes "plain native 64-bit"; "LP64 stage0 artifacts are directly compatible with the wasm64 runtime".
  - Pointer-width gates are fixed: `LEAN_SCALAR_PTR_LITERAL`, and `EM_ASM_PTR` instead of `EM_ASM_INT`.
  - ABI fixes said to be "wrong on every platform", two of which are now merged upstream (#14864, #14886).
  — [QED64 PATCHES.md](https://github.com/FawadHa1der/lean4/blob/qed64-wasm64/wasm64-build/PATCHES.md)
- Patch 0039 replaces the interpreter's dlsym-over-exports. Instead of 106,368 wasm exports (a 49 MB JS glue file and about 129 MiB of JS heap per isolate), it uses an in-module, link-time native-symbol table of about 105,799 entries. This is the same export-count problem that FRO cited as the reason for dropping wasm. Patch 0040 moves to native Wasm exceptions. — [QED64 PATCHES.md](https://github.com/FawadHa1der/lean4/blob/qed64-wasm64/wasm64-build/PATCHES.md)
- Source discrepancy: the QED64 README calls cauli's 5732b84 "the original Emscripten/Memory64 enablement". PATCHES.md and cauli's own repos describe reinstate-wasm as wasm32, and the -m64/wasm64 conversion appears as QED64's own patches 0001–0009. — [QED64 README](https://github.com/FawadHa1der/lean4/blob/qed64-wasm64/wasm64-build/README.md); [cauli/lean4-wasm-in-browser](https://github.com/cauli/lean4-wasm-in-browser)

**Community: lean2wasm**
- T-Brick/lean2wasm is a "Tool for compiling Lean to WASM" with 9 commits. It is "really just for me to test things out" and is a translation of the Zulip wasm-build instructions; it needs `emcc`. Thea Brick announced it on 2023-12-13. — [lean2wasm](https://github.com/T-Brick/lean2wasm); [Zulip: wasm build](https://leanprover-community.github.io/archive/stream/270676-lean4/topic/wasm.20build.html)

### Inferences
- Upstream now tests only 64-bit (LP64/LLP64) targets. The 32-bit CI was disabled in April 2025 and wasm32 in December 2024. Every olean, IR artifact and generated C file that upstream produces and tests is therefore 64-bit. wasm64 (LP64) is the only wasm flavour whose pointer width matches what upstream exercises, so stage0 oleans and `.ir` data built by a stock native 64-bit compiler stay layout-compatible. wasm32 needs a separate 32-bit stage0 and 32-bit oleans that nobody upstream builds or tests. That favours wasm64 for durability, despite Memory64's newer engine support.
- Upstream's actual policy as of 2026-10 is "unsupported, untested, but small correctness fixes are welcome". Five or more Emscripten- or wasm64-motivated fixes were merged in 2026, but CI was not re-enabled. A fork such as QED64 will keep carrying rebase cost for the Emscripten build glue, the pthread and exception handling, and the export and symbol-table design.
- The specific blocker FRO named (EXPORT_ALL exceeding the export limit) is what QED64 patch 0039, and to a lesser degree cauli's explicit export list, address. If an upstreamable form of 0039 were proposed, it would meet Markus Himmel's stated wish ("a working build of a recent Lean that doesn't need the export_all"). No such upstream PR was found.

### Gaps
- No core-developer statement on wasm64 or Memory64 was found. The only Zulip mention is a community link to a SpiderMonkey Memory64 post (TongKe Xue, 2025-12-03), and the only upstream PR text is the community author's "wasm64 is not supported at the moment".
- The full 350+ message "wasm build" Zulip thread and any threads after Feb 2026 were not fully read. The last message seen in "what is lean.js" is from 2026-02-19 and got no reply.
- It was not determined whether `CHECK_OLEAN_VERSION` is turned ON in official release CI. The CMake default at v4.35.0 is OFF.

## Q3. What is the Lean FRO's stated direction for running Lean in the browser, and which approaches does it maintain or fund?

### Takeaway
The FRO's browser story is server-side: Lean runs on a server and the browser hosts the UI. This covers live.lean-lang.org / lean4web, the planned "Lean Online Platform … with secure sandboxing", the Year 4 "Workbench" zero-install web environment, and lean4game with server-side bubblewrap. No FRO roadmap or release note commits to in-browser (wasm) execution. The only FRO-affiliated in-browser effort found is lean-vir, a personal proof-of-concept repo by an FRO-affiliated engineer. It runs Lean's real IR interpreter on wasm32-wasip1.

### Cited Findings
- lean4web: "This is a web application running Lean 4 server-side"; "the Lean server is running on a web server, and not in the browser". "There is a playground hosted at live.lean-lang.org". It lives in the leanprover-community organisation. — [lean4web](https://github.com/leanprover-community/lean4web)
- Year 3 roadmap (Aug 2025–Jul 2026):
  - "Improvements will be made to the usability and administration of the live.lean-lang.org playground software."
  - "We will also release an MVP for the Lean Online Platform as a web-only UI solution with secure sandboxing".
  - It also mentions "an initial version of a revamped, basic framework for educational Lean games" and that "Verso will be enhanced to support both PDF extraction and interactive website generation."
  — [Year 3 Roadmap](https://lean-lang.org/fro/roadmap/y3/)
- Year 4 Part 1 roadmap (Sep 2026–Feb 2027): "the Workbench, our zero-install web environment, is in beta testing with external users." It does not mention wasm, the browser runtime or lean-vir, and it does not say whether Workbench executes on a server or in the browser. — [Year 4 Part 1 Roadmap](https://lean-lang.org/fro/roadmap/y4-1/)
- lean4game: "Providing the use access to a Lean instance running on the server is a severe security risk… That is why we start the Lean server with bubblewrap." The main developers are Alexander Bentkamp and Jon Eugster, and the server is run by the hhu-adam team. — [lean4game](https://github.com/leanprover-community/lean4game)
- In November 2023 Alexander Bentkamp said the in-browser wasm lean4game variant was "actually not that useful" after discussing it with Jon Eugster. Scott (Kim) Morrison warned that without a pure JS solution "we cut off most external innovation in these directions". — [Zulip: wasm build](https://leanprover-community.github.io/archive/stream/270676-lean4/topic/wasm.20build.html)

**lean-vir (ejgallego/lean-vir; local clone at 81de859, 2026-10-20)**
- What it is (GitHub "About" and README):
  - About: "Lean 4 IR to wasm32-wasi proof of concept".
  - "Lean VIR runs selected Lean 4 declarations in the browser through Lean's real IR interpreter compiled to `wasm32-wasip1`. It packages compiled module IR; it is not a general Lean-to-Wasm compiler."
  - Officially supported: "the runtime, package workflow, low-level object API and minimal two-way JS/Lean interop". DOM/React/editor-widget support is experimental.
  - Pinned to `leanprover/lean4:v4.35.0`. Licence Apache-2.0.
  — [lean-vir](https://github.com/ejgallego/lean-vir); [lean-vir lean-toolchain](https://github.com/ejgallego/lean-vir/blob/main/lean-toolchain)
- How it plugs into Lean (`UPSTREAM_BOUNDARY.md`):
  - "VIR compiles the unmodified `third_party/lean4-src/src/library/ir_interpreter.cpp` against the pinned Lean headers". A local shim supplies WASI policy and stubs.
  - It selects "upstream runtime, utility and kernel sources plus pinned stage0 C modules". Pinned generated `Init/Prelude.c`, `Lean/Level.c` and `Lean/Expr.c` supply the constructors.
  - The browser rebuilds `Lean.IR.Decl` objects "in Lean's actual constructor layout" from its own `.irpkg` packages and "does not load raw Lean module artifacts or construct a normal compiler `Environment`".
  - "`IRType.struct` and `IRType.union` remain explicit package-generation errors."
  — [lean-vir UPSTREAM_BOUNDARY.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/UPSTREAM_BOUNDARY.md)
- The `.irpkg` format has its own versioning ("format-11 wire contract", manifest version 13), and its metadata records the exact `leanVersion`, `leanToolchain` and `leanGithash`. Packaging consumes Lake's compiled artifacts, "including private data and interpretation IR". — [lean-vir IRPKG_FORMAT.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/IRPKG_FORMAT.md); [lean-vir BUILD_WORKFLOWS.md](https://github.com/ejgallego/lean-vir/blob/main/docs/guides/BUILD_WORKFLOWS.md)
- Affiliation: Emilio J. Gallego Arias's GitHub profile lists "Lean FRO" as his organisation. lean-vir is pinned there as a personal repo. — [ejgallego profile](https://github.com/ejgallego)
- A curated list describes lean-vir as running "Lean in the browser via Lean's IR interpreter compiled to WebAssembly, with a runtime under 200 KiB (early, Lean FRO)". It also lists lean4web as "(Official)" and QED64 as "Lean and Mathlib running in the browser via wasm64". — [awesome-lean-programming](https://github.com/nozaq/awesome-lean-programming)
- No FRO roadmap, release note or blog post found mentions lean-vir. — [Year 4 Part 1 Roadmap](https://lean-lang.org/fro/roadmap/y4-1/); [Roadmap index](https://lean-lang.org/fro/roadmap/)

### Inferences
- The FRO funds and operates server-side browser experiences: the playground administration, the Online Platform/Workbench, and Verso web output. In-browser execution is not an FRO deliverable in any published roadmap through Feb 2027.
- lean-vir is the closest thing to FRO-adjacent in-browser execution. It is a personal-namespace proof of concept by an FRO engineer, not an FRO product, and it carries no upstream maintenance commitment. Its design deliberately reuses unmodified upstream interpreter sources. That reduces patch burden but ties it to Lean.IR's constructor layout and the interpreter's internals, both of which changed in 4.36.0-rc1 (Q1/Q4) and may change again if a bytecode interpreter lands.
- lean-vir targets wasm32-wasip1. It avoids the olean pointer-width problem by not loading oleans: it re-serializes IR into `.irpkg`. It still compiles pinned stage0 C and runtime sources for 32-bit, a configuration upstream no longer tests.

### Gaps
- No public description of the Workbench's architecture (server-side vs in-browser) was found.
- No FRO statement on funding or adopting lean-vir was found. Whether it is a sanctioned FRO project is unknown beyond the author's affiliation and the curated list's "(early, Lean FRO)" tag.
- Verso "live code" in the browser: no source was found describing in-browser execution for Verso docs.

## Q4. How stable are the interfaces each approach depends on (lean.h C ABI and runtime, IR data structures and serialization, .olean format)?

### Takeaway
None of these interfaces is stable across Lean releases. `lean.h` changes in every release, sometimes in object-header semantics. The `.olean` format is keyed to the exact build githash and to pointer width. Lean.IR's constructor layout changed in 4.26 and again in 4.36.0-rc1. The only stable unit is "one exact Lean toolchain": every approach must pin a toolchain and rebuild runtime, generated C and IR packages per release. Approaches that consume generated C (Lean→C→wasm) depend on `lean.h` plus runtime sources. Approaches that consume IR (lean-vir) additionally depend on Lean.IR layout and the interpreter's internals, which are currently the most actively churning layer.

### Cited Findings
**`lean.h` churn** (diff lines between upstream tags; verified by fetching the raw files)

| Tags | Lines changed |
|---|---|
| 4.22.0→4.26.0 | 48 |
| 4.26.0→4.28.0 | 61 |
| 4.28.0→4.30.0 | 402 |
| 4.30.0→4.32.0 | 38 |
| 4.32.0→4.33.0 | 47 |
| 4.33.0→4.34.0 | 145 |
| 4.34.0→4.35.0 | 202 |
| 4.35.0→4.36.0-rc1 | 235 |

The file grew from 3,135 lines (v4.22.0) to 3,813 lines (v4.36.0-rc1). — [lean.h @ v4.22.0](https://github.com/leanprover/lean4/blob/v4.22.0/src/include/lean/lean.h); [lean.h @ v4.36.0-rc1](https://github.com/leanprover/lean4/blob/v4.36.0-rc1/src/include/lean/lean.h)

**Examples of semantic or ABI-relevant `lean.h` changes** (verified in source and release notes)
- 4.30: `lean_array_get` changed `def_val` from owned (`lean_obj_arg`) to borrowed (`b_lean_obj_arg`), and checked `usize` overflow helpers and `lean_runtime_hold` were added.
- 4.34: TSan builds read `m_rc` through seq-cst atomics.
- 4.35:
  - A linearity marker bit was added in the `m_other` header field (`LEAN_LINEAR_MARK_MASK 0x80u`), along with stuck-RC states (`LEAN_RC_STUCK_ST`).
  - #14948 "builds mimalloc with `MI_MAX_ALIGN_SIZE=8`, which means that objects like `List.cons` take 24 bytes instead of 32".
  - #15075 fixes an off-by-one in max object size.
- 4.36.0-rc1: `LEAN_MAX_CTOR_FIELDS 256` became `LEAN_MAX_CTOR_NUM_OBJS 255` ("must be storable in `m_other:8`") and `LEAN_MAX_CTOR_SCALARS_SIZE` went from 1024 to 1023.

— [lean.h @ v4.30.0](https://github.com/leanprover/lean4/blob/v4.30.0/src/include/lean/lean.h); [lean.h @ v4.35.0](https://github.com/leanprover/lean4/blob/v4.35.0/src/include/lean/lean.h); [v4.35.0 release notes](https://lean-lang.org/doc/reference/latest/releases/v4.35.0/)

**Lean.IR churn** (`IR/Basic.lean` diff lines)
- 4.22.0→4.26.0: 204 lines. `IRType` constructors changed: `irrelevant` became `erased`, `tagged` and `void` were added, and `struct`/`union` handling was dropped from several functions.
- 4.26.0→4.35.0: about 1 line.
- 4.35.0→4.36.0-rc1: 48 lines. `DeclInfo` gained `maxJp`/`maxVar`, and `LocalContext` was restructured.

— [IR/Basic.lean @ v4.26.0](https://github.com/leanprover/lean4/blob/v4.26.0/src/Lean/Compiler/IR/Basic.lean); [IR/Basic.lean @ v4.36.0-rc1](https://github.com/leanprover/lean4/blob/v4.36.0-rc1/src/Lean/Compiler/IR/Basic.lean)

**IR interpreter churn** (`ir_interpreter.cpp` diff lines)

| Tags | Lines changed |
|---|---|
| 4.26→4.28 | 62 |
| 4.28→4.30 | 27 |
| 4.30→4.33 | 0 |
| 4.33→4.34 | 2 |
| 4.34→4.35 | 12 |
| 4.35→4.36.0-rc1 | 85 |

The 4.36.0-rc1 change switched frame handling to precomputed sizes and removed dynamic stack growth. Several draft interpreter rewrites were open as of 2026-10 (Q1). — [ir_interpreter.cpp @ v4.36.0-rc1](https://github.com/leanprover/lean4/blob/v4.36.0-rc1/src/library/ir_interpreter.cpp)

**`.olean` format** (verified in source)
- The header contains `version` ("incremented on structural changes to header"), `lean_version[33]`, `githash[40]` and `size_t base_addr`. With `LEAN_CHECK_OLEAN_VERSION`, files whose githash differs fail with "incompatible header". — [module.cpp @ v4.35.0](https://github.com/leanprover/lean4/blob/v4.35.0/src/library/module.cpp)
- Recent content changes:
  - 4.30 #13142 restructured olean-level entry export (`OLeanEntries`).
  - 4.30 #13117 computes axiom dependencies at olean serialization time.
  - 4.35 #14748: "Entries logged during elaboration are saved in the `.olean` file for the module."
  — [v4.30.0 release notes](https://lean-lang.org/doc/reference/latest/releases/v4.30.0/); [v4.35.0 release notes](https://lean-lang.org/doc/reference/latest/releases/v4.35.0/)
- QED64 builds with `CHECK_OLEAN_VERSION=OFF` and enforces compatibility "at the SHA-256 manifest layer, and no patch touches serialization". Its environment snapshots are "binary-paired to the exact runtime — rebake after every runtime change". — [QED64 PATCHES.md](https://github.com/FawadHa1der/lean4/blob/qed64-wasm64/wasm64-build/PATCHES.md); [QED64 README](https://github.com/FawadHa1der/lean4/blob/qed64-wasm64/wasm64-build/README.md)

**Exported symbols and the interpreter's native-symbol contract**
- In the v4.34.0 import, QED64 recorded that "upstream dropped their `@[export lean_*]`" for 23 seed names. It also recorded that v4.34.0 would otherwise have linked without "5,812 boxed wrappers, 168 module initializers (56 new modules) and 213 cells", "each a runtime correctness contract of the interpreter". — [QED64 PATCHES.md](https://github.com/FawadHa1der/lean4/blob/qed64-wasm64/wasm64-build/PATCHES.md)
- lean-vir pins IR format, toolchain and githash in every package, and its supported native-extern set is a curated catalog: "New catalog entries require matching runtime bytes, not just updated Lean sources." — [lean-vir UPSTREAM_BOUNDARY.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/UPSTREAM_BOUNDARY.md); [lean-vir IRPKG_FORMAT.md](https://github.com/ejgallego/lean-vir/blob/main/docs/reference/IRPKG_FORMAT.md)

### Inferences
- For a Lean→C→wasm64 pipeline like LeanUI's, the upgrade unit per Lean release is: rebuild the runtime from that release's sources (plus fork patches) and regenerate C with that release's compiler. `lean.h` changes are absorbed automatically, because generated C and runtime are built from the same tree. The risky surface is the fork patches against the runtime and Emscripten glue, not the C emitter.
- For an IR-interpreter approach (lean-vir), each release can also break the external IR codec (`.irpkg` mirrors Lean.IR constructor layout), the curated native-extern catalog and the interpreter internals. 4.36.0-rc1 already changed both `DeclInfo` layout and the interpreter, and the bytecode draft could replace the stored IR entirely. Per release, this layer is more fragile than generated C.
- No approach gets an ABI-stability guarantee from upstream. No source was found promising `lean.h`, `.olean` or Lean.IR stability across versions.

### Gaps
- No official documentation was found stating a stability policy, or the lack of one, for `lean.h` or `.olean`. The conclusions above rest on observed churn.
- The `.ir` artifact format (`mkIRData`) carries a "TODO: should we use a more specific/efficient data format for IR?" comment in v4.34.0 source. Its future format is unannounced. — [LeanIR.lean @ v4.34.0](https://github.com/leanprover/lean4/blob/v4.34.0/src/LeanIR.lean)

## Q5. Which approach is upstream most likely to keep supporting long-term?

### Takeaway
Ranked by upstream durability, with evidence:
1. **The C backend (EmitC) emitting C against `lean.h`.** It is the production path for every official binary, was rewritten onto LCNF in 2026, and its improvement is funded on the Year 4 roadmap.
2. **The IR interpreter as a component.** It is needed for `#eval` and meta code and is actively optimised in October 2026, but its input representation (Lean.IR vs bytecode) is in flux.
3. **Server-side browser hosting.** lean4web/live.lean-lang.org, the Online Platform and Workbench are FRO-funded.
4. **Emscripten/wasm builds of Lean itself.** These are officially unsupported since 2024-12, have no CI, and returning them is a "very high bar". wasm64/Memory64 has never been acknowledged upstream.
5. **Out-of-tree native backends** (LLVM CI disabled; a wasm-object backend PR closed unmerged).

### Cited Findings
- C backend investment: 4.30 ported C emission and the IR passes to LCNF (#12781, #12665, #12705). Year 4 Part 1 plans code-generator design work (stack-allocated objects, uniqueness annotations, recursive join points) with "implementation at the beginning of 2027". — [v4.30.0 release notes](https://lean-lang.org/doc/reference/latest/releases/v4.30.0/); [Year 4 Part 1 Roadmap](https://lean-lang.org/fro/roadmap/y4-1/)
- Interpreter investment: there is a series of FRO-authored interpreter performance PRs, from #10345 (2025-09) through #15493 (merged 2026-10-05) and draft #15444 (2026-10-02). There is also a community draft bytecode interpreter, #15557 (2026-10-08). — [#15493](https://github.com/leanprover/lean4/pull/15493); [#15444](https://github.com/leanprover/lean4/pull/15444); [#15557](https://github.com/leanprover/lean4/pull/15557)
- The interpreter is about 10x slower than native ("usually 10x", Henrik Böving, 2025-12-03). — [Zulip: what is lean.js](https://leanprover-community.github.io/archive/stream/113488-general/topic/what.20is.20lean.2Ejs.html)
- Status of wasm builds:
  - "WASM is no longer supported" (Kim Morrison, 2025-10-14).
  - Return requires a use case "important enough to justify the significant investment to bring it back and keep it running (this is a very high bar)" (Markus Himmel, 2025-11-28).
  - The CI wasm and 32-bit jobs are commented out.
  — [Zulip: wasm build](https://leanprover-community.github.io/archive/stream/270676-lean4/topic/wasm.20build.html); [Zulip: what is lean.js](https://leanprover-community.github.io/archive/stream/113488-general/topic/what.20is.20lean.2Ejs.html); [ci.yml](https://github.com/leanprover/lean4/blob/master/.github/workflows/ci.yml)
- Upstream nonetheless merged community Emscripten and wasm64 correctness fixes in 2026: #13233, #13234, #13952, #14864 and #14886. — [#14864](https://github.com/leanprover/lean4/pull/14864); [#14886](https://github.com/leanprover/lean4/pull/14886)
- Server-side browser direction is funded: live.lean-lang.org administration, the Lean Online Platform MVP "with secure sandboxing", and Workbench in beta. — [Year 3 Roadmap](https://lean-lang.org/fro/roadmap/y3/); [Year 4 Part 1 Roadmap](https://lean-lang.org/fro/roadmap/y4-1/)
- Alternative backends: the LLVM CI job is disabled, and the re-enable PR #13700 has been open since 2026-05. The experimental wasm/ARM64 backend PR #14851 was closed unmerged on 2026-08-20. — [#13700](https://github.com/leanprover/lean4/pull/13700); [#14851](https://github.com/leanprover/lean4/pull/14851)

### Inferences (for LeanUI's backend decision)
- LeanUI's Lean→C→wasm64 path rests on the most durable upstream interface, the C emitter's output. Its fragile dependency is the Emscripten/wasm64 build of the runtime, which only forks maintain (cauli wasm32, QED64 wasm64). Upstream's demonstrated willingness to merge platform-correctness fixes lowers that cost over time, but it does not remove it.
- An interpreter-based approach (lean-vir style) depends on two things: the interpreter, which upstream will keep because it is core to `#eval` and meta code, and Lean.IR as the stored, interpretable format, which upstream is actively changing and may replace with bytecode. It also accepts the stated ~10x slowdown. It is "more upstream" in that it compiles unmodified upstream sources. It is "less stable" in that it couples to internal data layouts with no stability promise and uses a 32-bit wasm target upstream no longer tests.
- Choosing wasm64 over wasm32 aligns with the only pointer width upstream tests. The one known upstream wasm64 hazard, `LEAN_SCALAR_PTR_LITERAL` keyed on `LEAN_EMSCRIPTEN` in `lean.h`, is still unfixed upstream at v4.36.0-rc1 and must be carried as a fork patch, or upstreamed in the same way as #14864 and #14886.
- The highest-leverage upstreaming targets for durability would be:
  1. the `UINTPTR_MAX`-gated `LEAN_SCALAR_PTR_LITERAL` (QED64 0003);
  2. an export-free native-symbol table for the interpreter (QED64 0039), which addresses the exact blocker the FRO named;
  3. the remaining Emscripten stub and signature fixes (#13298).
  None of these is evidenced as planned upstream.

### Gaps
- No official, dated FRO statement compares in-browser approaches (C-compiled wasm vs interpreter-on-wasm), or says which, if any, it would adopt.
- It is unknown whether the FRO intends Workbench or the Online Platform to ever execute Lean client-side.
