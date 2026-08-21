import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Cached local state for instant 0ms UI load and non-extraIndex contract tracking.
class WalletDatabaseService {
  static const _keyDbSnapshot = 'argus_local_wallet_db_v1';
  static const _keyTrackedLineages = 'argus_tracked_lineages_v1';

  /// Load cached wallet summary instantly (0ms) from local persistence.
  static Future<Map<String, dynamic>?> loadCachedState() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyDbSnapshot);
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Save the latest synced wallet summary.
  static Future<void> saveCachedState({
    required String? primaryAddress,
    required List<Map<String, dynamic>> usedAddresses,
    required int balanceNano,
    required List<Map<String, dynamic>> tokens,
    required List<Map<String, dynamic>> transactions,
    required int utxoCount,
    int lastSyncedHeight = 0,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final snapshot = {
      'primary_address': primaryAddress,
      'used_addresses': usedAddresses,
      'balance_nano_erg': balanceNano,
      'tokens': tokens,
      'transactions': transactions,
      'utxo_count': utxoCount,
      'last_synced_height': lastSyncedHeight,
      'last_sync_timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    await prefs.setString(_keyDbSnapshot, jsonEncode(snapshot));
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
    await prefs.remove(_keyDbSnapshot);
    await prefs.remove(_keyTrackedLineages);
  }
}
