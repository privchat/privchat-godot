#!/bin/bash
# Build the privchat GDExtension for macOS.
# 1. cargo build privchat-sdk-c-api (release cdylib)
# 2. scons the godot-cpp extension against it
# 3. stage both dylibs + gdextension into addons/privchat/
#
# privchat-sdk location resolution order:
#   1. $SDK_REPO environment variable
#   2. <repo-root>/../privchat-sdk (sibling checkout)
#   3. $HOME/projects/privchat/privchat-sdk (monorepo layout)
set -euo pipefail

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$NATIVE_DIR/.." && pwd)"
ADDON_DIR="$REPO_ROOT/addons/privchat"
BIN_DIR="$ADDON_DIR/bin"

resolve_sdk_repo() {
    if [ -n "${SDK_REPO:-}" ]; then
        echo "$SDK_REPO"
        return
    fi
    local cand
    for cand in "$REPO_ROOT/../privchat-sdk" "$HOME/projects/privchat/privchat-sdk"; do
        if [ -f "$cand/Cargo.toml" ] && [ -d "$cand/crates/privchat-sdk-c-api" ]; then
            echo "$cand"
            return
        fi
    done
    echo ""
}

SDK_REPO="$(resolve_sdk_repo)"
if [ -z "$SDK_REPO" ] || [ ! -d "$SDK_REPO" ]; then
    echo "ERROR: could not locate the privchat-sdk repository" >&2
    echo "(SDK_REPO=${SDK_REPO:-<unset>})." >&2
    echo "Searched: \$SDK_REPO, $REPO_ROOT/../privchat-sdk," >&2
    echo "          $HOME/projects/privchat/privchat-sdk" >&2
    echo "Fix: export SDK_REPO=/path/to/privchat-sdk and re-run." >&2
    exit 1
fi
SDK_REPO="$(cd "$SDK_REPO" && pwd)"
export SDK_REPO
echo "==> using privchat-sdk at $SDK_REPO"

# Ensure the vendored godot-cpp dependency is present (clean-clone support).
if [ ! -f "$NATIVE_DIR/godot-cpp/SConstruct" ]; then
    "$REPO_ROOT/scripts/setup.sh"
fi

echo "==> cargo build privchat-sdk-c-api (release)"
# Run from inside the SDK checkout so its toolchain resolution applies; from
# elsewhere rustup may pick a toolchain without the cargo component.
(cd "$SDK_REPO" && cargo build --release -p privchat-sdk-c-api)

echo "==> scons godot-cpp extension"
cd "$NATIVE_DIR"
# arch=arm64: Rust cdylib is single-arch; godot-cpp universal link would fail.
scons platform=macos target=template_release arch=arm64 "$@"

echo "==> staging artifacts into $BIN_DIR"
mkdir -p "$BIN_DIR"
cp "$SDK_REPO/target/release/libprivchat_sdk_c_api.dylib" "$BIN_DIR/"
# cargo records an absolute build path as the dylib's own id; rewrite it so
# anything linking against the staged copy records @rpath instead.
install_name_tool -id @rpath/libprivchat_sdk_c_api.dylib "$BIN_DIR/libprivchat_sdk_c_api.dylib"
codesign --force --sign - "$BIN_DIR/libprivchat_sdk_c_api.dylib" || true
cp "$NATIVE_DIR/privchat.gdextension" "$ADDON_DIR/"
DYLIB="$BIN_DIR/libprivchat_godot.macos.template_release.dylib"
if [ -f "$DYLIB" ]; then
    # Point the SDK dependency at @loader_path so the bin/ copy is used.
    # otool indents with a TAB, so the class must exclude all whitespace —
    # `[^ ]*` keeps the tab, install_name_tool then matches nothing and
    # silently leaves the absolute path in place (it warns, it does not fail).
    OLD_DEP="$(otool -L "$DYLIB" | grep -o '[^[:space:]]*libprivchat_sdk_c_api.dylib' | head -1 || true)"
    if [ -n "$OLD_DEP" ] && [ "$OLD_DEP" != "@rpath/libprivchat_sdk_c_api.dylib" ]; then
        install_name_tool -change "$OLD_DEP" @rpath/libprivchat_sdk_c_api.dylib "$DYLIB"
    fi
    codesign --force --sign - "$DYLIB" || true
fi

# Guard: the staged extension must not reference anything outside the addon,
# otherwise it loads only on the machine that built it.
BAD="$(otool -L "$DYLIB" | tail -n +3 | grep -o '[^[:space:]]*libprivchat_sdk_c_api.dylib' | grep -v '^@rpath/' || true)"
if [ -n "$BAD" ]; then
    echo "ERROR: extension still references $BAD instead of @rpath" >&2
    exit 1
fi

echo "==> done"
ls -lh "$BIN_DIR"
