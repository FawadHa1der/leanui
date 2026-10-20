# LeanUI on lean-vir

A second way to run a LeanUI program, kept for the benchmarks. The site and every app ship the
wasm64 build (Lean → C → wasm64 with Emscripten, `tools/build-app.sh`); this directory runs the
same Lean source in [lean-vir](https://github.com/ejgallego/lean-vir), Lean's own IR interpreter
compiled to wasm32, so the two can be compared on the same programs: side by side in the browser
on the race page (`bench/race/`, served at `/race/`), and in the automated benchmarks
(`tests/browser/bench.mjs --impls leanui,vanilla,leanvir`; results in docs/BENCHMARKS.md).

Nothing in the main build depends on this directory, and it changes nothing in the apps: the
benchmarked programs (`examples/Bench.lean`, `examples/Life.lean`) are the same files, compiled by
both.

## How it runs

| | wasm64 (production) | lean-vir (this directory) |
|---|---|---|
| Lean | 4.34.0 (`lean-toolchain`) | 4.35.0 (`vir/lean-toolchain`): lean-vir pins one Lean release |
| What the browser runs | the app compiled to C, then to wasm64 | lean-vir's interpreter (`runtime.wasm`, one for every app) and the app's IR (`.irpkg` files) |
| Entry module | `examples/BenchApp.lean`: `leanui_app Bench.program` | `vir/LeanUIVir/BenchApp.lean`: `leanui_vir_app Bench.program` |
| Host | `LeanUI/Host/Wasm.lean` + `runtime/leanui_wasm.c`: each update read in place from wasm memory | `vir/LeanUIVir/Host.lean`: each update returned to JavaScript as bytes (`[u32 opsBytes][ops][strs]`, the server's format) |
| JavaScript | `runtime/leanui.js` (`LeanUI.start`) | `runtime/leanui.js` plus `vir/leanui-vir.js` (`LeanUIVir.start`) |
| Build | `tools/build-app.sh BenchApp bench` → `dist/bench/` | `vir/build.sh bench` → `dist/vir/bench/` |
| Browsers | needs Memory64 (not in Safari yet) | any browser with WebAssembly |

Both hosts feed the same DOM code: `vir/leanui-vir.js` builds a `LeanUI.Runtime` with its own
transport, which calls the app's exported `event` and `callback` and applies the updates they
return.

## Building

    vir/build.sh            # both apps; or vir/build.sh bench, vir/build.sh life

Lake runs on the toolchain in `vir/lean-toolchain` (elan installs it). The first build needs the
network: Lake fetches lean-vir at the commit `vir/lakefile.toml` pins and downloads the matching
prebuilt interpreter. `vir/.lake` holds that build, apart from the main `.lake`.

`vir/lakefile.toml` compiles LeanUI's core from `../LeanUI` and the benchmarked programs from
`../examples`. Per app: an entry module (`LeanUIVir/<App>App.lean`), a resource module
(`LeanUIVir/<App>Resources.lean`, which makes Lake package the app's IR), a line in `apps` in
`Publish.lean`, and a page (`pages/<app>.html`).

## Limits

lean-vir interprets everything except a fixed catalog of native functions (bignums, strings,
arrays, …), and it has no C compiler. So:

* LeanUI's two inline-C buffer helpers (`LeanUI.pushU32`, `LeanUI.appendUtf8`) run as their Lean
  definitions (`vir_extern_fallback` in `leanui_vir_app`; that is why `LeanUI/Patch.lean` exposes
  them).
* The photo editor and the video lab cannot run: their pixel code uses inline C (`Editor.get32`,
  `set32`, `histAdd`) and functions outside the catalog (`ByteArray.uset`, `ByteArray.usize`,
  `Float.toUInt8`, `Float.toInt64`).
* Effects that answer with bytes (`Cmd.readFile`, `Cmd.decodeImage`) are refused: lean-vir copies
  byte arrays across the boundary, and the benchmarked apps need none.
* It is an interpreter: the benchmarks measure it at tens of times slower than the wasm64 build.

## Updating lean-vir

lean-vir promises no compatibility across revisions, and its runtime (`runtime.js`,
`runtime.wasm`) must come from the same revision as the packages. To move to a newer one: change
`rev` in `vir/lakefile.toml`, set `vir/lean-toolchain` to the Lean release that revision pins (its
own `lean-toolchain`), run `lake update` in `vir/`, then `vir/build.sh` and the race test
(`tests/browser/race.mjs`).
