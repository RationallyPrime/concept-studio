#!/bin/bash
# Clone Blockout at the commit PrevisCore was translated from, for the parity and extraction scripts.
# Usage: scripts/blockout/fetch.sh [dir]   (prints the checkout path; use it as BLOCKOUT_DIR)
# The checkout is reference material: read it and import its engine modules by path, but never run
# npm, its package scripts or its app from it.
set -euo pipefail
commit=3f2d0564fd575f70fc28e9bfaa7e94b05e3955d9
dir="${1:-${TMPDIR:-/tmp}/blockout-3f2d056}"
if [ ! -d "$dir/.git" ]; then
    git clone --quiet https://github.com/wassermanproductions/blockout.git "$dir"
fi
git -C "$dir" checkout --quiet "$commit"
echo "$dir"
