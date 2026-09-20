#!/usr/bin/env bash
# Build the image locally. Usage: scripts/build.sh [tag]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TAG="${1:-novasdr-rx-888:dev}"

if [ ! -f vendor/SDDC_Driver/CMakeLists.txt ] || [ ! -f vendor/NovaSDR/Cargo.toml ]; then
  echo "submodules missing -- running scripts/bootstrap.sh" >&2
  ./scripts/bootstrap.sh
fi

# The frontend is a submodule OF a submodule; without it stage 4 fails on a
# missing package.json, which reads as a Docker error rather than a git one.
if [ ! -f vendor/NovaSDR/frontend/package.json ]; then
  echo "FATAL: vendor/NovaSDR/frontend is empty. Run: git submodule update --init --recursive" >&2
  exit 1
fi

exec docker build --progress=plain -t "$TAG" .
