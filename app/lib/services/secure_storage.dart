import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

/// Platform Keystore/Keychain for the sealed seed, PIN wrap, and optional wrap key.
class SecureStorageService {
  static const _channel = MethodChannel('com.argus.wallet/secure_storage');

  static Future<bool> saveEncryptedSeed(String encryptedSeedJson, {String? walletId}) async {
    try {
      await _channel.invokeMethod('saveEncryptedSeed', {
        'encryptedSeedJson': encryptedSeedJson,
        if (walletId != null) 'walletId': walletId,
      });
      return true;
    } on PlatformException catch (e) {
      throw _map(e, 'Failed to save');
    }
  }

  static Future<bool> saveWrapKey(String wrapKey, {String? walletId}) async {
    try {
      await _channel.invokeMethod('saveWrapKey', {
        'wrapKey': wrapKey,
        if (walletId != null) 'walletId': walletId,
      });
      return true;
    } on PlatformException catch (e) {
      throw _map(e, 'Failed to save wrap key');
    }
  }

  // ── Mix keys ────────────────────────────────────────────────────────
  //
  // The extended key one level above a mix's rounds, kept only while
  // background mixing is on and the mix is in flight. It can spend that
  // mix's boxes and nothing else.

  static Future<void> saveMixKey({
    required String walletId,
    required int mixId,
    required String keyHex,
  }) async {
    try {
      await _channel.invokeMethod('saveMixKey', {
        'walletId': walletId,
        'mixId': mixId,
        'key': keyHex,
      });
    } on PlatformException catch (e) {
      throw _map(e, 'Failed to save mix key');
    }
  }

  static Future<String?> loadMixKey({required String walletId, required int mixId}) async {
    try {
      return await _channel.invokeMethod<String>('loadMixKey', {
        'walletId': walletId,
        'mixId': mixId,
      });
    } on PlatformException catch (e) {
      throw _map(e, 'Failed to load mix key');
    }
  }

  static Future<void> deleteMixKey({required String walletId, required int mixId}) async {
    try {
      await _channel.invokeMethod('deleteMixKey', {'walletId': walletId, 'mixId': mixId});
    } on PlatformException catch (e) {
      throw _map(e, 'Failed to delete mix key');
    }
  }

  /// `(walletId, mixId)` for every stored key.
  static Future<List<({String walletId, int mixId})>> listMixKeys() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('listMixKeys') ?? const [];
      final out = <({String walletId, int mixId})>[];
      for (final item in raw) {
        final s = item.toString();
        final i = s.lastIndexOf(':');
        if (i <= 0) continue;
        final id = int.tryParse(s.substring(i + 1));
        if (id == null) continue;
        out.add((walletId: s.substring(0, i), mixId: id));
      }
      return out;
    } on PlatformException catch (e) {
      throw _map(e, 'Failed to list mix keys');
    }
  }

  static Future<void> savePinWrap(String pinWrapJson, {String? walletId}) async {
    try {
      await _channel.invokeMethod('savePinWrap', {
        'pinWrapJson': pinWrapJson,
        if (walletId != null) 'walletId': walletId,
      });
    } on PlatformException catch (e) {
      throw _map(e, 'Failed to save PIN wrap');
    }
  }

  static Future<void> saveWalletWithPin({
    required String walletId,
    required String encryptedSeedJson,
    required String pinWrapJson,
    String? wrapKey,
  }) async {
    await saveEncryptedSeed(encryptedSeedJson, walletId: walletId);
    try {
      await savePinWrap(pinWrapJson, walletId: walletId);
    } catch (_) {
      await deleteEncryptedSeed(walletId: walletId);
      rethrow;
    }
    if (wrapKey != null) {
      await saveWrapKey(wrapKey, walletId: walletId);
    } else {
      await deleteWrapKey(walletId: walletId);
    }
  }

  static Future<String?> loadWrapKey({String? walletId}) async {
    try {
      return await _channel.invokeMethod<String>(
        'loadWrapKey',
        walletId != null ? {'walletId': walletId} : null,
      );
    } on PlatformException catch (e) {
      throw _map(e, 'Failed to load wrap key');
    }
  }

  static Future<String?> loadPinWrap({String? walletId}) async {
    try {
      return await _channel.invokeMethod<String>(
        'loadPinWrap',
        walletId != null ? {'walletId': walletId} : null,
      );
    } on PlatformException catch (e) {
      throw _map(e, 'Failed to load PIN wrap');
    }
  }

  static Future<String?> loadEncryptedSeed({String? walletId}) async {
    try {
      return await _channel.invokeMethod<String>(
        'loadEncryptedSeed',
        walletId != null ? {'walletId': walletId} : null,
      );
    } on PlatformException catch (e) {
      throw _map(e, 'Failed to load');
    }
  }

  static Future<void> deleteWrapKey({String? walletId}) async {
    try {
      await _channel.invokeMethod(
        'deleteWrapKey',
        walletId != null ? {'walletId': walletId} : null,
      );
    } on PlatformException catch (e) {
      throw SecureStorageException('Failed to delete wrap key: ${e.message}');
    }
  }

  static Future<void> deleteEncryptedSeed({String? walletId}) async {
    try {
      await _channel.invokeMethod(
        'deleteEncryptedSeed',
        walletId != null ? {'walletId': walletId} : null,
      );
    } on PlatformException catch (e) {
      throw SecureStorageException('Failed to delete wallet secrets: ${e.message}');
    }
  }

  static Future<void> deleteWallet(String walletId) async {
    try {
      await _channel.invokeMethod('deleteWallet', {'walletId': walletId});
    } on PlatformException catch (e) {
      throw SecureStorageException('Failed to delete wallet: ${e.message}');
    }
  }

  static Future<bool> hasEncryptedSeed({String? walletId}) async {
    try {
      return await _channel.invokeMethod<bool>(
        'hasEncryptedSeed',
        walletId != null ? {'walletId': walletId} : null,
      ) ?? false;
    } on PlatformException catch (e) {
      throw SecureStorageException('Failed to check: ${e.message}');
    }
  }

  static Future<bool> hasPinWrap({String? walletId}) async {
    try {
      return await _channel.invokeMethod<bool>(
        'hasPinWrap',
        walletId != null ? {'walletId': walletId} : null,
      ) ?? false;
    } on PlatformException catch (e) {
      throw _map(e, 'Failed to check PIN wrap');
    }
  }

  static Future<bool> hasWrapKey({String? walletId}) async {
    try {
      return await _channel.invokeMethod<bool>(
        'hasWrapKey',
        walletId != null ? {'walletId': walletId} : null,
      ) ?? false;
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
  static Future<String?> authenticateBiometric({String? walletId}) async {
    try {
      final raw = await _channel.invokeMethod(
        'authenticateBiometric',
        walletId != null ? {'walletId': walletId} : null,
      );
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
    } catch (_) {
      // PlatformException on old devices, MissingPluginException in tests.
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

  /// Returns all wallet IDs currently stored.
  static Future<List<String>> listWalletIds() async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('listWalletIds');
      return result?.map((e) => e.toString()).toList() ?? [];
    } on PlatformException catch (e) {
      throw SecureStorageException('Failed to list wallets: ${e.message}');
    }
  }

  /// Migrates a legacy single-slot wallet (pre-multi-wallet) to a new wallet ID.
  /// Returns the wallet ID if migration was performed, or null if there was
  /// nothing to migrate.
  static Future<String?> migrateLegacyWallet() async {
    final hasLegacy = await _channel.invokeMethod<bool>('hasEncryptedSeed');
    if (hasLegacy != true) return null;
    // If already migrated (wallet registry exists), do nothing.
    final ids = await listWalletIds();
    if (ids.isNotEmpty && !ids.contains('legacy')) return null;

    final newWalletId = const Uuid().v4();
    final migrated = await _channel.invokeMethod<bool>(
      'migrateLegacyWallet',
      {'newWalletId': newWalletId},
    );
    if (migrated == true) return newWalletId;
    return null;
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
