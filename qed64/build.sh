#!/bin/bash
# Build the QED64 lane (qed64/README.md): Lean's own interpreter in QED64's wasm64 build of Lean,
# running examples/Bench.lean and examples/Life.lean. Writes
#   dist/qed64/rt/             what a session loads, for both apps, under content-hashed names:
#                              lean.<h>.js, lean.<h>.wasm (and its .br, .gz), apps.<h>.snap.gz and
#                              its .deps, AppsRun.<h>.lean, qed64.worker.<h>.js, core.<h>.js, the
#                              licences (LICENSE-lean4.txt, LICENSE-qed64.txt; the race links them)
#   dist/qed64/{bench,life}/   index.html (pages/<app>.html), runtime/leanui.js, lane/leanui-qed64.js
#                              and qed64.json: the session's files and settings
#   dist/qed64/{bench,life}.css   the pages' stylesheets, one level up as in the race (dist/race)
#   qed64/.lake/build/bin/{bench,life}-host   the compiled reference test/node.mjs compares with
#   qed64/build.sh
# The steps: tools/shim.py; lake build (Lean 4.35.0, qed64/lean-toolchain, called by path like the
# main build's, docs/TOOLCHAIN.md); tools/node.sh (Node 24); tools/fetch.mjs (the downloads, once
# per lock); tools/bake.sh (what lean.wasm compiles and bakes, again only when its inputs change).
# LEAN_BIN overrides the toolchain, LEANUI_QED64_CACHE the cache (qed64/.cache).
set -euo pipefail
Q="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$Q")"
C="${LEANUI_QED64_CACHE:-$Q/.cache}"
L="${LEAN_BIN:-$HOME/.elan/toolchains/$(sed 's|/|--|; s|:|---|' "$Q/lean-toolchain")/bin}"
python3 -I "$Q/tools/shim.py" "$ROOT" "$Q/.shim"
log="$(mktemp)"; trap 'rm -f "$log"' EXIT
(cd "$Q" && "$L/lake" build > "$log" 2>&1) || { tail -40 "$log"; echo "qed64/: lake build failed" >&2; exit 1; }
N="$("$Q/tools/node.sh")"
# Node's fetch ignores HTTPS_PROXY unless told to use it
if [ -n "${HTTPS_PROXY:-${https_proxy:-}}" ]; then export NODE_USE_ENV_PROXY=1; fi
"$N" "$Q/tools/fetch.mjs"
"$Q/tools/bake.sh"

B="$C/build"; D="$ROOT/dist/qed64"
rm -rf "$D" && mkdir -p "$D/rt" "$D/bench" "$D/life"
h() { (sha256sum < "$1" 2>/dev/null || shasum -a 256 < "$1") | cut -c1-"$2"; }
put() { ln -f "$1" "$D/rt/$2" 2>/dev/null || cp "$1" "$D/rt/$2"; }   # hard links: these are large
js="lean.$(h "$C/rt/lean.js" 8).js"; wasm="lean.$(h "$C/rt/lean.wasm" 8).wasm"
snap="apps.$(h "$B/snap/apps.snap.gz" 12).snap"; run="AppsRun.$(h "$Q/run/AppsRun.lean" 8).lean"
core="core.$(h "$Q/lane/core.js" 8).js"; worker="qed64.worker.$(h "$Q/lane/qed64.worker.js" 8).js"
put "$C/rt/lean.js" "$js"
put "$C/rt/lean.wasm" "$wasm"; put "$B/wasm/lean.wasm.br" "$wasm.br"; put "$B/wasm/lean.wasm.gz" "$wasm.gz"
put "$B/snap/apps.snap.gz" "$snap.gz"; put "$B/snap/apps.snap.deps" "$snap.deps"
cp "$Q/run/AppsRun.lean" "$D/rt/$run"; cp "$Q/lane/core.js" "$D/rt/$core"; cp "$Q/lane/qed64.worker.js" "$D/rt/$worker"
for l in lean4 qed64; do cp "$C/rt/LICENSE-$l" "$D/rt/LICENSE-$l.txt"; done   # .txt: text/plain, which a browser shows
cp "$ROOT/bench/bench.css" "$ROOT/bench/race/life.css" "$D/"
for app in bench life; do
  cp "$Q/pages/$app.html" "$D/$app/index.html"; cp "$ROOT/runtime/leanui.js" "$Q/lane/leanui-qed64.js" "$D/$app/"
  cat > "$D/$app/qed64.json" <<JSON
{"rt": "../rt/", "worker": "$worker", "leanJs": "$js", "leanWasm": "$wasm", "snapshot": "$snap.gz", "snapshotBytes": $(cat "$B/snap/apps.snap.bytes"),
 "snapshotDeps": "$snap.deps", "runFile": "$run", "core": "$core", "app": "$app", "pool": 2}
JSON
done
size() { wc -c < "$1" | tr -d ' '; }
mb() { awk -v b="$1" 'BEGIN { printf "%.1f MB", b / 1e6 }'; }
br=$(size "$D/rt/$wasm.br"); gz=$(size "$D/rt/$snap.gz")
echo "dist/qed64: lean.wasm $(mb "$(size "$D/rt/$wasm")") ($(mb "$br") brotli), snapshot $(mb "$(cat "$B/snap/apps.snap.bytes")")" \
  "($(mb "$gz") gzip): a session downloads $(mb $((br + gz)))"
