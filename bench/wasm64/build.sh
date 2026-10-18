#!/bin/bash
# Builds bench/wasm64/rc{32,64}.{js,wasm} with the toolchain image (see tests/browser/wasm64.mjs).
set -euo pipefail
cd "$(dirname "$0")"
. ../../toolchain/fork.lock
docker run --rm -v "$PWD":/w -w /w "$image" bash -lc '
  emcc -O3 rc.c -o rc32.js -sMODULARIZE=1 -sEXPORT_NAME=M32 -sENVIRONMENT=web -sALLOW_MEMORY_GROWTH=1 -sEXPORTED_FUNCTIONS=_run
  emcc -O3 -m64 rc.c -o rc64.js -sMODULARIZE=1 -sEXPORT_NAME=M64 -sENVIRONMENT=web -sALLOW_MEMORY_GROWTH=1 -sEXPORTED_FUNCTIONS=_run' 2>&1 | grep -v "cache:INFO\|system_libs:INFO" || true
ls -la rc32.wasm rc64.wasm
