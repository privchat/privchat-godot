#!/bin/bash
# Build the privchat GDExtension for macOS.
# 1. cargo build privchat-sdk-c-api (release cdylib)
# 2. scons the godot-cpp extension against it
# 3. stage both dylibs + gdextension into addons/privchat/
set -euo pipefail

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
SDK_REPO="/Users/zoujiaqing/projects/privchat/privchat-sdk"
ADDON_DIR="$(cd "$NATIVE_DIR/.." && pwd)/addons/privchat"
BIN_DIR="$ADDON_DIR/bin"

echo "==> cargo build privchat-sdk-c-api (release)"
cargo build --release -p privchat-sdk-c-api --manifest-path "$SDK_REPO/Cargo.toml"

echo "==> scons godot-cpp extension"
cd "$NATIVE_DIR"
# arch=arm64: Rust cdylib is single-arch; godot-cpp universal link would fail.
scons platform=macos target=template_release arch=arm64 "$@"

echo "==> staging artifacts into $BIN_DIR"
mkdir -p "$BIN_DIR"
cp "$SDK_REPO/target/release/libprivchat_sdk_c_api.dylib" "$BIN_DIR/"
codesign --force --sign - "$BIN_DIR/libprivchat_sdk_c_api.dylib" || true
cp "$NATIVE_DIR/privchat.gdextension" "$ADDON_DIR/"
DYLIB="$BIN_DIR/libprivchat_godot.macos.template_release.dylib"
if [ -f "$DYLIB" ]; then
    # Point the SDK dependency at @loader_path so the bin/ copy is used.
    OLD_DEP="$(otool -L "$DYLIB" | grep -o '[^ ]*libprivchat_sdk_c_api.dylib' | head -1 || true)"
    if [ -n "$OLD_DEP" ] && [ "$OLD_DEP" != "@rpath/libprivchat_sdk_c_api.dylib" ]; then
        install_name_tool -change "$OLD_DEP" @rpath/libprivchat_sdk_c_api.dylib "$DYLIB"
    fi
    codesign --force --sign - "$DYLIB" || true
fi

echo "==> done"
ls -lh "$BIN_DIR"
