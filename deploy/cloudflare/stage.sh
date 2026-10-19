#!/bin/bash
# Stages what the site container needs into deploy/cloudflare/site/ (gitignored):
#   leanui-site (the native server), dist/site/ (the wasm build), and the files it serves from the
#   repository: examples/site/{site.css,benchmarks.json} and runtime/leanui.js.
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
du -sh "$OUT"
