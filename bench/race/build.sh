#!/bin/bash
# Assemble the race page (bench/race/index.html) and its lanes' pages (bench/race/lanes.mjs), one
# for each scenario and lane, into dist/race/:
#   life/{vanilla,wasm64,vir}/    examples/Life.lean three ways (bench/race/life-vanilla.html,
#                                 dist/life, dist/vir/life)
#   table/{vanilla,wasm64,vir}/   the js-framework-benchmark app three ways (bench/vanilla,
#                                 dist/bench, dist/vir/bench)
#   {life,table}/qed64/           the optional QED64 lane, if qed64/build.sh built it (dist/qed64):
#   qed64-rt/                     its two pages, and the runtime and snapshot they share
#   lanes.json                    the lanes built, for each scenario: the page offers an optional
#                                 lane only where its page is here
# Needs `tools/build-app.sh LifeApp life`, `tools/build-app.sh BenchApp bench` and `vir/build.sh`
# first; without dist/qed64 it says so and goes on, unless QED64=require. `leanui serve dist` then
# serves it at /race/; the site serves it at /race/ too.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; OUT="$ROOT/dist/race"
for d in dist/life dist/bench dist/vir/life dist/vir/bench; do
  [ -f "$ROOT/$d/index.html" ] || { echo "missing $d (see the comment at the top of this script)" >&2; exit 2; }
done
Q="$ROOT/dist/qed64" qed=
if [ -f "$Q/life/qed64.json" ] && [ -f "$Q/bench/qed64.json" ]; then qed=1
elif [ "${QED64:-}" = require ]; then echo "missing dist/qed64 (qed64/build.sh)" >&2; exit 2; fi
rm -rf "$OUT" && mkdir -p "$OUT/life/vanilla" "$OUT/table/vanilla"
cp "$ROOT"/bench/race/{index.html,race.js,race.css,lanes.mjs} "$ROOT/bench/ops.mjs" "$OUT/"
cp "$ROOT/bench/race/life.css" "$OUT/life/"
cp "$ROOT/bench/race/life-vanilla.html" "$OUT/life/vanilla/index.html"
cp "$ROOT/bench/bench.css" "$OUT/table/"
cp "$ROOT/bench/vanilla/index.html" "$OUT/table/vanilla/"
cp -R "$ROOT/dist/life" "$OUT/life/wasm64"
cp -R "$ROOT/dist/vir/life" "$OUT/life/vir"
cp -R "$ROOT/dist/bench" "$OUT/table/wasm64"
cp -R "$ROOT/dist/vir/bench" "$OUT/table/vir"
rm -f "$OUT"/*/*/*.{br,gz}
# The QED64 lane: its runtime is linked rather than copied (162 MB), with the .br and .gz siblings a
# server must send (qed64/README.md), and both pages point at it.
if [ -n "$qed" ]; then
  mkdir "$OUT/qed64-rt"
  for f in "$Q/rt"/*; do ln "$f" "$OUT/qed64-rt/" 2>/dev/null || cp "$f" "$OUT/qed64-rt/"; done
  cp -R "$Q/life" "$OUT/life/qed64"; cp -R "$Q/bench" "$OUT/table/qed64"
  for j in "$OUT"/{life,table}/qed64/qed64.json; do
    sed 's|"rt": "../rt/"|"rt": "../../qed64-rt/"|' "$j" > "$j.new" && mv "$j.new" "$j"
    grep -q '"rt": "../../qed64-rt/"' "$j" || { echo "$j: no \"rt\" to point at qed64-rt/" >&2; exit 1; }
  done
else echo "dist/race: no QED64 lane (qed64/build.sh builds it)"; fi
lanes() { local d sep=""; printf '"%s": [' "$1"; for d in "$OUT/$1"/*/; do printf '%s"%s"' "$sep" "$(basename "$d")"; sep=", "; done; printf ']'; }
echo "{ $(lanes life), $(lanes table) }" > "$OUT/lanes.json"
echo "dist/race: $(du -sh "$OUT" | cut -f1)"
