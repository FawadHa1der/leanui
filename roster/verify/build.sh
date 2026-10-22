#!/bin/bash
# Build the Roster verify page (roster/README.md) into dist/roster/verify/: the page (index.html,
# verify.js, verify.css, receipt.js), checker.wasm (checker/: nanoda, an independent Lean kernel,
# as a WASI command), worker.js, which runs it, and reference.json, the fingerprints of the
# published definitions and Valid as nanoda prints it (reference.mjs), exported like receipts from
# roster/notary's build of examples/Roster/Core.lean.
#   roster/verify/build.sh
# Needs Rust with the wasm32-wasip1 target (`rustup target add wasm32-wasip1`), Node, and the
# notary's toolchain, Lean 4.35 (roster/notary/lean-toolchain; elan installs it), whose tools are
# called by path like notarize.sh does (LEAN_BIN overrides it); exits with 3 without them. The first
# build needs the network: Cargo fetches nanoda_lib at the commit checker/Cargo.toml pins;
# Cargo.lock pins the rest: nanoda's dependencies at the versions of its own Cargo.lock, and sha2.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
V="$ROOT/roster/verify" N="$ROOT/roster/notary"
OUT="$ROOT/dist/roster/verify"
L="${LEAN_BIN:-$HOME/.elan/toolchains/$(sed 's|/|--|; s|:|---|' "$N/lean-toolchain")/bin}"
for tool in lake leanexport; do
  [ -x "$L/$tool" ] || { echo "no $tool in $L (elan toolchain install $(cat "$N/lean-toolchain"))" >&2; exit 3; }
done
(cd "$V/checker" && cargo build --release --locked -q)
rm -rf "$OUT" && mkdir -p "$OUT"
cp "$V/checker/target/wasm32-wasip1/release/checker.wasm" "$V"/{index.html,verify.js,verify.css,receipt.js,worker.js} "$OUT/"
# The reference: Valid, and checkRoster_iff, by which receipts prove it, with everything they rely
# on, which is everything a receipt holds outside Roster.Receipt
(cd "$N" && "$L/lake" build -q)
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# leanexport runs `lean` to find the core library: this toolchain's
LEAN_PATH="$N/.lake/build/lib/lean" PATH="$L:$PATH" "$L/leanexport" Roster.Core -- \
  Roster.Problem.Valid Roster.Problem.checkRoster_iff > "$T/reference.ndjson"
node "$V/reference.mjs" "$T/reference.ndjson" "$ROOT/examples/Roster/Core.lean" > "$OUT/reference.json"
echo "dist/roster/verify/checker.wasm: $(wc -c < "$OUT/checker.wasm") bytes, $(gzip -9c "$OUT/checker.wasm" | wc -c) gzipped"
node -e 'const r = require(process.argv[1]); console.log(`dist/roster/verify/reference.json: ${Object.keys(r.fingerprints).length} declarations from ${r.source}`)' "$OUT/reference.json"
