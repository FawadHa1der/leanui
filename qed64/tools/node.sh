#!/bin/bash
# Print the path of the Node that runs QED64's lean.wasm (Node 24: Memory64 without a flag), after
# downloading the release qed64.lock.json pins into the cache if it is not there yet (size and
# sha256 checked; only bin/node is kept). The cache is qed64/.cache, or $LEANUI_QED64_CACHE.
#   N="$(qed64/tools/node.sh)"
set -euo pipefail
Q="$(cd "$(dirname "$0")/.." && pwd)"
C="${LEANUI_QED64_CACHE:-$Q/.cache}"
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) p=linux-x64 ;; Linux-aarch64 | Linux-arm64) p=linux-arm64 ;;
  Darwin-arm64) p=darwin-arm64 ;; Darwin-x86_64) p=darwin-x64 ;;
  *) echo "node.sh: qed64.lock.json pins no Node for $(uname -sm)" >&2; exit 2 ;;
esac
read -r v url bytes sha < <(python3 -I -c 'import json, sys
n = json.load(open(sys.argv[1]))["node"]
print(n["version"], *n["files"][sys.argv[2]])' "$Q/qed64.lock.json" "$p")
N="$C/node/node-v$v-$p/bin/node"
if [ ! -x "$N" ]; then
  mkdir -p "$C/node"
  t="$C/node/download.$$.tar.xz"; trap 'rm -f "$t"' EXIT
  echo "node.sh: downloading Node $v ($p)" >&2
  curl -fsSL --retry 3 -o "$t" "$url"
  got="$( (sha256sum "$t" 2>/dev/null || shasum -a 256 "$t") | cut -d' ' -f1)"
  size="$(wc -c < "$t" | tr -d ' ')"
  if [ "$size" != "$bytes" ] || [ "$got" != "$sha" ]; then
    echo "node.sh: $url is $size bytes, sha256 $got; the lock pins $bytes bytes, $sha" >&2; exit 1
  fi
  tar -xJf "$t" -C "$C/node" "node-v$v-$p/bin/node"
fi
echo "$N"
