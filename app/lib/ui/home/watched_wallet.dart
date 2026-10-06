import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../format.dart';
import '../../services/network_controller.dart';
import '../../services/pending_balance.dart';
import '../../services/privacy_service.dart';
import '../../services/token_pricer.dart';
import '../../services/wallet_service.dart';
import '../../services/watch_account_service.dart';
import '../../theme/argus_theme.dart';
import '../cold_signing_screen.dart';
import '../offline_banner.dart';
import '../settings_screen.dart';
import '../transaction_detail_screen.dart';
import '../transactions_screen.dart';
import '../widgets/asset_tile.dart';
import '../widgets/empty_state.dart';
import '../widgets/soft_card.dart';
import '../widgets/token_detail_sheet.dart';
import 'overview_model.dart';
import 'value_lines.dart';
import 'wallet_sections.dart';

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
/// sections as a seed wallet; Send becomes "Send with offline signer", and
/// whatever needs a key here (swap, mix, tools) is left out.
class WatchedWalletPage extends StatefulWidget {
  const WatchedWalletPage({
    super.key,
    required this.target,
    required this.name,
    required this.onClose,
    required this.onRemoved,
    this.cached,
  });

  final WalletRef target;
  final String name;

  /// Back to the overview.
  final VoidCallback onClose;

  /// The wallet was unwatched from its settings.
  final VoidCallback onRemoved;

  /// The overview's last read of a watched address, painted at once.
  final WatchedHoldings? cached;

  @override
  State<WatchedWalletPage> createState() => _WatchedWalletPageState();
}

class _WatchedWalletPageState extends State<WatchedWalletPage> {
  late final WatchedWalletSource _source = _sourceFor(widget.target);
  int _tab = 0;
  final Set<int> _visited = {0};
  static const _assetCap = 4;
  static const _titles = ['', 'Activity', 'Settings'];

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

  void _selectTab(int index) {
    if (index == _tab) return;
    setState(() {
      _tab = index;
      _visited.add(index);
    });
  }

  void _back() {
    if (_tab != 0) {
      _selectTab(0);
    } else {
      widget.onClose();
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: widget.onClose),
          title: Text(
            _tab == 0 ? widget.name : _titles[_tab],
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          actions: [
            if (_tab == 0)
              ListenableBuilder(
                listenable: _source,
                builder: (context, _) => IconButton(
                  tooltip: _source.isAccount ? 'Rescan account' : 'Refresh',
                  icon: _source.loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  onPressed: _source.loading ? null : _source.refresh,
                ),
              ),
          ],
        ),
        body: Column(
          children: [
            const WarningStrip(),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: [
                  _walletTab(),
                  _visited.contains(1)
                      ? _activityTab()
                      : const SizedBox.shrink(),
                  _visited.contains(2)
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
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: _selectTab,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.account_balance_wallet_outlined),
              selectedIcon: Icon(Icons.account_balance_wallet),
              label: 'Wallet',
            ),
            NavigationDestination(
              icon: Icon(Icons.schedule_outlined),
              selectedIcon: Icon(Icons.schedule),
              label: 'Activity',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }

  Widget _activityTab() {
    return ListenableBuilder(
      listenable: _source,
      builder: (context, _) {
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
      },
    );
  }

  Widget _walletTab() {
    return ListenableBuilder(
      listenable: Listenable.merge([
        _source,
        privacyService,
        tokenPricer,
        networkController,
        walletService.metadataChanges,
      ]),
      builder: (context, _) {
        final s = _source;
        final hidden = privacyService.hideBalances;
        final holdings = s.tokens.map(walletService.displayMetadata).toList();
        final values = [
          for (final t in holdings)
            (id: t.id, amount: t.amount, decimals: t.decimals),
        ];
        final tiles = <Widget>[
          AssetTile.erg(
            balanceNano: s.balanceNano,
            fiatText: networkController.fiatText(s.balanceNano),
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
              onTap: () => _openToken(t),
            ),
        ];
        final identity = s.identity;
        return RefreshIndicator(
          onRefresh: s.refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              const OfflineBanner(),
              WalletBalanceCard(
                label: s.isAccount ? 'WATCHED ACCOUNT' : 'WATCHED ADDRESS',
                balanceNano: s.balanceNano,
                loading: s.balanceNano == null && s.loading,
                hidden: hidden,
                onToggleHidden: () => privacyService.setHideBalances(!hidden),
                valueLine: s.balanceNano == null
                    ? null
                    : headlineValueLine(
                        ergNano: s.balanceNano,
                        tokens: values,
                        hidden: hidden,
                      ),
                pending: switch (s.balanceNano) {
                  final shown? => s.pending?.under(shown),
                  null => null,
                },
                identity: identity == null
                    ? null
                    : WalletIdentityLine(address: identity),
                footer: WatchedStatusStrip(
                  lines: [
                    'Watch-only · cannot sign here',
                    if (s.loading)
                      s.isAccount ? 'Scanning…' : 'Refreshing…'
                    else if (s.updatedAt != null)
                      'Updated ${formatSyncAge(s.updatedAt)}',
                  ],
                  error: s.error,
                ),
              ),
              const SizedBox(height: 12),
              WatchOnlyActions(
                onSend: s.ready ? _send : null,
                // An account without a complete scan has no unused address
                // it can vouch for; the scan is a refresh away.
                onReceive: !s.isAccount || (s.ready && !s.loading)
                    ? _receive
                    : null,
              ),
              const SizedBox(height: 14),
              WalletNotice(
                lines: s.isAccount
                    ? const [
                        watchAccountLimitations,
                        'Discovery stops after 20 unused addresses. Payments beyond a larger gap can be missed.',
                      ]
                    : const [
                        'Cannot sign locally. Send with an offline signer; change returns to this same address. A watched account tracks more addresses.',
                      ],
              ),
              const SizedBox(height: 28),
              AssetsSection(
                title: 'Assets',
                tiles: tiles.take(_assetCap).toList(),
                total: tiles.length,
                onViewAll: tiles.length > _assetCap
                    ? () => Navigator.push(
                        context,
                        fadeRoute(WatchedAssetsScreen(source: _source)),
                      )
                    : null,
              ),
              const SizedBox(height: 28),
              RecentActivitySection(
                rows: s.recent,
                hidden: hidden,
                onOpen: _openTx,
                onViewAll: s.ready ? () => _selectTab(1) : null,
                loading: !s.activityLoaded && s.loading,
                error: s.recent.isEmpty ? s.activityError : null,
                emptyBody: s.ready
                    ? 'Payments to this ${s.isAccount ? 'account' : 'address'} will show up here.'
                    : 'Refresh the account to read its activity.',
              ),
              if (identity != null) ...[
                const SizedBox(height: 28),
                _AddressCard(
                  title: s.isAccount ? 'First address' : 'Address',
                  address: identity,
                  note: s.isAccount
                      ? 'Check this matches the first address in the wallet the key came from: '
                            'an extended key has no checksum. '
                            '${s.historyAddresses.length} addresses scanned.'
                      : null,
                  onCopy: () async {
                    await Clipboard.setData(ClipboardData(text: identity));
                    _snack('Address copied');
                  },
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _AddressCard extends StatelessWidget {
  const _AddressCard({
    required this.title,
    required this.address,
    required this.onCopy,
    this.note,
  });

  final String title;
  final String address;
  final String? note;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title),
        const SizedBox(height: 10),
        SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(address, style: monoStyle(context, size: 12.5)),
              if (note != null) ...[
                const SizedBox(height: 8),
                Text(note!, style: TextStyle(fontSize: 12.5, color: muted)),
              ],
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
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
