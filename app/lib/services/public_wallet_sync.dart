import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'network_controller.dart';
import 'wallet_database_service.dart';
import 'wallet_service.dart';
import 'wallet_sync_controller.dart';

const publicSnapshotNote =
    'Last-known public data · known addresses only; undiscovered funds may be missing';

/// Deliberately exposes no handle, discovery, derivation or stealth capability.
abstract class PublicWalletGateway {
  Future<Map<String, dynamic>?> load(String id);
  Future<Map<String, dynamic>> balance(String address);
  Future<List<dynamic>> history(String address);
  Future<TokenBalance> metadata(String id, int amount);
  Future<void> save(
    String id,
    Map<String, dynamic> data,
    bool Function() valid,
  );
}

class LivePublicWalletGateway implements PublicWalletGateway {
  @override
  Future<Map<String, dynamic>?> load(String id) =>
      WalletDatabaseService.loadCachedState(expectedWalletId: id);
  @override
  Future<Map<String, dynamic>> balance(String address) =>
      walletService.getBalance(address, nodeUrl: networkController.activeUrl);
  @override
  Future<List<dynamic>> history(String address) async =>
      jsonDecode(
            await walletService.getTransactionHistory(
              address,
              limit: 20,
              nodeUrl: networkController.activeUrl,
            ),
          )
          as List;
  @override
  Future<TokenBalance> metadata(String id, int amount) =>
      walletService.tokenMeta(id, amount);
  @override
  Future<void> save(
    String id,
    Map<String, dynamic> data,
    bool Function() valid,
  ) async {
    await walletService.persistTokenMeta();
    await WalletDatabaseService.savePublicSnapshot(id, data, valid);
  }
}

/// Single flight, one wallet/address/metadata request at a time. Failed attempts
/// also wait five minutes, so an outage cannot turn the fast poll into retries.
class PublicWalletSync extends ChangeNotifier {
  PublicWalletSync(this.gateway);
  final PublicWalletGateway gateway;
  static const interval = Duration(minutes: 5);
  DateTime? _lastAttempt;
  bool _busy = false;
  bool foreground = true;
  int _lifecycle = 0;

  void setForeground(bool value) {
    if (foreground != value) _lifecycle++;
    foreground = value;
  }

  bool isDue([DateTime? now]) =>
      !_busy &&
      foreground &&
      (_lastAttempt == null ||
          (now ?? DateTime.now()).difference(_lastAttempt!) >= interval);

  Future<void> tick({
    required Map<String, String?> wallets,
    required WalletSyncController controller,
    required String? activeId,
    required bool Function() unlocked,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    if (!unlocked() || !isDue(at)) return;
    _lastAttempt = at;
    _busy = true;
    final generation = controller.publicGeneration;
    final lifecycle = _lifecycle;
    bool valid() =>
        foreground &&
        lifecycle == _lifecycle &&
        unlocked() &&
        controller.publicGeneration == generation;
    try {
      for (final entry in wallets.entries) {
        if (!valid()) return;
        if (entry.key == activeId) continue;
        try {
          final old = await gateway.load(entry.key) ?? <String, dynamic>{};
          if (!valid()) return;
          final stamp =
              old['public_refreshed_at'] ?? old['last_successful_sync_at'];
          final age = stamp is int
              ? at.difference(DateTime.fromMillisecondsSinceEpoch(stamp))
              : null;
          if (age != null && !age.isNegative && age < interval) {
            if (old['balance_nano_erg'] != null)
              controller.rememberPublic(entry.key, old, generation);
            continue;
          }
          final addresses = <String>{
            ...((old['frontier_addresses'] as List?) ?? const [])
                .cast<String>(),
            for (final row in (old['used_addresses'] as List? ?? const []))
              if (row is Map && row['address'] is String)
                row['address'] as String,
            if (old['primary_address'] is String)
              old['primary_address'] as String,
            if (entry.value != null) entry.value!,
          }..remove('');
          if (addresses.isEmpty) continue;
          var nano = 0;
          final amounts = <String, int>{};
          final transactions = <String, Map<String, dynamic>>{};
          for (final address in addresses) {
            if (!valid()) return;
            final balance = await gateway.balance(address);
            nano += (balance['balance_nano_erg'] as num).toInt();
            for (final token in balance['tokens'] as List? ?? const []) {
              final id = token['id'] as String;
              amounts[id] =
                  (amounts[id] ?? 0) + (token['amount'] as num).toInt();
            }
            if (!valid()) return;
            for (final tx in await gateway.history(address)) {
              final row = Map<String, dynamic>.from(tx as Map);
              transactions[row['tx_id'] as String] = row;
            }
          }
          final tokens = <Map<String, dynamic>>[];
          for (final entry in amounts.entries) {
            if (!valid()) return;
            final t = await gateway.metadata(entry.key, entry.value);
            tokens.add({
              'id': t.id,
              'amount': t.amount,
              'name': t.name,
              'decimals': t.decimals,
              'iconUrl': t.iconUrl,
              'emissionAmount': t.emissionAmount,
            });
          }
          final rows = transactions.values.toList()
            ..sort(
              (a, b) => ((b['timestamp'] as num?) ?? 0).compareTo(
                (a['timestamp'] as num?) ?? 0,
              ),
            );
          final snapshot = <String, dynamic>{
            ...old,
            'wallet_id': entry.key,
            'balance_nano_erg': nano,
            'tokens': tokens,
            'transactions': rows.take(5).toList(),
            'public_only': true,
            'public_refreshed_at': at.millisecondsSinceEpoch,
            'last_sync_timestamp': at.millisecondsSinceEpoch,
            'sync_phase': 'idle',
          };
          if (!valid()) return;
          await gateway.save(entry.key, snapshot, valid);
          if (!valid()) return;
          controller.rememberPublic(entry.key, snapshot, generation);
        } catch (_) {
          // Any missing address/history keeps the prior snapshot and its age.
        }
      }
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}

final publicWalletSync = PublicWalletSync(LivePublicWalletGateway());
