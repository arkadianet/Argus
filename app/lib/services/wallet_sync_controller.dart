import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'network_controller.dart';
import 'privacy_service.dart';
import 'mix_activity.dart';
import 'mix_service.dart';
import 'stealth_service.dart';
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

  /// Resolves names for ordinary public holdings, after balances publish.
  /// Never called with stealth-only ids. Returns what it resolved, so the
  /// caller can apply it to holdings already on screen.
  Future<Map<String, TokenBalance>> resolveTokenNames(
    Iterable<String> ids, {
    required String walletId,
    required String servedBy,
    required bool Function() stillCurrent,
  });

  /// Keeps missing-address status attached to the request that produced the rows.
  Future<HistoryResult> loadHistory(List<String> addresses, {int limit = 20});
  Future<int> countUnspentBoxes(List<String> addresses);
  Future<Map<String, dynamic>?> loadCachedState(String walletKey);
  Future<void> saveCachedState(Map<String, dynamic> snapshot);
  void probeNetwork();

  /// Learns names and decimals for tokens seen in activity, best effort.


  /// Whether the user has left the stealth scan on.
  bool get stealthScanEnabled;

  /// Queries the explorer for stealth boxes and tests them against this
  /// wallet's key. Returns null when the explorer could not be reached,
  /// which must degrade the view rather than fail the sync.
  Future<StealthScanResult?> scanStealth();
}

/// One refresh owns this read; it is never reused by a later refresh.
abstract interface class WalletSyncRead {
  Future<Map<String, dynamic>> balance(String address);
  Future<HistoryResult> history();
  Future<int> count();

  /// The node that actually answered this read. `connect` falls back past
  /// the preferred URL, so this is not necessarily the configured one — and
  /// it is the only endpoint that has already been shown these addresses and
  /// the token ids in their boxes. Null when it cannot be established.
  Future<String?> servedBy();
}

abstract interface class WalletSyncBatchGateway {
  WalletSyncRead startRead(List<String> addresses);
}

class _LiveSyncRead implements WalletSyncRead {
  _LiveSyncRead(List<String> addresses) {
    final inputs = walletService.loadSyncInputs(
      addresses,
      nodeUrl: networkController.activeUrl,
    );
    _inputs = inputs;
    _history = walletService.loadHistory(
      addresses,
      pending: inputs.then((value) {
        final pending = value['pending'];
        if (pending == null) throw StateError('Pending values unavailable');
        return pending as List;
      }),
    );
  }
  late final Future<Map<String, dynamic>> _inputs;
  late final Future<HistoryResult> _history;
  @override
  Future<Map<String, dynamic>> balance(String address) async {
    final raw = (await _inputs)['balances'][address];
    if (raw == null) throw StateError('Address balance unavailable');
    return Map<String, dynamic>.from(raw as Map);
  }

  @override
  Future<HistoryResult> history() async {
    final history = await _history;
    if ((await _inputs)['pending'] == null) {
      // Keep the last activity snapshot when input values cannot be verified.
      throw StateError('Pending values unavailable');
    }
    return history;
  }

  @override
  Future<int> count() async {
    final count = (await _inputs)['utxo_count'] as int?;
    if (count == null) throw StateError('UTXO listing incomplete');
    return count;
  }

  @override
  Future<String?> servedBy() async {
    try {
      final url = (await _inputs)['served_by'];
      return url is String && url.isNotEmpty ? url : null;
    } catch (_) {
      return null;
    }
  }
}

/// Production gateway over the app's singleton services.
class LiveWalletSyncGateway
    implements WalletSyncGateway, WalletSyncBatchGateway {
  @override
  WalletSyncRead startRead(List<String> addresses) => _LiveSyncRead(addresses);
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
  Future<Map<String, TokenBalance>> resolveTokenNames(
    Iterable<String> ids, {
    required String walletId,
    required String servedBy,
    required bool Function() stillCurrent,
  }) => walletService.prefetchTokenMeta(
    ids,
    walletId: walletId,
    servedBy: servedBy,
    stillCurrent: stillCurrent,
  );

  /// Passes request-local completeness through without consulting shared state.
  @override
  Future<HistoryResult> loadHistory(List<String> addresses, {int limit = 20}) =>
      walletService.loadHistory(addresses, limit: limit);

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

  /// Preserves sync validity separately from the time the snapshot is written.
  @override
  Future<void> saveCachedState(Map<String, dynamic> snapshot) =>
      WalletDatabaseService.saveCachedState(
        walletId: snapshot['wallet_id'] as String,
        frontierAddresses: (snapshot['frontier_addresses'] as List? ?? const [])
            .cast<String>(),
        discoveredAt: snapshot['discovered_at'] as int?,
        discoveryPinnedIndex: snapshot['discovery_pinned_index'] as int?,
        discoveryUnusedChange: snapshot['discovery_unused_change'] as bool?,
        changeAddress: snapshot['change_address'] as String?,
        primaryAddress: snapshot['primary_address'] as String?,
        usedAddresses: (snapshot['used_addresses'] as List)
            .cast<Map<String, dynamic>>(),
        stealthNano: (snapshot['stealth_nano_erg'] as num?)?.toInt() ?? 0,
        stealthScannedAt: (snapshot['stealth_scanned_at'] as num?) == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                (snapshot['stealth_scanned_at'] as num).toInt(),
              ),
        balanceNano: snapshot['balance_nano_erg'] as int?,
        tokens: (snapshot['tokens'] as List).cast<Map<String, dynamic>>(),
        transactions: (snapshot['transactions'] as List)
            .cast<Map<String, dynamic>>(),
        utxoCount: snapshot['utxo_count'] as int,
        publicOnly: snapshot['public_only'] == true,
        syncPhase: snapshot['sync_phase'] as String?,
        lastSuccessfulSyncAt: (snapshot['last_successful_sync_at'] as num?)
            ?.toInt(),
      );

  @override
  void probeNetwork() {
    networkController.probe();
  }

  @override
  bool get stealthScanEnabled => stealthService.scanEnabled;

  @override
  Future<StealthScanResult?> scanStealth() => stealthService.scan();
}

/// Owns the unlocked wallet's synced view: addresses, balances, activity and
/// UTXO count, plus the cache that makes the next launch instant.
///
/// The dashboard drives it (hydrate on unlock, full refresh on pull, light
/// refresh on the poll timer) and renders from its fields. Polls reuse known
/// addresses until discovery expires; manual refresh forces a rescan.
/// Remembered views are scoped to a wallet and cleared on security lock.
/// Tokens in a stable order for display: fungible before NFTs, then by
/// name, then by id. The balance answer lists them in whatever order the
/// node's map iterates, which changes from one poll to the next and made
/// the asset tiles shuffle while the screen sat idle.
List<TokenBalance> orderTokensForDisplay(List<TokenBalance> tokens) {
  final out = List<TokenBalance>.of(tokens);
  out.sort((a, b) {
    if (a.isCollectible != b.isCollectible) return a.isCollectible ? 1 : -1;
    final byName = a.label.toLowerCase().compareTo(b.label.toLowerCase());
    if (byName != 0) return byName;
    return a.id.compareTo(b.id);
  });
  return out;
}

class WalletSyncController extends ChangeNotifier {
  WalletSyncController(this._gw);

  final WalletSyncGateway _gw;
  final Map<String, _WalletView> _remembered = {};
  String? _viewWalletId;
  bool ownsWallet(String? walletId) =>
      walletId != null &&
      walletId == _viewWalletId &&
      walletId == _gw.activeWalletId &&
      _gw.isUnlocked;
  DateTime? discoveredAt;
  int? _discoveryPinnedIndex;
  bool? _discoveryUnusedChange;
  static const discoveryFreshness = Duration(minutes: 15);

  /// Called synchronously before the service publishes a new wallet identity.
  void activateWallet(String walletId) {
    if (_viewWalletId == walletId) return;
    deactivate();
    _viewWalletId = walletId;
    _remembered.remove(walletId)?.restore(this);
    final warm = _publicWarm.remove(walletId);
    if (warm != null) _applyPublic(warm);
    notifyListeners();
  }

  /// A switch drops the visible view but retains public data until session lock.
  void deactivate() {
    _publicGeneration++;
    final id = _viewWalletId;
    if (id != null) _remembered[id] = _WalletView(this);
    _clearView();
    _viewWalletId = null;
  }

  void forgetWallet(String walletId) {
    _publicGeneration++;
    _publicWarm.remove(walletId);
    _remembered.remove(walletId);
    if (_viewWalletId == walletId) {
      _clearView();
      _viewWalletId = null;
    }
  }

  final Map<String, Map<String, dynamic>> _publicWarm = {};
  int _publicGeneration = 0;
  int get publicGeneration => _publicGeneration;
  bool publicSnapshotOnly = false;

  bool rememberPublic(
    String id,
    Map<String, dynamic> snapshot,
    int generation,
  ) {
    if (generation != publicGeneration ||
        !_gw.isUnlocked ||
        id == _gw.activeWalletId ||
        snapshot['wallet_id'] != id)
      return false;
    _publicWarm[id] = snapshot;
    return true;
  }

  void _applyPublic(Map<String, dynamic> snapshot) {
    publicSnapshotOnly = true;
    balanceNano = snapshot['balance_nano_erg'] as int;
    recentTxs = _mapList(snapshot['transactions']);
    tokens = orderTokensForDisplay([
      for (final t in snapshot['tokens'] as List)
        TokenBalance(
          id: t['id'],
          amount: t['amount'],
          name: t['name'],
          decimals: t['decimals'],
          iconUrl: t['iconUrl'],
          emissionAmount: t['emissionAmount'],
        ),
    ]);
    phase = SyncPhase.idle;
  }

  SyncPhase phase = SyncPhase.idle;
  String? receiveAddress;
  String? changeAddress;
  String? senderAddress;
  int? balanceNano;
  List<TokenBalance> tokens = const [];
  List<Map<String, dynamic>> recentTxs = const [];
  List<Map<String, dynamic>> usedAddresses = const [];

  /// Derived addresses from index 0 to the usage frontier, set by
  /// discovery. Always included in balance queries.
  List<String> frontierAddresses = const [];
  int utxoCount = 0;
  DateTime? lastSyncedAt;

  /// ERG sitting in stealth boxes this wallet can spend. Zero when the scan
  /// found none; see [stealthBalanceUnknown] for "we could not look".
  int stealthNano = 0;

  /// Activity rows for stealth receipts, which the address-derived history
  /// cannot see: a stealth box sits on a one-time script, not on any
  /// address this wallet queries.
  List<Map<String, dynamic>> stealthRows = const [];
  List<String> _stealthBoxIds = const [];

  /// Tokens held in stealth boxes, with [TokenBalance.stealthAmount] equal
  /// to the whole amount.
  List<TokenBalance> stealthTokens = const [];

  /// True when the scan is on but has never succeeded, so the stealth
  /// balance shown is unknown rather than zero. Also true right after a
  /// failed explorer call.
  bool stealthBalanceUnknown = true;

  /// When [stealthNano] was last confirmed. Untouched by a failed scan.
  DateTime? stealthScannedAt;

  /// True when the user has the scan on, so an unknown stealth balance is
  /// worth reporting rather than simply "not in use".
  bool get stealthScanning => _gw.stealthScanEnabled;

  /// True when the stealth scan is switched off in Settings.
  bool get stealthScanEnabled => _gw.stealthScanEnabled;

  /// Balance including stealth funds — what the wallet is worth. Distinct
  /// from [balanceNano], which is what ordinary coin selection can spend.
  int? get totalNanoWithStealth =>
      balanceNano == null ? null : balanceNano! + stealthNano;

  /// The asset list as the user should see it: spendable holdings merged
  /// with stealth ones, each carrying how much of it is in stealth boxes.
  List<TokenBalance> get displayTokens =>
      mergeStealthTokens(tokens, stealthTokens);

  /// Box ids of the stealth funds this wallet can spend. Empty while the
  /// balance is unknown: the last scan's boxes may be stale.
  List<String> get stealthRowBoxIds =>
      stealthBalanceUnknown ? const [] : _stealthBoxIds;

  /// Activity as the user should see it: address history plus stealth
  /// receipts, newest first.
  List<Map<String, dynamic>> get displayActivity => mergeStealthActivity(
    mergeMixActivity(recentTxs, mixService.mixActivityRows()),
    stealthRows,
  );

  /// Non-null when the stored pinned address index can't be derived.
  String? pinIssue;

  Future<void>? _inFlight;
  int _generation = 0;
  String? _refreshWalletId;

  /// Rejects work from a wallet or refresh that no longer owns the screen.
  bool _current(int generation, String? walletId) {
    if (generation != _generation || walletId != _gw.activeWalletId)
      return false;
    if (!_gw.isUnlocked) {
      reset();
      return false;
    }
    return true;
  }

  /// Reserves success for a completed wallet sync, even when a node is online.
  String statusLabel({required bool online}) {
    if (publicSnapshotOnly)
      return 'Public data · known addresses only';
    if (isSyncing) return 'Syncing…';
    if (isStale) return 'Out of sync';
    if (!online) return 'Offline';
    if (phase == SyncPhase.historyPartial) return 'History incomplete';
    if (phase == SyncPhase.synced && lastSyncedAt != null) return 'Synced';
    return 'Not synced';
  }

  /// Transactions this app broadcast recently, by id: when, and the
  /// balance change they carry. A row for each is shown at once, and kept
  /// until the node's own view has it or [broadcastGrace] passes.
  final Map<String, _Broadcast> _broadcasts = {};

  /// How long a broadcast row and its balance delta stand in for the
  /// node's view. Mempool propagation takes seconds; a transaction still
  /// unseen after this was most likely dropped, and the node's view wins.
  static const broadcastGrace = Duration(seconds: 90);

  /// Quiet polls between two stealth scans: the explorer read is the slow
  /// leg of a refresh and stealth funds move rarely.
  static const stealthScanEvery = 3;
  int _quietPollsSinceStealth = 0;

  /// True while something is unconfirmed: a Pending row in the activity, or
  /// a broadcast still inside its grace. The home screen polls faster then.
  bool get hasPending {
    _dropExpiredBroadcasts();
    if (_broadcasts.isNotEmpty) return true;
    return recentTxs.any((tx) => ((tx['height'] as num?)?.toInt() ?? 0) == 0);
  }

  /// A transaction this app just broadcast. Shows it as Pending at once and
  /// moves the balance by [valueNano] (negative for a spend) when known,
  /// then refreshes now and again shortly after, by which time the node's
  /// mempool has it. Calling twice for one id merges the value in.
  void noteBroadcast(String txId, {int? valueNano}) {
    if (txId.isEmpty) return;
    final prior = _broadcasts[txId];
    final known = prior?.valueNano;
    final note = _Broadcast(DateTime.now(), valueNano ?? known);
    _broadcasts[txId] = note;
    final idx = recentTxs.indexWhere((tx) => tx['tx_id'] == txId);
    final row = {
      'tx_id': txId,
      'height': 0,
      'timestamp': note.at.millisecondsSinceEpoch,
      'value_nano_erg': note.valueNano ?? 0,
      'token_ids': const <String>[],
      'tokens_received': const <Map<String, dynamic>>[],
      'confirmed': false,
      'broadcast': true,
    };
    if (idx < 0) {
      recentTxs = [row, ...recentTxs];
    } else if (recentTxs[idx]['broadcast'] == true) {
      recentTxs = [...recentTxs]..[idx] = row;
    }
    // Apply the delta once: on the first note that carries a value.
    if (valueNano != null && known == null && balanceNano != null) {
      balanceNano = (balanceNano! + valueNano).clamp(0, 1 << 62);
    }
    notifyListeners();
    unawaited(refresh(discover: false, quiet: true));
    final broadcastWalletId = _gw.activeWalletId;
    Future.delayed(const Duration(seconds: 4), () {
      if (_gw.activeWalletId == broadcastWalletId &&
          _broadcasts.containsKey(txId)) {
        unawaited(refresh(discover: false, quiet: true));
      }
    });
  }

  void _dropExpiredBroadcasts() {
    final now = DateTime.now();
    _broadcasts.removeWhere((_, b) => now.difference(b.at) > broadcastGrace);
  }

  /// Rows from the node, with the broadcasts it has not seen yet put back
  /// in front; a broadcast the node does show is settled and forgotten.
  List<Map<String, dynamic>> _withBroadcasts(List<Map<String, dynamic>> txs) {
    _dropExpiredBroadcasts();
    if (_broadcasts.isEmpty) return txs;
    final ids = {for (final tx in txs) tx['tx_id']?.toString()};
    for (final id in ids) {
      if (id != null) _broadcasts.remove(id);
    }
    final unseen = <Map<String, dynamic>>[
      for (final tx in recentTxs)
        if (tx['broadcast'] == true && _broadcasts.containsKey(tx['tx_id'])) tx,
    ];
    return [...unseen, ...txs];
  }

  /// The node's balance omits a broadcast its mempool has not seen yet;
  /// the deltas of those are carried until it does.
  int _withBroadcastDeltas(int nodeBalance) {
    var out = nodeBalance;
    for (final b in _broadcasts.values) {
      out += b.valueNano ?? 0;
    }
    return out < 0 ? 0 : out;
  }

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
    for (final a in frontierAddresses) {
      if (!out.contains(a)) out.add(a);
    }
    final receive = receiveAddress;
    if (receive != null && !out.contains(receive)) out.add(receive);
    return out;
  }

  /// Clears everything back to the locked state.
  void reset() {
    _publicGeneration++;
    _publicWarm.clear();
    _remembered.clear();
    _viewWalletId = null;
    _clearView();
  }

  void _clearView() {
    _generation++;
    _inFlight = null;
    _refreshWalletId = null;
    discoveredAt = null;
    _discoveryPinnedIndex = null;
    _discoveryUnusedChange = null;
    publicSnapshotOnly = false;
    phase = SyncPhase.idle;
    receiveAddress = null;
    changeAddress = null;
    senderAddress = null;
    balanceNano = null;
    tokens = const [];
    recentTxs = const [];
    usedAddresses = const [];
    frontierAddresses = const [];
    utxoCount = 0;
    pinIssue = null;
    lastSyncedAt = null;
    _broadcasts.clear();
    _quietPollsSinceStealth = 0;
    stealthNano = 0;
    stealthTokens = const [];
    stealthRows = const [];
    _stealthBoxIds = const [];
    stealthBalanceUnknown = true;
    stealthScannedAt = null;
    notifyListeners();
  }

  /// Derives the main address locally and hydrates from the cache so the
  /// ledger paints before any network call. Returns false when no address
  /// could be derived (or the wallet locked meanwhile).
  Future<bool> hydrateAfterUnlock() async {
    if (!_gw.isUnlocked) return false;
    final id = _gw.activeWalletId;
    if (id != null) activateWallet(id);
    final generation = _generation;
    final walletId = _gw.activeWalletId;
    final pinned = await _gw.getPinnedAddressIndex();
    if (!_current(generation, walletId)) return false;
    final unusedChange = _gw.useUnusedChangeAddress(walletId);
    if (receiveAddress != null) {
      if (_discoveryPinnedIndex == pinned &&
          _discoveryUnusedChange == unusedChange) {
        return true;
      }
      discoveredAt = null;
      receiveAddress = null;
      changeAddress = null;
      senderAddress = null;
      notifyListeners();
    }
    var derived = await _gw.tryDeriveAddress(pinned);
    if (!_current(generation, walletId)) return false;
    if (derived == null && pinned != 0) {
      pinIssue = _pinIssueFor(pinned);
      derived = await _gw.tryDeriveAddress(0);
    } else {
      pinIssue = null;
    }
    if (!_current(generation, walletId)) return false;
    if (derived == null) {
      phase = SyncPhase.noAddresses;
      notifyListeners();
      return false;
    }
    final receive = derived;
    receiveAddress ??= receive;
    changeAddress ??= receive;

    final cached = await _gw.loadCachedState(_cacheKey(receive));
    if (!_current(generation, walletId)) return false;
    if (cached != null) {
      publicSnapshotOnly = cached['public_only'] == true;
      final stamp = (cached['last_successful_sync_at'] as num?)?.toInt();
      lastSyncedAt = stamp == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(stamp);
      // Older snapshots have no evidence of a complete successful sync.
      phase = SyncPhase.values.firstWhere(
        (p) => p.name == cached['sync_phase'] && p != SyncPhase.syncing,
        orElse: () => SyncPhase.idle,
      );
      if (phase == SyncPhase.synced && lastSyncedAt == null)
        phase = SyncPhase.idle;
      frontierAddresses = (cached['frontier_addresses'] as List? ?? const [])
          .cast<String>();
      final discoveryStamp = (cached['discovered_at'] as num?)?.toInt();
      discoveredAt = discoveryStamp == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(discoveryStamp);
      _discoveryPinnedIndex = cached['discovery_pinned_index'] as int?;
      _discoveryUnusedChange = cached['discovery_unused_change'] as bool?;
      if (_discoveryPinnedIndex == pinned &&
          _discoveryUnusedChange == unusedChange) {
        receiveAddress = cached['primary_address'] as String? ?? receive;
        changeAddress = cached['change_address'] as String? ?? receiveAddress;
      } else {
        // A pin/privacy change invalidates routing, but known addresses can refresh.
        discoveredAt = null;
      }
      usedAddresses = _mapList(cached['used_addresses']);
      balanceNano = (cached['balance_nano_erg'] as num?)?.toInt();
      recentTxs = _mapList(cached['transactions']);
      tokens = orderTokensForDisplay([
        for (final t in (cached['tokens'] as List? ?? const []))
          if (t is Map)
            TokenBalance(
              id: t['id']?.toString() ?? '',
              amount: (t['amount'] as num?)?.toInt() ?? 0,
              name: t['name']?.toString(),
              decimals: (t['decimals'] as num?)?.toInt() ?? 0,
              iconUrl: t['iconUrl']?.toString(),
              emissionAmount: (t['emissionAmount'] as num?)?.toInt(),
            ),
      ]);
      utxoCount = (cached['utxo_count'] as num?)?.toInt() ?? 0;
    }
    senderAddress ??= _bestSender(receiveAddress ?? receive);
    notifyListeners();
    return true;
  }

  /// Refreshes balances, activity and UTXO count. With [discover] the
  /// address set is rescanned first and the node list re-probed.
  /// Concurrent callers in the same wallet generation share the operation.
  /// [quiet] is for the background poll: it refreshes without announcing
  /// itself, so the status strip does not flip to "Syncing…" and back every
  /// 20 seconds. The result still updates the phase, so a failure or stale
  /// balance is reported as soon as it happens.
  Future<void> refresh({
    required bool discover,
    bool quiet = false,
    bool forceDiscovery = true,
  }) {
    if (!_gw.isUnlocked) return Future.value();
    final walletId = _gw.activeWalletId;
    // Legacy/test callers can seed a view before the first refresh.
    _viewWalletId ??= walletId;
    if (walletId != null && _viewWalletId != walletId) activateWallet(walletId);
    final running = _inFlight;
    if (running != null && _refreshWalletId == walletId) return running;
    final generation = ++_generation;
    _refreshWalletId = walletId;
    late final Future<void> op;
    final age = discoveredAt == null
        ? null
        : DateTime.now().difference(discoveredAt!);
    final expired = age == null || age.isNegative || age >= discoveryFreshness;
    final needsDiscovery =
        (discover && (forceDiscovery || expired)) ||
        (quiet && discoveredAt != null && expired);
    op = _refreshScheduled(needsDiscovery, generation, walletId, quiet: quiet)
        .whenComplete(() {
          if (identical(_inFlight, op)) _inFlight = null;
        });
    _inFlight = op;
    return op;
  }

  Future<void> _refreshScheduled(
    bool discover,
    int generation,
    String? walletId, {
    required bool quiet,
  }) async {
    if (!discover || historyAddresses.isEmpty) {
      await _refresh(discover, generation, walletId, quiet: quiet);
      return;
    }
    // Publish remembered-address results before discovery can change the set.
    // Discovery starts after this pass: it never delays known holdings.
    await _refresh(false, generation, walletId, quiet: quiet);
    if (!_current(generation, walletId)) return;
    final before = historyAddresses.toSet();
    _gw.probeNetwork();
    await _discover(generation, walletId);
    if (!_current(generation, walletId)) return;
    if (!setEquals(before, historyAddresses.toSet())) {
      await _refresh(
        false,
        generation,
        walletId,
        quiet: true,
        includeStealth: false,
      );
    } else {
      await _saveSnapshot(walletId);
    }
  }

  /// Keeps publication and cache writes tied to the wallet that started the work.
  Future<void> _refresh(
    bool discover,
    int generation,
    String? walletId, {
    bool quiet = false,
    bool includeStealth = true,
  }) async {
    // A first load has nothing to show yet, so it always announces itself.
    if (!quiet || phase == SyncPhase.idle) {
      phase = SyncPhase.syncing;
      notifyListeners();
    }

    if (discover) {
      _gw.probeNetwork();
      final ok = await _discover(generation, walletId);
      if (!ok || !_current(generation, walletId)) return;
    }

    final addresses = historyAddresses;
    if (addresses.isEmpty) {
      phase = SyncPhase.noAddresses;
      notifyListeners();
      return;
    }

    // Balances, activity, UTXO count and the stealth scan don't depend on
    // each other. The stealth leg never throws: an unreachable explorer
    // leaves the stealth balance unknown and the rest of the sync intact.
    // The balance is the fast leg and is shown as soon as it lands; the
    // history, which can take ten seconds on a public node, follows.
    // A quiet poll asks the explorer only every few ticks.
    final scanStealth =
        includeStealth &&
        (!quiet || discover || ++_quietPollsSinceStealth >= stealthScanEvery);
    final gateway = _gw;
    final read = gateway is WalletSyncBatchGateway
        ? (gateway as WalletSyncBatchGateway).startRead(addresses)
        : null;
    final balancesFuture = _fetchBalances(addresses, read);
    final historyFuture = _fetchHistory(addresses, read);
    final countFuture = (read?.count() ?? _gw.countUnspentBoxes(addresses))
        .catchError((_) => utxoCount);
    final stealthFuture = scanStealth
        ? _scanStealth(generation, walletId)
        : Future<void>.value();
    if (scanStealth) _quietPollsSinceStealth = 0;

    final balances = await balancesFuture;
    if (!_current(generation, walletId)) return;
    final failed = balances.failed;
    if (failed < addresses.length) {
      balanceNano = _withBroadcastDeltas(balances.erg);
      tokens = orderTokensForDisplay(balances.tokens);
      notifyListeners();
    }

    final results = await Future.wait<Object?>([
      historyFuture,
      countFuture,
      stealthFuture,
    ]);
    if (!_current(generation, walletId)) return;
    final history = results[0] as HistoryResult?;
    final txs = history?.rows;
    final boxes = results[1] as int;

    // Replace only when trustworthy: an empty result with no failures means
    // pending entries dropped from the mempool and must leave the list; an
    // empty result alongside failures is unreliable, keep what we had.
    if (txs != null && (txs.isNotEmpty || failed == 0)) {
      recentTxs = _withBroadcasts(txs).take(5).toList();
      // The node now vouches for what it shows; a broadcast it lists no
      // longer needs its delta carried.
      if (failed < addresses.length)
        balanceNano = _withBroadcastDeltas(balances.erg);
    }
    utxoCount = boxes;

    if (failed == addresses.length) {
      phase = SyncPhase.failed;
    } else if (failed > 0) {
      phase = SyncPhase.balancesStale;
    } else if (history == null || history.partial) {
      phase = SyncPhase.historyPartial;
    } else {
      publicSnapshotOnly = false;
      phase = SyncPhase.synced;
      lastSyncedAt = DateTime.now();
    }
    notifyListeners();
    if (!_current(generation, walletId)) return;

    // Names. Candidates come only from balance responses that SUCCEEDED in
    // this refresh — `tokens` is retained on failure, so using the field
    // could send a previous wallet state to a node that never returned it.
    // Ids seen moving in recent activity are deliberately excluded: history
    // is fetched through a separate client that can resolve to a different
    // node, so those ids were not necessarily served by `servedBy`.
    //
    // Stealth containment is structural, not a filter: candidates are the
    // ids the node itself just returned in `balances.tokens`, so a holding
    // that exists only in stealth boxes cannot be among them. A token held
    // in BOTH stays resolvable — its id is already in the node's own boxes.
    // Widening this set is what would need a filter; narrowing it here
    // would only be decoration.
    final ordinaryIds = <String>{
      if (failed < addresses.length) for (final t in balances.tokens) t.id,
    };
    final servedBy = read == null ? null : await read.servedBy();
    if (!_current(generation, walletId)) return;
    if (ordinaryIds.isNotEmpty && servedBy != null && walletId != null) {
      _startNameResolution(ordinaryIds, generation, walletId, servedBy);
    }

    if (!_current(generation, walletId)) return;
    await _saveSnapshot(walletId);
  }

  /// Name resolution owned by the controller rather than awaited by the
  /// refresh. A slow node must not hold `_inFlight`: polls, manual
  /// refreshes, post-broadcast refreshes and scheduled discovery all join
  /// that future, and forty 15-second timeouts would block them for ten
  /// minutes. Cancellation is by generation, checked inside the pass.
  Future<void>? _nameResolution;

  /// Exposed so tests can await the pass instead of racing it.
  @visibleForTesting
  Future<void>? get pendingNameResolution => _nameResolution;

  void _startNameResolution(
    Set<String> ids,
    int generation,
    String walletId,
    String servedBy,
  ) {
    _nameResolution = _gw
        .resolveTokenNames(
          ids,
          walletId: walletId,
          servedBy: servedBy,
          stillCurrent: () => _current(generation, walletId),
        )
        .then((resolved) {
          if (resolved.isEmpty || !_current(generation, walletId)) return;
          _applyResolved(resolved);
          notifyListeners();
        })
        .catchError((_) {})
        .whenComplete(() => _nameResolution = null);
  }

  /// Strips resolved metadata back out of the published holdings, keeping
  /// the holdings themselves. `_applyResolved` copies names, evidence and
  /// classification into `tokens`/`stealthTokens`, so clearing the service
  /// caches alone would leave a wiped collectible still named and still
  /// classified on screen.
  void stripResolvedMetadata() {
    List<TokenBalance> bare(List<TokenBalance> current) => [
      for (final t in current)
        TokenBalance(
          id: t.id,
          amount: t.amount,
          stealthAmount: t.stealthAmount,
        ),
    ];
    tokens = bare(tokens);
    stealthTokens = bare(stealthTokens);
    // Retained views and warm public snapshots carry their own copies, so
    // switching back to a wallet would restore the names the wipe removed —
    // without any lookup, which makes it look like nothing was cleared.
    // Dropping them costs a resync, not data.
    _remembered.clear();
    _publicWarm.clear();
    // A public refresh already holding named tokens would otherwise resume
    // after the wipe, pass its own validity check, and write them straight
    // back to disk and memory. The descriptor epoch does not reach it.
    _publicGeneration++;
    notifyListeners();
  }

  /// Folds resolved descriptors into the holdings already on screen. Without
  /// this a completed refresh keeps showing truncated ids and zero-decimal
  /// amounts until some later hydration happens to pick them up.
  void _applyResolved(Map<String, TokenBalance> resolved) {
    List<TokenBalance> apply(List<TokenBalance> current) => [
      for (final t in current)
        resolved[t.id]?.withHolding(t.amount, stealthAmount: t.stealthAmount) ??
            t,
    ];
    tokens = apply(tokens);
    stealthTokens = apply(stealthTokens);
  }

  Future<void> _saveSnapshot(String? walletId) async {
    final receive = receiveAddress;
    if (receive != null &&
        (phase != SyncPhase.failed || discoveredAt != null)) {
      await _gw.saveCachedState({
        'wallet_id': walletId ?? receive,
        'public_only': publicSnapshotOnly,
        'sync_phase': phase.name,
        'last_successful_sync_at': lastSyncedAt?.millisecondsSinceEpoch,
        'primary_address': receive,
        'used_addresses': usedAddresses,
        'frontier_addresses': frontierAddresses,
        'discovered_at': discoveredAt?.millisecondsSinceEpoch,
        'discovery_pinned_index': _discoveryPinnedIndex,
        'discovery_unused_change': _discoveryUnusedChange,
        'change_address': changeAddress,
        // A locked wallet cannot derive its stealth key, so it can never
        // rescan; the last known figure is the only thing it can honestly
        // show, and it is labelled as of a time.
        'stealth_nano_erg': stealthNano,
        // Only a successful scan moves this on, so a failed one preserves
        // both the figure and how old it is.
        'stealth_scanned_at': stealthScannedAt?.millisecondsSinceEpoch,
        'balance_nano_erg': balanceNano,
        'tokens': [
          for (final t in tokens)
            {
              'id': t.id,
              'amount': t.amount,
              'name': t.name,
              'decimals': t.decimals,
              'iconUrl': t.iconUrl,
              'emissionAmount': t.emissionAmount,
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
  Future<bool> _discover(int generation, String? walletId) async {
    try {
      final raw = await _gw.discoverAddresses();
      if (!_current(generation, walletId)) return false;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final used = _mapList(map['addresses']);
      final next = (map['next_unused_index'] as num?)?.toInt() ?? 0;

      final pinned = await _gw.getPinnedAddressIndex();
      if (!_current(generation, walletId)) return false;
      final pinnedReceive = pinned > 0
          ? await _gw.tryDeriveAddress(pinned)
          : null;
      if (!_current(generation, walletId)) return false;
      pinIssue = pinned > 0 && pinnedReceive == null
          ? _pinIssueFor(pinned)
          : null;

      // Reuse mode (default): everything goes to the main address, which is
      // the pinned one or index 0. Fresh mode (Nautilus-style): receive and
      // change move to the next unused address, except that a pinned
      // address at or beyond the frontier stays the receive address.
      final main = pinnedReceive ?? await _gw.deriveAddress(0);
      if (!_current(generation, walletId)) return false;
      final fresh = _gw.useUnusedChangeAddress(walletId);
      final String receive;
      final String change;
      if (!fresh) {
        receive = main;
        change = main;
      } else {
        if (pinnedReceive != null && pinned >= next) {
          receive = pinnedReceive;
        } else {
          receive = next == 0 ? main : await _gw.deriveAddress(next);
        }
        change = await _gw.deriveAddress(next);
      }
      // Every index up to the frontier is queried for balances even when
      // discovery saw no confirmed history there: a node whose index lags
      // would otherwise hide funds the wallet itself just sent to a new
      // address.
      final frontier = <String>[
        for (var i = 0; i <= next && i < 64; i++) await _gw.deriveAddress(i),
      ];
      if (!_current(generation, walletId)) return false;
      _discoveryPinnedIndex = pinned;
      _discoveryUnusedChange = fresh;
      discoveredAt = DateTime.now();
      usedAddresses = used;
      frontierAddresses = frontier;
      receiveAddress = receive;
      changeAddress = change;
      senderAddress = _bestSender(receive);
      notifyListeners();
    } catch (_) {
      // Fall through to a balance refresh with the addresses we know.
    }
    return true;
  }

  Future<_BalanceResult> _fetchBalances(
    List<String> addresses,
    WalletSyncRead? read,
  ) async {
    final maps = await Future.wait(
      addresses.map((address) async {
        try {
          return await (read?.balance(address) ?? _gw.getBalance(address));
        } catch (_) {
          return null;
        }
      }),
    );
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
        merged[t.id] = t.withHolding((prev?.amount ?? 0) + t.amount);
      }
    }
    return _BalanceResult(erg, merged.values.toList(), failed);
  }

  /// Folds a stealth scan into [stealthNano] and [stealthTokens].
  ///
  /// Off means "no stealth funds to show"; on but unreachable means
  /// "unknown", which the UI says out loud instead of showing a wrong zero.
  Future<void> _scanStealth(int generation, String? walletId) async {
    if (!_gw.stealthScanEnabled) {
      stealthNano = 0;
      stealthTokens = const [];
      stealthRows = const [];
      _stealthBoxIds = const [];
      stealthBalanceUnknown = false;
      stealthScannedAt = null;
      return;
    }
    StealthScanResult? result;
    try {
      result = await _gw.scanStealth();
    } catch (_) {
      result = null;
    }
    if (!_current(generation, walletId)) return;
    if (result == null) {
      stealthBalanceUnknown = true;
      return;
    }
    // Names and decimals, so a token held only in stealth boxes is not
    // rendered in base units and priced as if it had none. Hydration is
    // best effort: on failure the raw amounts still show.
    final raw = [
      for (final t in result.tokens) {'id': t.id, 'amount': t.amount.toInt()},
    ];
    List<TokenBalance> hydrated;
    try {
      hydrated = await _gw.hydrateTokens(raw);
    } catch (_) {
      hydrated = const [];
    }
    if (!_current(generation, walletId)) return;
    stealthNano = result.totalNanoErg;
    final meta = {for (final t in hydrated) t.id: t};
    stealthTokens = [
      for (final t in result.tokens)
        TokenBalance(
          id: t.id,
          amount: t.amount.toInt(),
          name: meta[t.id]?.name,
          decimals: meta[t.id]?.decimals ?? 0,
          emissionAmount: meta[t.id]?.emissionAmount,
          iconUrl: meta[t.id]?.iconUrl,
          stealthAmount: t.amount.toInt(),
        ),
    ];
    _stealthBoxIds = List.of(result.boxIds);
    stealthRows = stealthActivityRows(result.boxes);
    stealthBalanceUnknown = false;
    stealthScannedAt = DateTime.now();
  }

  /// Null when the history call itself failed.
  Future<HistoryResult?> _fetchHistory(
    List<String> addresses,
    WalletSyncRead? read,
  ) async {
    try {
      return await (read?.history() ?? _gw.loadHistory(addresses, limit: 20));
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

class _Broadcast {
  const _Broadcast(this.at, this.valueNano);
  final DateTime at;
  final int? valueNano;
}

class _BalanceResult {
  const _BalanceResult(this.erg, this.tokens, this.failed);
  final int erg;
  final List<TokenBalance> tokens;
  final int failed;
}

/// The app's one sync controller: the home screen drives it and the
/// navigator-level [WalletArgsScope] in `main.dart` reads from it.
final walletSyncController = WalletSyncController(
  const LiveWalletSyncGateway(),
);

class _WalletView {
  _WalletView(WalletSyncController c)
    : data = (
        publicSnapshotOnly: c.publicSnapshotOnly,
        phase: c.phase,
        receiveAddress: c.receiveAddress,
        changeAddress: c.changeAddress,
        senderAddress: c.senderAddress,
        balanceNano: c.balanceNano,
        tokens: c.tokens,
        recentTxs: c.recentTxs,
        usedAddresses: c.usedAddresses,
        frontierAddresses: c.frontierAddresses,
        utxoCount: c.utxoCount,
        lastSyncedAt: c.lastSyncedAt,
        stealthNano: c.stealthNano,
        stealthRows: c.stealthRows,
        stealthBoxIds: c._stealthBoxIds,
        stealthTokens: c.stealthTokens,
        stealthBalanceUnknown: c.stealthBalanceUnknown,
        stealthScannedAt: c.stealthScannedAt,
        pinIssue: c.pinIssue,
        discoveredAt: c.discoveredAt,
        discoveryPinnedIndex: c._discoveryPinnedIndex,
        discoveryUnusedChange: c._discoveryUnusedChange,
        broadcasts: Map<String, _Broadcast>.of(c._broadcasts),
      );
  final ({
    bool publicSnapshotOnly,
    SyncPhase phase,
    String? receiveAddress,
    String? changeAddress,
    String? senderAddress,
    int? balanceNano,
    List<TokenBalance> tokens,
    List<Map<String, dynamic>> recentTxs,
    List<Map<String, dynamic>> usedAddresses,
    List<String> frontierAddresses,
    int utxoCount,
    DateTime? lastSyncedAt,
    int stealthNano,
    List<Map<String, dynamic>> stealthRows,
    List<String> stealthBoxIds,
    List<TokenBalance> stealthTokens,
    bool stealthBalanceUnknown,
    DateTime? stealthScannedAt,
    String? pinIssue,
    DateTime? discoveredAt,
    int? discoveryPinnedIndex,
    bool? discoveryUnusedChange,
    Map<String, _Broadcast> broadcasts,
  })
  data;
  void restore(WalletSyncController c) {
    c.publicSnapshotOnly = data.publicSnapshotOnly;
    c.phase = data.phase;
    c.receiveAddress = data.receiveAddress;
    c.changeAddress = data.changeAddress;
    c.senderAddress = data.senderAddress;
    c.balanceNano = data.balanceNano;
    c.tokens = data.tokens;
    c.recentTxs = data.recentTxs;
    c.usedAddresses = data.usedAddresses;
    c.frontierAddresses = data.frontierAddresses;
    c.utxoCount = data.utxoCount;
    c.lastSyncedAt = data.lastSyncedAt;
    c.stealthNano = data.stealthNano;
    c.stealthRows = data.stealthRows;
    c._stealthBoxIds = data.stealthBoxIds;
    c.stealthTokens = data.stealthTokens;
    c.stealthBalanceUnknown = data.stealthBalanceUnknown;
    c.stealthScannedAt = data.stealthScannedAt;
    c.pinIssue = data.pinIssue;
    c.discoveredAt = data.discoveredAt;
    c._discoveryPinnedIndex = data.discoveryPinnedIndex;
    c._discoveryUnusedChange = data.discoveryUnusedChange;
    if (c.phase == SyncPhase.syncing) c.phase = SyncPhase.idle;
    c._broadcasts.addAll(data.broadcasts);
  }
}
