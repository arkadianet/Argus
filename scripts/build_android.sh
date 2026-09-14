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
# Callers (release_check.sh) may build to a scratch directory instead.
OUT_DIR="${OUT_DIR:-$FLUTTER_APP_DIR/android/app/src/main/jniLibs}"
# The default jniLibs directory is ours to prune; a caller-supplied one is only
# safe to prune if we created its contents.
if [ "$OUT_DIR" = "$FLUTTER_APP_DIR/android/app/src/main/jniLibs" ] \
   || [ -z "$(ls -A "$OUT_DIR" 2>/dev/null)" ]; then
  OUT_DIR_WAS_EMPTY=1
else
  OUT_DIR_WAS_EMPTY=""
fi

cd "$RUST_DIR"

# Reproducible output: without these the absolute build path is baked into the
# binary, so the same source built from a worktree and from the main checkout
# produce different bytes. scripts/release_check.sh compares a fresh build
# against the tracked libraries, and that comparison is only meaningful if the
# build is deterministic. Verified byte-identical across two path lengths.
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$REPO_ROOT=/argus --remap-path-prefix=$HOME/.cargo=/cargo"

echo "=== Building wallet-ffi for aarch64-linux-android ==="
cargo ndk -t aarch64-linux-android -o "$OUT_DIR" build --release -p wallet-ffi 2>&1

echo "=== Building wallet-ffi for x86_64-linux-android ==="
cargo ndk -t x86_64-linux-android -o "$OUT_DIR" build --release -p wallet-ffi 2>&1

# cargo-ndk copies every cdylib; the app only loads libwallet_ffi.so. OUT_DIR is
# caller-settable, so only prune a directory this build actually produced —
# pointed at a populated directory this would delete unrelated libraries.
if [ -n "$OUT_DIR_WAS_EMPTY" ]; then
  find "$OUT_DIR" -name '*.so' ! -name 'libwallet_ffi.so' -delete
else
  echo "OUT_DIR was not empty before the build; leaving other .so files alone."
fi

echo "=== Done ==="
echo "Outputs:"
find "$OUT_DIR" -name "*.so" 2>/dev/null || echo "(no .so files found)"

# Optional: verify no ergo-node/ergo-state objects were linked
echo "=== Symbol check ==="
for abi in arm64-v8a x86_64; do
    so="$OUT_DIR/$abi/libwallet_ffi.so"
    if [ -f "$so" ]; then
        echo "$abi: $(ls -lh "$so" | awk '{print $5}')"
        if nm -D "$so" 2>/dev/null | grep -q "ergo_node\|ergo_state"; then
            echo "  WARNING: contains ergo-node/ergo-state symbols!"
        else
            echo "  OK: no ergo-node/ergo-state symbols"
        fi
    fi
done