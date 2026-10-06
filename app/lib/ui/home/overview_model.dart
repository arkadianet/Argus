import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../services/address_holdings.dart';
import '../../services/address_label_service.dart';
import '../../services/mix_service.dart';
import '../../services/network_controller.dart';
import '../../services/pending_balance.dart';
import '../../services/portfolio.dart';
import '../../services/public_wallet_sync.dart';
import '../../services/wallet_database_service.dart';
import '../../services/wallet_service.dart';
import '../../services/wallet_sync_controller.dart';
import '../../services/watch_account_service.dart';
import '../../services/watch_only_service.dart';

enum WalletKind { seed, watchedAddress, watchedAccount }

/// One wallet on the overview: a seed wallet, a watched address or a watched
/// extended-key account. What the home screen has open, when it has one.
@immutable
class WalletRef {
  const WalletRef.seed(String walletId) : kind = WalletKind.seed, id = walletId;
  const WalletRef.watchedAddress(String address)
    : kind = WalletKind.watchedAddress,
      id = address;
  const WalletRef.watchedAccount(String key)
    : kind = WalletKind.watchedAccount,
      id = key;

  final WalletKind kind;

  /// The wallet id, the watched address, or the account's extended key.
  final String id;

  /// No key on this device: nothing here can sign.
  bool get watched => kind != WalletKind.seed;

  @override
  bool operator ==(Object other) =>
      other is WalletRef && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'WalletRef(${kind.name}, $id)';
}

enum OverviewRowState {
  /// The seed wallet whose key is in memory now.
  unlocked,

  /// A seed wallet shown from its last public snapshot.
  locked,

  /// A watched address or account: public data, no key at all.
  watched,
}

/// One overview row with every figure already decided, so the row widget
/// only lays it out. Balances are display figures: a seed wallet's include
/// its stealth funds (and, while unlocked, its mixes), exactly as its own
/// page shows them, and the overview total is the sum of these.
@immutable
class OverviewEntry {
  const OverviewEntry({
    required this.ref,
    required this.name,
    required this.state,
    this.address,
    this.balanceNano,
    this.loading = false,
    this.tokens = const [],
    this.tokensKnown = false,
    this.publicTokensOnly = true,
    this.asOf,
    this.stealthNano = 0,
    this.stealthAsOf,
    this.elsewhere,
    this.unavailable,
    this.pending,
  });

  final WalletRef ref;
  final String name;
  final OverviewRowState state;

  /// The address the wallet is shown as: the pinned address, index 0, the
  /// watched address, or a watched account's first address.
  final String? address;

  /// Null when unknown: never shown, and never added, as zero.
  final int? balanceNano;
  final bool loading;
  final List<({String id, int amount, int decimals})> tokens;

  /// False when the source cannot say which tokens the wallet holds; the
  /// row then shows no count rather than "0 tokens".
  final bool tokensKnown;
  final bool publicTokensOnly;

  /// Age of a snapshot figure. Null for live figures.
  final Duration? asOf;

  /// Stealth ERG included in [balanceNano].
  final int stealthNano;

  /// When a locked wallet's stealth figure was last scanned; it cannot be
  /// rescanned without the seed.
  final DateTime? stealthAsOf;

  /// Funds on addresses other than [address].
  final FundsElsewhere? elsewhere;

  /// Why [balanceNano] is null, when the row should say so.
  final String? unavailable;

  /// What transactions still in the mempool do to [balanceNano], split
  /// against it (see [PendingBalance.under]). Null when nothing valued it:
  /// no read since pending summaries, or one that could not value the
  /// mempool.
  final PendingBalance? pending;

  bool get watched => ref.watched;
}

/// The overview's headline: the sum of the rows it can see.
class OverviewTotals {
  const OverviewTotals({
    required this.total,
    required this.wallets,
    required this.watched,
    required this.tokens,
    this.pending,
  });
  final PortfolioTotal total;
  final int wallets;
  final int watched;

  /// Every counted row's tokens, for the fiat valuation of the total.
  final List<({String id, int amount, int decimals})> tokens;

  /// What is pending across the counted rows, split against the total; null
  /// when no row has a split.
  final PendingBalance? pending;
}

OverviewTotals overviewTotals(List<OverviewEntry> entries) {
  final total = portfolioTotal([for (final e in entries) e.balanceNano]);
  PendingBalance? pending;
  for (final e in entries) {
    final split = e.pending;
    if (e.balanceNano == null || split == null) continue;
    pending = pending == null ? split : pending.plus(split);
  }
  return OverviewTotals(
    total: total,
    wallets: entries.where((e) => !e.watched).length,
    watched: entries.where((e) => e.watched).length,
    tokens: [
      for (final e in entries)
        if (e.balanceNano != null) ...e.tokens,
    ],
    // Rows without a split add nothing pending: as far as anything here
    // knows, their figures are in blocks.
    pending: pending?.under(total.totalNano),
  );
}

/// What a watched address held at its last read.
class WatchedHoldings {
  const WatchedHoldings({
    required this.nanoErg,
    this.tokens = const [],
    this.pending,
  });
  final int nanoErg;
  final List<({String id, int amount})> tokens;

  /// How [nanoErg] splits into confirmed and pending: `get_balance`'s
  /// `summary`. Null when the answer had none.
  final PendingBalance? pending;

  factory WatchedHoldings.fromBalance(Map<String, dynamic> balance) {
    final holding = AddressHolding.fromBalance('', balance);
    return WatchedHoldings(
      nanoErg: holding.nanoErg,
      tokens: holding.tokens,
      pending: PendingBalance.fromJson(balance['summary']),
    );
  }
}

/// Live figures of the unlocked wallet, read from the sync controller.
class ActiveWalletFigures {
  const ActiveWalletFigures({
    required this.walletId,
    required this.balanceNano,
    required this.syncing,
    required this.stealthNano,
    required this.stealthUnknown,
    required this.mixNano,
    required this.tokens,
    required this.holdings,
    this.pending,
  });

  /// The controller's view, when it owns [walletId]; null otherwise.
  static ActiveWalletFigures? of(
    WalletSyncController sync,
    String? walletId, {
    int mixNano = 0,
  }) {
    if (walletId == null || !sync.ownsWallet(walletId)) return null;
    return ActiveWalletFigures(
      walletId: walletId,
      balanceNano: sync.balanceNano,
      syncing: sync.isSyncing,
      stealthNano: sync.stealthNano,
      stealthUnknown: sync.stealthBalanceUnknown,
      mixNano: mixNano,
      tokens: [
        for (final t
            in (sync.stealthBalanceUnknown ? sync.tokens : sync.displayTokens))
          (id: t.id, amount: t.amount, decimals: t.decimals),
      ],
      holdings: sync.addressHoldings,
      pending: sync.pending,
    );
  }

  final String walletId;

  /// Spendable public ERG; null before the first read.
  final int? balanceNano;
  final bool syncing;
  final int stealthNano;
  final bool stealthUnknown;

  /// In the mixing pool, or mixed and waiting: the wallet's money too.
  final int mixNano;
  final List<({String id, int amount, int decimals})> tokens;
  final List<AddressHolding> holdings;

  /// The sync's split of [balanceNano], this app's unseen broadcasts
  /// included.
  final PendingBalance? pending;

  /// What the wallet is worth, as its page shows it.
  int? get totalNano =>
      balanceNano == null ? null : balanceNano! + stealthNano + mixNano;
}

/// The overview rows, in display order: seed wallets in the user's order,
/// then watched addresses, then watched accounts.
List<OverviewEntry> buildOverviewEntries({
  required List<WalletInfo> wallets,
  required Map<String, LastKnownBalance> lastKnown,
  Map<String, PendingBalance> lastPending = const {},
  required String? unlockedWalletId,
  ActiveWalletFigures? active,
  List<String> watchedAddresses = const [],
  Map<String, WatchedHoldings?> watchedHoldings = const {},
  Map<String, Duration> watchedAsOf = const {},
  bool watchedLoading = false,
  List<WatchAccount> accounts = const [],
  String? Function(String address)? labelFor,
  int Function(String tokenId)? decimalsOf,
}) {
  final decimals = decimalsOf ?? (_) => 0;
  return [
    for (final w in wallets)
      if (active != null && active.walletId == w.walletId)
        _activeEntry(w, active)
      else
        _lockedEntry(
          w,
          lastKnown[w.walletId],
          lastPending[w.walletId],
          unlocked: w.walletId == unlockedWalletId,
        ),
    for (final a in watchedAddresses)
      _watchedAddressEntry(
        a,
        watchedHoldings[a],
        loading: watchedLoading && !watchedHoldings.containsKey(a),
        failed: watchedHoldings.containsKey(a) && watchedHoldings[a] == null,
        asOf: watchedAsOf[a],
        label: labelFor?.call(a),
        decimals: decimals,
      ),
    for (final account in accounts) _accountEntry(account, decimals),
  ];
}

OverviewEntry _activeEntry(WalletInfo w, ActiveWalletFigures active) {
  final identity = w.displayAddress;
  return OverviewEntry(
    ref: WalletRef.seed(w.walletId),
    name: w.name,
    state: OverviewRowState.unlocked,
    address: identity,
    balanceNano: active.totalNano,
    loading: active.balanceNano == null && active.syncing,
    tokens: active.tokens,
    tokensKnown: active.balanceNano != null,
    publicTokensOnly: active.stealthUnknown,
    stealthNano: active.stealthNano,
    pending: switch (active.totalNano) {
      final shown? => active.pending?.under(shown),
      null => null,
    },
    elsewhere: fundsElsewhere(
      withWalletIndexes(
        active.holdings,
        address0: w.address0,
        pinnedAddress: w.pinnedAddress,
        pinnedIndex: w.pinnedAddressIndex,
      ),
      identity: identity,
    ),
  );
}

OverviewEntry _lockedEntry(
  WalletInfo w,
  LastKnownBalance? known,
  PendingBalance? pending, {
  required bool unlocked,
}) {
  final identity = w.displayAddress;
  return OverviewEntry(
    ref: WalletRef.seed(w.walletId),
    name: w.name,
    state: unlocked ? OverviewRowState.unlocked : OverviewRowState.locked,
    address: identity,
    // A locked wallet cannot rescan for stealth funds, so its last scanned
    // figure stays in, labelled with its age, as the row has always shown.
    balanceNano: known == null ? null : known.balanceNano + known.stealthNano,
    tokens: known?.tokens ?? const [],
    tokensKnown: known != null && known.tokensKnown,
    publicTokensOnly: true,
    asOf: known?.age,
    stealthNano: known?.stealthNano ?? 0,
    stealthAsOf: known?.stealthScannedAt,
    // Saved with the figure, so exactly as old as it is.
    pending: known == null
        ? null
        : pending?.under(known.balanceNano + known.stealthNano),
    elsewhere: known == null
        ? null
        : fundsElsewhere(
            withWalletIndexes(
              known.addressHoldings,
              address0: w.address0,
              pinnedAddress: w.pinnedAddress,
              pinnedIndex: w.pinnedAddressIndex,
            ),
            identity: identity,
          ),
    unavailable: known != null
        ? null
        : identity == null
        ? 'Open to load'
        : 'Not loaded yet',
  );
}

OverviewEntry _watchedAddressEntry(
  String address,
  WatchedHoldings? holdings, {
  required bool loading,
  required bool failed,
  Duration? asOf,
  required String? label,
  required int Function(String) decimals,
}) => OverviewEntry(
  ref: WalletRef.watchedAddress(address),
  name: label ?? 'Watched address',
  state: OverviewRowState.watched,
  address: address,
  balanceNano: holdings?.nanoErg,
  loading: loading,
  tokens: [
    for (final t in holdings?.tokens ?? const <({String id, int amount})>[])
      (id: t.id, amount: t.amount, decimals: decimals(t.id)),
  ],
  tokensKnown: holdings != null,
  asOf: asOf,
  unavailable: failed ? 'Balance unavailable' : null,
  pending: holdings?.pending?.under(holdings.nanoErg),
);

OverviewEntry _accountEntry(
  WatchAccount account,
  int Function(String) decimals,
) {
  final snapshot = account.snapshot;
  return OverviewEntry(
    ref: WalletRef.watchedAccount(account.key),
    name: account.label ?? 'Watched account',
    state: OverviewRowState.watched,
    address: snapshot != null && snapshot.addresses.isNotEmpty
        ? snapshot.addresses.first
        : null,
    balanceNano: snapshot?.balance,
    loading: snapshot == null && account.busy,
    tokens: [
      for (final t in (snapshot?.tokens ?? const <String, int>{}).entries)
        (id: t.key, amount: t.value, decimals: decimals(t.key)),
    ],
    tokensKnown: snapshot != null,
    unavailable: snapshot == null && !account.busy
        ? (account.error ?? 'Balance unavailable')
        : null,
    pending: snapshot?.pending?.under(snapshot.balance),
  );
}

/// Feeds the launch overview: the wallet list, each wallet's last public
/// snapshot, watched balances, and the refresh schedule that keeps them
/// current without an unlock.
///
/// Locked seed wallets refresh through [PublicWalletSync] (known addresses
/// only, five-minute floor, one request at a time). Watched addresses are
/// read on the same floor; watched accounts, whose scan costs dozens of
/// requests, only at launch when they have no snapshot and on an explicit
/// refresh.
class WalletsOverviewModel extends ChangeNotifier {
  WalletsOverviewModel({
    PublicWalletSync? publicSync,
    DateTime Function()? clock,
  }) : _public = publicSync ?? publicWalletSync,
       _clock = clock ?? DateTime.now;

  final PublicWalletSync _public;
  final DateTime Function() _clock;

  List<WalletInfo> _wallets = const [];
  List<WalletInfo> get wallets => _wallets;

  final Map<String, LastKnownBalance> _lastKnown = {};
  final Map<String, PendingBalance> _lastPending = {};
  final Map<String, WatchedHoldings?> _watched = {};
  final Map<String, DateTime> _watchedReadAt = {};
  final Set<String> _watchedStale = {};
  bool _watchedLoading = false;
  DateTime? _watchedAt;
  int _watchedGeneration = 0;
  Future<void>? _refresh;
  int _loadGeneration = 0;
  bool _attached = false;
  bool _disposed = false;

  /// Floor between two reads of the watched addresses, as for locked wallets.
  static const watchedInterval = PublicWalletSync.interval;

  bool get refreshing => _refresh != null;

  WalletInfo? wallet(String walletId) {
    for (final w in _wallets) {
      if (w.walletId == walletId) return w;
    }
    return null;
  }

  LastKnownBalance? lastKnown(String walletId) => _lastKnown[walletId];

  /// The pending split saved with [lastKnown]'s snapshot, if any.
  PendingBalance? lastPending(String walletId) => _lastPending[walletId];

  /// What the watched [address] held at its last successful read; null when
  /// it has not been read or every read failed.
  WatchedHoldings? watchedHoldings(String address) => _watched[address];

  bool get isEmpty =>
      _wallets.isEmpty &&
      watchOnlyService.addresses.isEmpty &&
      watchAccountService.accounts.isEmpty;

  /// Starts listening to the services the rows are drawn from.
  void attach() {
    if (_attached || _disposed) return;
    _attached = true;
    watchOnlyService.addListener(_onWatchedChanged);
    watchAccountService.addListener(notifyListeners);
    addressLabelService.addListener(notifyListeners);
    walletSyncController.addListener(notifyListeners);
    mixService.addListener(notifyListeners);
    _public.addListener(_onPublicChanged);
  }

  @override
  void dispose() {
    if (_attached) {
      watchOnlyService.removeListener(_onWatchedChanged);
      watchAccountService.removeListener(notifyListeners);
      addressLabelService.removeListener(notifyListeners);
      walletSyncController.removeListener(notifyListeners);
      mixService.removeListener(notifyListeners);
      _public.removeListener(_onPublicChanged);
    }
    _disposed = true;
    super.dispose();
  }

  /// Reads finish after the screen is gone; they must not reach a disposed
  /// notifier.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  /// Rows for the current state of every source.
  List<OverviewEntry> entries() {
    final unlocked = walletService.isUnlocked
        ? walletService.activeWalletId
        : null;
    final now = _clock();
    return buildOverviewEntries(
      wallets: _wallets,
      lastKnown: _lastKnown,
      lastPending: _lastPending,
      unlockedWalletId: unlocked,
      active: ActiveWalletFigures.of(
        walletSyncController,
        unlocked,
        mixNano: mixService.inMixNano + mixService.mixedNano,
      ),
      watchedAddresses: watchOnlyService.addresses,
      watchedHoldings: _watched,
      watchedAsOf: {
        for (final a in _watchedStale)
          if (_watchedReadAt[a] case final at?) a: now.difference(at),
      },
      watchedLoading: _watchedLoading,
      accounts: List.of(watchAccountService.accounts),
      labelFor: addressLabelService.labelFor,
      decimalsOf: (id) => walletService.cachedTokenMeta(id)?.decimals ?? 0,
    );
  }

  /// Reads the wallet list and every wallet's last snapshot from disk: no
  /// network, so the overview paints at once.
  Future<void> loadWallets() async {
    final generation = ++_loadGeneration;
    final wallets = await walletService.listWallets();
    final snapshots = await _snapshots(wallets);
    if (generation != _loadGeneration || _disposed) return;
    _wallets = wallets;
    _remember(snapshots);
    notifyListeners();
  }

  /// Every wallet's last figures, and the pending split saved with them.
  static Future<_Snapshots> _snapshots(List<WalletInfo> wallets) async {
    final known = <String, LastKnownBalance>{};
    final pending = <String, PendingBalance>{};
    for (final w in wallets) {
      final k = await WalletDatabaseService.lastKnownBalance(w.walletId);
      if (k != null) known[w.walletId] = k;
      final p = await lastKnownPending(w.walletId);
      if (p != null) pending[w.walletId] = p;
    }
    return (known: known, pending: pending);
  }

  void _remember(_Snapshots snapshots) {
    _lastKnown
      ..clear()
      ..addAll(snapshots.known);
    _lastPending
      ..clear()
      ..addAll(snapshots.pending);
  }

  /// Saves the order the user dragged the seed wallets into.
  Future<void> reorder(int oldIndex, int newIndex) async {
    final ids = [for (final w in _wallets) w.walletId];
    if (oldIndex < 0 || oldIndex >= ids.length) return;
    final moved = ids.removeAt(oldIndex);
    ids.insert(
      (newIndex > oldIndex ? newIndex - 1 : newIndex).clamp(0, ids.length),
      moved,
    );
    // Paint the new order at once; the reload confirms it from storage.
    final byId = {for (final w in _wallets) w.walletId: w};
    _wallets = [for (final id in ids) byId[id]!];
    notifyListeners();
    await walletService.setWalletOrder(ids);
    await loadWallets();
  }

  /// The launch pass: locked wallets and watched addresses, plus the
  /// watched accounts that have no snapshot yet (they are not persisted).
  Future<void> refreshOnLaunch() => _start(allAccounts: false);

  /// Pull to refresh: locked wallets (when due), watched addresses and
  /// every watched account. Completes when all of them have.
  Future<void> refresh() => _start(allAccounts: true);

  Future<void> _start({required bool allAccounts}) {
    final running = _refresh;
    if (running != null) return running;
    final op = _run(allAccounts).whenComplete(() {
      _refresh = null;
      notifyListeners();
    });
    _refresh = op;
    notifyListeners();
    return op;
  }

  Future<void> _run(bool allAccounts) => Future.wait<void>([
    _refreshPublic(),
    refreshWatchedAddresses(),
    watchMapOrdered(
      [
        for (final a in watchAccountService.accounts)
          if (allAccounts || a.snapshot == null) a,
      ],
      watchAccountService.refresh,
      concurrency: watchAccountConcurrency,
    ),
  ]);

  /// The poll's share: whatever is due, never a watched-account scan.
  Future<void> refreshIfDue() async {
    if (_refresh != null || _disposed) return;
    final now = _clock();
    final publicDue = _public.isDue(now);
    final watchedDue =
        _watchedAt == null || now.difference(_watchedAt!) >= watchedInterval;
    await Future.wait<void>([
      if (publicDue) _refreshPublic(),
      if (watchedDue) refreshWatchedAddresses(),
    ]);
  }

  Future<void> _refreshPublic() async {
    await _public.tick(
      wallets: {for (final w in _wallets) w.walletId: w.displayAddress},
      recordedAddresses: {
        for (final w in _wallets)
          w.walletId: [
            if (w.address0 != null) w.address0!,
            if (w.pinnedAddress != null) w.pinnedAddress!,
          ],
      },
      controller: walletSyncController,
      activeId: walletService.isUnlocked ? walletService.activeWalletId : null,
      unlocked: () => walletService.isUnlocked,
      whileLocked: true,
    );
    await _reloadSnapshots();
  }

  Future<void> _reloadSnapshots() async {
    final generation = _loadGeneration;
    final snapshots = await _snapshots(_wallets);
    if (generation != _loadGeneration || _disposed) return;
    _remember(snapshots);
    notifyListeners();
  }

  void _onPublicChanged() => unawaited(_reloadSnapshots());

  void _onWatchedChanged() {
    final addresses = watchOnlyService.addresses.toSet();
    _watched.removeWhere((a, _) => !addresses.contains(a));
    _watchedReadAt.removeWhere((a, _) => !addresses.contains(a));
    _watchedStale.removeWhere((a) => !addresses.contains(a));
    notifyListeners();
    // A newly watched address is read at once rather than at the next floor.
    if (addresses.any((a) => !_watched.containsKey(a))) {
      unawaited(refreshWatchedAddresses());
    }
  }

  /// Reads every watched address's ERG and tokens from the user's node.
  Future<void> refreshWatchedAddresses() async {
    final generation = ++_watchedGeneration;
    final addresses = watchOnlyService.addresses;
    _watchedAt = _clock();
    if (addresses.isEmpty) {
      _watchedLoading = false;
      notifyListeners();
      return;
    }
    _watchedLoading = true;
    notifyListeners();
    final results = await Future.wait(
      addresses.map((a) async {
        try {
          final balance = await walletService.getBalance(
            a,
            nodeUrl: networkController.activeUrl,
          );
          return (a, WatchedHoldings.fromBalance(balance));
        } catch (_) {
          return (a, null);
        }
      }),
    );
    if (generation != _watchedGeneration || _disposed) return;
    final at = _clock();
    for (final (a, holdings) in results) {
      if (holdings != null) {
        _watched[a] = holdings;
        _watchedReadAt[a] = at;
        _watchedStale.remove(a);
      } else if (_watched[a] == null) {
        // Never read: the row says the balance is unavailable.
        _watched[a] = null;
      } else {
        // Keep the last figure, but say how old it is.
        _watchedStale.add(a);
      }
    }
    _watchedLoading = false;
    notifyListeners();
  }
}

typedef _Snapshots = ({
  Map<String, LastKnownBalance> known,
  Map<String, PendingBalance> pending,
});
