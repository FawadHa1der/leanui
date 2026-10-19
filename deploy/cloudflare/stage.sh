#!/bin/bash
# Stages what the site container needs into deploy/cloudflare/site/ (gitignored):
#   leanui-site (the native server), dist/site/ (the wasm build), and the files it serves from the
#   repository: examples/site/{site.css,benchmarks.json} and runtime/leanui.js.
# The wasm build's app.wasm, app.js and leanui.js get brotli (quality 11) and gzip siblings, which the
# server sends to clients that accept them (as `leanui build --compress` does); Cloudflare passes
# encoded bodies through.
# Needs `lake build leanui-site` and `tools/build-app.sh SiteApp site` first. On a Mac this stages a
# macOS binary, which the linux/amd64 image cannot run: CI stages from its Linux build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; OUT="$ROOT/deploy/cloudflare/site"
for f in .lake/build/bin/leanui-site dist/site/app.wasm dist/site/app.js dist/site/leanui.js; do
  [ -f "$ROOT/$f" ] || { echo "missing $f (see the comment at the top of this script)" >&2; exit 2; }
done
rm -rf "$OUT" && mkdir -p "$OUT/dist" "$OUT/examples/site" "$OUT/runtime"
cp "$ROOT/.lake/build/bin/leanui-site" "$OUT/"
cp -R "$ROOT/dist/site" "$OUT/dist/site"
cp "$ROOT/examples/site/site.css" "$ROOT/examples/site/benchmarks.json" "$OUT/examples/site/"
cp "$ROOT/runtime/leanui.js" "$OUT/runtime/"
rm -f "$OUT"/dist/site/*.{br,gz}
node -e '
const fs=require("fs"),z=require("zlib");
for (const f of process.argv.slice(1)) {
  const b=fs.readFileSync(f), br=z.brotliCompressSync(b,{params:{[z.constants.BROTLI_PARAM_QUALITY]:11}}), gz=z.gzipSync(b,{level:9});
  fs.writeFileSync(f+".br",br); fs.writeFileSync(f+".gz",gz);
  console.log(f.split("/").pop().padEnd(10), String(b.length).padStart(9), "-> br", String(br.length).padStart(8), ", gz", String(gz.length).padStart(8));
}' "$OUT"/dist/site/{app.wasm,app.js,leanui.js}
du -sh "$OUT"
