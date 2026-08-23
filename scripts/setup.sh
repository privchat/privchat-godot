#!/bin/bash
# Fetch the vendored godot-cpp dependency (skipped when already present).
#
# godot-cpp is git-ignored in this repo instead of being a submodule because
# the extension build needs no upstream tracking — but a clean clone must be
# able to restore it. Pinned to the exact commit this extension was built
# and verified against (branch 4.5).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$REPO_ROOT/native/godot-cpp"

GODOT_CPP_REPO="https://github.com/godotengine/godot-cpp.git"
GODOT_CPP_BRANCH="4.5"
GODOT_CPP_REV="60b5a41"

if [ -f "$DEST/SConstruct" ]; then
    echo "==> godot-cpp already present at $DEST"
    exit 0
fi

echo "==> cloning godot-cpp ($GODOT_CPP_BRANCH @ $GODOT_CPP_REV)"
git clone --branch "$GODOT_CPP_BRANCH" "$GODOT_CPP_REPO" "$DEST"
git -C "$DEST" checkout --quiet "$GODOT_CPP_REV"
echo "==> godot-cpp ready at $DEST"
