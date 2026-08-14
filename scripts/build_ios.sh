#!/usr/bin/env bash
# ─── build_ios.sh ─────────────────────────────────────────────────────────
# Build libwallet_ffi.a for iOS and copy into the Flutter project.
#
# Requires: macOS with Xcode, rustup targets installed:
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
#
# Usage: Run this on a Mac with Xcode.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUST_DIR="$SCRIPT_DIR/../rust"
FLUTTER_APP_DIR="$SCRIPT_DIR/../app"

cd "$RUST_DIR"

echo "=== Building wallet-ffi for aarch64-apple-ios ==="
cargo build --release -p wallet-ffi --target aarch64-apple-ios 2>&1

echo "=== Copying to iOS Runner ==="
mkdir -p "$FLUTTER_APP_DIR/ios/Runner"
cp "$RUST_DIR/target/aarch64-apple-ios/release/libwallet_ffi.a" \
   "$FLUTTER_APP_DIR/ios/Runner/"

echo "=== Done ==="
echo "NOTE: You must also add libwallet_ffi.a to the Xcode project's"
echo "  linked frameworks and library build phase."
echo ""
echo "After the .a is linked, run from the app directory:"
echo "  cd app && flutter build ios"