import 'package:flutter/material.dart';

import '../format.dart';
import '../services/privacy_service.dart';
import '../services/public_wallet_sync.dart';
import '../services/token_pricer.dart';
import '../services/network_controller.dart';
import '../theme/argus_theme.dart';
import 'home/overview_model.dart';
import 'home/overview_sections.dart';
import 'home/value_lines.dart';
import 'offline_banner.dart';

/// "2 wallets · 3 watch-only" headline for the overview summary card.
String overviewHeadline({required int wallets, required int watchOnly, int accounts = 0}) {
  if (accounts > 0) {
    final accountText = '$accounts watched ${accounts == 1 ? 'account' : 'accounts'}';
    if (wallets == 0 && watchOnly == 0) return accountText;
    return '${overviewHeadline(wallets: wallets, watchOnly: watchOnly)} · $accountText';
  }
  if (wallets == 0) {
    return '$watchOnly watch-only ${watchOnly == 1 ? 'address' : 'addresses'}';
  }
  final w = '$wallets ${wallets == 1 ? 'wallet' : 'wallets'}';
  return watchOnly == 0 ? w : '$w · $watchOnly watch-only';
}

String overviewTotalLine({required int known, required int total}) =>
    known == 0 ? 'Total balance unavailable' : 'Visible total  ${formatErg(total)}';

/// The launch screen: every wallet on this device — seed wallets, watched
/// addresses and watched accounts — with its balance, and the total across
/// them. Nothing here needs an unlock: locked wallets show their public
/// snapshot. Tapping a wallet opens its page; that is where a key is asked
/// for, if it needs one.
///
/// This is the only wallet list in the app. Creating, restoring and
/// watching start here; renaming and removing live in each wallet's own
/// settings.
class WalletsOverviewScreen extends StatelessWidget {
  const WalletsOverviewScreen({
    super.key,
    required this.model,
    required this.onOpen,
    required this.onCreate,
    required this.onRestore,
    required this.onWatchAddress,
    required this.onWatchAccount,
    required this.onSettings,
    this.onLock,
    this.notice,
    this.noticeIsError = false,
  });

  final WalletsOverviewModel model;
  final ValueChanged<WalletRef> onOpen;
  final VoidCallback onCreate;
  final VoidCallback onRestore;
  final VoidCallback onWatchAddress;
  final VoidCallback onWatchAccount;
  final VoidCallback onSettings;

  /// Locks the unlocked wallet; null when none is unlocked.
  final VoidCallback? onLock;

  /// A parked link waiting for an unlock, or a startup error.
  final String? notice;
  final bool noticeIsError;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Argus', style: Theme.of(context).textTheme.headlineSmall),
        actions: [
          if (onLock != null)
            IconButton(
              icon: const Icon(Icons.lock_open_outlined),
              tooltip: 'Lock wallet',
              onPressed: onLock,
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: onSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          const WarningStrip(),
          Expanded(
            child: ListenableBuilder(
              listenable: Listenable.merge([
                model,
                privacyService,
                tokenPricer,
                networkController,
              ]),
              builder: (context, _) => RefreshIndicator(
                onRefresh: model.refresh,
                child: _body(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    final hidden = privacyService.hideBalances;
    final actions = OverviewAddActions(
      onCreate: onCreate,
      onRestore: onRestore,
      onWatchAddress: onWatchAddress,
      onWatchAccount: onWatchAccount,
    );
    final padding = EdgeInsets.fromLTRB(16, 8, 16, 40 + MediaQuery.paddingOf(context).bottom);
    final noticeCard = notice == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: OverviewNotice(message: notice!, error: noticeIsError),
          );
    if (model.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: padding,
        children: [
          const OfflineBanner(),
          ?noticeCard,
          OverviewWelcome(actions: actions),
        ],
      );
    }
    final entries = model.entries();
    final seeds = entries.where((e) => !e.watched).toList();
    final watched = entries.where((e) => e.watched).toList();
    final totals = overviewTotals(entries);
    Widget row(OverviewEntry e) => OverviewWalletRow(
          key: ValueKey('overview-row-${e.ref.kind.name}-${e.ref.id}'),
          entry: e,
          hidden: hidden,
          valueText: rowValueText(ergNano: e.balanceNano, tokens: e.tokens, hidden: hidden),
          onTap: () => onOpen(e.ref),
        );
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: padding,
      children: [
        const OfflineBanner(),
        ?noticeCard,
        OverviewTotalCard(
          totals: totals,
          hidden: hidden,
          loading: model.refreshing,
          valueLine: totals.total.known == 0
              ? null
              : headlineValueLine(
                  ergNano: totals.total.totalNano,
                  tokens: totals.tokens,
                  hidden: hidden,
                ),
          onToggleHidden: () => privacyService.setHideBalances(!hidden),
        ),
        if (seeds.isNotEmpty) ...[
          const SizedBox(height: 24),
          OverviewGroup(
            title: 'Wallets',
            scope: 'On this device',
            rows: [for (final e in seeds) row(e)],
            onReorder: model.reorder,
          ),
        ],
        if (watched.isNotEmpty) ...[
          const SizedBox(height: 24),
          OverviewGroup(
            title: 'Watched',
            scope: 'No keys',
            rows: [for (final e in watched) row(e)],
          ),
        ],
        const SizedBox(height: 24),
        actions,
        const SizedBox(height: 20),
        Text(
          [
            if (seeds.length > 1) 'Long-press a wallet to change the order.',
            lockedWalletsExplainer,
          ].join(' '),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
