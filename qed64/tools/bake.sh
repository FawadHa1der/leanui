#!/bin/bash
# Compile the lane's Lean with lean.wasm and bake the header snapshot its sessions load
# (qed64/README.md), all with the Node tools/node.sh prints, into <cache>/build:
#   std/      the 8 Std modules LeanUI's shimmed core needs (qed64.lock.json std), from the sources
#             of the toolchain qed64/lean-toolchain names; each facet the lock pins (all but
#             .olean.private) must have QED64's digest, or the build stops: the sources would differ
#   out/      LeanUI's core (.shim), Bench and Life (../examples) and LeanUIQed.Host
#   snap/     apps.snap.gz (gzip -9), apps.snap.deps, apps.snap.bytes (its size unpacked): the bake
#             of run/AppsRun.lean at /workspace/AppsRun.lean, named by --root=/workspace as every
#             session names it (lane/core.js), so its main module is `AppsRun` in both
#   wasm/     lean.wasm.br (brotli 9) and lean.wasm.gz (gzip -9), for servers that send them
# std/ and wasm/ are made once per lock, out/ and snap/ once per STAMP (the lock, the sources and
# these tools); delete <cache>/build to start over. tools/fetch.mjs and tools/shim.py come first:
# qed64/build.sh runs all three.
set -euo pipefail
Q="$(cd "$(dirname "$0")/.." && pwd)"
C="${LEANUI_QED64_CACHE:-$Q/.cache}"; B="$C/build"
L="${LEAN_BIN:-$HOME/.elan/toolchains/$(sed 's|/|--|; s|:|---|' "$Q/lean-toolchain")/bin}"
N="$("$Q/tools/node.sh")"
W=("$N" --stack-size=8192 "$Q/tools/wasm-lean.mjs")
hash() { (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1; }
ms() { echo $(( $(date +%s) - $1 )) s; }
LOCK="$(hash < "$Q/qed64.lock.json")"
mkdir -p "$B"

# Init's and Std's .olean files alone, hard-linked, for the bake: given the other facets too, the
# snapshot also holds their server and private data (patch 0042), 352 MB instead of 114 MB
oleans() {
  rm -rf "$2" && mkdir -p "$2"
  (cd "$1" && find . -name '*.olean') | while read -r f; do mkdir -p "$2/$(dirname "$f")"; ln -f "$1/$f" "$2/$f"; done
  echo "$LOCK" > "$2/.lock"
}

if [ "$(cat "$B/std/.lock" 2>/dev/null)" != "$LOCK" ]; then
  t=$(date +%s); echo "bake: Std with lean.wasm"
  mods="$("$N" -e 'console.log(Object.keys(JSON.parse(require("fs").readFileSync(process.argv[1])).std.modules).join(" "))' "$Q/qed64.lock.json")"
  rm -rf "$B/std-src" "$B/std.tmp"
  for m in $mods; do f="${m//.//}.lean"; mkdir -p "$B/std-src/$(dirname "$f")"; cp "$L/../src/lean/$f" "$B/std-src/$f"; done
  "${W[@]}" make --src "$B/std-src" --out "$B/std.tmp" --lib "$C/init" $mods
  "$N" -e '
const fs = require("fs"), crypto = require("crypto"), [lock, dir] = process.argv.slice(1);
let bad = 0;
for (const [m, facets] of Object.entries(JSON.parse(fs.readFileSync(lock)).std.modules))
  for (const [ext, want] of Object.entries(facets)) {
    const f = `${dir}/${m.replace(/\./g, "/")}.${ext}`, got = crypto.createHash("sha256").update(fs.readFileSync(f)).digest("hex");
    if (got !== want) { console.error(`bake: ${m}.${ext} has sha256 ${got}; QED64 built ${want}`); bad++; }
  }
process.exit(bad ? 1 : 0);' "$Q/qed64.lock.json" "$B/std.tmp"
  rm -rf "$B/std" && mv "$B/std.tmp" "$B/std" && echo "$LOCK" > "$B/std/.lock"
  echo "bake: Std: $(echo $mods | wc -w | tr -d ' ') modules, as QED64 built them, $(ms $t)"
fi
[ "$(cat "$B/init-olean/.lock" 2>/dev/null)" = "$LOCK" ] || oleans "$C/init" "$B/init-olean"
[ "$(cat "$B/std-olean/.lock" 2>/dev/null)" = "$LOCK" ] || oleans "$B/std" "$B/std-olean"

inputs() { echo "$LOCK"; for f in "$@"; do echo "$f $(hash < "$f")"; done; }
STAMP="$(cd "$Q" && inputs $(find .shim -type f | LC_ALL=C sort) ../examples/Bench.lean ../examples/Life.lean \
  LeanUIQed/Host.lean run/AppsRun.lean tools/bake.sh tools/wasm-lean.mjs | hash)"
if [ "$(cat "$B/snap/.stamp" 2>/dev/null)" != "$STAMP" ]; then
  t=$(date +%s); echo "bake: LeanUI, Bench, Life, LeanUIQed.Host with lean.wasm"
  rm -rf "$B/src" "$B/out" "$B/snap" && mkdir -p "$B/src/LeanUIQed" "$B/snap" "$B/run"
  cp -R "$Q/.shim/." "$B/src/"
  cp "$Q/../examples/Bench.lean" "$Q/../examples/Life.lean" "$B/src/"
  cp "$Q/LeanUIQed/Host.lean" "$B/src/LeanUIQed/"
  "${W[@]}" make --src "$B/src" --out "$B/out" --lib "$C/init" --lib "$B/std" LeanUIQed.Host Bench Life
  echo "bake: the header snapshot"
  cp "$Q/run/AppsRun.lean" "$B/run/"
  "${W[@]}" run --lib "$B/init-olean" --lib "$B/std-olean" --lib "$B/out" --mount "$B/run:/workspace" --mount "$B/snap:/work/snap" -- \
    --incr-header-save=/work/snap/apps.snap --root=/workspace /workspace/AppsRun.lean < /dev/null > "$B/snap/bake.log" 2>&1 \
    || { tail -20 "$B/snap/bake.log"; echo "bake: the bake failed ($B/snap/bake.log)" >&2; exit 1; }
  # the page ships the snapshot alone: it must not refer to other snapshot files
  [ "$(cat "$B/snap/apps.snap.deps")" = "[]" ] || { echo "bake: apps.snap depends on other files: $(cat "$B/snap/apps.snap.deps")" >&2; exit 1; }
  wc -c < "$B/snap/apps.snap" | tr -d ' ' > "$B/snap/apps.snap.bytes"
  gzip -9 -n -c "$B/snap/apps.snap" > "$B/snap/apps.snap.gz"
  rm "$B/snap/apps.snap"
  echo "$STAMP" > "$B/snap/.stamp"
  echo "bake: apps.snap $(cat "$B/snap/apps.snap.bytes") bytes, $(wc -c < "$B/snap/apps.snap.gz" | tr -d ' ') gzipped, $(ms $t)"
fi

if [ "$(cat "$B/wasm/.lock" 2>/dev/null)" != "$LOCK" ]; then
  t=$(date +%s); rm -rf "$B/wasm" && mkdir -p "$B/wasm"
  # brotli 9: 11 MB in about 20 s (11 saves another 1.6 MB, in 4 minutes)
  "$N" -e '
const fs = require("fs"), z = require("zlib"), [src, dst] = process.argv.slice(1), b = fs.readFileSync(src);
fs.writeFileSync(dst, z.brotliCompressSync(b, { params: { [z.constants.BROTLI_PARAM_QUALITY]: 9, [z.constants.BROTLI_PARAM_LGWIN]: 24, [z.constants.BROTLI_PARAM_SIZE_HINT]: b.length } }));' \
    "$C/rt/lean.wasm" "$B/wasm/lean.wasm.br"
  gzip -9 -n -c "$C/rt/lean.wasm" > "$B/wasm/lean.wasm.gz"
  echo "$LOCK" > "$B/wasm/.lock"
  echo "bake: lean.wasm.br $(wc -c < "$B/wasm/lean.wasm.br" | tr -d ' ') bytes, .gz $(wc -c < "$B/wasm/lean.wasm.gz" | tr -d ' '), $(ms $t)"
fi
