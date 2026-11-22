#!/bin/bash
# Native build of ThreadLab against the upstream Lean 4.34.0 toolchain (multi-threaded runtime).
set -euo pipefail
cd "$(dirname "$0")"
T=~/.elan/toolchains/leanprover--lean4---v4.34.0
$T/bin/lean -c ThreadLab.c ThreadLab.lean
mkdir -p native
for f in ThreadLab lab_ffi lab_shim; do clang -O3 -I$T/include -c $f.c -o native/$f.o; done
$T/bin/leanc native/ThreadLab.o native/lab_ffi.o native/lab_shim.o -o native/threadlab
