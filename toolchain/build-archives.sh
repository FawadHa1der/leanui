#!/bin/bash
# Builds the single-threaded wasm64 Lean archives LeanUI links against:
#   .toolchain/wasm64/lib/{libleanrt,libInit,libStd,libuv}.a  and  .toolchain/wasm64/include/lean/lean.h
# from the fork pinned in toolchain/fork.lock, with toolchain/lean-wasm-threads.patch applied
# (MULTI_THREAD=OFF, no -pthread: no SharedArrayBuffer, so pages need no COOP/COEP).
# Requires Docker; toolchain/image.sh builds the image named in fork.lock when it is missing.
# Env: LEANUI_FORK_SRC=<path to an existing clone of the fork> skips the network clone.
# About 10 minutes cold (stage 0 + runtime + Init + Std), a few minutes with a warm ccache.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/toolchain/fork.lock"
T="$ROOT/.toolchain"; SRC="$T/lean4-fork"; B="$T/build"; OUT="$T/wasm64"
mkdir -p "$T" "$T/ccache"
if [ ! -d "$SRC/.git" ]; then
  if [ -n "${LEANUI_FORK_SRC:-}" ]; then cp -a "$LEANUI_FORK_SRC" "$SRC"
  else git init -q "$SRC" && git -C "$SRC" remote add origin "$repo" && git -C "$SRC" fetch -q --depth 1 origin "$commit"; git -C "$SRC" -c advice.detachedHead=false checkout -q FETCH_HEAD; fi
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$commit" ] || { echo "fork is not at $commit" >&2; exit 2; }
git -C "$SRC" checkout -q -- src/CMakeLists.txt
git -C "$SRC" apply "$ROOT/toolchain/lean-wasm-threads.patch"
trap 'git -C "$SRC" checkout -q -- src/CMakeLists.txt' EXIT
"$ROOT/toolchain/image.sh"
docker run --rm -v "$SRC":/lean4 -v "$B":/build -v "$T/ccache":/root/.ccache -e EM_COMPILER_WRAPPER=ccache "$image" bash -lc '
  set -e; git config --global --add safe.directory /lean4
  cmake /lean4 --preset release -B /build -DCMAKE_C_COMPILER_WORKS=1 \
    -DCMAKE_TOOLCHAIN_FILE=/emsdk/upstream/emscripten/cmake/Modules/Platform/Emscripten.cmake \
    -DCMAKE_C_FLAGS=-m64 -DCMAKE_CXX_FLAGS=-m64 -DCMAKE_AR=/emsdk/upstream/emscripten/emar \
    -DSTAGE0_CMAKE_C_COMPILER=/usr/bin/gcc -DSTAGE0_CMAKE_CXX_COMPILER=/usr/bin/g++ -DSTAGE0_CMAKE_EXECUTABLE_SUFFIX= \
    -DSTAGE0_USE_GMP=OFF -DSTAGE0_MMAP=OFF -DUSE_GMP=OFF -DMMAP=OFF -DUSE_MIMALLOC=OFF -DCHECK_OLEAN_VERSION=OFF \
    -DMULTI_THREAD=OFF -DLEAN_WASM_THREADS=OFF -DLEAN_INSTALL_SUFFIX=-linux_wasm64 \
    -DSTAGE1_LEAN_PLATFORM_TARGET=wasm64-unknown-emscripten \
    -DEMSCRIPTEN_INITIAL_MEMORY=134217728 -DEMSCRIPTEN_MAXIMUM_MEMORY=17179869184
  make -C /build stage1-configure -j12
  make -C /build/stage1 libuv leanrt -j12
  cd /build/stage1 && make -f /build/stage1/stdlib.make Init LAKE_EXTRA_ARGS="Init:static Std:static" -j12'
mkdir -p "$OUT/lib" "$OUT/include"
cp "$B/stage1/lib/lean/libInit.a" "$B/stage1/lib/lean/libStd.a" "$B/stage1/lib/lean/libleanrt.a" "$B/stage1/libuv/src/libuv/libuv.a" "$OUT/lib/"
rm -rf "$OUT/include/lean" && cp -R "$B/stage1/include/lean" "$OUT/include/lean"
grep -q 'MULTI_THREAD:BOOL=OFF' "$B/stage1/CMakeCache.txt" || { echo "the runtime was configured multi-threaded" >&2; exit 4; }
if grep -q pthread "$B/stage1/compile_commands.json"; then echo "-pthread in the compile commands" >&2; exit 4; fi
( cd "$OUT/lib" && shasum -a 256 *.a ) > "$OUT/SHA256SUMS"
echo "archives in $OUT/lib:"; ls -la "$OUT/lib"
