#!/usr/bin/env bash
# Notarize a roster (README.md): Lean 4.35 compiles the receipt, so its kernel checks the theorem
# `Roster.Receipt.valid`, then leanexport writes that theorem and everything it depends on as NDJSON
# (Lean's export format). Prints how long each step took.
#   roster/notary/notarize.sh Receipt.lean out.ndjson
# Receipt.lean is `Roster.receiptSource`'s output (examples/Roster/Receipt.lean). This project is
# built first if need be. Exits 3 if the toolchain is missing (the server then answers 503), 1 on
# any other failure, with the reason on stderr. The tools are the toolchain's that lean-toolchain
# names (elan installs it), called by path like vir/build.sh does; LEAN_BIN overrides it.
set -euo pipefail
N="$(cd "$(dirname "$0")" && pwd)"
L="${LEAN_BIN:-$HOME/.elan/toolchains/$(sed 's|/|--|; s|:|---|' "$N/lean-toolchain")/bin}"
[ $# -eq 2 ] || { echo "usage: roster/notary/notarize.sh Receipt.lean out.ndjson" >&2; exit 2; }
src="$1" out="$2"
[ -f "$src" ] || { echo "notarize: no such file: $src" >&2; exit 1; }
for tool in lake lean leanexport; do
  [ -x "$L/$tool" ] || { echo "notarize: no $tool in $L (elan toolchain install $(cat "$N/lean-toolchain"))" >&2; exit 3; }
done
# EPOCHREALTIME is bash 5's; macOS's bash 3.2 has none, and gets whole seconds
ms() { local t=${EPOCHREALTIME:-$(date +%s).000000}; t=${t/[.,]/}; echo $((t / 1000)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { cat "$T/log" >&2; rm -f "$out"; echo "notarize: $1" >&2; exit 1; }
t0=$(ms)
(cd "$N" && "$L/lake" build -q) > "$T/log" 2>&1 || fail "building roster/notary failed"
# The receipt's module sits beside Roster.Core, linked from this build: Lean looks a module up only
# under the first search path entry that has its root directory (`Roster/`).
mkdir "$T/Roster"
ln -s "$N/.lake/build/lib/lean/Roster/Core."* "$T/Roster/"
cp "$src" "$T/Roster/Receipt.lean"
t1=$(ms)
LEAN_PATH="$T" "$L/lean" -R "$T" -o "$T/Roster/Receipt.olean" "$T/Roster/Receipt.lean" > "$T/log" 2>&1 ||
  fail "Lean rejected the receipt"
t2=$(ms)
# leanexport runs `lean` to find the core library: this toolchain's
LEAN_PATH="$T" PATH="$L:$PATH" "$L/leanexport" Roster.Receipt -- Roster.Receipt.valid > "$out" 2> "$T/log" ||
  fail "leanexport failed"
t3=$(ms)
echo "notarized in $((t3 - t0)) ms (build $((t1 - t0)), lean $((t2 - t1)), leanexport $((t3 - t2))): $out, $(wc -c < "$out") bytes"
