import 'dart:convert';

/// Structured error from the Rust wallet core, serialized as JSON.
class ArgusException implements Exception {
  final String code;
  final String message;

  ArgusException({required this.code, required this.message});

  factory ArgusException.fromJson(String json) {
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return ArgusException(
        code: map['code'] as String? ?? 'UNKNOWN',
        message: map['message'] as String? ?? json,
      );
    } catch (_) {
      return ArgusException(code: 'GENERIC', message: json);
    }
  }

  @override
  String toString() => 'ArgusException[$code]: $message';

  bool get isHandleNotFound => code == 'HANDLE_NOT_FOUND';
  bool get isWalletLocked => code == 'WALLET_LOCKED';
  bool get isNodeUnreachable => code == 'NODE_UNREACHABLE';
  bool get isNoUtxos => code == 'NO_UTXOS';
  bool get isTxBuildFailed => code == 'TX_BUILD_FAILED';
  bool get isSigningFailed => code == 'SIGNING_FAILED';
  bool get isInvalidAddress => code == 'INVALID_ADDRESS';
  bool get isGeneric => code == 'GENERIC';
}

/// Helper to parse FRB function results.
extension FrbResult on String {
  ArgusException toArgusException() => ArgusException.fromJson(this);
}
