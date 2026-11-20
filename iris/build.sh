#!/bin/bash
# Checks every proof and writes the translated programs (iris/README.md):
#   dist/iris/gen/{js,c}/<program>, dist/iris/gen/manifest.json   (lake build; lake exe iris-gen)
#   dist/iris/index.html, bench/, rt/                             the page, the harness, the JS runtime
#   dist/iris/native/<program>                                    when cc is available
#   dist/iris/wasm/<program>.{js,wasm}                            when emcc is available
#   iris/build.sh [--no-native] [--no-wasm]
# Lake is the toolchain's that iris/lean-toolchain names (elan installs it), called by path like
# the main build's; LEAN_BIN overrides it. EMCC names an emcc that is not on PATH. The first build
# needs the network: Lake fetches iris-lean at the commit iris/lakefile.toml pins.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L="${LEAN_BIN:-$HOME/.elan/toolchains/$(sed 's|/|--|; s|:|---|' "$ROOT/iris/lean-toolchain")/bin}"
native=1 wasm=1
for a in "$@"; do
  case "$a" in
    --no-native) native=0 ;;
    --no-wasm) wasm=0 ;;
    *) echo "usage: iris/build.sh [--no-native] [--no-wasm]" >&2; exit 64 ;;
  esac
done
OUT="$ROOT/dist/iris"
cd "$ROOT/iris"
log="$(mktemp)"; trap 'rm -f "$log"' EXIT
"$L/lake" build > "$log" 2>&1 || { tail -40 "$log"; echo "iris/: lake build failed" >&2; exit 1; }
rm -rf "$OUT/gen" "$OUT/native" "$OUT/wasm" "$OUT/rt" "$OUT/bench"
"$L/lake" -q exe iris-gen "$OUT/gen"
# the runtime, the harness and the page next to the programs, so that dist/ serves the page
# (dist/iris/index.html) and the browser launcher (rt/browser/index.html)
mkdir -p "$OUT/rt/browser" "$OUT/bench/scenarios"
cp rt/runtime.mjs rt/pool.mjs rt/launch.mjs rt/embed.mjs "$OUT/rt/"
cp rt/browser/index.html rt/browser/worker.mjs "$OUT/rt/browser/"
cp bench/core.mjs bench/chips.mjs bench/kernels.mjs bench/worker.mjs bench/host-web.mjs "$OUT/bench/"
cp bench/scenarios/*.mjs "$OUT/bench/scenarios/"
cp page/index.html page/iris.mjs page/iris.css "$OUT/"

# Each translated C program is a whole program: the runtime is two headers it includes. A compile
# that fails fails the build (xargs exits nonzero).
CC="${CC:-cc}"
if [ $native = 1 ] && command -v "$CC" > /dev/null; then
  mkdir -p "$OUT/native"
  ls "$OUT"/gen/c/*.c | xargs -P "$(nproc)" -I{} sh -c \
    'n=$(basename {} .c); '"$CC"' -O2 -pthread -I"'"$ROOT"'/iris/rt" -w {} -o "'"$OUT"'/native/$n"'
  echo "dist/iris/native: $(ls "$OUT/native" | wc -l) programs"
else
  echo "dist/iris/native: not built (no C compiler, or --no-native)"
fi

# The pool is fixed in C: PTHREAD_POOL_SIZE must cover the threads the tests ask for (64), since a
# pthread that is not preallocated cannot start while the main thread waits.
EMCC="${EMCC:-$(command -v emcc || true)}"
if [ $wasm = 1 ] && [ -n "$EMCC" ]; then
  mkdir -p "$OUT/wasm"
  ls "$OUT"/gen/c/*.c | xargs -P 2 -I{} sh -c \
    'n=$(basename {} .c); "'"$EMCC"'" -O2 -pthread -I"'"$ROOT"'/iris/rt" -w {} -o "'"$OUT"'/wasm/$n.js" \
       -sPTHREAD_POOL_SIZE=72 -sINITIAL_MEMORY=1280MB -sENVIRONMENT=node -sEXIT_RUNTIME=1 -sSTACK_SIZE=1MB'
  echo "dist/iris/wasm: $(ls "$OUT"/wasm/*.wasm | wc -l) programs"
else
  echo "dist/iris/wasm: not built (no emcc, or --no-wasm)"
fi
