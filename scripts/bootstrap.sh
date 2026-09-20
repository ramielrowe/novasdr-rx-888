#!/usr/bin/env bash
# Fetch/refresh the vendored submodules. Safe to re-run.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
git submodule update --init --recursive
echo
echo "Pinned revisions:"
git submodule status
