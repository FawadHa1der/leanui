# LeanUI on lean-vir: integration analysis and benchmark plan

Scope: how LeanUI (local repo `/home/user/leanui`, commit `7766c28`) would map onto lean-vir
(`ejgallego/lean-vir`, read at commit `81de859a3ba1cb5da8bc5f128af025dd5a40b343`, 2026-10-20), and how
lean-vir could be added as another implementation in LeanUI's benchmarks. Local sources are cited by
absolute path; lean-vir sources by GitHub URL at that commit (abbreviated `VIR@81de859` below). Numbers
marked "own measurement" were taken for this note on a 4-core x86-64 cloud VM (Intel Xeon @ 2.80GHz),
Lean 4.34.0, with the scratch script
`/tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/interp-bench/Bench.lean`
(not in the repository).

Base URL used below: `VIR` = https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343

## 1. What a LeanUI app needs from its runtime, precisely

### Takeaway
A LeanUI browser app needs very little host surface. It has 4 Lean entry points exported to C. The C shim adds 6 wasm exports plus malloc/free and 2 JS imports (flush, blob). Two inline-C buffer primitives are on every app's hot path, and the editor adds three more inline-C pixel primitives and one `ptrAddrUnsafe` use. It also needs zero-copy views of `ByteArray`s in wasm memory, UTF-8 strings passed with an explicit length, a 1 MiB stack, and memory growth up to 4 GiB. No `Task` or threads are needed in the browser.

### Cited Findings
**Lean exports (called by the C shim).**
- `leanui_app p` (macro) defines `@[export leanui_app_start] leanuiAppStart (flags selector : String) (hydrate : UInt8) : IO LeanUI.Instance`. `LeanUI.Wasm` also exports `leanui_instance_event (i : Instance) (slot : UInt32) (payload : String) : IO Unit`, `leanui_instance_callback (… cb : UInt32) (ok : UInt8) (payload : String)` and `leanui_instance_callback_bytes (… payload : String) (bytes : ByteArray)` — [LeanUI/Host/Wasm.lean](/home/user/leanui/LeanUI/Host/Wasm.lean)
- `Instance` is a structure of three closures (`event`, `callback`, `callbackBytes`). `start p host flags selector hydrate : IO Instance` keeps all state in an `IO.Ref` created in `start`, never in an `initialize`d global, because "persistent refs mark contents multi-threaded; MT objects are never exclusive, so every `Array.push` would copy" — [LeanUI/App.lean](/home/user/leanui/LeanUI/App.lean); [docs/DESIGN.md §1](/home/user/leanui/docs/DESIGN.md)
- `Host` = `{ flush : ByteArray → ByteArray → IO Unit, blobs : Array ByteArray → IO Unit := fun _ => pure () }`. `finish` calls `host.blobs` (if any blobs), then `host.flush ops strs`, once per update — [LeanUI/App.lean](/home/user/leanui/LeanUI/App.lean)

**Wasm exports from the C shim** (frozen interface, DESIGN §2).
- `leanui_boot(flags, flagsLen, selector, selectorLen, hydrate)`. It runs the generated `runtime_initialize_<pkg>_<Mod>(1)` (through `leanui_initialize_app`), then `lean_io_mark_end_initialization()`, then `leanui_app_start`, and keeps the `Instance` in a C global `g_inst` — [runtime/leanui_wasm.c](/home/user/leanui/runtime/leanui_wasm.c); [tools/build-app.sh](/home/user/leanui/tools/build-app.sh)
- `leanui_event(slot, payload, len)` and `leanui_callback(cb, ok, payload, len)`. Strings are malloc'd UTF-8 that C frees, passed with a length so a payload may contain U+0000 (`lean_mk_string_from_bytes`) — [runtime/leanui_wasm.c](/home/user/leanui/runtime/leanui_wasm.c); [docs/PROTOCOL.md §4](/home/user/leanui/docs/PROTOCOL.md)
- `leanui_bytes_alloc(len)`, `leanui_bytes_data(obj)` and `leanui_callback_bytes(cb, ok, payload, len, bytes)`. JS asks for an uninitialised Lean `ByteArray` (built by hand with `malloc` + `lean_set_st_header`, returning NULL instead of aborting when memory is short), writes the bytes in place, and hands ownership to Lean. That is exactly one copy (browser buffer → wasm memory) — [runtime/leanui_wasm.c](/home/user/leanui/runtime/leanui_wasm.c); [docs/PROTOCOL.md §8](/home/user/leanui/docs/PROTOCOL.md)
- Link-time export list: `_leanui_boot,_leanui_event,_leanui_callback,_leanui_callback_bytes,_leanui_bytes_alloc,_leanui_bytes_data,_malloc,_free`. Runtime methods: `lengthBytesUTF8,stringToUTF8,HEAPU8` — [tools/build-app.sh](/home/user/leanui/tools/build-app.sh)

**Imported host functions (wasm → JS).**
- `@[extern "leanui_host_flush"] hostFlush (ops strs : @& ByteArray) : IO Unit` → `EM_JS leanui_js_flush` → `LeanUI.__flush(HEAPU8, ops, opsLen, strs, strsLen)`. Both arrays are borrowed views of wasm memory; the JS applier reads `new Uint32Array(bytes.buffer, …)` in place, falling back to `slice` only when the offset is unaligned — [LeanUI/Host/Wasm.lean](/home/user/leanui/LeanUI/Host/Wasm.lean); [runtime/leanui_wasm.c](/home/user/leanui/runtime/leanui_wasm.c); [runtime/leanui.js `apply`](/home/user/leanui/runtime/leanui.js)
- `@[extern "leanui_host_blobs"] hostBlobs (blobs : @& Array ByteArray) : IO Unit` → `LeanUI.__blob(index, address, length)` per blob, before the flush. `PUT_IMAGE` wraps the view in a `Uint8ClampedArray`/`ImageData` with no copy and runs at the end of the buffer, "before control returns to Lean". `DOWNLOAD` copies through the `Blob` constructor — [docs/PROTOCOL.md §8](/home/user/leanui/docs/PROTOCOL.md); [runtime/leanui.js `blob`/`putImage`](/home/user/leanui/runtime/leanui.js)

**`@[extern]`, inline C and unsafe primitives.**
- Core, used by every app: `LeanUI.pushU32` and `LeanUI.appendUtf8` are `@[extern c inline "…"]` definitions with Lean reference bodies. The C uses `lean_is_exclusive`, `lean_sarray_capacity`, an in-place store or memcpy, then `lean_byte_array_push` or `lean_byte_array_copy_slice`. DESIGN notes that "code that writes a `Buf` (mount, diff, `LeanUI.Testing`) needs the compiled LeanUI library … `#eval` and `lean --run` need it loaded" — [LeanUI/Patch.lean](/home/user/leanui/LeanUI/Patch.lean); [docs/DESIGN.md §3](/home/user/leanui/docs/DESIGN.md)
- Editor:
  - `Editor.get32` (an unaligned 32-bit load through `__builtin_memcpy`) and `Editor.set32` (copy if not exclusive, then an unaligned `uint32_t` store) — [examples/Editor/Image.lean](/home/user/leanui/examples/Editor/Image.lean)
  - `Editor.histAdd` (four histogram-bin increments in inline C) — [examples/Editor/Adjust.lean](/home/user/leanui/examples/Editor/Adjust.lean)
  - `sameRef` = `@[implemented_by sameRefImpl]` with `ptrAddrUnsafe a == ptrAddrUnsafe b` — [examples/Editor/Image.lean](/home/user/leanui/examples/Editor/Image.lean)
- No `isExclusiveUnsafe` appears in `LeanUI/` or `examples/` (grep). Exclusivity checks happen only inside the inline C above — grep of `/home/user/leanui/LeanUI`, `/home/user/leanui/examples`
- Primitive counts in `LeanUI/*.lean`, `examples/*.lean` and `examples/Editor/*.lean` (grep): `.push` 194, `.usize` 33, `.uset` 27, `.extract` 20, `.uget` 16, `.copySlice` 14, `.toUTF8` 10. `.uset`/`.usize` appear only in `examples/Editor/{Adjust,Image,Png}.lean`. Float use is heavy in the editor (`Float.ofNat` ×46, `Float.ofInt` ×13, plus `sqrt`, `exp`, `pow`, `floor`, `sin`, `cos`) — grep of `/home/user/leanui`
- UInt64 is used for hashing in the diff (`shapeHash`, `mixHash`, `Std.HashMap UInt64 …`), in the benchmark's 64-bit LCG, and in the editor's pixel arithmetic (`UInt64` accumulators in `Filter`/`Geometry`) — [LeanUI/Diff.lean](/home/user/leanui/LeanUI/Diff.lean); [examples/Bench.lean](/home/user/leanui/examples/Bench.lean); [examples/Editor/Geometry.lean](/home/user/leanui/examples/Editor/Geometry.lean)

**Task, IO, memory and stack.**
- Browser paths use no `Task`, `IO.asTask` or threads. Those appear only in `LeanUI/Server/*` (dedicated session threads). The runtime is built `MULTI_THREAD=OFF` without `-pthread`, and "Lean's `Task` API still works single-threaded (tasks run when forced)" — grep; [docs/TOOLCHAIN.md](/home/user/leanui/docs/TOOLCHAIN.md)
- Link flags: `-sMALLOC=dlmalloc -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=16MiB -sMAXIMUM_MEMORY=4GiB -sSTACK_SIZE=1MiB`, `-fwasm-exceptions -sWASM_LEGACY_EXCEPTIONS=1`, Memory64 (`-m64`) — [docs/TOOLCHAIN.md](/home/user/leanui/docs/TOOLCHAIN.md); [tools/build-app.sh](/home/user/leanui/tools/build-app.sh)
- Stack depth: "a view nests about 1,050 levels in Chromium and 1,700 in Firefox before an update overflows the browser's native stack (the diff recurses once per level)". The app then stops with a `leanui:error` event — [docs/DESIGN.md §5](/home/user/leanui/docs/DESIGN.md); [tests/browser/depth.mjs](/home/user/leanui/tests/browser/depth.mjs)
- Memory in use: the benchmark app has 16 MB of wasm memory at load and 27.75 MB after 10,000 rows. The editor has 57 MiB with a 12 MP image open and 1.23 GiB after 50 brush strokes — [docs/BENCHMARKS.md](/home/user/leanui/docs/BENCHMARKS.md)
- Other runtime behaviour LeanUI relies on:
  - `update` receives the model uniquely owned (`updateModel`) and each message unshared (`popLast`), so pixels and frames are written in place
  - wasm64 pointers cross to JS as BigInt (`ptr()` in leanui.js)
  - JS reads `HEAPU8` after any allocation, because memory may grow

  Sources: [LeanUI/App.lean](/home/user/leanui/LeanUI/App.lean); [runtime/leanui.js](/home/user/leanui/runtime/leanui.js)
- The server-driven host already exists as a second, non-wasm Host. It pushes `encodeFlush ops strs` (`[u32 opsBytes][ops][strs]`) into a ref per request, and leanui.js's `RemoteTransport` applies those bytes with `applyEncoded` (one copy). Its buffers carry no blobs — [LeanUI/Server/Session.lean](/home/user/leanui/LeanUI/Server/Session.lean); [runtime/leanui.js](/home/user/leanui/runtime/leanui.js); [docs/PROTOCOL.md §6, §8](/home/user/leanui/docs/PROTOCOL.md)

### Inferences
- The only contract LeanUI needs from any runtime is: (a) call `start`/`event`/`callback`/`callbackBytes` on a held `Instance`; (b) get per-update `(ops, strs, blobs)` byte arrays to the JS applier; (c) get bytes into a Lean `ByteArray`; (d) run the IR of LeanUI and the app, including the five inline-C primitives (two core, three editor) or their Lean bodies. Everything else (DOM, effects, events) already lives in the fixed `leanui.js`.
- The server-driven host shows that a "buffer returned per call" transport is already a supported shape, so a VIR transport can start as a synchronous `RemoteTransport`.

### Gaps
- I did not enumerate the full transitive set of `Init`/`Std` externs reached by LeanUI's IR. The definitive list comes from running VIR's package generator on a LeanUI app, which prints "missing native extern registrations" (section 2).

## 2. How each need maps onto lean-vir's model

### Takeaway
lean-vir runs Lean's real IR interpreter compiled to `wasm32-wasip1`. JavaScript calls `@[vir_export]` Lean functions with structural value conversion, Lean holds or receives opaque JS-side values (`JSL`, `Js`), and Lean calls JS through `@[vir_js]` host imports limited to JS-value/Unit types.

Three LeanUI needs fit directly: the entry points (as exports holding an opaque `Instance`), UTF-8 strings, and the `ptrAddrUnsafe` primitive. Three need adaptation:
- **Flush.** Raw `ByteArray`s are rejected on host imports, and the shipped `ByteArray` codec copies with `.slice()`. Zero-copy is still possible through the supported low-level object ABI (`vir_obj_byte_array_data` plus `exports.memory`).
- **Inline-C externs.** Interpreted code cannot run inline C. It must use `vir_extern_fallback` (Lean bodies) or client-native C providers, which require a custom VIR wasm build.
- **Missing catalog primitives.** `ByteArray.uset` and `ByteArray.usize` are not in VIR's native extern catalog.

LeanUI would need a new `LeanUI.Host.Vir`, a `VirTransport` in leanui.js, and a Lake/VIR publishing step replacing `tools/build-app.sh` for this target.

### Cited Findings
**What VIR is.**
- "Lean VIR runs selected Lean 4 declarations in the browser through Lean's real IR interpreter compiled to `wasm32-wasip1`. It packages compiled module IR; it is not a general Lean-to-Wasm compiler." The officially supported scope is "the runtime, package workflow, low-level object API and minimal two-way JS/Lean interop". DOM, React/JSX and widgets are experimental — [VIR README](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/README.md); [docs/SUPPORT.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/SUPPORT.md)
- Application workflow: mark entry points `@[vir_export]`, include `include_vir_assets (modules := #[…])` in a separate resource library, and add `needs := #[`+Module:virResourcePack]`. Lake "prepares the program … and downloads the matching prebuilt interpreter". "No npm, WASI SDK, supplied pack or repository website build is needed." JS calls `program.call("Full.Decl.Name", args…)` — [docs/guides/EMBEDDED_RESOURCES.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/guides/EMBEDDED_RESOURCES.md)
- VIR main pins `leanprover/lean4:v4.35.0`, while LeanUI is on v4.34.0. VIR published 4.34-era runtime resources on 07 Oct (e.g. "Runtime resource e415e41a (Lean 4.34, VIR 3)"). Its policy is "VIR maintains the current contracts without legacy APIs or backward compatibility layers", and JS/Wasm assets must match the revision — [VIR lean-toolchain](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/lean-toolchain); [releases](https://github.com/ejgallego/lean-vir/releases); [docs/SUPPORT.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/SUPPORT.md); [/home/user/leanui/lean-toolchain](/home/user/leanui/lean-toolchain)

**Calling Lean from JS (entry points).**
- Exports accept `Unit, Nat, Int, Bool, String, Float, Float32, UInt8…UInt64, USize, ByteArray`, arrays, lists, options, products, structures, enums, custom inductives, opaque host resources and `Lean.Expr`. "ByteArray results are returned as `Uint8Array`." "Exported entrypoints with erased type parameters require a concrete wrapper" — [docs/guides/JS_API.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/guides/JS_API.md); [docs/guides/LEAN_VIR_LIBRARY.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/guides/LEAN_VIR_LIBRARY.md)
- Opaque Lean state held by JS: `JSL α` carriers ("Lean owns the model … JavaScript needs only small display results"). Example: `@[vir_export] def buildHeld (count : Nat) : RuntimeM (JSL (Array Nat)) := LeanRef.toJSL (build count)`, which can then be passed back to other exports; a captured `Unit → String` closure works the same way — [docs/guides/OPAQUE_LEAN_STATE.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/guides/OPAQUE_LEAN_STATE.md); [fixtures/runtime/ManagedCore.lean](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/fixtures/runtime/ManagedCore.lean)
- Strings: "String conversion copies between JS UTF-16 and Lean UTF-8." `vir_obj_string(ptr, len)` builds the object from a length, so U+0000 is fine — [docs/reference/OBJECT_ABI.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/reference/OBJECT_ABI.md); [web/src/runtime/primitive-values.js](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/web/src/runtime/primitive-values.js)
- Initialisation: module constants are package-backed init globals run lazily by single-threaded `*_once_cold` providers, which `lean_mark_persistent` the value. `@[vir_startup]` hooks "are callable, not automatically executed". There is no equivalent of the explicit `runtime_initialize_*`/`lean_io_mark_end_initialization` sequence — [wasm/upstream_shim/README.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/wasm/upstream_shim/README.md); [docs/guides/EMBEDDED_RESOURCES.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/guides/EMBEDDED_RESOURCES.md)

**Calling JS from Lean (flush and blobs).**
- `@[vir_js "target"] opaque …` declares a synchronous host import. Its argument and result types are limited to `Unit`, `Lean.Vir.Js α`, `Js.Nullable`, `JSL`, and top-level callbacks over those. "Raw Lean scalars and structures are rejected on an ordinary host-import boundary." `@[vir_js_explicit_conversion]` is the exception and must "convert between exactly one `Lean.Vir.Js ...` resource and one Lean value". Limits: 128 host imports, IR arity ≤ 6 — [docs/reference/HOST_BINDINGS.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/reference/HOST_BINDINGS.md); [docs/guides/LEAN_VIR_LIBRARY.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/guides/LEAN_VIR_LIBRARY.md); [Vir/Compiler/HostValidation.lean](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/Vir/Compiler/HostValidation.lean)
- `.byteArray` is classified as a "raw Lean type", so `hostFlush (ops strs : @& ByteArray) : IO Unit` cannot be declared as-is. An explicit conversion `ByteArray → Js …` passes validation (`isExplicitConversionArgument` accepts any non-resource type) — [Vir/Compiler/HostValidation.lean](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/Vir/Compiler/HostValidation.lean)
- The shipped Vir JS/DOM bindings (`Vir/Js/Generated.lean`, `Vir/Browser/Generated.lean`) have no ByteArray↔Uint8Array or `ImageData`/`putImageData` binding. The canvas surface covers drawing calls such as `arc`, `beginPath` and `fillRect` (grep) — [Vir/Browser/Generated.lean](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/Vir/Browser/Generated.lean)

**ByteArray layout and views (zero-copy question).**
- The wasm module exports `memory` (wasm32: memory flags 0, 64 initial pages = 4 MiB, no maximum). Its only non-WASI import is `env.vir_js_call_objects`. 87 exports include `vir_obj_byte_array`, `vir_obj_byte_array_data`, `vir_obj_byte_array_size`, `vir_alloc_bytes`, `vir_free_bytes`, `vir_call_resolved_objects`, `vir_obj_field`, `vir_obj_array_get`, `vir_obj_inc` and `vir_obj_dec` — own inspection of [hosted vir-upstream.wasm](https://ejgallego.github.io/lean-vir/vir-upstream.wasm), 2026-10-20
- "Strings and byte arrays return borrowed pointers into the Lean object. JavaScript must read the bytes while the object is still live … create memory views after the accessor returns, so they use the current buffer after memory growth." The low-level object API is in the official support scope — [docs/reference/OBJECT_ABI.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/reference/OBJECT_ABI.md); [docs/SUPPORT.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/SUPPORT.md)
- The default codec copies:
  - Reading: `readWasmBytes(ptr, len) { return new Uint8Array(this.exports.memory.buffer, ptr, len).slice(); }` — [web/src/runtime/managed-core.js](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/web/src/runtime/managed-core.js)
  - Lowering a `Uint8Array` argument: `allocBytes` → `vir_obj_byte_array(ptr, len)` → `freeBytes`, which is two copies into wasm against LeanUI's one — [web/src/runtime/primitive-values.js](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/web/src/runtime/primitive-values.js)

**Externs, inline C and user C.**
- The interpreter "always call[s] the 'boxed' versions of native functions". For an extern with no native symbol it throws "Could not find native implementation of external declaration". There are no arithmetic fast paths: every `UInt32.add`, `UInt64.mul`, `ByteArray.uget` etc. is a native call through a boxed wrapper. It "strive[s] for simplicity instead of performance and thus reuse[s] the existing compiler IR instead of inventing something like a new bytecode format". Self tail calls are turned into loops — [lean4 src/library/ir_interpreter.cpp](https://github.com/leanprover/lean4/blob/master/src/library/ir_interpreter.cpp)
- Boxing cost: `lean_box_uint32` allocates a heap object when `sizeof(void*) == 4` (wasm32). `lean_box_uint64`, `lean_box_usize` and `lean_box_float` always allocate — [lean4 lean.h](https://github.com/leanprover/lean4/blob/master/src/include/lean/lean.h)
- VIR compiles the interpreter with `-DLEAN_DEFAULT_INTERPRETER_PREFER_NATIVE=false`, so all packaged Lean code, `Init`/`Std` included, is interpreted. Native code is limited to a closed extern catalog (`nativeExternSpecs`) — [scripts/build-upstream-probe.sh](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/scripts/build-upstream-probe.sh); [Vir/Compiler/NativeExterns.lean](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/Vir/Compiler/NativeExterns.lean)
- Catalog coverage relevant to LeanUI:
  - Present: `ptrAddrUnsafe`, `ST.Prim.Ref.*`, `Task.pure/get/map`, `Array.uget/uset/usize/push/pop/swap`, `ByteArray.push/get!/set!/size/extract/copySlice/emptyWithCapacity/uget`, `String.toUTF8/append/hash/…`, `mixHash`, UInt8/32/64 and USize arithmetic, `Float` add/sub/mul/div, `sqrt/sin/cos/floor/exp/pow/round/toUInt64/toUInt32`, `UInt64.toFloat`
  - Not found by name search: `ByteArray.uset` and `ByteArray.usize`. Both are `@[extern "lean_byte_array_uset"]` / `@[extern "lean_sarray_size"]` in Lean 4.35, and the editor uses them 27 and 33 times
  - `Float.ofNat` is not an extern (`@[export lean_float_of_nat] protected def`), so it is interpreted

  Sources: [Vir/Compiler/NativeExterns.lean](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/Vir/Compiler/NativeExterns.lean); [lean4 v4.35.0 ByteArray/Basic.lean](https://github.com/leanprover/lean4/blob/v4.35.0/src/Init/Data/ByteArray/Basic.lean); [lean4 v4.35.0 OfScientific.lean](https://github.com/leanprover/lean4/blob/v4.35.0/src/Init/Data/OfScientific.lean)
- Package generation blocks on unresolved externs. Names in primitive namespaces (`ByteArray`, `Float`, `UInt32`, …) that are not in the catalog become "missing native extern registrations". Other extern declarations (e.g. `LeanUI.pushU32`) are not found as IR function declarations and become "missing IR declarations". Either is a blocking diagnostic — [Vir/GeneratePackage/Closure.lean](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/Vir/GeneratePackage/Closure.lean); [Vir/GeneratePackage/Inputs.lean](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/Vir/GeneratePackage/Inputs.lean); [Vir/GeneratePackage/Run.lean](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/Vir/GeneratePackage/Run.lean)
- `vir_extern_fallback name,…` compiles an extern's transparent Lean body into a clone that the package uses instead. It requires an `@[extern] def` and rejects recursive bodies. "The ordinary native backend continues to use each extern" — [Vir/ExternFallback.lean](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/Vir/ExternFallback.lean); [fixtures/runtime/ExternFallback.lean](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/fixtures/runtime/ExternFallback.lean)
- Client-native externs: a `lean-vir-native-externs.json` manifest (`modules`, `externs`, `providerSources` in C11/C++20) compiles project C providers into the VIR runtime behind compiler-generated boxed adapters. "The resulting Wasm runtime is specific to that manifest", and the runtime must be built with `VIR_NATIVE_EXTERN_MANIFEST=… npm run build:demo`, i.e. a Wasm build (WASI SDK 33). Symbols come from `getExternNameFor env `c`, which yields only standard (non-inline) extern names — [docs/reference/CLIENT_NATIVE_EXTERNS.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/reference/CLIENT_NATIVE_EXTERNS.md); [Vir/Compiler/NativeExterns.lean](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/Vir/Compiler/NativeExterns.lean); [scripts/install-wasi-sdk.sh](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/scripts/install-wasi-sdk.sh)

**Runtime limits.**
- Default Wasm build: 4 MiB initial memory and a 1 MiB stack, changeable via `VIR_WASM_STACK_SIZE` (a runtime rebuild) — [docs/HARNESS.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/HARNESS.md)
- "System, heartbeat, stack and trace hooks: Inert". "C++ exceptions and other escaping Wasm traps also retire [the instance], without claiming frame unwinding" — [wasm/upstream_shim/README.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/wasm/upstream_shim/README.md)
- "Host calls execute synchronously"; "Suspending a Lean call on a Promise still needs a later JSPI-shaped boundary" — [docs/guides/JS_API.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/guides/JS_API.md)
- Wasm features of the hosted runtime: `bulk-memory, bulk-memory-opt, call-indirect-overlong, extended-const, multivalue, mutable-globals, nontrapping-fptoint, reference-types, sign-ext`. There is no memory64 and no exception-handling (tag) section — own inspection of [hosted vir-upstream.wasm](https://ejgallego.github.io/lean-vir/vir-upstream.wasm)

### Inferences
**Entry points.** Replace the C shim with a Lean module `LeanUI.Host.Vir` and a macro `leanui_vir_app p` that emits concrete exports:
- `start : String → String → Bool → IO (JSL Instance)`, or a `RuntimeM` variant
- `event : JSL Instance → UInt32 → String → IO Out`, with `callback` and `callbackBytes` alike

`Out` carries the update's bytes, and the host accumulates flushes into an `IO.Ref`, as `Session.lean` does. Keeping `Instance` behind `JSL` avoids the structural codec turning its closure fields into JS functions. The state still lives in the `IO.Ref` inside the closures, so it stays uniquely owned. VIR only `lean_mark_persistent`s init globals, not JS-held roots (grep of `wasm/`).

**Flush, step 1 (copying).** Return `Buf.encode`-style `ByteArray`s (`[u32 opsLen][ops][strs]`) and reuse leanui.js's `applyEncoded`. That costs two copies: the codec's `.slice()`, then `applyEncoded`'s copy. It is negligible for DOM buffers: create-1k is 36,000 words, about 144 KB.

**Flush, step 2 (zero copy).** Call through the low-level object ABI (`vir_resolve_call_export` + `vir_call_resolved_objects`), keep the owned result object, and use `vir_obj_field`/`vir_obj_array_get`/`vir_obj_byte_array_data` to build `Uint8Array`/`Uint32Array` views on `exports.memory.buffer`. Apply the buffer, run `PUT_IMAGE`, then `vir_obj_dec`. This reproduces today's contract that blobs are valid until the buffer is applied. The pointers are 32-bit Numbers, so the BigInt `ptr()` shims go away.

**Push-style flush.** A `@[vir_js "leanui.flush"]` host import would need an explicit `ByteArray → Js Uint8Array` conversion per array. That is a copy, unless VIR adds a borrowed view conversion.

**callbackBytes.** Use the export codec (`ByteArray` argument), at two copies. For one copy, LeanUI would need a VIR export like `leanui_bytes_alloc`, i.e. uninitialised `ByteArray` allocation. `vir_alloc_bytes` gives raw bytes, not a Lean object.

**Inline C.**
- Core `pushU32`/`appendUtf8`: `vir_extern_fallback` works as long as their bodies stay non-recursive, which they are. The interpreted bodies are much slower: per word, 4 `ByteArray.push` calls plus 3 `UInt32.shiftRight` and 4 `toUInt8` boxed native calls, and on wasm32 every `UInt32` argument or result box is a heap allocation.
- Editor `get32`/`set32`/`histAdd`: the fallbacks are pure Lean, so correct but slow. Fast versions need rewriting as standard `@[extern "leanui_get32"]` symbols with a C file, built into a custom VIR runtime through the client-native manifest. VIR then generates a boxed adapter, which still boxes `USize`/`UInt32` arguments.
- Module-system caveat (unverified): `vir_extern_fallback` reads `getConstInfo` of the extern's body. Calling it from a different module than `LeanUI.Patch` may need `import all` or `@[expose]`, so the simplest route is a `meta import Vir.ExternFallback` in `Patch.lean` and `Image.lean` themselves.

**Missing primitives.**
- `ByteArray.uset`/`ByteArray.usize` must be added to VIR's catalog (an upstream PR; the boxed wrappers would call `lean.h` inline functions) or supplied as a client extra. Otherwise the editor and PNG code will not package.
- Core LeanUI did not show `uset`/`usize` in the grep, but the generator report is authoritative.

**Build.** `tools/build-app.sh` (lake → C → Docker emsdk → wasm64 against the fork's archives) would be replaced for this target by:
- a lakefile with a `lean_vir` dependency
- a resource library whose `needs` names `+<App>Vir:virResourcePack`
- a small publisher exe calling `resources.forSite`, which writes the runtime, `.irpkg` and config next to `leanui.js` and the page

That needs no Docker, no Emscripten and no forked runtime archives, but either pins VIR to a Lean-4.34-compatible revision or upgrades LeanUI. The wasm64 fork is pinned to 4.34, so both targets on one toolchain means pinning VIR.

### Gaps
- I did not run VIR's package generator on LeanUI, so the exact list of missing externs and the `.irpkg` size for LeanUI apps are not measured.
- I did not confirm that `vir_extern_fallback` works across module boundaries for LeanUI's `@[extern c inline]` defs under the module system.
- I did not find documentation of whether `JSL` values can be passed to `IO` (not `RuntimeM`) exports, or of the per-call boundary overhead in browsers. PERFORMANCE.md's sample JSON (`base-bool`, 0.0185 ms per call) is shown as a format example, not stated as a measurement.

## 3. What would not work or would need another design, and what would be gained

### Takeaway
The DOM half of LeanUI (protocol, `leanui.js`, delegated events, effects, SSR and hydration) carries over unchanged. The Lean half pays interpretation.

My host measurement puts Lean's IR interpreter at roughly 35–50× compiled code on UI-style work (strings, hashing, HashMap), about 120× on recursion, and 160–250× on `ByteArray` pixel loops, before the extra cost of running the interpreter itself as wasm32. The benchmark app would likely stay usable but several times slower than today. The photo editor and video lab would not be practical without native C kernels.

Gains:
- Safari support in-page (wasm32, no Memory64, no wasm exceptions)
- no Docker/Emscripten/fork build
- one prebuilt interpreter shared by all apps
- faster builds (IR packaging only)

Download size is probably not smaller.

### Cited Findings
**Own measurement: Lean IR interpreter vs compiled, same program, host x86-64** (`lean --run` vs `lean -c` + `leanc -O3`). Times are the best of 3–7 repetitions over two runs, and ratios use the matching runs:

| workload | compiled | interpreted | ratio |
|---|--:|--:|--:|
| 1,000 js-framework-benchmark-style rows (LCG UInt64, label concatenation, `mixHash`, `Std.HashMap` insert) | 0.22–0.27 ms | 9.5–11.0 ms | ≈35–49× |
| 10,000 rows | 2.51 ms | 91.6–106 ms | ≈37–42× |
| 1 MP RGBA brightness loop (`uget`/`uset`, 4 M bytes) | 19.7–27.5 ms | 4,421–5,011 ms | ≈160–254× |
| `fib 27` | 2.18–2.30 ms | 273–285 ms | ≈119–125× |

With `-Dinterpreter.prefer_native=false` (VIR's setting) the interpreted times were similar: 10.4 ms, 91.6 ms, 4,441 ms and 279 ms. Script: `/tmp/claude-0/-home-user-leanui/7771372d-547e-5cc1-a748-4c311414ae82/scratchpad/interp-bench/Bench.lean`. These numbers are the native C++ interpreter; VIR runs the same interpreter compiled to wasm32.

**What VIR's own benchmarks publish.** VIR's harness compares "`fib` and `sort` rows against the host Lean IR baseline" (VIR wasm interpreter vs native interpreter), not against compiled code. Its browser catalog compares five lean-zip backends: `vir`, `fir-native`, `fir-emscripten` ("final LCNF through Lean C, LLVM, Emscripten, and the full Lean runtime", the analogue of LeanUI's route), `compression-stream` and `fflate`. It states that "Timing values are not a candidate gate and are not publication evidence on an uncontrolled host"; no timing results are committed — [docs/development/PERFORMANCE.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/development/PERFORMANCE.md); [benchmarks/browser/docs/LEAN_ZIP_INTEGRATION.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/benchmarks/browser/docs/LEAN_ZIP_INTEGRATION.md)

**LeanUI today.**
- Native Lean creates 1,000 rows in 0.63 ms, selects a row in 0.08 ms and creates 10,000 rows in 6.76 ms (update, view, diff, encoding) — [docs/BENCHMARKS.md](/home/user/leanui/docs/BENCHMARKS.md)
- In Chromium, create-1k costs 3.77 ms of script and 15.88 ms of render (19.67 ms total, 1.10× vanilla). The keyed-suite geometric mean is 1.19× vanilla — [docs/BENCHMARKS.md](/home/user/leanui/docs/BENCHMARKS.md)
- Editor: Lean (wasm) takes 0.61–0.73× the time of plain JS on its 19 image operations. A 12 MP blur takes 3.3 s. Video: colour filters keep up at 1280×720 — [docs/BENCHMARKS.md, "The photo editor"](/home/user/leanui/docs/BENCHMARKS.md)

**Download sizes.**
- VIR's hosted `vir-upstream.wasm` is 793,324 bytes raw, 192,589 gzip-9 and 148,322 brotli-11. The hosted JS bundle that contains the runtime and default host bindings (`browser-packages-*.js`) is 128,020 raw / 30,411 brotli. The sample package `demo-host.irpkg` is 1,458,652 raw / 91,158 brotli — own measurement of [ejgallego.github.io/lean-vir](https://ejgallego.github.io/lean-vir/) assets, 2026-10-20
- VIR release runtime packs are 1,011,875–1,120,065 bytes — [releases](https://github.com/ejgallego/lean-vir/releases)
- LeanUI today: the benchmark app is "168.36 KB over the wire with brotli" (wasm + glue + runtime). The editor is 292 KB brotli (wasm 266 KB, glue 15 KB, runtime 9.5 KB); the current `dist/editor/app.wasm` is 2,294,416 raw / 265,723 brotli — [docs/BENCHMARKS.md](/home/user/leanui/docs/BENCHMARKS.md); own measurement of `/home/user/leanui/dist/editor`

**Browsers, startup and build.**
- Safari: LeanUI needs "WebAssembly Memory64 and exception handling: Chrome and Edge 133+, Firefox 134+ … Safari has no Memory64 yet: there the server runs the same program". VIR's wasm is wasm32 with no exception-handling section (above) — [README.md](/home/user/leanui/README.md); own inspection of vir-upstream.wasm
- Startup: LeanUI is ready 25 ms after navigation, of which 20.3 ms is wasm compile/instantiate, Lean init and first render — [docs/BENCHMARKS.md](/home/user/leanui/docs/BENCHMARKS.md)
- Build: LeanUI's wasm path needs Docker, `toolchain/build-archives.sh` (about 10 minutes cold), and per app Emscripten compiles of every module's C. "Until then, `toolchain/build-archives.sh` reproduces them: about ten minutes cold" — [docs/TOOLCHAIN.md](/home/user/leanui/docs/TOOLCHAIN.md); [tools/build-app.sh](/home/user/leanui/tools/build-app.sh)
- VIR apps download "the matching prebuilt interpreter", and VIR keeps "the vanilla Lean interpreter source unmodified" — [docs/guides/EMBEDDED_RESOURCES.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/guides/EMBEDDED_RESOURCES.md); [wasm/upstream_shim/README.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/wasm/upstream_shim/README.md)
- What Memory64 itself costs LeanUI: 1.07× (Firefox) to 1.14× (Chrome) on an allocation-heavy C workload, wasm64 vs wasm32 — [docs/BENCHMARKS.md, "Findings about measuring"](/home/user/leanui/docs/BENCHMARKS.md)

### Inferences
**What would not work as is, or needs another design.**
1. **Performance-critical Lean.** The diff, encoding and hashing (UInt64 `mixHash`, shape hashes) are interpreted, and every scalar op is a boxed native call. On wasm32 even `UInt32` boxes allocate, which the host measurement above does not include, so VIR in a browser is likely slower than these host ratios. Scaling LeanUI's native create-1k (0.63 ms) by about 40× gives about 25 ms of Lean work on the host interpreter, and likely 30–60 ms in VIR in a browser. Applying the buffer and rendering stay the same (about 2–3 ms and 16 ms). So create-1k would be about 50–80 ms total, versus 19.7 ms today (≈2.5–4× LeanUI, ≈3–4.5× vanilla). Under the same assumptions, select-row would go from 0.34 ms of script to a few ms, and create-10k would add 300–600 ms of Lean work.
2. **Editor and video.** At 160–250× on pixel loops, a 3.3 s 12 MP blur would take many minutes, and per-frame video filters would not keep up at any size. The editor's "every pixel in Lean" premise would require client-native C kernels (a custom VIR runtime build per app profile). Practically, keep the editor on wasm64, or port only `EditorBench` at small sizes for measurement.
3. **Inline-C primitives** move to Lean fallbacks (slow) or regular `@[extern "sym"]` C providers in a custom VIR runtime. The latter brings back a C→wasm build step (WASI SDK, but no Docker or fork).
4. **Zero-copy pixels/blobs** need LeanUI-specific JS on VIR's low-level object ABI, because the high-level codec copies.
5. **Stack depth.** Each interpreted Lean call nests several C++ frames, with the same 1 MiB default stack, so maximum view nesting will be lower than 1,050/1,700. Re-measure with `tests/browser/depth.mjs`. The overflow behaviour is compatible: a trap retires the instance, and leanui.js already reports `leanui:error` and stops calling.
6. **Toolchain coupling.** VIR tracks the newest Lean (4.35 / 4.36-rc1 runtimes) with no backward-compatibility layers, while LeanUI's wasm64 fork is on 4.34. Keeping both targets means pinning VIR to a 4.34 runtime revision and refreshing in lockstep.
7. **Support scope.** VIR officially supports only runtime, packaging, the object API and minimal interop. LeanUI would avoid VIR's experimental DOM/React layers entirely (it has its own `leanui.js`), which keeps it inside the supported scope.

**What would be gained.**
1. **Safari and any wasm32 browser** could run in-page, replacing the server-driven fallback, which costs about 1–2 ms per event round trip on localhost and needs a server session ([docs/DESIGN.md §5](/home/user/leanui/docs/DESIGN.md)). Pixel and file commands also work in Safari, where the server-driven mode has to skip them.
2. **No Docker, Emscripten or forked runtime**, and no 10-minute archive build. App builds become IR packaging only (no per-app C→wasm compile). The interpreter wasm is shared across apps and cacheable across a multi-app site such as the site, TodoMVC and Counter.
3. **No `-m64`/BigInt pointer plumbing** in leanui.js.
4. **Download probably does not shrink.** VIR is 148 KB brotli for the interpreter, about 30 KB for its JS, plus an app package (unknown for LeanUI; VIR's own 1.46 MB demo package is 91 KB brotli) plus 9.5 KB for `leanui.js`. That is likely 200–300 KB for the benchmark app versus 168 KB today. The editor (292 KB today) might be similar or smaller, since its compiled wasm is 266 KB brotli on its own.

### Gaps
- No measured VIR-in-browser vs host-interpreter ratio was found. VIR has a `fib`/`sort` harness but publishes no numbers.
- No measured VIR startup time (wasm compile, package decode, IR object materialisation) was found.
- Safari's support for `extended-const` and the other feature flags above was not verified in this research.

## 4. Benchmark plan: lean-vir as another implementation

### Takeaway
Both LeanUI harnesses drive apps only through the DOM (clicks, `#cmd` input events) and read `window.__leanui`. So a VIR build of the same Lean apps, using the same `leanui.js` with a `VirTransport`, drops in as a third implementation after small, contained harness changes:
- mounts and page URLs per implementation
- startup file lists
- the wasm memory probe
- ratio columns

Measure the keyed suite, startup, download and memory first on Bench (plus Counter and TodoMVC for correctness), then EditorBench at small sizes. Expect several-fold slowdowns on script time and 100×+ on pixel kernels.

### Cited Findings
**`tests/browser/bench.mjs`.**
- Mounts are hard-coded: `MOUNTS = [["/leanui/", LEANUI_DIR], ["/vanilla/", …], ["/", "bench/"]]`, `PAGES = { leanui, vanilla }`.
- `--impls leanui,vanilla` selects implementations, `--leanui-dir` swaps the LeanUI build, and `crossCheck` verifies all `IMPLS` build identical tables.
- Memory reads `window.__leanui.stats.heapBytes`.
- Startup's brotli file list is `["index.html","leanui.js","app.js","app.wasm"]` for `impl === "leanui"`.
- The ratio column exists only for `leanui/vanilla`.
- `TYPES` maps `.html .js .wasm .css .json` and serves everything else as `application/octet-stream`.

Source: [tests/browser/bench.mjs](/home/user/leanui/tests/browser/bench.mjs)
- **Operations and method.** The nine keyed ops and warm-ups are in [bench/ops.mjs](/home/user/leanui/bench/ops.mjs), shared with `bench/runner.html` and `selfbench.mjs` (release browsers, no automation). Chromium is "traced: script = EventDispatch, render = frame work after it". Firefox must be measured on release builds ("Playwright's Firefox … runs wasm about 8× slower") — [docs/BENCHMARKS.md, Method](/home/user/leanui/docs/BENCHMARKS.md)
- **Page contract.** The page sets `window.__leanui = rt; window.__ready = performance.now()` after `LeanUI.start({ glue: "app.js" })` — [examples/bench.html](/home/user/leanui/examples/bench.html)
- **Editor operation benchmark.** It loads `base + "editor-bench/index.html"`, waits for `window.__leanui`, and drives commands through `#cmd` input events (`make W H`, `run OP`, `sum`, `blit`). It checks Lean's checksum against `bench/editor/ops.js`, and cuts an op to `--slow-runs 3` when a warm-up exceeds `--slow-ms 1500`. `wasmBytes()` reads `rt.transport.mod.HEAPU8.buffer.byteLength`, which is Emscripten-specific — [tests/browser/editor-bench.mjs](/home/user/leanui/tests/browser/editor-bench.mjs); [bench/editor/page.js](/home/user/leanui/bench/editor/page.js); [examples/EditorBench.lean](/home/user/leanui/examples/EditorBench.lean)
- **App entry modules** are one line each (`leanui_app Bench.program`, `leanui_app Counter.program`, `leanui_app EditorBench.program`), so a VIR entry module per app is the same size — [examples/BenchApp.lean](/home/user/leanui/examples/BenchApp.lean); [examples/CounterApp.lean](/home/user/leanui/examples/CounterApp.lean); [examples/EditorBenchApp.lean](/home/user/leanui/examples/EditorBenchApp.lean)
- **VIR's phase timing.** `vir.callTimed(entry, …)` returns `{ value, timings }` for phase attribution (lowering, execution, lifting; `hostMs` overlaps `executeMs`) — [docs/guides/JS_API.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/guides/JS_API.md); [docs/development/PERFORMANCE.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/development/PERFORMANCE.md)
- **Precedent.** VIR's browser catalog already runs the same workload under `vir`, `fir-emscripten` (Lean→C→Emscripten), `fir-native` and JS backends, with an exact native-Lean oracle and per-backend readiness — [benchmarks/browser/docs/LEAN_ZIP_INTEGRATION.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/benchmarks/browser/docs/LEAN_ZIP_INTEGRATION.md)

### Inferences
**Harness changes for `bench.mjs`.**
1. Add `--leanvir-dir dist/bench-vir`, mount `/leanvir/`, and `PAGES.leanvir`. Add `.mjs` to `TYPES`: VIR's runtime is an ES module, and a module script served as octet-stream fails the strict MIME check.
2. Generalise startup files per implementation. For leanvir: `index.html`, `leanui.js`, the VIR runtime JS, `vir-upstream.wasm`, `<app>.irpkg`, and `app.json` if used.
3. Have `VirTransport` set `stats.heapBytes = exports.memory.buffer.byteLength`, so the memory table works unchanged.
4. Print ratio columns for every implementation against vanilla, plus leanvir/leanui.
5. Extend `bench/runner.html`, `selfbench.mjs` and `tools/bench-tables.mjs` to N implementations.
6. Add Safari (WebKit) as an engine for vanilla vs leanvir vs server-driven LeanUI. WebKit is the one engine where VIR replaces a network transport.

**Harness changes for `editor-bench.mjs`.**
1. Add `--app editor-bench-vir`.
2. Change `page.js` `wasmBytes()` to ask the transport (`rt.transport.memoryBytes()`).
3. Start with `--sizes 333x250,1 --runs 3 --slow-ms 60000`, because 12 MP would take minutes per op.
4. Keep the bytes check as the correctness gate: identical checksums are required.

**What to measure.**
1. Per-op CPU in Chromium (traced) and in release Chrome, Firefox and Safari (self-timed).
2. Split script time into Lean (from `callTimed` or `performance.now` around `vir.call`) and applier time (`leanui.js` `apply`, already in `stats`).
3. Startup: navigation → ready, broken into module compile, package load (`vir_*_ir_package_set`), Lean init, and first render.
4. Download, raw and brotli per file.
5. Memory: wasm memory plus JS heap after the standard sequences, and DOM nodes.
6. Pixel paths:
   - `PUT_IMAGE` blit (zero-copy vs codec-copy variants)
   - `callbackBytes` ingest (two-copy lowering)
   - the 19 editor ops
7. Build: cold and warm build time per app (`build-app.sh` vs VIR package generation).
8. A native baseline: run `leanui-perf`'s workload under the host interpreter (`lean --run`, `prefer_native=false`) to separate "interpretation" from "wasm".

**Port order.**
1. Counter (smallest; exercises Patch fallbacks, events and flush)
2. Bench (the js-framework-benchmark app and its harness)
3. TodoMVC (storage, routing; has `tests/browser/todomvc.mjs`)
4. Site (fetch, SVG; SSR plus VIR hydration, making Safari in-page possible)
5. Pixels (putImage, files, downloads: the zero-copy blob path)
6. EditorBench (needs `ByteArray.uset`/`usize` and the get32/set32/histAdd fallbacks or C providers)
7. Editor/Video only if C kernels are allowed

**Expected results** (inference from the measurements above):
- **Keyed suite:** total time ≈2.5–4× today's LeanUI on create/replace/append. Small ops (select, swap, remove, update-10th) may be 3–10× in script time, but their totals are render-dominated, so smaller in total ratio.
- **Startup:** likely slower than 25 ms (an 800 KB interpreter to compile plus package decoding).
- **Memory:** a wasm32 heap holding the IR package plus app data.
- **Editor ops:** 100–250× slower than today's wasm64 (≈60–180× slower than plain JS).

### Gaps
- There are no published VIR browser timings to calibrate these expectations against. They must come from the first measurement.
- I did not confirm whether `selfbench.mjs` can drive Safari without automation on macOS.

## 5. Work estimate: proof of concept vs full parity

### Takeaway
A Counter proof of concept is a few days. It needs:
- a pinned VIR (4.34-compatible) dependency
- fallbacks for `pushU32`/`appendUtf8`
- `LeanUI.Host.Vir` with a `leanui_vir_app` macro
- a resource library and publisher replacing `build-app.sh`
- a synchronous `VirTransport` in `leanui.js` that reuses `applyEncoded`

Full parity, with zero-copy flush and blobs, byte callbacks, the missing ByteArray primitives, editor primitives as C providers, all browser suites, benchmark harness changes, CI, and Safari, is a multi-week effort. It is gated on upstream VIR catalog additions and on accepting interpreter-level performance.

### Cited Findings
- VIR app setup is "three changes" (`@[vir_export]`, a resource library with `include_vir_assets`, and a `needs` prerequisite), with a runnable Quickstart (`lake exe publish _site`) — [docs/guides/EMBEDDED_RESOURCES.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/guides/EMBEDDED_RESOURCES.md); [examples/tutorials/quickstart](https://github.com/ejgallego/lean-vir/tree/81de859a3ba1cb5da8bc5f128af025dd5a40b343/examples/tutorials/quickstart)
- The existing remote host already accumulates flushes into a ref and returns encoded bytes per request (`encodeFlush`). `RemoteTransport` and `applyEncoded` already apply such bytes, and send `callbackBytes` as a failure ("bytes need the in-page (wasm) host") — [LeanUI/Server/Session.lean](/home/user/leanui/LeanUI/Server/Session.lean); [runtime/leanui.js](/home/user/leanui/runtime/leanui.js)
- `LeanUI.boot` picks wasm when `supported()` (Memory64 validation) and otherwise connects to the server — [runtime/leanui.js](/home/user/leanui/runtime/leanui.js)
- The client-native extern path requires `VIR_NATIVE_EXTERN_MANIFEST` for both runtime and package builds — [docs/reference/CLIENT_NATIVE_EXTERNS.md](https://github.com/ejgallego/lean-vir/blob/81de859a3ba1cb5da8bc5f128af025dd5a40b343/docs/reference/CLIENT_NATIVE_EXTERNS.md)
- DESIGN rule: runtime code imports only `Init` and `Std`, and compile-time code goes behind `meta import` — [docs/DESIGN.md §3](/home/user/leanui/docs/DESIGN.md)

### Inferences
**Proof of concept (Counter), about 2–4 days for someone who knows both codebases.**
1. Add `require lean_vir` pinned to a Lean 4.34 VIR revision (e.g. the 07-Oct "Lean 4.34, VIR 3" resource) in `lakefile.toml`. Keep VIR imports out of the core library: a new `LeanUIVir` lean_lib holds `LeanUI/Host/Vir.lean` and the per-app entry modules, using `meta import Vir.Attributes` and `public import Vir.Runtime` for `JSL`.
2. Add `vir_extern_fallback LeanUI.pushU32, LeanUI.appendUtf8` (in `Patch.lean` if needed by the module system).
3. Write `LeanUI.Host.Vir`:
   - a host that pushes `encodeFlush ops strs` into an `IO.Ref (Array ByteArray)`
   - exports `start`, `event` and `callback` returning `ByteArray` (the concatenated updates) plus the `JSL Instance` handle
   - a `leanui_vir_app p` macro emitting the concrete wrappers, because exports with erased type parameters need concrete wrappers
4. Write `CounterVir.lean` and `CounterVirResources.lean` with `needs := #[`+CounterVir:virResourcePack]`, and a `leanui-publish` exe calling `resources.forSite` and copying `leanui.js` and the page. These replace `tools/build-app.sh` for this target.
5. In `leanui.js`, add `class VirTransport { event(slot,p){ apply(vir.call("…event", inst, slot, p)) } … }`, `LeanUI.startVir({ config })`, and `boot()` choosing VIR when Memory64 is missing. For the PoC, `callbackBytes` is a failure, as in `RemoteTransport`.
6. Run `tests/browser/counter.mjs` against `dist/counter-vir`, including in WebKit.

**Full parity, roughly 3–6 weeks including measurement and performance work.**
1. Zero-copy flush and blobs via the low-level object ABI (2–4 days, including memory-growth and lifetime tests).
2. `callbackBytes` via the `ByteArray` codec, then an upstream request for an uninitialised-ByteArray allocator (1–2 days).
3. Run VIR's generator on every app, then add the missing externs. `ByteArray.uset`/`usize` go to the VIR catalog upstream or into an extras file (days; depends on upstream).
4. Editor primitives (`get32`, `set32`, `histAdd`): Lean fallbacks first, then C providers via the client-native manifest. That gives a per-app VIR runtime built with WASI SDK 33, which makes CI build wasm again, but without Docker or the fork (3–5 days).
5. Run every browser suite against VIR builds:
   - counter, todomvc, site, keyed-dom, fuzz, templates, apply-semantics, effects, pixels, editor
   - re-calibrate `depth.mjs` limits
   - SSR hydration with VIR (the Lean side is unchanged)
   - 3–5 days
6. Benchmark harness generalisation (section 4) and a BENCHMARKS.md section (2–3 days).
7. CI job and deploy: publish the VIR assets next to the wasm64 ones, with `.br` siblings (1–2 days).
8. Contingency for VIR's fast-moving contracts, whose asset and contract revisions must match exactly.

**An alternative to evaluate before committing.** VIR's own benchmark catalog includes "FIR" (`ejgallego/lean-fir`): a "resident, zero-import Wasm compiler route" (`fir-native`) and a Lean C/Emscripten route. If FIR compiles Lean to wasm32 without an interpreter, it may give Safari support and no Docker without the 35–250× interpretation cost. Its maturity and API were not researched here.

### Gaps
- These estimates are my judgement, not sourced figures.
- I did not verify that a 4.34-pinned VIR revision supports all the APIs cited at `81de859`; VIR changed contracts several times in October 2026.
- I did not research FIR's status, support scope or performance.
