import 'package:flutter/services.dart';

/// Platform Keystore/Keychain for the sealed seed, PIN wrap, and optional wrap key.
class SecureStorageService {
  static const _channel = MethodChannel('com.argus.wallet/secure_storage');

  static Future<bool> saveEncryptedSeed(String encryptedSeedJson) async {
    try {
      await _channel.invokeMethod('saveEncryptedSeed', {
        'encryptedSeedJson': encryptedSeedJson,
      });
      return true;
    } on PlatformException catch (e) {
      throw _map(e, 'Failed to save');
    }
  }

  static Future<bool> saveWrapKey(String wrapKey) async {
    try {
      await _channel.invokeMethod('saveWrapKey', {'wrapKey': wrapKey});
      return true;
    } on PlatformException catch (e) {
      throw _map(e, 'Failed to save wrap key');
    }
  }

  static Future<void> savePinWrap(String pinWrapJson) async {
    try {
      await _channel.invokeMethod('savePinWrap', {'pinWrapJson': pinWrapJson});
    } on PlatformException catch (e) {
      throw _map(e, 'Failed to save PIN wrap');
    }
  }

  static Future<void> saveWalletWithPin({
    required String encryptedSeedJson,
    required String pinWrapJson,
  }) async {
    await saveEncryptedSeed(encryptedSeedJson);
    try {
      await savePinWrap(pinWrapJson);
    } catch (_) {
      await deleteEncryptedSeed();
      rethrow;
    }
    await deleteWrapKey();
  }

  static Future<String?> loadWrapKey() async {
    try {
      return await _channel.invokeMethod<String>('loadWrapKey');
    } on PlatformException catch (e) {
      throw _map(e, 'Failed to load wrap key');
    }
  }

  static Future<String?> loadPinWrap() async {
    try {
      return await _channel.invokeMethod<String>('loadPinWrap');
    } on PlatformException catch (e) {
      throw _map(e, 'Failed to load PIN wrap');
    }
  }

  static Future<String?> loadEncryptedSeed() async {
    try {
      return await _channel.invokeMethod<String>('loadEncryptedSeed');
    } on PlatformException catch (e) {
      throw _map(e, 'Failed to load');
    }
  }

  static Future<void> deleteEncryptedSeed() async {
    try {
      await _channel.invokeMethod('deleteEncryptedSeed');
    } on PlatformException catch (e) {
      throw SecureStorageException('Failed to delete: ${e.message}');
    }
  }

  static Future<void> deleteWrapKey() async {
    try {
      await _channel.invokeMethod('deleteWrapKey');
    } on PlatformException catch (e) {
      throw SecureStorageException('Failed to delete wrap key: ${e.message}');
    }
  }

  static Future<bool> hasEncryptedSeed() async {
    try {
      return await _channel.invokeMethod<bool>('hasEncryptedSeed') ?? false;
    } on PlatformException catch (e) {
      throw SecureStorageException('Failed to check: ${e.message}');
    }
  }

  static Future<bool> hasPinWrap() async {
    try {
      return await _channel.invokeMethod<bool>('hasPinWrap') ?? false;
    } on PlatformException catch (e) {
      throw _map(e, 'Failed to check PIN wrap');
    }
  }

  static Future<bool> hasWrapKey() async {
    try {
      return await _channel.invokeMethod<bool>('hasWrapKey') ?? false;
    } on PlatformException catch (e) {
      throw _map(e, 'Failed to check wrap key');
    }
  }

  static Future<bool> hasBiometric() async {
    try {
      return await _channel.invokeMethod<bool>('hasBiometric') ?? false;
    } on PlatformException catch (e) {
      if (e.code == 'BIOMETRIC') return false;
      throw _map(e, 'Failed to check biometrics');
    }
  }

  /// Returns the wrap key after a biometric prompt, or null if the user cancelled.
  static Future<String?> authenticateBiometric() async {
    try {
      final raw = await _channel.invokeMethod('authenticateBiometric');
      if (raw is String && raw.isNotEmpty) return raw;
      return null;
    } on PlatformException catch (e) {
      if (_isCancel(e)) return null;
      throw _map(e, 'Biometric');
    }
  }

  static Future<bool> setSecureFlag(bool enable) async {
    try {
      return await _channel.invokeMethod<bool>('setSecureFlag', {'enable': enable}) ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  static Future<({int count, int until})> loadPinGate() async {
    try {
      final raw = await _channel.invokeMethod('loadPinGate');
      if (raw is Map) {
        return (
          count: (raw['count'] as num?)?.toInt() ?? 0,
          until: (raw['until'] as num?)?.toInt() ?? 0,
        );
      }
      return (count: 0, until: 0);
    } on PlatformException catch (e) {
      throw _map(e, 'Failed to load PIN gate');
    }
  }

  static Future<String?> pinBlockedMessage() async {
    final gate = await loadPinGate();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (gate.until > now) {
      final wait = ((gate.until - now) / 1000).ceil();
      return 'Too many attempts. Try again in ${wait}s';
    }
    return null;
  }

  static Future<void> recordPinFailure() async {
    final gate = await loadPinGate();
    final count = gate.count + 1;
    final delaySec = 1 << (count > 6 ? 5 : count - 1);
    await savePinGate(
      count: count,
      until: DateTime.now().millisecondsSinceEpoch + delaySec * 1000,
    );
  }

  static Future<void> clearPinGate() async {
    await savePinGate(count: 0, until: 0);
  }

  static Future<void> savePinGate({required int count, required int until}) async {
    try {
      await _channel.invokeMethod('savePinGate', {'count': count, 'until': until});
    } on PlatformException catch (e) {
      throw SecureStorageException('Failed to persist PIN gate: ${e.message}');
    }
  }

  static bool _isCancel(PlatformException e) {
    final msg = e.message?.toLowerCase() ?? '';
    return e.code == 'BIOMETRIC' &&
        (msg.contains('cancel') || msg.contains('negative'));
  }

  static SecureStorageException _map(PlatformException e, String prefix) {
    if (e.code == 'KEY_INVALIDATED') {
      return SecureStorageException.biometricChanged();
    }
    return SecureStorageException('$prefix: ${e.message}');
  }
}

class SecureStorageException implements Exception {
  final String message;
  final bool isBiometricChanged;

  SecureStorageException(this.message) : isBiometricChanged = false;
  SecureStorageException.biometricChanged()
      : message = 'Biometric enrollment changed; re-enter mnemonic',
        isBiometricChanged = true;

  @override
  String toString() => 'SecureStorageException: $message';
}
