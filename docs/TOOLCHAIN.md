# The LeanUI toolchain

A LeanUI app is ordinary Lean 4.34 compiled twice: natively by `lake` (tests, the server, the C
the browser build starts from), and from that C to **single-threaded wasm64** by Emscripten. This
page says what the wasm64 side is built from, why it is single-threaded, and how to rebuild it.

## What an app links

| piece | from | notes |
|---|---|---|
| `libleanrt.a`, `libInit.a`, `libStd.a`, `libuv.a` | the QED64 wasm64 fork of Lean, `toolchain/fork.lock` | built by `toolchain/build-archives.sh` into `.toolchain/wasm64/` |
| `libleanui.a` | every LeanUI module except tests, CLI, `Testing`, `Server` | archived per app, so the linker keeps only what the app reaches |
| the app module | `lake build <Module>`'s C | the one object linked directly |
| `runtime/leanui_wasm.c` | the C shim | `leanui_boot`, `leanui_event`, `leanui_callback`, and the flush import |
| `runtime/leanui.js` | the browser runtime | dependency-free, about 6 KB brotli |

Compile flags for every object: `-O3 -m64 -fwasm-exceptions -sWASM_LEGACY_EXCEPTIONS=1
-D LEAN_EMSCRIPTEN`. Link: `-sMALLOC=dlmalloc -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=16MiB
-sMAXIMUM_MEMORY=4GiB -sSTACK_SIZE=1MiB -sMODULARIZE=1 -sENVIRONMENT=web` (the filesystem layer
stays: without it libuv's startup calls fail with `ENOSYS`). `tools/build-app.sh` documents the
environment variables that change these.

## Why single-threaded

The fork's published runtime is built with `-pthread`, which makes the module's memory a
`SharedArrayBuffer`. A page can only create one when it is cross-origin isolated (served with
`Cross-Origin-Opener-Policy` and `Cross-Origin-Embedder-Policy` headers), which most hosting
setups and most embedding contexts cannot promise. A UI does not need Lean's task threads: the
update loop is sequential, and Lean's `Task` API still works single-threaded (tasks run when
forced). So LeanUI builds the runtime with `MULTI_THREAD=OFF` and without `-pthread`: the page
loads from any static host, and no worker pool or shared memory is involved.

The switch costs no speed. Reference counting no longer needs atomic operations for objects
shared between threads, and the runtime's thread-local counters (the allocation heartbeat, for
one) become plain globals; on native macOS, by comparison, the thread-local lookup alone
(`_tlv_get_addr`) is about 2.5% of a diff.

## The patch, and the proposal to upstream it

`toolchain/lean-wasm-threads.patch` is the whole difference from the fork: a 9-line CMake option,
`LEAN_WASM_THREADS` (default `ON`, so the fork's own builds are unchanged), that drops `-pthread`
from the Emscripten settings when `OFF`. `build-archives.sh` applies it to a clean checkout of the
pinned commit, builds stage 1 with `-DMULTI_THREAD=OFF -DLEAN_WASM_THREADS=OFF`, checks that no
compile command mentions `-pthread`, and reverts the patch on exit.

Proposed for the fork's maintainers (LeanUI does not modify the fork):

1. Land the option as is. With the default `ON` it changes nothing for existing consumers.
2. Publish single-threaded archives next to the threaded ones for each runtime release (the four
   `.a` files and `include/lean`, with `SHA256SUMS`), so applications need neither Docker nor a
   10-minute build. Archives must match the release's runtime commit exactly: archives from
   different runtime commits must never be mixed.

Until then, `toolchain/build-archives.sh` reproduces them: about ten minutes cold, a few minutes
with a warm ccache.

## Rebuilding

```bash
toolchain/build-archives.sh            # once: .toolchain/wasm64/{lib,include}
tools/build-app.sh CounterApp counter  # an app: dist/counter/{index.html,leanui.js,app.js,app.wasm}
```

Never run a bare `lean` or `lake` in this repository's tooling: `lean-toolchain` pins
`leanprover/lean4:v4.34.0`, and the scripts call that toolchain's binaries by path. The one other
toolchain is `vir/`'s (`vir/lean-toolchain`, Lean 4.35.0): a separate project that runs the
benchmarked apps on lean-vir instead of wasm64 ([vir/README.md](../vir/README.md)); `vir/build.sh`
calls it by path the same way, and so do the Roster demo's notary and its verify page's build
(`roster/notary/`, `roster/verify/build.sh`, on the same release), and its Mathlib project
(`roster/hall/`, on the main build's release) ([roster/README.md](../roster/README.md)). The race's
QED64 lane (`qed64/lean-toolchain`, the same release; [qed64/README.md](../qed64/README.md)) calls
it by path too, for its native reference; everything else there runs in QED64's own build of that
release, `lean.wasm`, under the Node 24 that `qed64/tools/node.sh` downloads, both pinned in
`qed64/qed64.lock.json`.
