#!/usr/bin/env bash
# Build AirCore's vendored SideInstaller Rust FFI as a static XCFramework.
# Runs on a macOS GitHub Actions runner; no local Mac is required.
set -Eeuo pipefail
trap 'status=$?; echo "ERROR: native pairing build failed (exit $status) at line ${LINENO}: ${BASH_COMMAND}" >&2; exit "$status"' ERR

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE="$ROOT/Native/SideInstallerFFI"
NATIVE_DIR="$ROOT/build/native"
OUT="$NATIVE_DIR/SideInstallerFFI.xcframework"
HEADERS="$NATIVE_DIR/headers"
TOOLCHAIN="${RUST_TOOLCHAIN:-stable}"

command -v rustup >/dev/null 2>&1 || { echo 'ERROR: rustup is required on this macOS runner.' >&2; exit 1; }
command -v cargo >/dev/null 2>&1 || { echo 'ERROR: cargo is required on this macOS runner.' >&2; exit 1; }
command -v xcrun >/dev/null 2>&1 || { echo 'ERROR: Xcode command-line tools are required.' >&2; exit 1; }
command -v xcodebuild >/dev/null 2>&1 || { echo 'ERROR: xcodebuild is required.' >&2; exit 1; }

for file in "$CRATE/Cargo.toml" "$CRATE/Cargo.lock" "$CRATE/include/sideinstaller.h" "$CRATE/include/idevice.h"; do
  if [[ ! -f "$file" ]]; then
    echo "ERROR: required native source file is missing: $file" >&2
    exit 1
  fi
done

rustup toolchain install "$TOOLCHAIN" --profile minimal
rustup target add --toolchain "$TOOLCHAIN" aarch64-apple-ios aarch64-apple-ios-sim
mkdir -p "$NATIVE_DIR" "$HEADERS"
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
  echo "Building SideInstaller FFI for $target using $sdk ($sdk_path)"
  BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$sdk_path" \
    IPHONEOS_DEPLOYMENT_TARGET=16.0 \
    cargo "+$TOOLCHAIN" build --locked --release --target "$target" --manifest-path "$CRATE/Cargo.toml"
done

DEVICE_LIB="$CRATE/target/aarch64-apple-ios/release/libsideinstaller_ffi.a"
SIM_LIB="$CRATE/target/aarch64-apple-ios-sim/release/libsideinstaller_ffi.a"
for lib in "$DEVICE_LIB" "$SIM_LIB"; do
  [[ -f "$lib" ]] || { echo "ERROR: expected Rust static library was not produced: $lib" >&2; exit 1; }
done

rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "$DEVICE_LIB" -headers "$HEADERS" \
  -library "$SIM_LIB" -headers "$HEADERS" \
  -output "$OUT"

[[ -d "$OUT" ]] || { echo "ERROR: XCFramework output was not created: $OUT" >&2; exit 1; }
echo "Built $OUT"
