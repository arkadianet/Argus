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
    await savePinWrap(pinWrapJson);
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
    } on PlatformException catch (_) {
      return false;
    }
  }

  static Future<bool> hasWrapKey() async {
    try {
      return await _channel.invokeMethod<bool>('hasWrapKey') ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  static Future<bool> hasBiometric() async {
    try {
      return await _channel.invokeMethod<bool>('hasBiometric') ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  static Future<bool> authenticateBiometric() async {
    try {
      return await _channel.invokeMethod<bool>('authenticateBiometric') ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  static Future<void> setSecureFlag(bool enable) async {
    try {
      await _channel.invokeMethod('setSecureFlag', {'enable': enable});
    } on PlatformException catch (_) {}
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
