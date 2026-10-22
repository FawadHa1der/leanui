#!/usr/bin/env bash
# Checks the completeness proof. Downloads Mathlib's prebuilt files for only the modules
# RosterHall.lean imports (all of Mathlib is several GB), then builds: nothing of Mathlib compiles.
# Lake is the toolchain's that lean-toolchain names (elan installs it), called by path like the
# main build's (docs/TOOLCHAIN.md); LEAN_BIN overrides it.
set -euo pipefail
cd "$(dirname "$0")"
L="${LEAN_BIN:-$HOME/.elan/toolchains/$(sed 's|/|--|; s|:|---|' lean-toolchain)/bin}"
# Mathlib's cache runs `lean` to find the toolchain's leantar: this toolchain's
export PATH="$L:$PATH"
"$L/lake" exe cache get $(sed -n 's/^public import \(Mathlib\.[A-Za-z0-9.]*\)$/\1/p' RosterHall.lean)
"$L/lake" build
