# privchat-godot

Godot 4.x addon wrapping the PrivChat SDK via a stable C ABI: a GDExtension
(C++ over godot-cpp) hosting the Rust `privchat-sdk-c-api`, plus a GDScript
facade (`addons/privchat`) for game code.

Canonical spec (SSOT): `privchat-docs/spec/04-client/GODOT_SDK_SPEC.md`.
`docs/` in this repo holds process documents only.

The extension talks to the SDK **only** through the C ABI in
`privchat-sdk-c-api` (`privchat_sdk_c_api.h`). UniFFI is the binding layer for
Kotlin/Swift and is not used, included, or linked here.

## Layout

- `addons/privchat/` — the shipped addon: GDScript facade + `bin/` dylibs +
  `privchat.gdextension`. Copy this directory into any Godot 4 project.
- `native/` — GDExtension source, `SConstruct`, `build.sh`.
- `scripts/setup.sh` — restores the git-ignored `native/godot-cpp` dependency.

## Prerequisites

- macOS (arm64); other platforms are not wired yet
- Rust toolchain (`cargo`)
- Xcode command line tools (`cc`, `xcrun`)
- `scons` (`pip install scons`)
- a checkout of `privchat-sdk` (sibling dir, or `$SDK_REPO`)

## Build

```sh
# restores native/godot-cpp (branch 4.5 @ 60b5a41) on first run
./scripts/setup.sh

# cargo build privchat-sdk-c-api + scons + stage into addons/privchat/bin
./native/build.sh
```

`build.sh` locates `privchat-sdk` in this order:

1. `$SDK_REPO` environment variable
2. `<repo-root>/../privchat-sdk`
3. `$HOME/projects/privchat/privchat-sdk`

Running `scons` directly from `native/` also works: it reads `SDK_REPO`
(or `SDK_INCLUDE`/`SDK_LIB_DIR`) from the environment or scons CLI vars,
defaulting to the sibling checkout.

## Demo

See the companion `privchat-godot-demo` repository (login/chat/room scenes
and headless e2e scripts). Its `addons/privchat` is a relative symlink into
this repo's `addons/privchat`.
