import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'network_controller.dart';
import 'privacy_service.dart';
import 'wallet_database_service.dart';
import 'wallet_service.dart';

/// Where the active wallet's on-chain view stands.
enum SyncPhase {
  /// Nothing loaded (locked, or before the first hydrate).
  idle,

  /// A refresh is in flight.
  syncing,

  /// Every balance and history call succeeded.
  synced,

  /// Balances succeeded but at least one address history failed.
  historyPartial,

  /// Some address balance calls failed; totals may be low.
  balancesStale,

  /// Every balance call failed. Previous values are kept on screen.
  failed,

  /// The wallet has no derivable address to sync.
  noAddresses,
}

/// The slice of wallet, network and cache services the sync controller
/// needs. Kept narrow so tests can drive the controller with a fake.
abstract class WalletSyncGateway {
  bool get isUnlocked;
  String? get activeWalletId;
  Future<String> discoverAddresses();
  Future<int> getPinnedAddressIndex();
  Future<String?> tryDeriveAddress(int index);
  Future<String> deriveAddress(int index);
  bool useUnusedChangeAddress(String? walletId);
  Future<Map<String, dynamic>> getBalance(String address);
  Future<List<TokenBalance>> hydrateTokens(dynamic raw);
  Future<List<Map<String, dynamic>>> loadHistory(
    List<String> addresses, {
    int limit = 20,
  });
  bool get lastHistoryPartial;
  Future<int> countUnspentBoxes(List<String> addresses);
  Future<Map<String, dynamic>?> loadCachedState(String walletKey);
  Future<void> saveCachedState(Map<String, dynamic> snapshot);
  void probeNetwork();

  /// Learns names and decimals for tokens seen in activity, best effort.
  Future<void> prefetchTokenMeta(Iterable<String> ids);
}

/// Production gateway over the app's singleton services.
class LiveWalletSyncGateway implements WalletSyncGateway {
  const LiveWalletSyncGateway();

  @override
  bool get isUnlocked => walletService.isUnlocked;

  @override
  String? get activeWalletId => walletService.activeWalletId;

  @override
  Future<String> discoverAddresses() => walletService.discoverAddresses();

  @override
  Future<int> getPinnedAddressIndex() => walletService.getPinnedAddressIndex();

  @override
  Future<String?> tryDeriveAddress(int index) =>
      walletService.tryDeriveAddress(index);

  @override
  Future<String> deriveAddress(int index) => walletService.deriveAddress(index);

  @override
  bool useUnusedChangeAddress(String? walletId) =>
      privacyService.useUnusedChangeAddress(walletId);

  @override
  Future<Map<String, dynamic>> getBalance(String address) =>
      walletService.getBalance(address);

  @override
  Future<List<TokenBalance>> hydrateTokens(dynamic raw) =>
      walletService.hydrateTokens(raw);

  @override
  Future<List<Map<String, dynamic>>> loadHistory(
    List<String> addresses, {
    int limit = 20,
  }) =>
      walletService.loadHistory(addresses, limit: limit);

  @override
  bool get lastHistoryPartial => walletService.lastHistoryPartial;

  @override
  Future<int> countUnspentBoxes(List<String> addresses) async {
    final boxes = await walletService.listUnspentBoxes(
      addresses,
      nodeUrl: networkController.activeUrl,
    );
    return boxes.length;
  }

  @override
  Future<Map<String, dynamic>?> loadCachedState(String walletKey) =>
      WalletDatabaseService.loadCachedState(expectedWalletId: walletKey);

  @override
  Future<void> saveCachedState(Map<String, dynamic> snapshot) =>
      WalletDatabaseService.saveCachedState(
        walletId: snapshot['wallet_id'] as String,
        primaryAddress: snapshot['primary_address'] as String?,
        usedAddresses:
            (snapshot['used_addresses'] as List).cast<Map<String, dynamic>>(),
        balanceNano: snapshot['balance_nano_erg'] as int,
        tokens: (snapshot['tokens'] as List).cast<Map<String, dynamic>>(),
        transactions:
            (snapshot['transactions'] as List).cast<Map<String, dynamic>>(),
        utxoCount: snapshot['utxo_count'] as int,
      );

  @override
  void probeNetwork() {
    networkController.probe();
  }

  @override
  Future<void> prefetchTokenMeta(Iterable<String> ids) =>
      walletService.prefetchTokenMeta(ids).catchError((_) {});
}

/// Owns the unlocked wallet's synced view: addresses, balances, activity and
/// UTXO count, plus the cache that makes the next launch instant.
///
/// The dashboard drives it (hydrate on unlock, full refresh on pull, light
/// refresh on the poll timer) and renders from its fields. Only a full
/// refresh runs address discovery and a node probe; the poll path reuses
/// the addresses already known, which keeps a 20-second tick to a handful
/// of calls instead of a whole rescan.
class WalletSyncController extends ChangeNotifier {
  WalletSyncController(this._gw);

  final WalletSyncGateway _gw;

  SyncPhase phase = SyncPhase.idle;
  String? receiveAddress;
  String? changeAddress;
  String? senderAddress;
  int? balanceNano;
  List<TokenBalance> tokens = const [];
  List<Map<String, dynamic>> recentTxs = const [];
  List<Map<String, dynamic>> usedAddresses = const [];
  int utxoCount = 0;
  DateTime? lastSyncedAt;

  /// Non-null when the stored pinned address index can't be derived.
  String? pinIssue;

  Future<void>? _inFlight;

  bool get isStale =>
      phase == SyncPhase.failed ||
      phase == SyncPhase.balancesStale ||
      phase == SyncPhase.noAddresses;

  bool get isSyncing => phase == SyncPhase.syncing;

  /// True while a refresh is in flight; the dashboard poll skips ticks.
  bool get busy => _inFlight != null;

  /// Wallet context for pushed screens, mirroring the synced state.
  WalletRouteArgs get routeArgs {
    final receive = receiveAddress ?? '';
    return WalletRouteArgs(
      senderAddress: senderAddress ?? receive,
      receiveAddress: receive,
      changeAddress: changeAddress ?? receive,
      historyAddresses: historyAddresses,
      tokens: tokens,
      spendableNano: balanceNano,
    );
  }

  /// Addresses whose activity and balances make up the wallet view.
  List<String> get historyAddresses {
    final out = <String>[];
    for (final used in usedAddresses) {
      final a = used['address']?.toString();
      if (a != null && a.isNotEmpty) out.add(a);
    }
    final receive = receiveAddress;
    if (receive != null && !out.contains(receive)) out.add(receive);
    return out;
  }

  /// Clears everything back to the locked state.
  void reset() {
    phase = SyncPhase.idle;
    receiveAddress = null;
    changeAddress = null;
    senderAddress = null;
    balanceNano = null;
    tokens = const [];
    recentTxs = const [];
    usedAddresses = const [];
    utxoCount = 0;
    pinIssue = null;
    lastSyncedAt = null;
    notifyListeners();
  }

  /// Derives the main address locally and hydrates from the cache so the
  /// ledger paints before any network call. Returns false when no address
  /// could be derived (or the wallet locked meanwhile).
  Future<bool> hydrateAfterUnlock() async {
    if (!_gw.isUnlocked) return false;
    final pinned = await _gw.getPinnedAddressIndex();
    var derived = await _gw.tryDeriveAddress(pinned);
    if (derived == null && pinned != 0) {
      pinIssue = _pinIssueFor(pinned);
      derived = await _gw.tryDeriveAddress(0);
    } else {
      pinIssue = null;
    }
    if (!_gw.isUnlocked) return false;
    if (derived == null) {
      phase = SyncPhase.noAddresses;
      notifyListeners();
      return false;
    }
    final receive = derived;
    receiveAddress ??= receive;
    changeAddress ??= receive;

    final cached = await _gw.loadCachedState(_cacheKey(receive));
    if (cached != null) {
      usedAddresses = _mapList(cached['used_addresses']);
      balanceNano = (cached['balance_nano_erg'] as num?)?.toInt();
      recentTxs = _mapList(cached['transactions']);
      tokens = [
        for (final t in (cached['tokens'] as List? ?? const []))
          if (t is Map)
            TokenBalance(
              id: t['id']?.toString() ?? '',
              amount: (t['amount'] as num?)?.toInt() ?? 0,
              name: t['name']?.toString(),
              decimals: (t['decimals'] as num?)?.toInt() ?? 0,
              iconUrl: t['iconUrl']?.toString(),
            ),
      ];
      utxoCount = (cached['utxo_count'] as num?)?.toInt() ?? 0;
    }
    senderAddress ??= _bestSender(receive);
    notifyListeners();
    return true;
  }

  /// Refreshes balances, activity and UTXO count. With [discover] the
  /// address set is rescanned first and the node list re-probed.
  /// Concurrent callers share the in-flight operation.
  Future<void> refresh({required bool discover}) {
    final running = _inFlight;
    if (running != null) return running;
    final op = _refresh(discover).whenComplete(() => _inFlight = null);
    _inFlight = op;
    return op;
  }

  Future<void> _refresh(bool discover) async {
    phase = SyncPhase.syncing;
    notifyListeners();

    if (discover) {
      _gw.probeNetwork();
      final ok = await _discover();
      if (!ok) return;
    }

    final addresses = historyAddresses;
    if (addresses.isEmpty) {
      phase = SyncPhase.noAddresses;
      notifyListeners();
      return;
    }

    // Balances, activity and UTXO count don't depend on each other.
    final results = await Future.wait<Object?>([
      _fetchBalances(addresses),
      _fetchHistory(addresses),
      _gw.countUnspentBoxes(addresses).catchError((_) => utxoCount),
    ]);
    if (!_gw.isUnlocked) {
      reset();
      return;
    }
    final balances = results[0] as _BalanceResult;
    final txs = results[1] as List<Map<String, dynamic>>?;
    final boxes = results[2] as int;

    final failed = balances.failed;
    if (failed < addresses.length) {
      balanceNano = balances.erg;
      tokens = balances.tokens;
    }
    // Replace only when trustworthy: an empty result with no failures means
    // pending entries dropped from the mempool and must leave the list; an
    // empty result alongside failures is unreliable, keep what we had.
    if (txs != null && (txs.isNotEmpty || failed == 0)) {
      recentTxs = txs.take(5).toList();
    }
    utxoCount = boxes;

    if (failed == addresses.length) {
      phase = SyncPhase.failed;
    } else if (failed > 0) {
      phase = SyncPhase.balancesStale;
    } else if (txs == null || _gw.lastHistoryPartial) {
      phase = SyncPhase.historyPartial;
    } else {
      phase = SyncPhase.synced;
      lastSyncedAt = DateTime.now();
    }
    notifyListeners();

    // Names for tokens that moved, so activity rows can say "1 SigUSD".
    final tokenIds = <String>{
      for (final tx in recentTxs)
        for (final key in const ['tokens_received', 'tokens_sent'])
          for (final t in (tx[key] as List? ?? const []))
            if (t is Map) t['token_id']?.toString() ?? '',
    }..remove('');
    if (tokenIds.isNotEmpty) {
      await _gw.prefetchTokenMeta(tokenIds);
      notifyListeners();
    }

    final receive = receiveAddress;
    if (receive != null && phase != SyncPhase.failed) {
      await _gw.saveCachedState({
        'wallet_id': _cacheKey(receive),
        'primary_address': receive,
        'used_addresses': usedAddresses,
        'balance_nano_erg': balanceNano ?? 0,
        'tokens': [
          for (final t in tokens)
            {
              'id': t.id,
              'amount': t.amount,
              'name': t.name,
              'decimals': t.decimals,
              'iconUrl': t.iconUrl,
            },
        ],
        'transactions': recentTxs,
        'utxo_count': utxoCount,
      });
    }
  }

  /// Rescans the address set. Returns false when the wallet locked meanwhile.
  /// Discovery failures fall through so balances still refresh on the
  /// addresses already known.
  Future<bool> _discover() async {
    try {
      final raw = await _gw.discoverAddresses();
      if (!_gw.isUnlocked) {
        reset();
        return false;
      }
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final used = _mapList(map['addresses']);
      final next = (map['next_unused_index'] as num?)?.toInt() ?? 0;

      final pinned = await _gw.getPinnedAddressIndex();
      final pinnedReceive =
          pinned > 0 ? await _gw.tryDeriveAddress(pinned) : null;
      pinIssue = pinned > 0 && pinnedReceive == null ? _pinIssueFor(pinned) : null;

      // The pinned address stays the main address while it sits at or beyond
      // the usage frontier; once the wallet has moved past it, the next
      // unused address takes over.
      final String receive;
      if (pinnedReceive != null && (next == 0 || pinned >= next)) {
        receive = pinnedReceive;
      } else if (next == 0) {
        receive = receiveAddress ?? await _gw.deriveAddress(0);
      } else {
        receive = await _gw.deriveAddress(next);
      }
      final change = await _gw.deriveAddress(
        _gw.useUnusedChangeAddress(_gw.activeWalletId) ? next : 0,
      );
      if (!_gw.isUnlocked) {
        reset();
        return false;
      }
      usedAddresses = used;
      receiveAddress = receive;
      changeAddress = change;
      senderAddress = _bestSender(receive);
      notifyListeners();
    } catch (_) {
      // Fall through to a balance refresh with the addresses we know.
    }
    return true;
  }

  Future<_BalanceResult> _fetchBalances(List<String> addresses) async {
    final maps = await Future.wait(addresses.map((address) async {
      try {
        return await _gw.getBalance(address);
      } catch (_) {
        return null;
      }
    }));
    var erg = 0;
    var failed = 0;
    final merged = <String, TokenBalance>{};
    for (final map in maps) {
      if (map == null) {
        failed++;
        continue;
      }
      erg += (map['balance_nano_erg'] as num?)?.toInt() ?? 0;
      for (final t in await _gw.hydrateTokens(map['tokens'])) {
        final prev = merged[t.id];
        merged[t.id] = TokenBalance(
          id: t.id,
          amount: (prev?.amount ?? 0) + t.amount,
          name: t.name,
          decimals: t.decimals,
          emissionAmount: t.emissionAmount,
          iconUrl: t.iconUrl,
        );
      }
    }
    return _BalanceResult(erg, merged.values.toList(), failed);
  }

  /// Null when the history call itself failed.
  Future<List<Map<String, dynamic>>?> _fetchHistory(
    List<String> addresses,
  ) async {
    try {
      return await _gw.loadHistory(addresses, limit: 20);
    } catch (_) {
      return null;
    }
  }

  String _bestSender(String receive) {
    var best = receive;
    var bestNano = -1;
    for (final used in usedAddresses) {
      final addr = used['address']?.toString();
      final nano = (used['balance_nano_erg'] as num?)?.toInt() ?? 0;
      if (addr != null && addr.isNotEmpty && nano >= bestNano) {
        best = addr;
        bestNano = nano;
      }
    }
    return best;
  }

  /// Snapshots are stored per wallet id; older code keyed them by address.
  String _cacheKey(String receive) => _gw.activeWalletId ?? receive;

  static String _pinIssueFor(int index) =>
      "Pinned index $index can't be derived "
      '(max ${WalletService.maxAddressIndex}). Reset it in Settings.';

  static List<Map<String, dynamic>> _mapList(dynamic raw) =>
      (raw as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
}

class _BalanceResult {
  const _BalanceResult(this.erg, this.tokens, this.failed);
  final int erg;
  final List<TokenBalance> tokens;
  final int failed;
}

/// The app's one sync controller: the home screen drives it and the
/// navigator-level [WalletArgsScope] in `main.dart` reads from it.
final walletSyncController =
    WalletSyncController(const LiveWalletSyncGateway());
