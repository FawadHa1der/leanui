# wasm64 (Memory64) port feasibility for lean-vir, and the most durable route

Research date: 2026-10-20. Subject: lean-vir at `81de859` (pinned to Lean v4.35.0, hash `eb6cafb7`), the QED64 fork at `53cb11e` (LeanUI's `toolchain/fork.lock`), Emscripten 6.0.5 (the `qed64-toolchain:emsdk-6.0.5` image) and wasi-sdk 33. This note builds on `wasm_platform_toolchains.md` (engine status, toolchain survey), `lean_vir_project.md` (release cadence, compatibility model) and `upstream_lean_direction.md` (upstream Emscripten history). It does not repeat them.

Everything was built and run under one experiment directory, called **GR** below:
`/tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port`

- `GR/lean-vir` is a scratch clone of lean-vir 81de859 with the prototype edits applied. `git diff` there shows them, and a copy is at `GR/artifacts/lean-vir-wasm64-prototype.diff`.
- `GR/artifacts/` holds the built `.wasm` files, the benchmark and smoke scripts, the toolchain wrappers and the raw benchmark outputs.
- `GR/logs/` holds every build and test log.

All browser and Node timings below come from a 4-vCPU cloud VM. Load average was about 3 because another researcher was benchmarking at the same time. They are reported as ratios: **CI machine, to be re-measured on the reference Mac.**

---

## 1. Where does lean-vir assume 32-bit, and how big is the patch?

### Takeaway
The C/C++ side is almost width-clean. Building all 60 lean-vir sources for wasm64 needed two small edits:
- relax the explicit `#error` guard in `resource_abi.cpp`;
- hide lean-vir's `__cxa_throw` trap stubs from Emscripten.

The real work is the JavaScript boundary:
- 67 of the 85 exported functions change signature to i64 (BigInt).
- 13 sites hard-code 4-byte pointer arrays or `>>> 0` handles.
- USize transport is explicitly wasm32-only.
- **On wasm64 a `lean_object*` handle can be a boxed scalar up to 2^64, so it cannot safely become a JS Number.**

A working prototype took about 50 changed lines plus a generated signature table. A production port is probably a few hundred lines once you add tests and CI.

The `.irpkg` format and the generated native-extern wrappers are already width-independent. The same package gave identical results on wasm32 and wasm64.

### Cited Findings
**Explicit guards and C/C++ shim**
- `wasm/upstream_shim/abi/resource_abi.cpp:14-15` has `#if !defined(__wasm32__)` / `#error "VIR resource payload encoding requires wasm32"`. This was the only compile failure when all 60 lean-vir sources were built for wasm64, with both clang `--target=wasm64-wasip1` and `em++ -m64`. — [resource_abi.cpp](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/wasm/upstream_shim/abi/resource_abi.cpp); [GR/logs/A2-clang-wasm64.log](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/logs/A2-clang-wasm64.log)
- The maintainer documents that the payload encoding itself is already wasm64-safe: "The current build is explicitly guarded to wasm32. The encoding itself also fits a wasm64 payload… Enabling wasm64 must separately qualify the Lean/JavaScript pointer ABI and relax the target guard." — [docs/reference/OBJECT_ABI.md L55-60](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/reference/OBJECT_ABI.md)
- `wasm/upstream_shim/runtime/native_symbol_lookup.cpp:112-119` defines `__cxa_allocate_exception` and `__cxa_throw` as trap stubs, because wasi-sdk 33 is built without exceptions by default. Under Emscripten they collide with libc++abi (`wasm-ld: error: duplicate symbol: __cxa_throw`). This is a toolchain issue, not a width issue. — [native_symbol_lookup.cpp](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/wasm/upstream_shim/runtime/native_symbol_lookup.cpp); [GR/logs/B-emcc-m64.log](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/logs/B-emcc-m64.log)
- Several shim sites are already width-generic because they use `sizeof`:
  - `interpreter_bridge.cpp:67-68` (`vir_upstream_target_pointer_bytes` returns `sizeof(void *)`);
  - `package_ir_builders.cpp:40` (`object_fields * sizeof(void *)`);
  - `object_abi.cpp:151-163` (USize fields use `sizeof(size_t)`);
  - `object_expr_abi.cpp:224`.
  - Source: [lean-vir wasm/upstream_shim](https://github.com/ejgallego/lean-vir/tree/81de859a3ba1cb5da8bc5f128af025dd5a40b343/wasm/upstream_shim)
- `object_abi.cpp:176` declares `uint32_t vir_obj_scalar_value(lean::object *)`, which truncates on wasm64. There, scalar-boxed Nats reach 2^63−1 and `UInt32` is unboxed. In the experiment, Nat 4294967296 came back from `vir_obj_nat` as a scalar handle `8589934593`, and `vir_obj_scalar_value` returned `0`. — [object_abi.cpp](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/wasm/upstream_shim/abi/object_abi.cpp); [GR/artifacts/nat-debug.mjs](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/artifacts/nat-debug.mjs)
- `package_decl_provider_types.h:43`, `package_ir_decoder.cpp:377` and `package_decl_provider.cpp:119,450` carry a `needs_boxed_wasm32_boundary` flag. It marks top-level `Float`/`Float32`/`UInt64` signatures that need `_boxed` companions. Those types are heap-boxed on 64-bit too, so the flag's meaning carries over unchanged. — [IRPKG_FORMAT.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/reference/IRPKG_FORMAT.md); [GENERATE_PACKAGE.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/reference/GENERATE_PACKAGE.md)

**Package format and native externs**
- The `.irpkg` IR is target-independent. The same `fixtures-basic.irpkg` (857 decls) loaded into the wasm32-wasip1, wasm32-emscripten and wasm64-emscripten builds and gave identical checksums: `fib(25)×3 = 225075` and `sort16×3000 = 3681000`. — [GR/artifacts/bench-node24.txt](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/artifacts/bench-node24.txt)
- The generated native-extern wrappers (`native_wrappers.cpp`, 6,434 lines, 504 externs in the boundary registry) are byte-identical between the wasm32 and wasm64 builds, apart from whitespace. They contain no `uintptr_t`, `sizeof(void*)` or wasm32 references. — [GR/lean-vir/build/upstream-probe/generated/native_wrappers.cpp](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/lean-vir/build/upstream-probe/generated/native_wrappers.cpp); [GR/logs/probe-wasm32.log](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/logs/probe-wasm32.log)

**WASI imports**
- lean-vir's default WASI shims return `NOSYS`/`BADF` constants and never read their pointer arguments (`web/src/runtime/factory-core.js:120-148`).
- Emscripten's wasm64 standalone output imports 8 `wasi_snapshot_preview1` functions with **i64 pointer parameters**, for example `fd_write (i32 i64 i64 i64)`. This is a non-standard "wasm64 WASI" convention. lean-vir's stubs still worked unchanged.
- The wasm64 module needs one extra import, `env.emscripten_notify_memory_growth`, when memory growth is enabled.
- Source: [factory-core.js](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/web/src/runtime/factory-core.js); wasm-dis of [GR/artifacts/wasm64-emcc/vir-upstream.wasm](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/artifacts/wasm64-emcc/vir-upstream.wasm)

**JS export boundary (measured by diffing the export signatures of the two builds)**
- 85 exported functions are common to both builds, and 67 of them change signature: 72 parameters and 50 results go from i32 to i64. Examples:
  - `vir_alloc_bytes (i32)->i32` becomes `(i32)->i64`;
  - `vir_call_resolved_objects (i32,i32,i32)->i32` becomes `(i32,i64,i32)->i64`.
- The one host import `vir_js_call_objects (i32,i32,i32)->i32` becomes `(i32,i64,i32)->i64`.
- Source: [GR/exp/run64/wasm64-pointer-signatures.json](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/exp/run64/wasm64-pointer-signatures.json)

**JS runtime sites that hard-code 32-bit (lean-vir 81de859, `web/src/runtime/`)**
- 4-byte pointer arrays:
  - `managed-core.js:464-471` (`writePointerArray`);
  - `object-core.js:230`;
  - `object-values.js:76,591`;
  - `constructor-scratch.js:38,42,58,72`;
  - `host-state.js:305-307` (`readObjectArgv`);
  - `native-value-codecs.js:338`.
- Handle normalisation: `object-core.js:43-46` rejects values above `0xffffffff` and applies `>>> 0`.
- Scalar reads with `>>> 0`: `object-core.js:312`, `object-values.js:861`, `primitive-values.js:44,175,204`, `vir-codec.js:48`.
- wasm32-only USize and Nat paths: `primitive-values.js:19-20` (`MAX_WASM32_USIZE`, `MAX_WASM32_SCALAR_NAT`), `97-107` (`requireWasm32USize` throws "direct USize transport requires a wasm32 runtime"), `166-175`, `195-220`.
- Source: [web/src/runtime](https://github.com/ejgallego/lean-vir/tree/81de859a3ba1cb5da8bc5f128af025dd5a40b343/web/src/runtime)
- Tests also assume wasm32: `tests/runtime/fixed-width.test.mjs:48-49` expects "requires a wasm32 runtime", and the smoke tests assert `targetPointerBytes() === 4`. — [tests/runtime](https://github.com/ejgallego/lean-vir/tree/81de859a3ba1cb5da8bc5f128af025dd5a40b343/tests/runtime)

**Prototype size**
- The working prototype is 34 insertions and 18 deletions in 9 files, plus:
  - a 19-line `wasm64-adapter.js` that converts i64 arguments and results to and from Number using a 67-entry table generated from the two disassemblies;
  - a 14-line build-script diff (non-fatal compiles, selectable output directory);
  - three toolchain wrapper scripts.
- Source: [GR/artifacts/lean-vir-wasm64-prototype.diff](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/artifacts/lean-vir-wasm64-prototype.diff); [GR/artifacts/build-w64.sh.diff](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/artifacts/build-w64.sh.diff)

**Pointer-width behaviour in `lean.h` (v4.35.0)**
- Boxing: `lean_box_uint32`/`lean_unbox_uint32` heap-allocate a constructor when `sizeof(void*) == 4` and use a tagged scalar otherwise (L3096-3115).
- Small-int limits: `LEAN_MAX_SMALL_NAT` is `SIZE_MAX >> 1` (L1615). `LEAN_MAX_SMALL_INT` is `INT_MAX` on 64-bit and `INT_MAX >> 1` on 32-bit (L1826-1827).
- Static literals: `LEAN_SCALAR_PTR_LITERAL` takes its two-32-bit-halves form only under `#ifdef LEAN_EMSCRIPTEN` (L3501-3505).
- Source: [lean.h v4.35.0](https://github.com/leanprover/lean4/blob/v4.35.0/src/include/lean/lean.h)

**Side finding: a latent scalar-literal bug in lean-vir's current wasm32-wasip1 build**
- lean-vir does not define `LEAN_EMSCRIPTEN`, so on wasm32-wasip1 the 64-bit arm of `LEAN_SCALAR_PTR_LITERAL` is used. It truncates the 8-byte Name hash of static `Name.str` literals.
- A minimal test compiled with wasi-sdk 33 read back `stored-hash=0x0000000044332211` where `0x8877665544332211` was expected. With `-DLEAN_EMSCRIPTEN`, and natively on x86-64, the value was correct.
- The stage0 files lean-vir compiles contain 138 such literal objects (Prelude.c 16 uses, Init/Meta/Defs.c 82, Lean/Expr.c 113, Lean/Level.c 21).
- None appears to be linked into the 81de859 binary. Its data section has 33 static string objects but no static `Name.str` constructor header, so the bug is latent today.
- A wasm64 build without `LEAN_EMSCRIPTEN` takes the correct arm.
- Source: [GR/artifacts/t.c](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/artifacts/t.c); [lean.h L3501](https://github.com/leanprover/lean4/blob/v4.35.0/src/include/lean/lean.h); [native-support-sources.txt](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/wasm/upstream_shim/native-support-sources.txt)

### Inferences
- **The blocking design issue is object handles at the JS boundary, not memory addresses.**
  - Heap addresses stay below 2^53 because browsers cap memory64 at 16 GiB, so `Number(ptr)` is exact.
  - But lean-vir's JS treats any `lean_object*` as a handle. On LP64 that handle is a tagged scalar for any Nat up to 2^63−1, so `Number()` silently drops the tag bit for values ≥ 2^52. That is exactly the out-of-bounds trap seen in the `numeric-results` test (§3).
  - A real port has two options. Keep object handles as BigInt end-to-end, which costs a BigInt allocation per boundary crossing. Or change the C ABI so that scalars never travel as pointers: add `is_scalar` plus an i64 or decimal accessor, and only hand JS real heap pointers.
- **Patch estimate.**
  - Prototype: about 50 changed lines plus a generated table.
  - A production-quality, dual-width lean-vir is roughly 300–800 lines:
    - pointer-width–aware JS helpers instead of an export proxy;
    - BigInt-safe handles or a scalar-aware ABI;
    - 64-bit USize and Nat fast paths;
    - test parameterisation by pointer width;
    - a build-script target switch (Emscripten link flags vs wasi-sdk);
    - a second CI matrix entry.
  - Upstream Lean sources need **no** patches (see §2).
- The latent `LEAN_SCALAR_PTR_LITERAL` bug is worth reporting to lean-vir independently of any wasm64 decision. Defining `LEAN_EMSCRIPTEN` would be wrong under WASI; gating on `UINTPTR_MAX` (QED64 patch 0003) is the right fix.

### Gaps
- I did not write the production BigInt-handle variant, so its per-call cost is unmeasured. The prototype's export proxy is a naive closure-per-call and over-states the boundary cost (§4).
- The scalar-literal check covered only Name literals with the anonymous-prefix header layout searched for. Other static scalar-literal objects were not exhaustively searched.

---

## 2. What did LeanUI's QED64 fork change for wasm64, and which patches would a wasm64 lean-vir need?

### Takeaway
QED64's wasm64-specific patches fall into three groups:
- 0001–0009: build plumbing, plus fixing C declarations whose ABI mismatches wasm32 had hidden;
- 0010–0041: features and fixes for running the full Lean frontend, LSP and compactor in browsers;
- 0003: the `LEAN_SCALAR_PTR_LITERAL` gate.

lean-vir compiles only the runtime, kernel `level`/`expr`, the IR interpreter and about 20 stage0 C files. Of the fork's patches it would need essentially **none**:
- its sources do not define `LEAN_EMSCRIPTEN`, so 0003's bug does not arise;
- it does not compile `io.cpp`, `environment.cpp`, `llvm.cpp`, libuv or the shell, which is where 0004–0008 apply;
- it already has the in-module native-symbol table that QED64 introduced in 0017/0039.

The wasm64 link reported **zero** function-signature mismatches. On the fork, such mismatches were the class of bug that 0004/0005 fixed.

### Cited Findings
- **The fork's wasm64 contract**, stated as "15 files, +78/−307 over reinstate-wasm":
  - ABI corrections:
    - `llvm_is_declaration` returns `uint8_t`;
    - `lean_kernel_diag_is_enabled` is declared `uint8` (it was `uint8*`).
  - Pointer-width gates:
    - `LEAN_SCALAR_PTR_LITERAL` keyed on `UINTPTR_MAX == UINT32_MAX` instead of `LEAN_EMSCRIPTEN`;
    - `EM_ASM_INT`→`EM_ASM_PTR` in `io.cpp`;
    - removal of a `HEAPU32` 4-byte argv walker in `shell.cpp`.
  - Build: `-m64` everywhere, memory cache variables, `STAGE1_LEAN_PLATFORM_TARGET=wasm64-unknown-emscripten`, native 64-bit stage0.
  - Link: five libuv-less stubs and regenerated exports.
  - Source: [PATCHES.md "The wasm64 patch contract"](https://github.com/FawadHa1der/lean4/blob/53cb11e6d6ae0076f8885fec3690e01a6de03404/wasm64-build/PATCHES.md) (local copy: `/home/user/leanui/.toolchain/lean4-fork/wasm64-build/PATCHES.md`)
- The fork says wasm32 had hidden the ABI-correction bugs: `lean_box(0)` returned where `uint8_t` was declared "reads as true. wasm32 masked it (both lower to i32); wasm64 fails validation". The second symptom was "Cannot convert 0 to a BigInt". — [PATCHES.md](https://github.com/FawadHa1der/lean4/blob/53cb11e6d6ae0076f8885fec3690e01a6de03404/wasm64-build/PATCHES.md)
- The fork documents BigInt pitfalls at the JS boundary: "EM_JS pointer parameters arrive in JS as BigInt, and `UTF8ToString` does Number arithmetic — convert first or every probe throws 'Cannot mix BigInt'". — [PATCHES.md, 0017 notes](https://github.com/FawadHa1der/lean4/blob/53cb11e6d6ae0076f8885fec3690e01a6de03404/wasm64-build/PATCHES.md)
- **Later patches concern running the whole compiler and LSP in browser workers, not the pointer width:**
  - 0011/0012/0013: compactor and snapshots for multi-GB saves;
  - 0019/0035/0038: pthread pools;
  - 0036: deep recursion at the engine stack limit;
  - 0039: native symbols through an in-module table, replacing 106,368 exports and a 49 MB glue;
  - 0040: native Wasm exceptions, legacy encoding;
  - 0041: Binaryen inlining cap.
  - Source: [PATCHES.md](https://github.com/FawadHa1der/lean4/blob/53cb11e6d6ae0076f8885fec3690e01a6de03404/wasm64-build/PATCHES.md)
- LeanUI's own delta on top of the fork is a 9-line CMake option `LEAN_WASM_THREADS` that drops `-pthread`. LeanUI compiles with `-O3 -m64 -fwasm-exceptions -sWASM_LEGACY_EXCEPTIONS=1 -D LEAN_EMSCRIPTEN`. — [/home/user/leanui/docs/TOOLCHAIN.md](https://github.com/FawadHa1der/leanui/blob/main/docs/TOOLCHAIN.md); `/home/user/leanui/toolchain/lean-wasm-threads.patch`
- **What lean-vir compiles.** The runtime source set is `runtime/{alloc,apply,exception,hash,mpn,mpz,object,object_ref,platform,utf8}.cpp`, `util/{name,kvmap}.cpp` and `kernel/{level,expr,expr_eq_fn}.cpp`, plus stage0 `Lean/Data/KVMap.c`, `Lean/Level.c`, `Lean/Expr.c` and 18 `Init/*` files.
  - It does not include `io.cpp`, `environment.cpp`, `llvm.cpp`, `shell.cpp` or libuv.
  - Source: [scripts/build-upstream-probe.sh](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/scripts/build-upstream-probe.sh); [native-support-sources.txt](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/wasm/upstream_shim/native-support-sources.txt)
- LeanUI's wasm64 archives (`libleanrt.a`, `libInit.a`, `libStd.a`, `libuv.a`) contain no IR-interpreter symbols (`llvm-nm` found 0 matches). A LeanUI-plus-VIR hybrid therefore has to compile `src/library/ir_interpreter.cpp` and lean-vir's shims into the app, the way lean-vir does. — researcher `llvm-nm` run over `/home/user/leanui/.toolchain/wasm64/lib/*.a`
- The Emscripten wasm64 strict link of lean-vir reported "strict unresolved symbols: 0" and no signature-mismatch warnings. — [GR/logs/B4-emcc-m64-growth.log](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/logs/B4-emcc-m64-growth.log)

### Inferences
**How each QED64 patch applies to a wasm64 lean-vir**

| QED64 patch | Needed by a wasm64 lean-vir? |
|---|---|
| 0001/0002 (Emscripten Docker recipe, CMake `-m64`) | Only the idea. lean-vir's build is a shell script; the equivalent is the target switch plus Emscripten link flags (§3). |
| 0003 `LEAN_SCALAR_PTR_LITERAL` gate | Not needed for wasm64, because lean-vir does not define `LEAN_EMSCRIPTEN`. It *would* fix lean-vir's latent wasm32-wasip1 bug (§1). It becomes mandatory in a hybrid that compiles lean-vir's sources with LeanUI's `-D LEAN_EMSCRIPTEN`; the fork's `lean.h` already carries it. |
| 0004–0008 (llvm, environment, io, uv, shell) | No: those files are not compiled. |
| 0009/0039 (export lists, in-module symbol table) | No: lean-vir already resolves natives through its generated `native_symbols_registry.inc` / `native_wrappers_registry.inc`. |
| 0036 (deep recursion), 0041 (inlining cap) | Relevant in spirit. wasm64 frames are larger (§4: about 43% less recursion depth at the same stack size). 0041 applies only if Binaryen `-O` passes are used. |
| 0040 (native EH) | Independent of width. lean-vir currently traps on `throw`. A hybrid must link lean-vir's shims in the app's EH mode (legacy `-fwasm-exceptions`) and drop its `__cxa_throw` stub. |

- The fork carries the cost of being a fork (merging 330 upstream commits per release, export regeneration, rebakes). That cost comes from running the *whole* Lean frontend in the browser, not from wasm64 itself. lean-vir's narrower source set avoids it.

### Gaps
- I did not attempt the hybrid link: LeanUI's 4.34 fork runtime plus lean-vir's 4.35 shims. Lean versions must match exactly, because VIR keys compatibility to `Lean.githash`. It would need either LeanUI on 4.35 or lean-vir at a 4.34 revision.

---

## 3. Build attempt: what compiled, the first errors, and how far wasm64 lean-vir gets

### Takeaway
- **Route 1, Emscripten 6.0.5 `-m64`, works today.** lean-vir's own build script, with `CXX`/`WASM_LD` swapped for em++ wrappers, compiled all 60 sources (one 1-line guard relaxed). After two more fixes it linked a 793 KB standalone wasm64 module with zero unresolved symbols. With a 19-line JS adapter it ran the fixture package under Node 24, Chromium 141 and Firefox 142, and passed 15 of 21 "pure" runtime smoke tests.
- **Route 2, clang `--target=wasm64-*` with a WASI libc, does not exist as a toolchain.** wasi-sdk 33 has only wasm32 sysroots. Forcing the wasm32 headers made every object compile for wasm64, but the link failed for lack of a wasm64 `crt1.o`, libc, libc++, libc++abi and `libclang_rt.builtins`.
- **Route 3, the wasm32-wasip1 baseline, builds cleanly** in about 5 minutes.

### Cited Findings
**Baseline (route 3)**
- Steps:
  - `elan toolchain install leanprover/lean4:v4.35.0`;
  - sparse clone of `leanprover/lean4@v4.35.0` (`eb6cafb7`);
  - wasi-sdk 33.0 (clang 22.1.0);
  - `lake build Vir` (51 s), `npm ci`;
  - `LEAN4_SRC=… WASI_SDK_PATH=… bash scripts/build-upstream-probe.sh`.
- Result: 60 objects compiled, "strict unresolved symbols: 0", total 295 s.
- Output: `vir-upstream.wasm` of 4,080,659 B unstripped and 793,420 B stripped, matching the published SDK's 793,324 B.
- Imports: `env.vir_js_call_objects` plus 13 `wasi_snapshot_preview1` functions. Memory is `(memory 64)`: 4 MiB, growable.
- Source: [GR/logs/probe-wasm32.log](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/logs/probe-wasm32.log); [lean-vir SDK artifact json](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/vir/sdk/x/lean-vir-sdk/lean-vir-artifact.json)

**Route 2: clang wasm64 with a WASI sysroot**
- `clang++ --target={wasm64-wasip1, wasm64-wasip2, wasm64-unknown-unknown}` on `object.cpp` fails with `fatal error: 'atomic' file not found`. `share/wasi-sysroot/include` contains only `wasm32-wasi`, `wasm32-wasi-threads`, `wasm32-wasip1`, `wasm32-wasip1-threads` and `wasm32-wasip2`. — [GR/exp/clang-wasm64/A-targets.log](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/exp/clang-wasm64/A-targets.log)
- Forcing the wasm32-wasip1 libc and libc++ headers onto `--target=wasm64-wasip1` (`-nostdinc++ -nostdlibinc -isystem …/wasm32-wasip1/noeh/c++/v1 …`):
  - all of lean-vir's 60 sources compiled except `resource_abi.cpp` (its `#error`);
  - with the guard relaxed, the link failed with `cannot open crt1.o`, `unable to find library -lc++`, `-lc++abi`, `-lc`, and `cannot open …/lib/clang/22/lib/wasm64-unknown-wasip1/libclang_rt.builtins.a`.
  - Source: [GR/logs/A2b-clang-wasm64.log](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/logs/A2b-clang-wasm64.log)
- **wasi-sdk:** "64-bit linear memories (a "wasm64" target) are not supported at this time. Supporting this will require resolving WebAssembly/component-model#22 first… There are no plans to add support for `wasm64-wasi{,-threads,p1,p1-threads}`". — [wasi-sdk README](https://github.com/WebAssembly/wasi-sdk/blob/main/README.md)
- **component-model#22** ("Interaction with the memory64 proposal") is still open:
  - May 18, 2025: "There is no ETA while no one is working on this."
  - Dec 8, 2025: two candidate designs are on the table (relax the i32-only `memory`, or add a `memory64` canonical-ABI option).
  - Source: [component-model#22](https://github.com/WebAssembly/component-model/issues/22)
- **wasm64 WASI libc outside wasi-sdk:**
  - A wasi-libc fork has a "Make sysroot building for wasm64" commit (2025-11-14) — [trcrsired/wasi-libc](https://github.com/trcrsired/wasi-libc).
  - Zig lists libc for wasm64-wasi as not available — [Zig platform support](https://ziglang.org/learn/platform-support/wasm64-wasi).
  - A Debian llvm-toolchain MR ships compiler-rt for wasm64 but lists wasm64 libc++/libc++abi as future work — [Debian MR 96](https://salsa.debian.org/pkg-llvm-team/llvm-toolchain/-/merge_requests/96).
  - These three were seen through search snippets only.

**Route 1: Emscripten 6.0.5 `-m64`, in the `qed64-toolchain:emsdk-6.0.5` image**
- Setup: wrapper `em64.sh` (drops `--target=…`, runs `em++ -m64` via `docker exec`), with `WASM_LD` and `LLVM_NM` taken from emsdk. The first `-m64` use built the wasm64-emscripten system libraries in about 90 s.
- Run 1: all 60 sources compiled; the link failed on duplicate `__cxa_throw` and `__cxa_allocate_exception` (lean-vir stub vs `libstandalonewasm-nocatch.a` / `libc++abi-debug-noexcept.a`).
- Run 2, after guarding the stubs with `#if !defined(__EMSCRIPTEN__)`: `wasm-ld: error: initial memory too small, 17939840 bytes needed`, because lean-vir's 4 MiB `--initial-memory` is below Emscripten's layout.
- Run 3, with `VIR_WASM_INITIAL_MEMORY=33554432`: linked. "strict unresolved symbols: 0", 793,481 B.
- Final variant: `EM64_EXTRA="-sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=16GB -sASSERTIONS=0 -sSTACK_OVERFLOW_CHECK=0"`.
- Source: [GR/logs/B-emcc-m64.log](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/logs/B-emcc-m64.log); [B2](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/logs/B2-emcc-m64.log); [B3](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/logs/B3-emcc-m64.log); [B4](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/logs/B4-emcc-m64-growth.log)
- **Module shape:**
  - `(memory i64 …)` and `(table i64 1716 funcref)`, a 64-bit table;
  - an extra `externref` table;
  - an exported `__indirect_function_table`;
  - 8 WASI imports with i64 pointers;
  - extra exports `emscripten_stack_*` and `strerror`, and no `_start`.
- **Node 22.22 (V8 12.4) cannot compile the module** ("invalid table elements limits flags", i.e. no table64). Node 24.22 (V8 13.6) can. — [GR/artifacts/wasm64-emcc](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/artifacts/wasm64-emcc/vir-upstream.wasm)
- **With lean-vir's JS unmodified**, the module instantiates. The first failure is `TypeError: Cannot convert a BigInt value to a number` at `new Uint8Array(memory.buffer, ptr, …)` in `allocBytes` (`managed-core.js:447`), because `vir_alloc_bytes` returns i64. — [GR/exp/run64/smoke.mjs](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/exp/run64/smoke.mjs)
- **With the adapter and pointer-width edits** it reports `targetPointerBytes = 8` and installs `fixtures-basic.irpkg` (857 decls).
- **Runtime test suite**, `node tests/runtime/runner.mjs --group pure` under Node 24:
  - wasm32-wasip1 with the patched JS: 21/21 pass.
  - wasm64: 15/21 pass. The 6 failures:
    - `manifest`, `fixed-width`: assert pointer bytes == 4;
    - `usize-fields`, `object-abi-structural`: `requireWasm32USize` by design;
    - `resource-roots`: asserts that no table is exported, but Emscripten STANDALONE exports `__indirect_function_table`;
    - `numeric-results`: `RuntimeError: memory access out of bounds` in `vir_obj_nat_decimal`, the boxed-scalar handle precision bug from §1.
  - Source: [GR/logs/pure-wasm32.log](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/logs/pure-wasm32.log); [GR/logs/pure-wasm64.log](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/logs/pure-wasm64.log)
- **Control builds from the same objects and script:**
  - Emscripten wasm32 (`em++` without `-m64`): 720,411 B stripped.
  - Emscripten `-sMEMORY64=2`, which keeps i64 pointers but lowers to a 32-bit memory: 760,430 B stripped; its i64 export signatures are unchanged.
  - Source: [GR/logs/C-emcc-wasm32.log](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/logs/C-emcc-wasm32.log); [GR/logs/D-emcc-memory64-2.log](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/logs/D-emcc-memory64-2.log)

### Inferences
- A wasm64 lean-vir is **Emscripten-only for the foreseeable future**. Emscripten's standalone mode is a workable stand-in for "wasm64 WASI": it emits `wasi_snapshot_preview1` imports with i64 pointers, which lean-vir's stub loader tolerates. lean-vir keeps its own JS loader and needs none of Emscripten's JS glue.
- The cost of route 1 is Emscripten's churn: flags were renamed and deprecated across 6.0.x. Emscripten also requires a table64-capable engine, so Node ≥ 24 is needed. Today lean-vir runs on Node 22.
- Fixing the remaining 6 test failures is mechanical except for `numeric-results`. That one needs the scalar-handle ABI decision from §1.

### Gaps
- I did not run the "lean" test group (it needs Lake-built fixtures, over 10 minutes), the browser test suites, or the infoview/React demos on wasm64.
- I did not try `clang --target=wasm64-unknown-unknown` with a custom libc, because lean-vir needs libc++ (`std::string`, `unordered_map`, iostreams in the interpreter) and no wasm64 libc++ outside Emscripten was found. I also did not try building the trcrsired wasi-libc fork plus LLVM runtimes for wasm64. That is a multi-hour effort with no upstream support behind it, so I recorded it as a gap rather than a blocker.

---

## 4. Costs and benefits of wasm64 for an interpreter

### Takeaway
On this CI machine, lean-vir's interpreter on real Memory64 ran an interpreter-bound workload (`fib(25)` in the IR interpreter):
- about **1.1–1.35× slower** than lean-vir's shipped wasm32-wasip1 build;
- **1.2–1.7× slower** than an Emscripten wasm32 build of the same sources.

In V8, the `-sMEMORY64=2` lowered build (same 8-byte pointers, 32-bit memory) ran at wasm32 speed. So V8's penalty comes from the Memory64 memory, not from fatter objects. In Firefox the lowered build was slower still.

Other costs:
- wasm64 is about 10% larger raw and 8% larger gzipped than the same-toolchain wasm32 build;
- it reaches about 43% less recursion depth at equal stack size;
- it puts BigInt at every boundary crossing;
- it excludes all Safari and iOS users today.

The benefits:
- heaps above 4 GiB, which an app interpreter does not need;
- upstream's tested LP64 layout;
- unboxed `UInt32` scalars.

All timings: **CI machine, to be re-measured on the reference Mac.**

### Cited Findings
**Interpreter-bound workload, `fib(25)×3`, medians of 9–11 interleaved rounds**

| Engine | w32-emcc / w32-wasi | w64-emcc / w32-wasi | w64-emcc / w32-emcc | w64-lowered / w32-emcc |
|---|---|---|---|---|
| Node 24.22 (V8 13.6) | 0.83–0.95 | 1.09–1.36 | 1.28–1.54 | 1.00 |
| Chromium 141 | 0.76–0.90 | 1.11–1.32 | 1.27–1.74 | 0.93–1.16 |
| Firefox 142 (Playwright build) | 0.90–0.95 | 1.09–1.15 | 1.18–1.27 | 1.28–1.37 |

Sources: [GR/artifacts/bench-node24.txt](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/artifacts/bench-node24.txt); [bench-browsers.jsonl](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/artifacts/bench-browsers.jsonl); [bench-browsers-4way.jsonl](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/artifacts/bench-browsers-4way.jsonl)

- Absolute medians in Chromium were about 420–640 ms per sample. In Playwright's Firefox build they were about 2.8–3.5 s, roughly 5× slower in absolute terms; I did not investigate why.
- **Boundary-heavy workload, `sort16×3000`** (3,000 JS→Lean calls, each lowering a 16-element array): wasm64 was 1.47–2.06× slower than either wasm32 build in V8 and 1.10–1.36× in Firefox. These numbers include the prototype's naive closure-per-export adapter with BigInt conversion, so they over-state an engineered port. — same sources
- **V8 bounds checks:** Node 24.22 has `--wasm-memory64-trap-handling` on by default. Turning it off did not slow wasm64 measurably: fib was 1.41× on and 1.28× off, within noise. So the explicit bounds check is not the dominant cost here. — [GR/artifacts/bench-node24-traphandling.txt](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/artifacts/bench-node24-traphandling.txt)
- **SpiderMonkey's own view:** Memory64 workloads run "from just 10% to over 100%" slower, and "The only reason to use Memory64 is if you actually need more than 4GB of memory." — [SpiderMonkey blog, 2025-01-15](https://spidermonkey.dev/blog/2025/01/15/is-memory64-actually-worth-using.html)
- **Code size, stripped (gzip -9):**
  - wasm32-wasip1: 793,420 B (190,762);
  - wasm32-emcc: 720,411 B (186,781);
  - wasm64-lowered: 760,430 B (198,208);
  - wasm64-emcc: 793,481 B (200,981).
  - So wasm64 is +10.1% raw and +7.6% gzipped over same-toolchain wasm32, and +5.4% gzipped over the shipped wasm32-wasip1 build. — [GR/artifacts](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/artifacts/)
- **Stack depth:** with the same 1 MiB stack (`-z stack-size=1048576`), the largest `SortDemo.demoFromArray` input that completes is ~1893 elements (wasm32-wasi), ~2015 (wasm32-emcc) and ~1147 (wasm64). Larger inputs trap with "memory access out of bounds". — [GR/artifacts/stack-depth.txt](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/artifacts/stack-depth.txt)
- **Linear-memory footprint:** the wasm64 build's minimum memory was 32 MiB versus 4 MiB, because Emscripten's layout needed more than 16 MiB of initial memory. Small workloads did not grow either memory, so the heap-size difference was not measured. — [GR/artifacts/heap.mjs](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/artifacts/heap.mjs)
- **Safari:** caniuse (read 2026-10-20) shows Memory64 unsupported in every Safari version through "27.1 - TP" and in iOS Safari through "27.1 - 27.2". Chrome supports it from 133 and Firefox from 134. — [caniuse wf-wasm-memory64](https://caniuse.com/wf-wasm-memory64)
- Safari Technology Preview 251 (Aug 26, 2026) "Added support for WebAssembly Memory64". — [WebKit STP 251](https://webkit.org/blog/18194/release-notes-for-safari-technology-preview-251/)
- **Emscripten deprecations:**
  - "`MEMORY64=2` was marked as deprecated. (#27952)" is in 6.0.13 (10/19/26).
  - Earlier 6.0.x releases made `-m64` an alias (#26765) and deprecated `-sMEMORY64` in favour of `-m64` (#27025).
  - settings.js now tags `MEMORY64` as `[deprecated]` and describes mode 2 as "wasm64 for clang/lld but lowered to wasm32 in Binaryen".
  - Source: [Emscripten ChangeLog](https://github.com/emscripten-core/emscripten/blob/main/ChangeLog.md); [settings.js](https://github.com/emscripten-core/emscripten/blob/main/src/settings.js)
- **Benefits in `lean.h`:** on 64-bit, `UInt32` is an unboxed scalar (no allocation) and small Nats go up to 2^63−1; on 32-bit, `lean_box_uint32` allocates and small Nats stop at 2^31−1. — [lean.h v4.35.0 L1615, L3096-3115](https://github.com/leanprover/lean4/blob/v4.35.0/src/include/lean/lean.h)
- **Benefit: tested configuration.** Upstream CI tests only 64-bit targets. The "Linux 32bit" and "Web Assembly" jobs are commented out in `ci.yml` at v4.35.0 (lines ~424-442). — [lean4 ci.yml v4.35.0](https://github.com/leanprover/lean4/blob/v4.35.0/.github/workflows/ci.yml); see also `upstream_lean_direction.md`

### Inferences
- For an IR interpreter running app code, wasm64 is a net loss on every measured axis in 2026: speed (≈10–35% versus today's lean-vir), size, stack and reach (no Safari or iOS). Its main benefit, heaps above 4 GiB, matters only for whole-frontend or Mathlib workloads, which is QED64's use case and not LeanUI's.
- The "matches upstream's LP64" argument is real, but its practical value is small for lean-vir:
  - lean-vir compiles upstream sources unmodified and already passes on wasm32;
  - the only LP64-vs-ILP32 defect found (scalar literals) is latent;
  - IR, oleans and generated C are not consumed as wasm32 artifacts, because `.irpkg` is width-independent.
- The V8 decomposition (lowered ≈ wasm32, full Memory64 ≈ 1.3×) suggests that a future V8 or SpiderMonkey Memory64 codegen improvement could close most of the speed gap without code changes. Re-measuring each engine release is cheap.
- The "unboxed UInt32" benefit is real but narrow: only UInt32-heavy kernels (pixels, hashes) gain, and those are better handled by native externs anyway. It does not offset the 1.2–1.7× general slowdown.

### Gaps
- No UInt32-heavy benchmark was run to quantify the boxing benefit on wasm64.
- No Safari or JSC measurement was possible: Memory64 is only in STP, and there is no macOS here.
- The causes of the wasm32-emcc vs wasm32-wasip1 speed difference (5–25% faster with clang 24 / Emscripten libc vs clang 22 / wasi-libc) were not isolated.
- The machine was loaded, so ranges are wide. Re-measure on the reference Mac.

---

## 5. Maintenance per Lean release, and what the lean-vir maintainer has said

### Takeaway
lean-vir already tracks each Lean release within days, keyed to `Lean.githash`. It does so by recompiling *unmodified* upstream sources with wasi-sdk.

A wasm64 variant adds no Lean-source patching. It does add:
- an Emscripten toolchain pin that churns every 1–3 weeks;
- a second build and test matrix;
- a dual-width JS boundary.

The maintainer's only statements about wasm64 are in docs and commit messages, and they are explicitly deferring: "keep the current wasm32 target guard… for a future wasm64 port". Across lean-vir's 482 commits I found no mention of Emscripten, WASI preview 2 or the component model, and no Zulip statement.

### Cited Findings
- **Maintainer statements:**
  - Commit `8080b7a` (2026-10-02): "Keep the current wasm32 target guard and document the representation, ownership and width requirement for a future wasm64 port." — [commit 8080b7a](https://github.com/ejgallego/lean-vir/commit/8080b7a)
  - Commit `a58780d` (2026-10-05): "package format and wasm32 qualification remain unchanged." — [commit a58780d](https://github.com/ejgallego/lean-vir/commit/a58780d)
  - Commit `d91817a` (2026-10-05): "direct USize transport requires a wasm32 runtime." Commit `d32d057` (2026-08-21) is titled "test: cover wasm32 target semantics (#136)". — [commit d91817a](https://github.com/ejgallego/lean-vir/commit/d91817a); [commit d32d057](https://github.com/ejgallego/lean-vir/commit/d32d057)
  - `docs/development/WASM_RESOURCE_ROOTS.md`: "This change does not alter the package wire format or enable wasm64." — [WASM_RESOURCE_ROOTS.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/development/WASM_RESOURCE_ROOTS.md)
- **Search of the full history:** I cloned 482 commits (2026-05-18 to 2026-10-20) and grepped commit messages (case-insensitive) for wasm64, memory64, emscripten, wasip2, "preview 2", "component model" and "64-bit". The only hit was 8080b7a. A pickaxe search (`git log -S wasm64`) found only a58780d and 8080b7a. The GitHub issue and PR search API was not reachable from this sandbox. — researcher `git log --all` over a bare clone of [ejgallego/lean-vir](https://github.com/ejgallego/lean-vir)
- **Zulip:** a web search (2026-10-20) for "lean-vir ejgallego wasm interpreter zulip" returned no lean-vir thread, only unrelated Lean wasm projects such as [Talos](https://github.com/ashm1tr/talos) and [Wasm.lean](https://reservoir.lean-lang.org/@lurk-lab/Wasm.lean). `lean_vir_project.md` records only a second-hand mention in a Sept 2026 "DOM Manipulation in Lean" thread. I found no reliable source for any Zulip statement by the maintainer on wasm64.
- **Compatibility model:**
  - VIR pins one Lean toolchain per revision.
  - It has followed every release since v4.30.0-rc2, typically within days.
  - Compatibility is `{"leanRevision": <Lean.githash>, "virVersion": 7}`.
  - "VIR maintains the current contracts without legacy APIs or backward compatibility layers."
  - Source: `lean_vir_project.md`; [SUPPORT.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/SUPPORT.md)
- **QED64's per-release cost** for comparison: the v4.34.0 import merged 330 upstream commits, recorded conflict resolutions in CMake, stdin, FileWorker and the stage0 gates, regenerated exports (5,812 boxed wrappers, 168 initializers and 213 cells would otherwise have been missed), ran a 34-agent merge audit, and rebaked every `.snap`. — [PATCHES.md "Upstream import: Lean v4.34.0"](https://github.com/FawadHa1der/lean4/blob/53cb11e6d6ae0076f8885fec3690e01a6de03404/wasm64-build/PATCHES.md)
- **Emscripten cadence and churn** (6.0.0–6.0.13 in 2026: settings deprecated, minimum engine floors raised, `MEMORY64=2` deprecated) is documented in `wasm_platform_toolchains.md` §4. — [Emscripten ChangeLog](https://github.com/emscripten-core/emscripten/blob/main/ChangeLog.md)

### Inferences
**Per Lean release, a wasm64 lean-vir would have to redo:**
- (a) Nothing in Lean's sources, unlike QED64.
- (b) Regenerate the native-wrapper registry. It is width-independent and identical for both targets.
- (c) Re-run both target matrices.
- (d) Re-pin or re-qualify Emscripten, separately from Lean releases. That is the main recurring cost.
- (e) Keep the JS dual-width code paths tested.

The marginal cost over wasm32-only is roughly one CI job plus occasional Emscripten-upgrade fixes. That is small for LeanUI, but it is a cost the single upstream maintainer has explicitly deferred.

**What LeanUI can expect from upstream lean-vir:**
- lean-vir's direction (WASI p1 core module, own loader, externref tables, no Emscripten glue) is wasm32-first by design.
- An upstream wasm64 target is unlikely unless a user brings a concrete >4 GiB need.
- A LeanUI-maintained wasm64 fork of lean-vir would inherit lean-vir's "no backward compatibility" churn on top of Emscripten's.

### Gaps
- GitHub issues and PRs could not be queried by API, so issue and PR discussions not reflected in commit messages could have been missed.
- No direct statement from the maintainer about WASI preview 2 or the component model was found, either for or against.

---

## 6. Bottom line: which route is preferable for 2026–2028, when wasm64 becomes right, and the cheapest experiment to decide

### Takeaway
**Stay on wasm32-wasip1 (route 3) for any VIR-based LeanUI backend through at least 2027.** It is the only route that:
- runs everywhere, including Safari and iOS;
- is the fastest measured for interpreted code;
- matches upstream lean-vir, so it costs nothing per release;
- is free of Emscripten churn.

Keep a **wasm64 build of lean-vir as an optional, Emscripten-only secondary target**, and only if one of the conditions below arises. Route 2, wasm64 with a WASI libc, should be ruled out until wasi-sdk ships a `wasm64-wasip2` target, which is blocked on component-model#22 with no ETA.

**For hybrids:**
- The durable shape is two separate modules (LeanUI's compiled wasm64 app plus a wasm32 VIR instance) exchanging data, not raw objects.
- A single-module LeanUI-wasm64-plus-embedded-interpreter is feasible, since lean-vir's shims compile and link with `em++ -m64`. But it ties LeanUI to lean-vir's exact Lean hash and to the scalar-handle ABI work, and it inherits Memory64's interpreter slowdown and the lack of Safari support.

### Cited Findings
- The measured interpreter cost of wasm64 versus shipped lean-vir wasm32 was 1.09–1.36× across Node 24, Chromium 141 and Firefox 142 (CI machine, to be re-measured on the reference Mac). — §4 sources, e.g. [GR/artifacts/bench-browsers.jsonl](file:///tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/gap-research/wasm64-port/artifacts/bench-browsers.jsonl)
- Memory64 is unsupported in stable Safari and iOS as of 2026-10-20. — [caniuse](https://caniuse.com/wf-wasm-memory64)
- wasi-sdk has "no plans" for wasm64 p1, and wasm64 p2 waits on component-model#22, which has "no ETA". — [wasi-sdk README](https://github.com/WebAssembly/wasi-sdk/blob/main/README.md); [component-model#22](https://github.com/WebAssembly/component-model/issues/22)
- Emscripten deprecated the wasm32-compatible lowering mode `MEMORY64=2` in 6.0.13 (2026-10-19). So "wasm64 code that still runs on Safari" is closing as an option. — [Emscripten ChangeLog](https://github.com/emscripten-core/emscripten/blob/main/ChangeLog.md)
- A wasm64 lean-vir prototype needs only Emscripten plus about 50 lines of edits to run. Proving it out costs about 30 minutes of build time on top of an existing lean-vir checkout. — §3

### Inferences
**wasm64 becomes the right choice for a VIR-based LeanUI only when all of these hold:**
1. A real LeanUI workload needs more than about 3–4 GiB of Lean heap in one instance. For example, an in-browser elaborator, Mathlib-scale environments, or large datasets that must stay as Lean objects. App-UI interpretation will not get there.
2. Stable Safari and iOS ship Memory64, or the product is willing to drop them. Safari 27.x or 28 is plausible but unannounced.
3. Measured Memory64 interpreter overhead in the target engines falls to about ≤10%. V8's lowered-vs-Memory64 gap suggests this is a codegen issue an engine update could close.
4. LeanUI is already committed to Emscripten for its compiled path, so the toolchain cost is shared.

Condition 4 holds today. Conditions 1–3 do not.

**Cheapest decisive experiment.** Reuse the artifacts and scripts in `GR/artifacts/` on the reference Mac:
- (a) Serve `bench.html` with the four `.wasm` builds and `fixtures-basic.irpkg`. Run it in Chrome, Firefox and Safari Technology Preview; STP can at least run the wasm32 builds and possibly wasm64.
- (b) Add one LeanUI-shaped package: a real app's update/view IR from `GeneratePackage`, plus a UInt32-heavy kernel. This captures the boxing benefit.
- (c) Decide on the median wasm64/wasm32 ratio:
  - above about 1.1, stay on wasm32;
  - at about 1.0, with Safari stable Memory64 shipped and a concrete >4 GiB need, schedule the production port (scalar-safe handle ABI, dual-width tests, CI job).

This is about half a day of work, and the build half is already done.

**Durable hedge at near-zero cost:**
- Upstream to lean-vir the width-neutral pieces even while staying on wasm32: the `LEAN_SCALAR_PTR_LITERAL` fix, `pointerBytes`-aware pointer-array helpers, and a scalar-aware handle accessor.
- If a later decision says wasm64, the port is then mostly a build-flag change.

### Gaps
- The hybrid single-module build (LeanUI fork runtime plus VIR) was not attempted, because of the Lean 4.34 vs 4.35 version mismatch.
- No measurement exists yet of a full LeanUI app interpreted on either width; that is what the experiment above would add.
- The Safari Memory64 shipping date is unknown.

---

### Reproduction commands (for the report writer)
```bash
# Baseline wasm32-wasip1 (route 3)
elan toolchain install leanprover/lean4:v4.35.0
git clone --depth 1 --filter=blob:none --sparse --branch v4.35.0 https://github.com/leanprover/lean4.git lean4-v4.35.0
#   (sparse: src, stage0/stdlib/Init, stage0/stdlib/Lean/{Data/KVMap.c,Level.c,Expr.c})
curl -LO https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-33/wasi-sdk-33.0-x86_64-linux.tar.gz
cd lean-vir && lake build Vir && npm ci
LEAN4_SRC=… WASI_SDK_PATH=… bash scripts/build-upstream-probe.sh

# Route 1: Emscripten 6.0.5 -m64 (container from LeanUI's qed64-toolchain:emsdk-6.0.5 image, same-path mounts)
docker run -d --name w64research-emsdk -v $GR:$GR -v $LEAN_PREFIX:$LEAN_PREFIX:ro qed64-toolchain:emsdk-6.0.5 sleep infinity
#   edits: resource_abi.cpp guard -> !__wasm32__ && !__wasm64__; __cxa_* stubs under #if !defined(__EMSCRIPTEN__)
EM64_EXTRA="-sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=16GB -sASSERTIONS=0 -sSTACK_OVERFLOW_CHECK=0" \
CXX=$GR/wrappers/em64.sh WASM_LD=$GR/wrappers/em-wasm-ld64.sh LLVM_NM=$GR/wrappers/em-nm.sh \
WASI_TARGET=wasm64-unknown-emscripten VIR_OUT=build/w64-emcc VIR_SKIP_PACKAGES=1 \
VIR_WASM_INITIAL_MEMORY=33554432 bash scripts/build-w64.sh

# Route 2 (fails at link): wasi-sdk clang, wasm64 target, wasm32 headers forced
CXX=$GR/wrappers/clang64-forced.sh WASM_LD=$GR/wrappers/wasm-ld64.sh WASI_TARGET=wasm64-wasip1 \
VIR_OUT=build/w64-clang VIR_SKIP_PACKAGES=1 bash scripts/build-w64.sh

# Run / test / bench (Node >= 24 needed for table64)
node24 tests/runtime/runner.mjs --group pure
node24 $GR/artifacts/bench.mjs $GR/lean-vir 11 w32wasi=… w32emcc=… w64emcc=…
PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers node $GR/artifacts/serve-and-run.mjs $GR /tmp/claude-0/pw156/package.json chromium 9
```
