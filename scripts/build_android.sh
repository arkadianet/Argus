#!/usr/bin/env bash
# ─── build_android.sh ─────────────────────────────────────────────────────
# Build libwallet_ffi.so for Android targets using cargo-ndk, then copy
# outputs into the Flutter app's jniLibs directory.
#
# Prerequisites:
#   rustup target add aarch64-linux-android x86_64-linux-android
#   cargo install cargo-ndk
#   ANDROID_NDK_HOME, or ANDROID_HOME/ndk/<latest>, or ~/Android/Sdk/ndk/<latest>
#
set -euo pipefail

if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
  SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
  if [[ -d "$SDK/ndk" ]]; then
    ANDROID_NDK_HOME="$(ls -d "$SDK/ndk/"* 2>/dev/null | tail -1 || true)"
  fi
  export ANDROID_NDK_HOME
fi
if [[ -z "${ANDROID_NDK_HOME:-}" || ! -d "${ANDROID_NDK_HOME}" ]]; then
  echo "ANDROID_NDK_HOME is not set and no NDK was found under the Android SDK."
  exit 1
fi
echo "Using NDK: $ANDROID_NDK_HOME"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUST_DIR="$SCRIPT_DIR/../rust"
FLUTTER_APP_DIR="$SCRIPT_DIR/../app"

cd "$RUST_DIR"

echo "=== Building wallet-ffi for aarch64-linux-android ==="
cargo ndk -t aarch64-linux-android -o "$FLUTTER_APP_DIR/android/app/src/main/jniLibs" build --release -p wallet-ffi 2>&1

echo "=== Building wallet-ffi for x86_64-linux-android ==="
cargo ndk -t x86_64-linux-android -o "$FLUTTER_APP_DIR/android/app/src/main/jniLibs" build --release -p wallet-ffi 2>&1

# cargo-ndk copies every cdylib; the app only loads libwallet_ffi.so
find "$FLUTTER_APP_DIR/android/app/src/main/jniLibs" -name '*.so' ! -name 'libwallet_ffi.so' -delete

echo "=== Done ==="
echo "Outputs:"
find "$FLUTTER_APP_DIR/android/app/src/main/jniLibs" -name "*.so" 2>/dev/null || echo "(no .so files found)"

# Optional: verify no ergo-node/ergo-state objects were linked
echo "=== Symbol check ==="
for abi in arm64-v8a x86_64; do
    so="$FLUTTER_APP_DIR/android/app/src/main/jniLibs/$abi/libwallet_ffi.so"
    if [ -f "$so" ]; then
        echo "$abi: $(ls -lh "$so" | awk '{print $5}')"
        if nm -D "$so" 2>/dev/null | grep -q "ergo_node\|ergo_state"; then
            echo "  WARNING: contains ergo-node/ergo-state symbols!"
        else
            echo "  OK: no ergo-node/ergo-state symbols"
        fi
    fi
done