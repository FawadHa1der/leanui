#!/bin/bash
# Build the benchmarked apps for lean-vir (vir/README.md) into dist/vir/<app>/: the app's page,
# runtime/leanui.js, vir/leanui-vir.js, and what `lake exe publish` writes: app.json and lib/vir/
# (lean-vir's interpreter, its JavaScript, and the app's IR package).
#   vir/build.sh [bench] [life] [test] (default: bench and life; test is the browser test app)
# Lake is the toolchain's that vir/lean-toolchain names (elan installs it), called by path like the
# main build's (docs/TOOLCHAIN.md); LEAN_BIN overrides it. The first build needs the network: Lake
# fetches lean-vir and downloads its prebuilt interpreter.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L="${LEAN_BIN:-$HOME/.elan/toolchains/$(sed 's|/|--|; s|:|---|' "$ROOT/vir/lean-toolchain")/bin}"
apps=("$@"); [ ${#apps[@]} -gt 0 ] || apps=(bench life)
cd "$ROOT/vir"
log="$(mktemp)"; trap 'rm -f "$log"' EXIT
"$L/lake" build > "$log" 2>&1 || { tail -40 "$log"; echo "vir/: lake build failed" >&2; exit 1; }
for app in "${apps[@]}"; do
  OUT="$ROOT/dist/vir/$app"
  rm -rf "$OUT" && mkdir -p "$OUT"
  "$L/lake" -q exe publish "$app" "$OUT"
  cp "pages/$app.html" "$OUT/index.html"
  cp "$ROOT/runtime/leanui.js" leanui-vir.js "$OUT/"
  echo "dist/vir/$app:"
  node -e '
const fs=require("fs"),z=require("zlib"),path=require("path"),d=process.argv[1];
const walk=(d)=>fs.readdirSync(d,{withFileTypes:true}).flatMap((e)=>e.isDirectory()?walk(path.join(d,e.name)):[path.join(d,e.name)]);
const size=(fs_)=>fs_.reduce(([r,b],f)=>{const x=fs.readFileSync(f);return [r+x.length,b+z.brotliCompressSync(x,{params:{[z.constants.BROTLI_PARAM_QUALITY]:11}}).length];},[0,0]);
// what the page downloads besides its HTML and JSON: the interpreter, the JavaScript and the IR
const files=walk(d).filter((f)=>/\.(wasm|js|irpkg)$/.test(f)), ir=files.filter((f)=>f.endsWith(".irpkg"));
for (const [what,fs_] of [["interpreter, JavaScript",files.filter((f)=>!ir.includes(f))],["IR package ("+ir.length+" files)",ir]]) { const [r,b]=size(fs_); console.log("  "+what.padEnd(26),"raw",String(r).padStart(9),"brotli",String(b).padStart(8)); }' "$OUT"
done
