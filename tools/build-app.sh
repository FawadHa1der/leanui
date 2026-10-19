#!/bin/bash
# Build a LeanUI app to dist/<name>/: Lean -> C (native lake), then C -> wasm64 in the emsdk image,
# linked against the single-threaded archives (toolchain/build-archives.sh).
#   tools/build-app.sh <Module> [name] [--debug]     e.g.  tools/build-app.sh Examples.Counter counter
# --debug keeps function names (--profiling-funcs) for profilers. Environment:
#   LEANUI_PAGE            page template (default examples/<name>.html, else a minimal page)
#   LEANUI_MALLOC          emscripten allocator (default dlmalloc: same speed within noise as
#                          mimalloc here, half the linear memory; see docs/BENCHMARKS.md)
#   LEANUI_INITIAL_MEMORY  initial linear memory in bytes (default 16 MiB; it grows on demand)
#   LEANUI_FS              extra filesystem flag, e.g. -sFILESYSTEM=0 (default: keep the FS layer)
#   LEANUI_TOOLCHAIN       where the wasm64 archives live (default .toolchain)
#   LEANUI_COUNT_ALLOCS=1  link tools/alloc-count.c: count every malloc/free (tests/browser/allocs.mjs)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOD="$1"; NAME="${2:-$(echo "$MOD" | tr '.' '-' | tr 'A-Z' 'a-z')}"; MODE="${3:-}"
L="${LEAN_BIN:-$HOME/.elan/toolchains/leanprover--lean4---v4.34.0/bin}"
. "$ROOT/toolchain/fork.lock"
TC="${LEANUI_TOOLCHAIN:-$ROOT/.toolchain}/wasm64"; [ -f "$TC/lib/libInit.a" ] || { echo "run toolchain/build-archives.sh first" >&2; exit 2; }
OUT="$ROOT/dist/$NAME"; WORK="$ROOT/.lake/wasm/$NAME"
rm -rf "$WORK" && mkdir -p "$WORK/obj" "$OUT"
( cd "$ROOT" && "$L/lake" build "$MOD" 2>&1 | { grep -E "error|warning: " -A3 || true; } | head -40 )
IR="$ROOT/.lake/build/ir"
APPC="$IR/$(echo "$MOD" | tr '.' '/').c"; [ -f "$APPC" ] || { echo "no C for $MOD at $APPC (did lake build fail?)" >&2; exit 3; }
SYM="runtime_initialize_$(grep -o 'LEAN_EXPORT lean_object\* runtime_initialize_[A-Za-z0-9_]*' "$APPC" | head -1 | sed 's/.*runtime_initialize_//')"
cat > "$WORK/leanui_init.c" <<C
#include <lean/lean.h>
extern lean_object *$SYM(uint8_t builtin);
lean_object *leanui_initialize_app(void) { return $SYM(1); }
C
# Every package module goes into one archive and only the entry module is linked directly, so the
# linker pulls exactly what the app reaches (meta-only modules such as LeanUI.Syntax drop out).
# Excluded: tests, the CLI, the native-only testing and server modules, and other app entry points.
find "$IR" -name '*.c' ! -path "$IR/tests/*" ! -path "$IR/cli/*" ! -path '*/Testing/*' ! -path '*/Server*' ! -path "$APPC" \
  | { grep -v -E "^$IR/[^/]+App\.c$" || true; } > "$WORK/fw.list"
echo "$APPC" > "$WORK/app.list"
FSFLAG="${LEANUI_FS:-}"; OPT="-O3"; DBG=""; [ "$MODE" = "--debug" ] && DBG="--profiling-funcs"
CG="-m64 -fwasm-exceptions -sWASM_LEGACY_EXCEPTIONS=1 -D LEAN_EMSCRIPTEN"
map() { sed "s|^$ROOT|/proj|"; }
TCD="${LEANUI_TOOLCHAIN:-$ROOT/.toolchain}"
CNT_CC="true"; CNT_LINK=""; EXPORTS="_leanui_boot,_leanui_event,_leanui_callback,_malloc,_free"
if [ "${LEANUI_COUNT_ALLOCS:-}" = 1 ]; then
  CNT_CC="emcc $OPT $CG -c /proj/tools/alloc-count.c -o \$W/obj/count.o"
  CNT_LINK="\$W/obj/count.o"
  EXPORTS="$EXPORTS,_leanui_alloc_counter"
fi
docker run --rm -v "$ROOT":/proj -v "$TCD":/tc -v "$TCD/ccache":/root/.ccache -e EM_COMPILER_WRAPPER=ccache -w /proj "$image" bash -lc "
  set -e
  W=/proj/.lake/wasm/$NAME
  cc1() { f=\$1; o=\$W/obj/\$(echo \$f | md5sum | cut -c1-12).o; emcc $OPT $CG -I /tc/wasm64/include -c \$f -o \$o && echo \$o; }
  export -f cc1; export W
  cat \$W/fw.list | sed 's|^$ROOT|/proj|' | xargs -P 8 -I{} bash -c 'cc1 {}' > \$W/fw.objs
  cat \$W/app.list | sed 's|^$ROOT|/proj|' | xargs -P 8 -I{} bash -c 'cc1 {}' > \$W/app.objs
  emcc $OPT $CG -I /tc/wasm64/include -c /proj/runtime/leanui_wasm.c -o \$W/obj/shim.o
  emcc $OPT $CG -I /tc/wasm64/include -c \$W/leanui_init.c -o \$W/obj/init.o
  $CNT_CC
  rm -f \$W/libleanui.a && emar rcs \$W/libleanui.a \$(cat \$W/fw.objs)
  emcc $OPT $CG $DBG \$W/obj/shim.o \$W/obj/init.o $CNT_LINK \$(cat \$W/app.objs) \$W/libleanui.a \
    /tc/wasm64/lib/libStd.a /tc/wasm64/lib/libInit.a /tc/wasm64/lib/libleanrt.a /tc/wasm64/lib/libuv.a \
    -sMALLOC=${LEANUI_MALLOC:-dlmalloc} -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=${LEANUI_INITIAL_MEMORY:-16777216} -sMAXIMUM_MEMORY=4294967296 -sSTACK_SIZE=1048576 \
    -sMODULARIZE=1 -sEXPORT_NAME=LeanUIApp -sENVIRONMENT=web $FSFLAG \
    -sEXPORTED_FUNCTIONS=$EXPORTS -sEXPORTED_RUNTIME_METHODS=lengthBytesUTF8,stringToUTF8 \
    -o /proj/dist/$NAME/app.js
" 2>&1 | { grep -v "cache:INFO\|system_libs:INFO" || true; } | tail -20
cp "$ROOT/runtime/leanui.js" "$OUT/leanui.js"
PAGE="${LEANUI_PAGE:-$ROOT/examples/$NAME.html}"
if [ -f "$PAGE" ]; then cp "$PAGE" "$OUT/index.html"; else
cat > "$OUT/index.html" <<HTML
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>$NAME · LeanUI</title></head>
<body><div id="app"></div><script src="leanui.js"></script><script>LeanUI.start({ glue: "app.js", selector: "#app" }).then((rt) => { window.__leanui = rt; window.__ready = performance.now(); console.log("LeanUI ready in", rt.bootMs.toFixed(1), "ms"); }, (e) => { console.error("LeanUI failed to start:", e); document.getElementById("app").textContent = "LeanUI failed to start: " + e.message; });</script></body></html>
HTML
fi
node -e '
const fs=require("fs"),z=require("zlib"),d=process.argv[1];
for (const f of ["app.wasm","app.js","leanui.js"]) { const b=fs.readFileSync(d+"/"+f); console.log(f.padEnd(10), "raw", String(b.length).padStart(9), "gzip", String(z.gzipSync(b,{level:9}).length).padStart(8), "brotli", String(z.brotliCompressSync(b,{params:{[z.constants.BROTLI_PARAM_QUALITY]:11}}).length).padStart(8)); }' "$OUT"
