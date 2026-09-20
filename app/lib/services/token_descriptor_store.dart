import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'token_evidence.dart';

/// Per-wallet cache of resolved token descriptors.
///
/// Wallet-scoped rather than app-wide: one shared table would record that two
/// wallets hold the same token, an association neither wallet's own data
/// carries. Deleting a wallet drops its table with it.
///
/// This sits beside `argus_local_wallet_db_v3_*`, which already persists the
/// same wallet's token ids, amounts, addresses, balances and recent history.
/// Storing the names of tokens whose ids are already there adds legibility,
/// not exposure. It is still public chain data and never a secret — nothing
/// here may hold anything that is.
///
/// Evidence fields are kept rather than flattened to a name, so a cached
/// descriptor cannot quietly read as stronger proof than it was when
/// fetched. A cached name is never identity: `verifiedToken` and
/// `impersonatedToken` still key on the token id.
class TokenDescriptorStore {
  static const _prefix = 'argus_token_descriptors_v1_';
  static String _key(String walletId) => '$_prefix$walletId';

  /// Bounds one wallet's table. Matches the legacy cache's ceiling.
  static const maxEntries = 1000;

  static Map<String, dynamic> encode(CachedDescriptor d) => {
    'name': d.name,
    'decimals': d.decimals,
    'emissionAmount': d.emissionAmount,
    'iconUrl': d.iconUrl,
    'supplyEvidence': d.supplyEvidence.name,
    'decimalsEvidence': d.decimalsEvidence.name,
    'declaredAssetKind': d.declaredAssetKind.name,
    'metadataState': d.metadataState.name,
    'mediaState': d.mediaState.name,
    'source': d.source,
    if (d.incomplete) 'incomplete': true,
  };

  static CachedDescriptor? decode(String id, Object? raw) {
    if (raw is! Map) return null;
    try {
      return CachedDescriptor(
        id: id,
        name: raw['name'] as String?,
        decimals: (raw['decimals'] as num?)?.toInt() ?? 0,
        emissionAmount: (raw['emissionAmount'] as num?)?.toInt(),
        iconUrl: raw['iconUrl'] as String?,
        supplyEvidence: byName(
          SupplyEvidence.values,
          raw['supplyEvidence'],
          SupplyEvidence.unknown,
        ),
        decimalsEvidence: byName(
          DecimalsEvidence.values,
          raw['decimalsEvidence'],
          DecimalsEvidence.unknown,
        ),
        declaredAssetKind: byName(
          DeclaredAssetKind.values,
          raw['declaredAssetKind'],
          DeclaredAssetKind.none,
        ),
        metadataState: byName(
          MetadataState.values,
          raw['metadataState'],
          MetadataState.partial,
        ),
        mediaState: byName(
          MediaState.values,
          raw['mediaState'],
          MediaState.unknown,
        ),
        source: raw['source'] as String?,
        incomplete: raw['incomplete'] == true,
      );
    } catch (_) {
      // One unreadable row costs a refetch, not the whole table.
      return null;
    }
  }

  /// Unknown or absent names fall back rather than throwing, so a table
  /// written by a newer build stays readable.
  static T byName<T extends Enum>(List<T> values, Object? raw, T fallback) {
    if (raw is! String) return fallback;
    for (final v in values) {
      if (v.name == raw) return v;
    }
    return fallback;
  }

  static Future<Map<String, CachedDescriptor>> load(String walletId) async {
    if (walletId.isEmpty) return {};
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(walletId));
    if (raw == null || raw.isEmpty) return {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final out = <String, CachedDescriptor>{};
      for (final e in map.entries.take(maxEntries)) {
        final decoded = decode(e.key, e.value);
        if (decoded != null) out[e.key] = decoded;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  /// Test seam: runs just before a write. The window between selecting
  /// descriptors and writing them is real and has to be reachable
  /// deterministically, not by hoping a timer lands inside it.
  @visibleForTesting
  static Future<void> Function()? beforeSave;

  static Future<void> save(
    String walletId,
    Map<String, CachedDescriptor> entries,
  ) async {
    if (walletId.isEmpty) return;
    final hook = beforeSave;
    if (hook != null) await hook();
    // Serialize before suspending. Callers may hand over a map they mutate;
    // enumerating it after an await could capture a different wallet's data.
    final payload = jsonEncode({
      for (final e in entries.entries.take(maxEntries)) e.key: encode(e.value),
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(walletId), payload);
  }

  static Future<void> clear(String walletId) async {
    if (walletId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(walletId));
  }

  /// Every wallet's table, for a global wipe.
  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().toList()) {
      if (key.startsWith(_prefix)) await prefs.remove(key);
    }
  }
}

/// A descriptor as stored: chain-derived facts plus the evidence that backs
/// them. Deliberately not a `TokenBalance` — it carries no amount, so a
/// holding can never be reconstructed from the cache alone.
class CachedDescriptor {
  const CachedDescriptor({
    required this.id,
    this.name,
    this.decimals = 0,
    this.emissionAmount,
    this.iconUrl,
    this.supplyEvidence = SupplyEvidence.unknown,
    this.decimalsEvidence = DecimalsEvidence.unknown,
    this.declaredAssetKind = DeclaredAssetKind.none,
    this.metadataState = MetadataState.partial,
    this.mediaState = MediaState.unknown,
    this.source,
    this.incomplete = false,
  });

  final String id;
  final String? name;
  final int decimals;
  final int? emissionAmount;
  final String? iconUrl;
  final SupplyEvidence supplyEvidence;
  final DecimalsEvidence decimalsEvidence;
  final DeclaredAssetKind declaredAssetKind;
  final MetadataState metadataState;
  final MediaState mediaState;

  /// Endpoint this came from, so a descriptor's provenance survives a
  /// restart and is not silently attributed to whatever node is current.
  final String? source;

  /// The issuance box could not be read, so the registers are missing.
  /// Persisted: without it a restart cannot tell a partial descriptor from
  /// a complete one, and would never ask for the rest again.
  final bool incomplete;
}
