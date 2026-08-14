# Argus Wallet — Flutter App

This is the Flutter UI for the Argus Ergo wallet. It communicates with the
Rust core via flutter_rust_bridge (FRB) generated bindings.

## Setup

```bash
# Install FRB codegen tool
dart pub global activate flutter_rust_bridge_codegen

# Install Flutter dependencies
cd app
flutter pub get
```

## Regenerate FRB Bindings

After making changes to `rust/crates/wallet-ffi/src/lib.rs`, regenerate the
Dart bindings:

```bash
cd app
flutter_rust_bridge_codegen generate \
    --rust-input ../rust/crates/wallet-ffi/src/lib.rs \
    --dart-output lib/bridge/generated_bridge.dart
```

The generated file is gitignored and rebuilt on demand.

## Build Rust native library

### Android

```bash
# Ensure cargo-ndk is installed and targets added
cargo install cargo-ndk
rustup target add aarch64-linux-android x86_64-linux-android

# Build
./scripts/build_android.sh
```

This produces `libwallet_ffi.so` in `app/android/app/src/main/jniLibs/`.

### iOS (placeholder)

```bash
./scripts/build_ios.sh
```

## Run

```bash
cd app
flutter run
```

Requires an Android emulator or device with the `.so` present in jniLibs.

## Test Vectors

The app surface displays a test vector address to verify the bridge works:
- Mnemonic: `slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet`
- Path: `m/44'/429'/0'/0/0`
- Expected: `9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8`

In production, the mnemonic NEVER enters Dart — it comes from Android
Keystore as an encrypted blob and is decrypted only in Rust.