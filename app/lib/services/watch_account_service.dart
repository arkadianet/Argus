import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../bridge/api.dart' as api;
import 'wallet_service.dart';
import 'network_controller.dart';

const watchAccountLimitations =
    'Public payment addresses only. Cannot see stealth identities or stealth funds: the /3\' branch is hardened. This balance excludes stealth funds. Cannot sign locally; sending requires an offline signer.';
const watchAccountDisclosure =
    'An extended public key lets anyone holding it derive and link every public payment address in this account forever. Only import a key you intend to share with this device. $watchAccountLimitations';
const watchAccountExpected =
    'Expected an Ergo Wallet App extended public key: 156 hex characters starting 0488b21e (mainnet), depth 4 external chain /0 or depth 3 account 0. Base58 xpub and testnet are not supported.';

class WatchAccount {
  WatchAccount(this.key, {this.highestUsed = -1});
  final String key;
  int highestUsed;
  WatchAccountSnapshot? snapshot;
  String? error;
  bool busy = false;
}

class WatchAccountSnapshot {
  WatchAccountSnapshot(
    this.addresses,
    this.receiveAddress,
    this.balance,
    this.tokens,
    this.history,
    this.highestUsed,
  );
  final List<String> addresses;
  final String receiveAddress;
  final int balance;
  final Map<String, int> tokens;
  final List<Map<String, dynamic>> history;
  final int highestUsed;
}

/// Bound node pressure and retain submission order, including on failures.
const watchAddressConcurrency = 4;
const watchAccountConcurrency = 2;

Future<List<R>> watchMapOrdered<T, R>(
  List<T> items,
  Future<R> Function(T) read, {
  required int concurrency,
}) async {
  final results = <R>[];
  for (var start = 0; start < items.length; start += concurrency) {
    results.addAll(
      await Future.wait(items.skip(start).take(concurrency).map(read)),
    );
  }
  return results;
}

/// History, not balance, defines use: a spent address must reset the gap too.
/// Reads fail closed; no partial totals or fresh Receive on an incomplete scan.
Future<WatchAccountSnapshot> scanWatchAccount({
  required Future<List<String>> Function(int, int) derive,
  required Future<List<dynamic>> Function(String) history,
  required Future<Map<String, dynamic>> Function(String) balance,
  int highestUsed = -1,
  int gap = 20,
  int maxAddresses = 10000,
}) async {
  if (gap < 1 || gap > 100) throw ArgumentError.value(gap);
  var empty = 0;
  var lastUsed = highestUsed;
  var total = 0;
  final addresses = <String>[];
  final transactions = <String, Map<String, dynamic>>{};
  final tokens = <String, int>{};
  for (var start = 0; start < maxAddresses; start += gap) {
    final count = (maxAddresses - start).clamp(0, gap);
    final batch = await derive(start, count);
    if (batch.length != count) throw StateError('Incomplete derivation');
    for (
      var offset = 0;
      offset < batch.length;
      offset += watchAddressConcurrency
    ) {
      final group = batch.skip(offset).take(watchAddressConcurrency).toList();
      final results = await watchMapOrdered(group, (address) async {
        final values = await Future.wait<Object>([
          history(address),
          balance(address),
        ]);
        return (values[0] as List<dynamic>, values[1] as Map<String, dynamic>);
      }, concurrency: watchAddressConcurrency);
      for (var i = 0; i < group.length; i++) {
        final address = group[i];
        final index = addresses.length;
        final (rows, funds) = results[i];
        final nano = (funds['balance_nano_erg'] as num).toInt();
        final assets = funds['tokens'] as List;
        final used = rows.isNotEmpty || nano != 0 || assets.isNotEmpty;
        addresses.add(address);
        total += nano;
        for (final asset in assets) {
          final id = asset['id'] as String;
          tokens[id] = (tokens[id] ?? 0) + (asset['amount'] as num).toInt();
        }
        for (final row in rows) {
          final tx = Map<String, dynamic>.from(row as Map);
          transactions[tx['tx_id'] as String] = tx;
        }
        if (used) {
          lastUsed = index > lastUsed ? index : lastUsed;
          empty = 0;
        } else {
          empty++;
        }
        if (empty >= gap && index >= lastUsed + gap) {
          final sorted = transactions.values.toList()
            ..sort(
              (a, b) => ((b['timestamp'] as num?) ?? 0).compareTo(
                (a['timestamp'] as num?) ?? 0,
              ),
            );
          return WatchAccountSnapshot(
            addresses,
            addresses[lastUsed + 1],
            total,
            tokens,
            sorted,
            lastUsed,
          );
        }
      }
    }
  }
  throw StateError(
    'Scan incomplete after $maxAddresses addresses; no unused receive address confirmed.',
  );
}

class WatchAccountService extends ChangeNotifier {
  WatchAccountService({NetworkController? network})
    : _network = network ?? networkController {
    _node = _network.activeUrl;
    _network.addListener(_onNetworkChanged);
  }

  final NetworkController _network;
  String? _node;
  int _nodeGeneration = 0;

  void _onNetworkChanged() {
    if (_node == _network.activeUrl) return;
    _node = _network.activeUrl;
    _nodeGeneration++;
    for (final account in accounts) {
      account.snapshot = null;
      account.error = 'Node changed. Refresh the account before receiving.';
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _network.removeListener(_onNetworkChanged);
    super.dispose();
  }

  static const storageKey = 'argus_watch_only_accounts_v1';
  final List<WatchAccount> accounts = [];
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    accounts.clear();
    if (raw != null) {
      for (final row in jsonDecode(raw) as List) {
        accounts.add(
          WatchAccount(
            row['key'] as String,
            highestUsed: row['highestUsed'] as int,
          ),
        );
      }
    }
    notifyListeners();
  }

  Future<bool> add(String input) async {
    final key = input.trim().toLowerCase();
    await api.deriveWatchAddresses(input: key, start: 0, count: 20);
    if (accounts.any((a) => a.key == key)) return false;
    final account = WatchAccount(key);
    accounts.add(account);
    try {
      await _save();
    } catch (_) {
      accounts.remove(account);
      rethrow;
    }
    unawaited(refresh(account));
    return true;
  }

  Future<void> remove(WatchAccount account) async {
    final index = accounts.indexOf(account);
    if (index < 0) return;
    accounts.removeAt(index);
    try {
      await _save();
    } catch (_) {
      accounts.insert(index.clamp(0, accounts.length), account);
      rethrow;
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(
      storageKey,
      jsonEncode([
        for (final a in accounts)
          {
            'kind': 'extendedPublicKey',
            'key': a.key,
            'highestUsed': a.highestUsed,
          },
      ]),
    );
    if (!saved) {
      await prefs.reload();
      throw StateError('Could not save watched accounts. Please try again.');
    }
    notifyListeners();
  }

  Future<void> refresh(WatchAccount account) async {
    if (account.busy) return;
    account.busy = true;
    account.error = null;
    notifyListeners();
    final node = _network.activeUrl;
    final generation = _nodeGeneration;
    try {
      final result = await scanWatchAccount(
        highestUsed: account.highestUsed,
        derive: (start, count) => api.deriveWatchAddresses(
          input: account.key,
          start: start,
          count: count,
        ),
        history: (address) async =>
            jsonDecode(
                  await walletService.getTransactionHistory(
                    address,
                    nodeUrl: node,
                    limit: 20,
                  ),
                )
                as List,
        balance: (address) => walletService.getBalance(address, nodeUrl: node),
      );
      if (!accounts.contains(account)) return;
      if (_network.activeUrl != node || _nodeGeneration != generation)
        throw StateError('Node changed during scan; refresh again.');
      account.snapshot = result;
      account.highestUsed = result.highestUsed;
      await _save();
    } catch (e) {
      account.snapshot = null;
      account.error = 'Account refresh unavailable: $e';
    } finally {
      account.busy = false;
      notifyListeners();
    }
  }
}

final watchAccountService = WatchAccountService();
