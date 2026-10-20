#!/bin/bash
# Assemble the race page (bench/race/index.html) and the six pages it runs into dist/race/:
#   life/{vanilla,wasm64,vir}/    examples/Life.lean three ways (bench/race/life-vanilla.html,
#                                 dist/life, dist/vir/life)
#   table/{vanilla,wasm64,vir}/   the js-framework-benchmark app three ways (bench/vanilla,
#                                 dist/bench, dist/vir/bench)
# Needs `tools/build-app.sh LifeApp life`, `tools/build-app.sh BenchApp bench` and `vir/build.sh`
# first. `leanui serve dist` then serves it at /race/; the site serves it at /race/ too.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; OUT="$ROOT/dist/race"
for d in dist/life dist/bench dist/vir/life dist/vir/bench; do
  [ -f "$ROOT/$d/index.html" ] || { echo "missing $d (see the comment at the top of this script)" >&2; exit 2; }
done
rm -rf "$OUT" && mkdir -p "$OUT/life/vanilla" "$OUT/table/vanilla"
cp "$ROOT"/bench/race/{index.html,race.js,race.css} "$ROOT/bench/ops.mjs" "$OUT/"
cp "$ROOT/bench/race/life.css" "$OUT/life/"
cp "$ROOT/bench/race/life-vanilla.html" "$OUT/life/vanilla/index.html"
cp "$ROOT/bench/bench.css" "$OUT/table/"
cp "$ROOT/bench/vanilla/index.html" "$OUT/table/vanilla/"
cp -R "$ROOT/dist/life" "$OUT/life/wasm64"
cp -R "$ROOT/dist/vir/life" "$OUT/life/vir"
cp -R "$ROOT/dist/bench" "$OUT/table/wasm64"
cp -R "$ROOT/dist/vir/bench" "$OUT/table/vir"
rm -f "$OUT"/*/*/*.{br,gz}
echo "dist/race: $(du -sh "$OUT" | cut -f1)"
