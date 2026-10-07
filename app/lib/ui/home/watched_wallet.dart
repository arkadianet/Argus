import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../format.dart';
import '../../services/network_controller.dart';
import '../../services/privacy_service.dart';
import '../../services/token_pricer.dart';
import '../../services/wallet_service.dart';
import '../../services/watch_account_service.dart';
import '../../theme/argus_theme.dart';
import '../cold_signing_screen.dart';
import '../settings_screen.dart';
import '../transaction_detail_screen.dart';
import '../transactions_screen.dart';
import '../widgets/asset_tile.dart';
import '../widgets/empty_state.dart';
import '../widgets/soft_card.dart';
import '../widgets/token_detail_sheet.dart';
import 'erg_price_feed.dart';
import 'home_data.dart';
import 'home_models.dart';
import 'overview_model.dart';
import 'wallet_nav_bar.dart';
import 'wallet_page.dart';
import 'watched_actions.dart';

/// What a watched wallet's page shows, read from public data only: the
/// node's balance and history for a watched address, the last scan for a
/// watched account. No handle, no derivation beyond the account's public
/// key, no stealth scan.
class WatchedWalletSource extends ChangeNotifier {
  WatchedWalletSource.address(String this.address, {WatchedHoldings? cached})
    : account = null {
    if (cached != null) {
      balanceNano = cached.nanoErg;
      pending = cached.pending;
      _raw = [
        for (final t in cached.tokens) {'id': t.id, 'amount': t.amount},
      ];
    }
  }

  WatchedWalletSource.account(WatchAccount this.account) : address = null;

  final String? address;
  final WatchAccount? account;

  int? balanceNano;

  /// How [balanceNano] splits into confirmed and pending: the address's
  /// `get_balance` summary, or the account's last scan summed address by
  /// address. Null when the read had none.
  PendingBalance? pending;
  List<TokenBalance> tokens = const [];
  List<Map<String, dynamic>> recent = const [];

  /// A read is in flight.
  bool loading = false;

  /// Activity has been read at least once, so an empty list means none.
  bool activityLoaded = false;
  String? error;
  String? activityError;
  DateTime? updatedAt;

  List<Map<String, dynamic>> _raw = const [];
  WatchAccountSnapshot? _seen;
  int _generation = 0;
  bool _started = false;
  bool _disposed = false;

  bool get isAccount => account != null;

  /// The address this wallet is shown as.
  String? get identity => address ?? account?.snapshot?.addresses.firstOrNull;

  /// Receive and history need an address set: an account before its first
  /// complete scan has none it can vouch for.
  bool get ready => address != null || account?.snapshot != null;

  List<String> get historyAddresses =>
      address != null ? [address!] : (account?.snapshot?.addresses ?? const []);

  /// Context for pushed screens. Watch-only route arguments override the
  /// unlocked wallet's scope, so nothing of the signing wallet leaks in.
  WalletRouteArgs? get routeArgs {
    final a = address;
    if (a != null) {
      return WalletRouteArgs(
        watchOnly: true,
        senderAddress: a,
        receiveAddress: a,
        changeAddress: a,
        historyAddresses: [a],
        tokens: tokens,
        spendableNano: balanceNano,
      );
    }
    final snapshot = account?.snapshot;
    if (snapshot == null || snapshot.addresses.isEmpty) return null;
    return WalletRouteArgs(
      watchOnly: true,
      watchAccount: true,
      senderAddress: snapshot.addresses.first,
      receiveAddress: snapshot.receiveAddress,
      changeAddress: snapshot.receiveAddress,
      historyAddresses: snapshot.addresses,
      tokens: tokens,
      spendableNano: snapshot.balance,
    );
  }

  /// Paints what is known, then reads. Opening an account reuses its last
  /// scan: a scan is dozens of requests, run only when asked for.
  void start() {
    if (_started) return;
    _started = true;
    final a = account;
    if (a != null) {
      watchAccountService.addListener(_fromSnapshot);
      _fromSnapshot();
      return;
    }
    unawaited(_hydrate(_raw, _generation));
    unawaited(refresh());
  }

  @override
  void dispose() {
    _disposed = true;
    if (account != null) watchAccountService.removeListener(_fromSnapshot);
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Future<void> refresh() async {
    final a = account;
    if (a != null) {
      await watchAccountService.refresh(a);
      return;
    }
    final generation = ++_generation;
    loading = true;
    error = null;
    notifyListeners();
    final addr = address!;
    await Future.wait<void>([
      () async {
        try {
          final balance = await walletService.getBalance(
            addr,
            nodeUrl: networkController.activeUrl,
          );
          if (generation != _generation) return;
          balanceNano = (balance['balance_nano_erg'] as num?)?.toInt() ?? 0;
          pending = PendingBalance.fromJson(balance['summary']);
          _raw = [
            for (final t in (balance['tokens'] as List? ?? const []))
              if (t is Map) t.cast<String, dynamic>(),
          ];
          updatedAt = DateTime.now();
          await _hydrate(_raw, generation);
        } catch (e) {
          if (generation == _generation) error = 'Balance unavailable: $e';
        }
      }(),
      () async {
        try {
          final history = await walletService.loadHistory([addr], limit: 5);
          if (generation != _generation) return;
          recent = history.rows.take(5).toList();
          activityLoaded = true;
          activityError = history.partial
              ? 'Some activity could not be read.'
              : null;
        } catch (e) {
          if (generation == _generation)
            activityError = 'Could not load activity.';
        }
      }(),
    ]);
    if (generation != _generation) return;
    loading = false;
    notifyListeners();
  }

  /// Names and decimals from the cache only: opening a watched wallet puts
  /// no metadata request on the wire.
  Future<void> _hydrate(List<Map<String, dynamic>> raw, int generation) async {
    final hydrated = await walletService.hydrateTokens(raw);
    if (generation != _generation || _disposed) return;
    tokens = orderTokensForWatched(hydrated);
    notifyListeners();
  }

  void _fromSnapshot() {
    final a = account!;
    final snapshot = a.snapshot;
    loading = a.busy;
    error = a.error;
    if (!identical(snapshot, _seen)) {
      _seen = snapshot;
      final generation = ++_generation;
      if (snapshot == null) {
        balanceNano = null;
        pending = null;
        tokens = const [];
        recent = const [];
        activityLoaded = false;
      } else {
        balanceNano = snapshot.balance;
        pending = snapshot.pending;
        recent = snapshot.history.take(5).toList();
        activityLoaded = true;
        updatedAt = DateTime.now();
        unawaited(
          _hydrate([
            for (final t in snapshot.tokens.entries)
              {'id': t.key, 'amount': t.value},
          ], generation),
        );
      }
    }
    notifyListeners();
  }
}

/// Fungible tokens before collectibles, then by name: the same stable order
/// the signing wallet uses, so a watched list does not reshuffle per read.
List<TokenBalance> orderTokensForWatched(List<TokenBalance> tokens) {
  final out = List<TokenBalance>.of(tokens);
  out.sort((a, b) {
    if (a.isCollectible != b.isCollectible) return a.isCollectible ? 1 : -1;
    final byName = a.label.toLowerCase().compareTo(b.label.toLowerCase());
    return byName != 0 ? byName : a.id.compareTo(b.id);
  });
  return out;
}

/// The standard wallet page for a wallet with no key on this device. Same
/// page as a seed wallet's; Send becomes "Send with offline signer", and
/// whatever needs a key here (swap, mix, tools, Discover) is left out.
class WatchedWalletPage extends StatefulWidget {
  const WatchedWalletPage({
    super.key,
    required this.target,
    required this.name,
    required this.onClose,
    required this.onRemoved,
    this.cached,
    this.priceFeed,
  });

  final WalletRef target;
  final String name;

  /// Back to the overview.
  final VoidCallback onClose;

  /// The wallet was unwatched from its settings.
  final VoidCallback onRemoved;

  /// The overview's last read of a watched address, painted at once.
  final WatchedHoldings? cached;

  /// ERG's day of prices, for the ERG row's 24h change.
  final ErgPriceFeed? priceFeed;

  /// No Discover: a watched wallet has no keys to use a protocol with.
  static const _tabs = [WalletTab.wallet, WalletTab.activity, WalletTab.settings];

  @override
  State<WatchedWalletPage> createState() => _WatchedWalletPageState();
}

class _WatchedWalletPageState extends State<WatchedWalletPage> {
  late final WatchedWalletSource _source = _sourceFor(widget.target);

  Future<void> _menu(_WatchedMenu choice) async {
    switch (choice) {
      case _WatchedMenu.rename:
        // The header's name follows the label services it is built from.
        await renameWatched(context, widget.target);
      case _WatchedMenu.stop:
        if (await stopWatching(context, widget.target)) widget.onRemoved();
    }
  }
  WalletTab _tab = WalletTab.wallet;
  final Set<WalletTab> _visited = {WalletTab.wallet};

  WatchedWalletSource _sourceFor(WalletRef ref) {
    if (ref.kind == WalletKind.watchedAccount) {
      // Gone between the tap and the build: an empty account page, which
      // the home screen closes as soon as it hears of the removal.
      final account = watchAccountService.accounts.firstWhere(
        (a) => a.key == ref.id,
        orElse: () => WatchAccount(ref.id),
      );
      return WatchedWalletSource.account(account);
    }
    return WatchedWalletSource.address(ref.id, cached: widget.cached);
  }

  @override
  void initState() {
    super.initState();
    _source.start();
  }

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }

  void _selectTab(WalletTab tab) {
    if (tab == _tab) return;
    setState(() {
      _tab = tab;
      _visited.add(tab);
    });
  }

  void _back() {
    if (_tab != WalletTab.wallet) {
      _selectTab(WalletTab.wallet);
    } else {
      widget.onClose();
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _send() async {
    final account = _source.account;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => account != null
            ? ColdWatchSendScreen(account: account)
            : ColdWatchSendScreen.address(address: _source.address!),
      ),
    );
  }

  /// An account's Receive offers the first unused address, so it scans
  /// first: a stale scan could hand out an address that has since been paid.
  Future<void> _receive() async {
    if (_source.isAccount) {
      await _source.refresh();
      if (!mounted) return;
      if (_source.account!.snapshot == null) {
        _snack('Account refresh unavailable. Try again.');
        return;
      }
    }
    final args = _source.routeArgs;
    if (args == null || !mounted) return;
    await Navigator.pushNamed(context, '/receive', arguments: args);
  }

  void _openTx(Map<String, dynamic> tx) {
    final args = _source.routeArgs;
    if (args == null) return;
    Navigator.push(
      context,
      fadeRoute(
        const TransactionDetailScreen(),
        settings: RouteSettings(arguments: args.copyWith(transaction: tx)),
      ),
    );
  }

  void _openToken(TokenBalance t) => showTokenDetailSheet(
        context,
        token: t,
        explorerUrl: networkController.explorerToken(t.id),
      );

  void _allAssets() => Navigator.push(context, fadeRoute(WatchedAssetsScreen(source: _source)));

  Future<void> _copyAddress(String address) async {
    await Clipboard.setData(ClipboardData(text: address));
    _snack('Address copied');
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: ListenableBuilder(
        listenable: _source,
        builder: (context, _) => WalletPageScreen(
          title: _tab == WalletTab.wallet ? widget.name : walletTabLook(_tab).label,
          subtitle: _tab == WalletTab.wallet ? (_source.isAccount ? 'Watched account' : 'Watched address') : null,
          immersive: _tab == WalletTab.wallet,
          onBack: widget.onClose,
          actions: [
            if (_tab == WalletTab.wallet)
              IconButton(
                tooltip: _source.isAccount ? 'Rescan account' : 'Refresh',
                icon: _source.loading
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh),
                onPressed: _source.loading ? null : _source.refresh,
              ),
            // As a seed wallet's header has its ⋮: the ways to rename the
            // wallet or stop watching it, not only from its Settings tab.
            if (_tab == WalletTab.wallet)
              PopupMenuButton<_WatchedMenu>(
                key: const Key('watched-menu'),
                tooltip: 'More options',
                icon: const Icon(Icons.more_vert),
                onSelected: _menu,
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    key: Key('watched-menu-rename'),
                    value: _WatchedMenu.rename,
                    child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Rename')),
                  ),
                  PopupMenuItem(
                    key: Key('watched-menu-stop'),
                    value: _WatchedMenu.stop,
                    child: ListTile(leading: Icon(Icons.visibility_off_outlined), title: Text('Stop watching')),
                  ),
                ],
              ),
          ],
          body: IndexedStack(
            index: WatchedWalletPage._tabs.indexOf(_tab),
            children: [
              _walletTab(),
              _visited.contains(WalletTab.activity) ? _activityTab() : const SizedBox.shrink(),
              _visited.contains(WalletTab.settings)
                  ? SettingsScreen(
                      key: ValueKey('settings-${widget.target}'),
                      embedded: true,
                      watched: widget.target,
                      onShowAllWallets: widget.onClose,
                      onWalletRemoved: (_) => widget.onRemoved(),
                    )
                  : const SizedBox.shrink(),
            ],
          ),
          navBar: WalletNavBar(
            current: _tab,
            onSelect: _selectTab,
            watchOnly: true,
            pendingCount: _source.recent.where(isPendingTx).length,
          ),
        ),
      ),
    );
  }

  Widget _activityTab() {
    final args = _source.routeArgs;
    if (args == null) {
      return EmptyState(
        icon: Icons.account_tree_outlined,
        title: 'Account not scanned',
        body: 'Refresh the account to read its addresses and activity.',
        actionLabel: 'Refresh account',
        onAction: _source.refresh,
      );
    }
    return TransactionsScreen(
      // A rescan can change the address set; the list follows it.
      key: ValueKey('watched-activity-${args.historyAddresses.length}'),
      embedded: true,
      args: args,
    );
  }

  Widget _walletTab() {
    return ListenableBuilder(
      listenable: Listenable.merge([
        privacyService,
        tokenPricer,
        networkController,
        walletService.metadataChanges,
        ?widget.priceFeed,
      ]),
      builder: (context, _) {
        final s = _source;
        final hidden = privacyService.hideBalances;
        final holdings = s.tokens.map(walletService.displayMetadata).toList();
        final shown = s.recent.take(WalletPageView.activityLimit).toList();
        final data = watchedPageData(
          s,
          ref: widget.target,
          name: widget.name,
          holdings: holdings,
          shown: shown,
          hidden: hidden,
          price: ergPriceView(widget.priceFeed?.history),
        );
        final address = s.identity;
        return WalletPageView(
          data: data,
          onRefresh: s.refresh,
          onToggleHidden: () => privacyService.setHideBalances(!hidden),
          onAction: (a) => switch (a) {
            WalletAction.sendOffline => _send(),
            WalletAction.receive => _receive(),
            _ => null,
          },
          onAsset: (id) {
            if (id == 'ERG') return _allAssets();
            for (final t in holdings) {
              if (t.id == id) return _openToken(t);
            }
          },
          onAllAssets: _allAssets,
          onActivity: (id) {
            for (final (i, tx) in shown.indexed) {
              if (activityRowId(tx, i) == id) return _openTx(tx);
            }
          },
          onAllActivity: s.ready ? () => _selectTab(WalletTab.activity) : null,
          onReceive: data.watched!.canReceive && s.ready ? _receive : null,
          onRetry: networkController.probe,
          onCopyAddress: address == null ? null : () => _copyAddress(address),
        );
      },
    );
  }
}

/// A watched wallet's page from its public reads: the balance and tokens
/// of the address or the account's last scan, its last few transactions,
/// and what it can and cannot do from here.
WalletPageData watchedPageData(
  WatchedWalletSource s, {
  required WalletRef ref,
  required String name,
  required List<TokenBalance> holdings,
  required List<Map<String, dynamic>> shown,
  required bool hidden,
  ErgPriceView? price,
}) {
  final nano = s.balanceNano;
  final value = holdingsFiat(nano, [
    for (final t in holdings) (id: t.id, amount: t.amount, decimals: t.decimals),
  ]);
  return WalletPageData(
    wallet: WalletSummary(
      ref: ref,
      name: name,
      nanoErg: nano,
      loading: nano == null && s.loading,
      fiatValue: value.fiat,
      tokenCount: nano == null ? null : holdings.length,
      pending: nano == null ? null : s.pending?.under(nano),
      address: s.identity,
    ),
    currency: homeCurrency(),
    offline: networkOffline(),
    assets: nano == null ? const [] : assetRows(nano, holdings, price),
    assetCount: nano == null ? 0 : 1 + holdings.length,
    activity: [for (final (i, tx) in shown.indexed) activityRow(tx, id: activityRowId(tx, i))],
    activityLoading: !s.activityLoaded && s.loading,
    activityError: s.recent.isEmpty ? s.activityError : null,
    activityEmpty: s.ready ? 'No activity yet' : 'Refresh the account to read its activity.',
    activityEmptyAction: s.ready ? 'Show its address' : null,
    unpricedCount: value.unpriced,
    pricesNote: pricesNote(),
    hidden: hidden,
    pendingCount: s.recent.where(isPendingTx).length,
    watched: WatchedDetails(
      status: [
        'Watch-only · cannot sign here',
        if (s.loading)
          s.isAccount ? 'Scanning…' : 'Refreshing…'
        else if (s.updatedAt != null)
          'Updated ${formatSyncAge(s.updatedAt)}',
      ],
      error: s.error,
      notes: s.isAccount
          ? const [
              watchAccountLimitations,
              'Discovery stops after 20 unused addresses. Payments beyond a larger gap can be missed.',
            ]
          : const [
              'Cannot sign locally. Send with an offline signer; change returns to this same address. A watched account tracks more addresses.',
            ],
      addressTitle: s.isAccount ? 'First address' : 'Address',
      addressNote: s.isAccount
          ? 'Check this matches the first address in the wallet the key came from: '
              'an extended key has no checksum. '
              '${s.historyAddresses.length} addresses scanned.'
          : null,
      canSend: s.ready,
      // An account without a complete scan has no unused address it can
      // vouch for; the scan is a refresh away.
      canReceive: !s.isAccount || (s.ready && !s.loading),
    ),
  );
}

/// Every holding of a watched wallet. The signing wallet's Assets screen
/// reads the unlocked wallet's live holdings, so it cannot stand in here.
class WatchedAssetsScreen extends StatelessWidget {
  const WatchedAssetsScreen({super.key, required this.source});

  final WatchedWalletSource source;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Assets')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          source,
          privacyService,
          tokenPricer,
          walletService.metadataChanges,
        ]),
        builder: (context, _) {
          final hidden = privacyService.hideBalances;
          final holdings = source.tokens
              .map(walletService.displayMetadata)
              .toList();
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              SoftCard(
                padding: EdgeInsets.zero,
                child: DividedColumn(
                  children: [
                    AssetTile.erg(
                      balanceNano: source.balanceNano,
                      fiatText: networkController.fiatText(source.balanceNano),
                      hidden: hidden,
                      showChevron: false,
                    ),
                    for (final t in holdings)
                      AssetTile.token(
                        t,
                        fiatText: t.isCollectible
                            ? null
                            : tokenPricer.fiatTextFor(
                                tokenId: t.id,
                                amount: t.amount,
                                decimals: t.decimals,
                              ),
                        hidden: hidden,
                        onTap: () => showTokenDetailSheet(
                          context,
                          token: t,
                          explorerUrl: networkController.explorerToken(t.id),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

enum _WatchedMenu { rename, stop }
