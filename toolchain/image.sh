#!/bin/bash
# Makes sure the Docker image named in toolchain/fork.lock exists: the emsdk image the archives and
# every app build run in. When it is missing, builds it from the fork's docker-wasm64/Dockerfile at
# the pinned commit (the local fork clone if there is one, else fetched from GitHub). A minute or two.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/toolchain/fork.lock"
docker info >/dev/null 2>&1 || { echo "Docker is not running" >&2; exit 30; }
docker image inspect "$image" >/dev/null 2>&1 && exit 0
SRC="$ROOT/.toolchain/lean4-fork"
if [ -f "$SRC/docker-wasm64/Dockerfile" ] && [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" = "$commit" ]; then
  docker build -t "$image" "$SRC/docker-wasm64"
else
  raw="${repo%.git}"; raw="https://raw.githubusercontent.com/${raw#https://github.com/}/$commit/docker-wasm64/Dockerfile"
  curl -fsSL "$raw" | docker build -t "$image" -
fi
