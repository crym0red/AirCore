#!/usr/bin/env bash
# Build AirCore's vendored SideInstaller Rust FFI as a static XCFramework.
# Runs on a macOS GitHub Actions runner; no local Mac is required.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRATE="$ROOT/Native/SideInstallerFFI"
OUT="$ROOT/build/native/SideInstallerFFI.xcframework"
HEADERS="$ROOT/build/native/headers"
TOOLCHAIN="${RUST_TOOLCHAIN:-stable}"

command -v rustup >/dev/null || { echo 'rustup is required'; exit 1; }
rustup toolchain install "$TOOLCHAIN" --profile minimal
rustup target add --toolchain "$TOOLCHAIN" aarch64-apple-ios aarch64-apple-ios-sim
mkdir -p "$ROOT/build/native" "$HEADERS"
cp "$CRATE/include/sideinstaller.h" "$HEADERS/sideinstaller.h"
cp "$CRATE/include/idevice.h" "$HEADERS/idevice.h"
cat > "$HEADERS/SideInstallerFFI.h" <<'HEADER'
#ifndef SIDEINSTALLER_FFI_UMBRELLA_H
#define SIDEINSTALLER_FFI_UMBRELLA_H
#include "sideinstaller.h"
#include "idevice.h"
#endif
HEADER
cat > "$HEADERS/module.modulemap" <<'MAP'
module SideInstallerFFI {
  umbrella header "SideInstallerFFI.h"
  export *
  module * { export * }
}
MAP

for target_sdk in 'aarch64-apple-ios iphoneos' 'aarch64-apple-ios-sim iphonesimulator'; do
  read -r target sdk <<< "$target_sdk"
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  echo "Building SideInstaller FFI for $target using $sdk"
  BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$sdk_path" \
    IPHONEOS_DEPLOYMENT_TARGET=16.0 \
    cargo "+$TOOLCHAIN" build --locked --release --target "$target" --manifest-path "$CRATE/Cargo.toml"
done
rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "$CRATE/target/aarch64-apple-ios/release/libsideinstaller_ffi.a" -headers "$HEADERS" \
  -library "$CRATE/target/aarch64-apple-ios-sim/release/libsideinstaller_ffi.a" -headers "$HEADERS" \
  -output "$OUT"

echo "Built $OUT"
