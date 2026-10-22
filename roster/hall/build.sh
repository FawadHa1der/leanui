#!/usr/bin/env bash
# Checks the completeness proof. Downloads Mathlib's prebuilt files for only the modules
# RosterHall.lean imports (all of Mathlib is several GB), then builds: nothing of Mathlib compiles.
set -euo pipefail
cd "$(dirname "$0")"
lake exe cache get $(sed -n 's/^public import \(Mathlib\.[A-Za-z0-9.]*\)$/\1/p' RosterHall.lean)
lake build
