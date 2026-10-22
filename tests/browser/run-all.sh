#!/bin/bash
# Every browser suite, in headless Chromium and Firefox; exit code 0 iff all of them passed.
#   tests/browser/run-all.sh [--build | --build-only]
# Needs the native build (`lake build`) and the wasm builds of the apps below; --build makes them
# first (tools/build-app.sh, which needs the archives from toolchain/build-archives.sh; then the
# lean-vir builds, vir/build.sh, the race page, bench/race/build.sh, and the Roster verify page,
# roster/verify/build.sh), and --build-only makes them and stops. Playwright comes from
# tests/browser/playwright.mjs (LEANUI_PLAYWRIGHT_FROM). On a shared machine, run it under the host
# browser lock.
# LEANUI_CORPUS: where the fuzz corpora go (default .lake/corpus).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT"
BIN=.lake/build/bin PORT=5331 ROSTER_PORT=5370
if [ "${1:-}" = --build ] || [ "${1:-}" = --build-only ]; then
  for app in "TodoMVCApp todomvc" "SiteApp site" "CounterApp counter" "BenchApp bench" "EffectsApp effects" \
             "PixelsApp pixels" "EditorApp editor" "VideoApp editor/video" "EditorBenchApp editor-bench" \
             "LeanUI.Testing.DepthProbe depth-probe" "LifeApp life" "RosterApp roster"; do
    read -r mod name <<< "$app"
    tools/build-app.sh "$mod" "$name" || { echo "build of $name failed"; exit 1; }
  done
  vir/build.sh || { echo "lean-vir build failed"; exit 1; }
  bench/race/build.sh || { echo "race page build failed"; exit 1; }
  roster/verify/build.sh || { echo "Roster verify page build failed"; exit 1; }
  [ "$1" = --build-only ] && exit 0
fi
CORPUS="${LEANUI_CORPUS:-.lake/corpus}"
"$BIN/leanui-props" --only corpus --corpus "$CORPUS" | tail -2 || { echo "corpus generation failed"; exit 1; }
"$BIN/leanui" serve dist --port $PORT --quiet > /dev/null 2>&1 &
SRV=$!
# The Roster demo on its own server, which notarizes rosters (roster/README.md); its receipts go to
# a fresh directory, for the verify page's tests below.
RECEIPTS="$(mktemp -d)"
"$BIN/leanui-roster" --port $ROSTER_PORT --receipts "$RECEIPTS" --quiet > /dev/null 2>&1 &
ROSTER_SRV=$!
trap 'kill $SRV $ROSTER_SRV 2>/dev/null; rm -rf "$RECEIPTS"' EXIT
for _ in $(seq 1 100); do curl -s -o /dev/null "http://127.0.0.1:$PORT/counter/index.html" && break; sleep 0.2; done
for _ in $(seq 1 100); do curl -s -o /dev/null "http://127.0.0.1:$ROSTER_PORT/roster/index.html" && break; sleep 0.2; done
failed=()
run() {
  local name=$1; shift
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::group::$name" || echo "=== $name"
  "$@"; local rc=$?
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::endgroup::"
  if [ $rc -eq 0 ]; then echo "pass: $name"; else echo "FAIL: $name (exit $rc)"; failed+=("$name"); fi
}
run todomvc node tests/browser/todomvc.mjs
run site node tests/browser/site.mjs
run counter-chromium node tests/browser/counter.mjs "http://127.0.0.1:$PORT/counter/index.html" chromium
run counter-firefox node tests/browser/counter.mjs "http://127.0.0.1:$PORT/counter/index.html" firefox
run keyed-dom node tests/browser/keyed-dom.mjs
run fuzz node tests/browser/fuzz.mjs "$CORPUS/corpus.jsonl" both
run templates node tests/browser/templates.mjs "$CORPUS/templates.jsonl" both
run apply-semantics node tests/browser/apply-semantics.mjs
run server node tests/browser/server.mjs all
run effects node tests/browser/effects.mjs --no-build
run bench-smoke-chromium node tests/browser/bench-smoke.mjs chromium
run bench-smoke-firefox node tests/browser/bench-smoke.mjs firefox
run pixels-chromium node tests/browser/pixels.mjs "http://127.0.0.1:$PORT/pixels/index.html" chromium
run pixels-firefox node tests/browser/pixels.mjs "http://127.0.0.1:$PORT/pixels/index.html" firefox
run editor-chromium node tests/browser/editor.mjs "http://127.0.0.1:$PORT/editor/index.html" chromium
run editor-firefox node tests/browser/editor.mjs "http://127.0.0.1:$PORT/editor/index.html" firefox
run video-chromium node tests/browser/video.mjs "http://127.0.0.1:$PORT/editor/video/index.html" chromium
run video-firefox node tests/browser/video.mjs "http://127.0.0.1:$PORT/editor/video/index.html" firefox
run depth node tests/browser/depth.mjs "http://127.0.0.1:$PORT/depth-probe/index.html"
run race-chromium node tests/browser/race.mjs "http://127.0.0.1:$PORT/" chromium
run race-firefox node tests/browser/race.mjs "http://127.0.0.1:$PORT/" firefox
run roster-chromium node tests/browser/roster.mjs "http://127.0.0.1:$ROSTER_PORT/roster/index.html" chromium
run roster-firefox node tests/browser/roster.mjs "http://127.0.0.1:$ROSTER_PORT/roster/index.html" firefox
# the receipt the app's test had notarized, checked under Node and on the verify page
receipt="$(ls "$RECEIPTS"/*.ndjson 2>/dev/null | head -1)"
if [ -z "$receipt" ]; then echo "FAIL: roster-verify (no receipt was notarized)"; failed+=(roster-verify)
else
  run roster-verify-node node roster/verify/test.mjs "$receipt"
  for engine in chromium firefox; do
    run "roster-verify-$engine" node tests/browser/roster-verify.mjs \
      "http://127.0.0.1:$ROSTER_PORT/roster/verify/?receipt=/roster/receipts/$(basename "$receipt")" "$engine"
  done
fi
if [ ${#failed[@]} -eq 0 ]; then echo "all browser suites passed"; else echo "failed: ${failed[*]}"; exit 1; fi
