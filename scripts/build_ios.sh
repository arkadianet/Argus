#!/usr/bin/env bash
# Build libwallet_ffi as an xcframework (device + simulator).
# Requires macOS with Xcode:
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "iOS xcframework builds require macOS with Xcode."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUST_DIR="$SCRIPT_DIR/../rust"
OUT_DIR="$SCRIPT_DIR/../app/ios/Frameworks"
XCFRAMEWORK="$OUT_DIR/ArgusWallet.xcframework"

cd "$RUST_DIR"

echo "=== device: aarch64-apple-ios ==="
cargo build --release -p wallet-ffi --target aarch64-apple-ios

echo "=== simulator: aarch64-apple-ios-sim ==="
cargo build --release -p wallet-ffi --target aarch64-apple-ios-sim

SIM_LIB="$RUST_DIR/target/aarch64-apple-ios-sim/release/libwallet_ffi.a"
if rustup target list --installed | grep -q '^x86_64-apple-ios$'; then
  echo "=== simulator: x86_64-apple-ios ==="
  cargo build --release -p wallet-ffi --target x86_64-apple-ios
  lipo -create \
    "$SIM_LIB" \
    "$RUST_DIR/target/x86_64-apple-ios/release/libwallet_ffi.a" \
    -output "$RUST_DIR/target/libwallet_ffi-sim.a"
  SIM_LIB="$RUST_DIR/target/libwallet_ffi-sim.a"
fi

rm -rf "$XCFRAMEWORK"
mkdir -p "$OUT_DIR"
xcodebuild -create-xcframework \
  -library "$RUST_DIR/target/aarch64-apple-ios/release/libwallet_ffi.a" \
  -library "$SIM_LIB" \
  -output "$XCFRAMEWORK"

echo "=== Done ==="
echo "$XCFRAMEWORK"
echo "Add ArgusWallet.xcframework to the Xcode project, then: cd app && flutter build ios"
