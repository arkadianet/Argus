#!/usr/bin/env bash
# ─── build_ios.sh ─────────────────────────────────────────────────────────
# Build libwallet_ffi.a for iOS targets using cargo-xcodebuild or
# manual cross-compilation. Placeholder for Phase 1.
#
# Prerequisites:
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim
#   cargo install cargo-xcodebuild
#
set -euo pipefail

echo "=== iOS build not yet implemented ==="
echo "Phase 0 is Android-first. iOS will be added in a later phase."
echo ""
echo "To build for iOS manually:"
echo "  cd rust"
echo "  cargo build --release -p wallet-ffi --target aarch64-apple-ios"
echo "  # Then copy to app/ios/Runner/"