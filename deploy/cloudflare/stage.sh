#!/bin/bash
# Stages what the site container needs into deploy/cloudflare/site/ (gitignored):
#   leanui-site (the native server), dist/site/ (the wasm build), dist/editor/ (the photo editor,
#   its own page at /editor/, with the video lab in dist/editor/video/), dist/race/ (the race page
#   at /race/: vanilla JavaScript, wasm64 and lean-vir side by side, and the optional QED64 lane
#   where qed64/build.sh built it, its runtime in dist/race/qed64-rt/), dist/roster/ (the Roster
#   demo at /roster/: the app and its verify page, with the Feasible preset's receipt, notarized
#   here; the site has no notary), and the files it serves from the repository:
#   examples/site/{site.css,benchmarks.json} and runtime/leanui.js.
# Every .wasm, .js, .mjs, .irpkg (lean-vir's IR packages, which shrink about 8:1) and .ndjson file
# gets brotli (quality 11) and gzip siblings, which the server sends to clients that accept them (as
# `leanui build --compress` does); the Worker keeps those bytes as they are (src/worker.js,
# SiteServer.fetch; docs/DEPLOY.md, "Compression"). The exception is the QED64 lane's
# dist/race/qed64-rt (qed64/build.sh): its apps.<h>.snap.gz is the snapshot itself, not a sibling,
# and lean.wasm keeps the siblings it came with (brotli 9: 11 would take 4 more minutes for 1.6 MB).
# Needs `lake build leanui-site leanui-roster`, `tools/build-app.sh SiteApp site`,
# `tools/build-app.sh EditorApp editor`, `tools/build-app.sh VideoApp editor/video`,
# `tools/build-app.sh RosterApp roster`, `bench/race/build.sh` and `roster/verify/build.sh` (which
# say what they need) first, and Lean 4.35 for the receipt (roster/README.md). On a Mac this
# stages a macOS binary, which the linux/amd64 image cannot run: CI stages from its Linux build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; OUT="$ROOT/deploy/cloudflare/site"
for f in .lake/build/bin/leanui-site dist/site/app.wasm dist/site/app.js dist/site/leanui.js dist/editor/app.wasm \
         dist/editor/index.html dist/editor/video/app.wasm dist/race/index.html dist/race/life/vir/app.json \
         .lake/build/bin/leanui-roster dist/roster/app.wasm dist/roster/verify/checker.wasm; do
  [ -f "$ROOT/$f" ] || { echo "missing $f (see the comment at the top of this script)" >&2; exit 2; }
done
rm -rf "$OUT" && mkdir -p "$OUT/dist" "$OUT/examples/site" "$OUT/runtime"
cp "$ROOT/.lake/build/bin/leanui-site" "$OUT/"
cp -R "$ROOT/dist/site" "$OUT/dist/site"
cp -R "$ROOT/dist/editor" "$OUT/dist/editor"
cp -R "$ROOT/dist/race" "$OUT/dist/race"
cp -R "$ROOT/dist/roster" "$OUT/dist/roster"
mkdir -p "$OUT/dist/roster/receipts"
(cd "$ROOT" && .lake/build/bin/leanui-roster --notarize-sample "$OUT/dist/roster/receipts/feasible.ndjson")
cp "$ROOT/examples/site/site.css" "$ROOT/examples/site/benchmarks.json" "$OUT/examples/site/"
cp "$ROOT/runtime/leanui.js" "$OUT/runtime/"
find "$OUT/dist" \( -name '*.br' -o -name '*.gz' \) -not -path '*/race/qed64-rt/*' -delete
# prints one line per directory of dist/: files, bytes, and the siblings' bytes
find "$OUT/dist" \( -name '*.wasm' -o -name '*.js' -o -name '*.mjs' -o -name '*.irpkg' -o -name '*.ndjson' \) \
  -not -path '*/race/qed64-rt/*.wasm' -exec node -e '
const fs=require("fs"),z=require("zlib"),sum=new Map();
for (const f of process.argv.slice(1)) {
  const b=fs.readFileSync(f), br=z.brotliCompressSync(b,{params:{[z.constants.BROTLI_PARAM_QUALITY]:11}}), gz=z.gzipSync(b,{level:9});
  fs.writeFileSync(f+".br",br); fs.writeFileSync(f+".gz",gz);
  const d=f.split("/dist/").pop().split("/")[0], s=sum.get(d)||[0,0,0,0];
  sum.set(d,[s[0]+1,s[1]+b.length,s[2]+br.length,s[3]+gz.length]);
}
for (const [d,[n,b,br,gz]] of sum)
  console.log(d.padEnd(7), String(n).padStart(4), "files", String(b).padStart(9), "-> br", String(br).padStart(8), ", gz", String(gz).padStart(8));
' {} +
du -sh "$OUT"
