import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'address_holdings.dart';
import 'network_controller.dart';
import 'pending_balance.dart';
import 'wallet_database_service.dart';
import 'wallet_service.dart';
import 'wallet_sync_controller.dart';

/// Shown once per screen, never per row: locked rows carry only their age.
const lockedWalletsExplainer =
    'Locked wallets refresh from public data every 5 minutes, covering only '
    'the addresses this app already knows. Unlock one to pick up new '
    'addresses and stealth funds.';

/// Deliberately exposes no handle, discovery, derivation or stealth capability.
abstract class PublicWalletGateway {
  Future<Map<String, dynamic>?> load(String id);
  Future<Map<String, dynamic>> balance(String address);
  Future<List<dynamic>> history(String address);
  Future<void> save(
    String id,
    Map<String, dynamic> data,
    bool Function() valid,
  );

  /// Every address's balance in one read, one address at a time, shaped
  /// like the sync inputs: `balances` by address, plus `pending` activity
  /// rows and the wallet-wide pending `summary` when the gateway can value
  /// the mempool across the addresses. This fallback has neither.
  Future<Map<String, dynamic>> inputs(List<String> addresses) async => {
    'balances': {
      for (final address in addresses) address: await balance(address),
    },
  };
}

class LivePublicWalletGateway extends PublicWalletGateway {
  @override
  Future<Map<String, dynamic>?> load(String id) =>
      WalletDatabaseService.loadCachedState(expectedWalletId: id);
  @override
  Future<Map<String, dynamic>> balance(String address) =>
      walletService.getBalance(address, nodeUrl: networkController.activeUrl);

  /// One sequential read for the whole wallet: balances, pending rows and
  /// the pending summary, valued across all the known addresses at once.
  @override
  Future<Map<String, dynamic>> inputs(List<String> addresses) => walletService
      .loadPublicSyncInputs(addresses, nodeUrl: networkController.activeUrl);
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

  /// Forgets the last attempt, so the next check is due. The scheduler is a
  /// process-wide singleton; tests that each launch the home screen need it.
  @visibleForTesting
  void resetSchedule() => _lastAttempt = null;

  bool isDue([DateTime? now]) =>
      !_busy &&
      foreground &&
      (_lastAttempt == null ||
          (now ?? DateTime.now()).difference(_lastAttempt!) >= interval);

  /// [recordedAddresses] are addresses the wallet list itself keeps for a
  /// wallet (index 0, and the pinned address), queried even when no
  /// snapshot recorded them: without them a pinned wallet that has no
  /// snapshot yet is read at its pinned address alone, and what index 0
  /// holds goes missing from its total.
  ///
  /// [whileLocked] lets the pass run with every wallet locked. The launch
  /// overview shows each wallet's balance before anything is unlocked, and
  /// these reads need no key: they ask the user's node about addresses it
  /// was already shown. Unlocking, switching, locking or deleting still
  /// revokes the pass through the controller's public generation.
  Future<void> tick({
    required Map<String, String?> wallets,
    required WalletSyncController controller,
    required String? activeId,
    required bool Function() unlocked,
    Map<String, Iterable<String>> recordedAddresses = const {},
    bool whileLocked = false,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    if ((!whileLocked && !unlocked()) || !isDue(at)) return;
    _lastAttempt = at;
    _busy = true;
    final generation = controller.publicGeneration;
    final lifecycle = _lifecycle;
    bool valid() =>
        foreground &&
        lifecycle == _lifecycle &&
        (whileLocked || unlocked()) &&
        controller.publicGeneration == generation;
    var finished = false;
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
            ...?recordedAddresses[entry.key],
          }..remove('');
          if (addresses.isEmpty) continue;
          var nano = 0;
          final amounts = <String, int>{};
          final transactions = <String, Map<String, dynamic>>{};
          final holdings = <AddressHolding>[];
          final frontier = ((old['frontier_addresses'] as List?) ?? const [])
              .cast<String>();
          final used = [
            for (final row in (old['used_addresses'] as List? ?? const []))
              if (row is Map) row.cast<String, dynamic>(),
          ];
          if (!valid()) return;
          final read = await gateway.inputs(addresses.toList());
          final balances = read['balances'] as Map? ?? const {};
          for (final address in addresses) {
            final balance = balances[address];
            // Any missing address keeps the prior snapshot, as a failed
            // balance call always has.
            if (balance is! Map) throw StateError('Balance unavailable');
            nano += (balance['balance_nano_erg'] as num).toInt();
            // Each address's figure is valued over the whole wallet's
            // mempool list, as the summary below is, so the split agrees
            // with the total it explains.
            holdings.add(
              AddressHolding.fromBalance(
                address,
                balance.cast<String, dynamic>(),
                index: recordedAddressIndex(
                  address,
                  frontier: frontier,
                  used: used,
                ),
              ),
            );
            for (final token in balance['tokens'] as List? ?? const []) {
              final id = token['id'] as String;
              amounts[id] =
                  (amounts[id] ?? 0) + (token['amount'] as num).toInt();
            }
          }
          // Valued across all the addresses at once when the node could:
          // a payment between two of them is not counted twice.
          final pending = PendingBalance.fromJson(read['summary']);
          if (pending != null) {
            nano = pending.netNano;
            for (final flow in pending.tokens) {
              amounts[flow.id] = flow.amount;
            }
            amounts.removeWhere((_, amount) => amount <= 0);
          }
          for (final address in addresses) {
            if (!valid()) return;
            for (final tx in await gateway.history(address)) {
              final row = Map<String, dynamic>.from(tx as Map);
              transactions[row['tx_id'] as String] = row;
            }
          }
          // A public refresh updates amounts, not metadata. Keep the target
          // wallet's last known token scale and label from this same snapshot.
          // Looking in the active wallet's cache would substitute another
          // wallet's data; a cache wipe would also turn known scales into zero.
          final knownTokens = {
            for (final row in (old['tokens'] as List? ?? const []))
              (row as Map)['id'] as String: row,
          };
          final tokens = [
            for (final holding in amounts.entries)
              <String, dynamic>{
                ...?knownTokens[holding.key]?.cast<String, dynamic>(),
                'id': holding.key,
                'amount': holding.value,
                'decimals': knownTokens[holding.key]?['decimals'] ?? 0,
              },
          ];
          final confirmed = transactions.values.toList()
            ..sort(
              (a, b) => ((b['timestamp'] as num?) ?? 0).compareTo(
                (a['timestamp'] as num?) ?? 0,
              ),
            );
          // Pending rows ride ahead of confirmed history, as in the live
          // wallet; one that has since confirmed shows once, confirmed.
          final rows = mergePending(
            read['pending'] as List? ?? const [],
            confirmed,
          );
          final snapshot = <String, dynamic>{
            ...old,
            'wallet_id': entry.key,
            'balance_nano_erg': nano,
            'pending': pending?.toJson(),
            'tokens': tokens,
            'transactions': rows.take(5).toList(),
            'address_holdings': [for (final h in holdings) h.toJson()],
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
      finished = true;
    } finally {
      _busy = false;
      // Revoked part way (an unlock, switch, lock, delete, or a biometric
      // sheet taking the foreground) rather than failed: run again at the
      // next check instead of leaving the remaining wallets for five
      // minutes. Opening a wallet moments after launch is the common case
      // now that the app opens on the overview. Wallets this pass already
      // refreshed are fresh, so the rerun skips them.
      if (!finished) _lastAttempt = null;
      notifyListeners();
    }
  }
}

final publicWalletSync = PublicWalletSync(LivePublicWalletGateway());
