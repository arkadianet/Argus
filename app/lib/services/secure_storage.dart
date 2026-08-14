import 'package:flutter/services.dart';

/// Stores and retrieves the encrypted seed blob using platform-native secure
/// storage (Android Keystore + EncryptedSharedPreferences / iOS Keychain).
///
/// The Dart side never sees the raw seed or mnemonic — only the encrypted blob.
class SecureStorageService {
  static const _channel = MethodChannel('com.argus.wallet/secure_storage');

  /// Save the encrypted seed JSON blob to platform secure storage.
  /// Returns true on success.
  static Future<bool> saveEncryptedSeed(String encryptedSeedJson) async {
    try {
      await _channel.invokeMethod('saveEncryptedSeed', {
        'encryptedSeedJson': encryptedSeedJson,
      });
      return true;
    } on PlatformException catch (e) {
      // Handle biometric enrollment change
      if (e.code == 'KEY_INVALIDATED') {
        throw SecureStorageException.biometricChanged();
      }
      throw SecureStorageException('Failed to save: ${e.message}');
    }
  }

  /// Load the encrypted seed JSON blob from platform secure storage.
  /// Returns null if no seed is stored.
  static Future<String?> loadEncryptedSeed() async {
    try {
      final result = await _channel.invokeMethod<String>('loadEncryptedSeed');
      return result;
    } on PlatformException catch (e) {
      if (e.code == 'KEY_INVALIDATED') {
        throw SecureStorageException.biometricChanged();
      }
      throw SecureStorageException('Failed to load: ${e.message}');
    }
  }

  /// Delete the stored encrypted seed.
  static Future<void> deleteEncryptedSeed() async {
    try {
      await _channel.invokeMethod('deleteEncryptedSeed');
    } on PlatformException catch (e) {
      throw SecureStorageException('Failed to delete: ${e.message}');
    }
  }

  /// Check if a seed is stored.
  static Future<bool> hasEncryptedSeed() async {
    try {
      final result = await _channel.invokeMethod<bool>('hasEncryptedSeed');
      return result ?? false;
    } on PlatformException catch (e) {
      throw SecureStorageException('Failed to check: ${e.message}');
    }
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