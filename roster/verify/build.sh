#!/bin/bash
# Build the Roster verify page (roster/README.md) into dist/roster/verify/: checker.wasm (checker/:
# nanoda, an independent Lean kernel, as a WASI command) and worker.js, which runs it.
#   roster/verify/build.sh
# Needs Rust with the wasm32-wasip1 target (`rustup target add wasm32-wasip1`). The first build
# needs the network: Cargo fetches nanoda_lib at the commit checker/Cargo.toml pins; Cargo.lock
# pins the rest, at the versions of nanoda's own Cargo.lock.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
V="$ROOT/roster/verify"
OUT="$ROOT/dist/roster/verify"
(cd "$V/checker" && cargo build --release --locked -q)
rm -rf "$OUT" && mkdir -p "$OUT"
cp "$V/checker/target/wasm32-wasip1/release/checker.wasm" "$V/worker.js" "$OUT/"
echo "dist/roster/verify/checker.wasm: $(wc -c < "$OUT/checker.wasm") bytes, $(gzip -9c "$OUT/checker.wasm" | wc -c) gzipped"
