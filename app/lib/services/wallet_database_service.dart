import 'dart:convert';
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';

/// Local cache for instant 0ms UI load and non-extraIndex contract tracking.
///
/// NOT encryption: `_obfuscate` only deters casual greps of prefs files. The
/// key is derived from the wallet id, which is stored inside the payload
/// itself, so anyone with file access (root, backup, malware) can read
/// everything here — addresses, balances, full transaction history.
///
/// Platform notes: Android excludes this data from cloud backup and D2D
/// transfer (see AndroidManifest + data_extraction_rules.xml). On iOS,
/// NSUserDefaults IS included in iCloud/device backups — only obfuscated,
/// never encrypted. This is acceptable solely because the payload is public
/// chain data; never store secrets through this service. FLAG_SECURE guards
/// the screen, not storage, and is irrelevant here.
/// A wallet's last synced total, for rows the app cannot sync right now.
class LastKnownBalance {
  const LastKnownBalance({required this.balanceNano, required this.age});
  final int balanceNano;
  final Duration age;
}

class WalletDatabaseService {
  /// One snapshot per wallet id (v3); the older single slot is ignored.
  static String _snapshotKey(String walletId) => 'argus_local_wallet_db_v3_$walletId';
  static const _keyTrackedLineages = 'argus_tracked_lineages_v2';

  /// Obfuscate plaintext with a wallet-specific deterministic keystream.
  static String _obfuscate(String plaintext, String walletId) {
    final textBytes = utf8.encode(plaintext);
    final keyBytes = utf8.encode(walletId);
    if (keyBytes.isEmpty) return base64Encode(textBytes);

    final out = Uint8List(textBytes.length);
    for (var i = 0; i < textBytes.length; i++) {
      final k = keyBytes[i % keyBytes.length] ^ ((i * 31 + 17) & 0xFF);
      out[i] = textBytes[i] ^ k;
    }
    return base64Encode(out);
  }

  /// De-obfuscate ciphertext with the expected wallet-specific keystream.
  static String? _deobfuscate(String ciphertext, String walletId) {
    try {
      final encBytes = base64Decode(ciphertext);
      final keyBytes = utf8.encode(walletId);
      if (keyBytes.isEmpty) return utf8.decode(encBytes);

      final out = Uint8List(encBytes.length);
      for (var i = 0; i < encBytes.length; i++) {
        final k = keyBytes[i % keyBytes.length] ^ ((i * 31 + 17) & 0xFF);
        out[i] = encBytes[i] ^ k;
      }
      return utf8.decode(out);
    } catch (_) {
      return null;
    }
  }

  /// Load cached wallet summary scoped to a stable unlocked-wallet identifier.
  static Future<Map<String, dynamic>?> loadCachedState({
    required String expectedWalletId,
  }) async {
    if (expectedWalletId.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_snapshotKey(expectedWalletId));
    if (raw == null || raw.isEmpty) return null;

    try {
      final decrypted = _deobfuscate(raw, expectedWalletId);
      if (decrypted == null) return null;

      final map = jsonDecode(decrypted) as Map<String, dynamic>;
      if (map['wallet_id'] != expectedWalletId) {
        // Mismatched wallet identifier — reject cache
        return null;
      }
      return map;
    } catch (_) {
      return null;
    }
  }

  /// Save the latest synced wallet summary scoped to the unlocked wallet identifier.
  static Future<void> saveCachedState({
    required String walletId,
    required String? primaryAddress,
    required List<Map<String, dynamic>> usedAddresses,
    required int balanceNano,
    required List<Map<String, dynamic>> tokens,
    required List<Map<String, dynamic>> transactions,
    required int utxoCount,
    int lastSyncedHeight = 0,
  }) async {
    if (walletId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final snapshot = {
      'wallet_id': walletId,
      'primary_address': primaryAddress,
      'used_addresses': usedAddresses,
      'balance_nano_erg': balanceNano,
      'tokens': tokens,
      'transactions': transactions,
      'utxo_count': utxoCount,
      'last_synced_height': lastSyncedHeight,
      'last_sync_timestamp': DateTime.now().millisecondsSinceEpoch,
    };

    final obfuscated = _obfuscate(jsonEncode(snapshot), walletId);
    await prefs.setString(_snapshotKey(walletId), obfuscated);
  }

  static Future<LastKnownBalance?> lastKnownBalance(String walletId) async {
    final map = await loadCachedState(expectedWalletId: walletId);
    if (map == null) return null;
    final at = (map['last_sync_timestamp'] as num?)?.toInt();
    return LastKnownBalance(
      balanceNano: (map['balance_nano_erg'] as num?)?.toInt() ?? 0,
      age: at == null ? Duration.zero : DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(at)),
    );
  }

  static Future<void> clearWallet(String walletId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_snapshotKey(walletId));
  }

  /// Record or update a tracked DeFi singleton contract lineage.
  static Future<void> recordLineage({
    required String singletonTokenId,
    required String protocolName,
    required String rootBoxId,
    required String currentBoxId,
    required int lastUpdatedHeight,
    Map<String, dynamic>? boxJson,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyTrackedLineages);
    final map = raw != null ? (jsonDecode(raw) as Map<String, dynamic>) : <String, dynamic>{};

    map[singletonTokenId] = {
      'singleton_token_id': singletonTokenId,
      'protocol_name': protocolName,
      'root_box_id': rootBoxId,
      'current_box_id': currentBoxId,
      'last_updated_height': lastUpdatedHeight,
      'box_json': boxJson,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };

    await prefs.setString(_keyTrackedLineages, jsonEncode(map));
  }

  /// Get all tracked contract lineages.
  static Future<Map<String, dynamic>> getTrackedLineages() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyTrackedLineages);
    if (raw == null || raw.isEmpty) return {};
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  /// Clear cached local state (e.g. on wallet reset).
  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in prefs.getKeys().where((k) => k.startsWith('argus_local_wallet_db_')).toList()) {
      await prefs.remove(k);
    }
    await prefs.remove(_keyTrackedLineages);
  }
}
