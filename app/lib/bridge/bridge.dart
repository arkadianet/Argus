/// Argus Wallet — Bridge API
///
/// Re-exports the flutter_rust_bridge generated bindings.
/// Regenerate with:
/// ```bash
/// cd app
/// flutter_rust_bridge_codegen generate \
///     --rust-input crate::api \
///     --rust-root ../rust/crates/wallet-ffi \
///     --dart-output lib/bridge
/// ```

export 'frb_generated.dart';
