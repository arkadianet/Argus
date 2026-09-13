#!/usr/bin/env bash
# ─── release_check.sh ─────────────────────────────────────────────────────
# Release-time correctness gates. Each one exists because it was missed by
# hand at least once.
#
#   version          build_info.dart and pubspec.yaml agree
#   libs             the tracked jniLibs match a fresh build of this source
#   apks <dir>       the built APKs carry the right versionCode, ABI and cert
#   all <dir>        all three
#
# Every check asserts on positive evidence — a file exists, a number equals an
# expected value. A check that silently measures nothing is worse than none:
# it reports success for a build it never looked at.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="$REPO_ROOT/app"
JNI="$APP/android/app/src/main/jniLibs"
ABIS=(arm64-v8a x86_64)

# Flutter adds these to the base versionCode when it performs the split
# itself. They come from Flutter's tooling, not from build.gradle.kts, which
# is only `versionCode = flutter.versionCode`. A plain `flutter build apk`
# run after a --split-per-abi run re-runs Gradle, which splits anyway, and
# overwrites the split APKs with ones carrying the bare base code. That
# shipped once as a silent downgrade: an arm64 user on a +2000 code cannot
# install a later release numbered without it.
declare -A ABI_OFFSET=([arm64-v8a]=2000 [x86_64]=4000)

FAIL=0
pass() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=1; }
head_() { printf '\n=== %s ===\n' "$1"; }

sdk_tool() {
  local name="$1" d
  d="$(ls -d "${ANDROID_HOME:-$HOME/Android/Sdk}"/build-tools/*/ 2>/dev/null | sort -V | tail -1)"
  [ -n "$d" ] && [ -x "$d$name" ] && { echo "$d$name"; return 0; }
  command -v "$name" 2>/dev/null
}

# ── version ───────────────────────────────────────────────────────────────
declare -g BASE_CODE="" VERSION_NAME=""

read_version() {
  local bi="$APP/lib/build_info.dart" ps="$APP/pubspec.yaml"
  local bi_ver bi_code ps_ver ps_code ps_line
  bi_ver="$(sed -n "s/^const appVersion = '\(.*\)';/\1/p" "$bi")"
  bi_code="$(sed -n 's/^const appBuildNumber = \([0-9]*\);/\1/p' "$bi")"
  ps_line="$(sed -n 's/^version: \(.*\)$/\1/p' "$ps")"
  ps_ver="${ps_line%%+*}"; ps_code="${ps_line##*+}"
  if [ -z "$bi_ver" ] || [ -z "$bi_code" ] || [ -z "$ps_ver" ] || [ -z "$ps_code" ]; then
    fail "could not parse a version from build_info.dart and pubspec.yaml"
    return 1
  fi
  VERSION_NAME="$bi_ver"; BASE_CODE="$bi_code"
  [ "$bi_ver" = "$ps_ver" ] \
    && pass "version name agrees: $bi_ver" \
    || fail "version name differs: build_info=$bi_ver pubspec=$ps_ver"
  [ "$bi_code" = "$ps_code" ] \
    && pass "build number agrees: $bi_code" \
    || fail "build number differs: build_info=$bi_code pubspec=$ps_code"
}

check_version() { head_ "version"; read_version; }

# ── libs ──────────────────────────────────────────────────────────────────
# Rebuilds into a scratch directory and compares byte for byte. This is only
# valid because build_android.sh passes --remap-path-prefix; without it the
# absolute build path is baked in and two builds of identical source differ.
#
# rustContentHash cannot stand in for this. A change to the bridge's wire
# encoding can leave it untouched — it did for the mix-key change in #118 —
# so the init-time check passes against a stale library and the mismatch
# surfaces only when the changed function is first called.
check_libs() {
  head_ "native libraries"
  for abi in "${ABIS[@]}"; do
    [ -f "$JNI/$abi/libwallet_ffi.so" ] || { fail "$abi: no tracked library at $JNI/$abi"; return; }
  done
  local scratch; scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' RETURN
  echo "  rebuilding into $scratch (a few minutes) ..."
  if ! OUT_DIR="$scratch" "$SCRIPT_DIR/build_android.sh" >"$scratch/build.log" 2>&1; then
    fail "the rebuild failed; see $scratch/build.log"; trap - RETURN; return
  fi
  for abi in "${ABIS[@]}"; do
    local fresh="$scratch/$abi/libwallet_ffi.so" tracked="$JNI/$abi/libwallet_ffi.so"
    if [ ! -s "$fresh" ]; then
      fail "$abi: the rebuild produced no library — cannot conclude anything"
    elif cmp -s "$fresh" "$tracked"; then
      pass "$abi: tracked library matches a fresh build"
    else
      fail "$abi: tracked library is STALE — run scripts/build_android.sh and commit"
    fi
  done
}

# ── apks ──────────────────────────────────────────────────────────────────
check_apks() {
  local dir="${1:-}"
  head_ "APKs"
  [ -n "$dir" ] && [ -d "$dir" ] || { fail "usage: release_check.sh apks <directory>"; return; }
  [ -n "$BASE_CODE" ] || { read_version >/dev/null || { fail "no version to check against"; return; }; }

  local aapt apksigner
  aapt="$(sdk_tool aapt2)"; apksigner="$(sdk_tool apksigner)"
  [ -n "$aapt" ] || { fail "aapt2 not found; cannot inspect APKs"; return; }

  # universal first, so its certificate becomes the expected one
  local expect_cert="" order=(universal "${ABIS[@]}")
  for kind in "${order[@]}"; do
    local apk; apk="$(ls "$dir"/*"$kind"*.apk 2>/dev/null | head -1)"
    if [ -z "$apk" ]; then fail "$kind: no APK matching *$kind*.apk in $dir"; continue; fi

    local want=$BASE_CODE
    [ "$kind" != universal ] && want=$(( BASE_CODE + ${ABI_OFFSET[$kind]} ))

    local badging code name abis
    badging="$("$aapt" dump badging "$apk" 2>/dev/null)"
    code="$(sed -n "s/.*versionCode='\([0-9]*\)'.*/\1/p" <<<"$badging" | head -1)"
    name="$(sed -n "s/.*versionName='\([^']*\)'.*/\1/p" <<<"$badging" | head -1)"
    abis="$(sed -n "s/^native-code: //p" <<<"$badging" | tr -d \' | tr -s ' ')"

    [ -n "$code" ] || { fail "$kind: could not read a versionCode from $(basename "$apk")"; continue; }
    [ "$code" = "$want" ] \
      && pass "$kind: versionCode $code" \
      || fail "$kind: versionCode $code, expected $want (rebuild with --split-per-abi ONLY; a plain build after it overwrites these)"
    [ "$name" = "$VERSION_NAME" ] \
      && pass "$kind: versionName $name" \
      || fail "$kind: versionName $name, expected $VERSION_NAME"

    if [ "$kind" = universal ]; then
      [ "$abis" = "${ABIS[*]}" ] \
        && pass "universal: carries ${ABIS[*]}" \
        || fail "universal: carries '$abis', expected '${ABIS[*]}'"
    else
      [ "$abis" = "$kind" ] \
        && pass "$kind: carries only $kind" \
        || fail "$kind: carries '$abis', expected only '$kind'"
    fi

    if [ -n "$apksigner" ]; then
      local cert
      cert="$("$apksigner" verify --print-certs "$apk" 2>/dev/null | sed -n 's/.*SHA-256 digest: //p' | head -1)"
      if [ -z "$cert" ]; then
        fail "$kind: unsigned, or the signature could not be read"
      elif [ -z "$expect_cert" ]; then
        expect_cert="$cert"; pass "universal: signed, cert ${cert:0:16}…"
      elif [ "$cert" = "$expect_cert" ]; then
        pass "$kind: same signing cert"
      else
        fail "$kind: cert ${cert:0:16}… differs from universal's ${expect_cert:0:16}… — these will not install over each other"
      fi
    fi
  done
  [ -n "$expect_cert" ] && printf '\n  Compare against the previous release before publishing:\n    apksigner verify --print-certs <previous.apk>\n    this release: %s\n' "$expect_cert"
}

case "${1:-all}" in
  version) check_version ;;
  libs)    check_version; check_libs ;;
  apks)    check_version; check_apks "${2:-}" ;;
  all)     check_version; check_libs; check_apks "${2:-}" ;;
  *) echo "usage: $0 {version|libs|apks <dir>|all <dir>}" >&2; exit 2 ;;
esac

echo
if [ "$FAIL" -eq 0 ]; then echo "All checks passed."; else echo "Some checks FAILED — see above."; fi
exit "$FAIL"
