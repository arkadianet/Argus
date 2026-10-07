import 'package:flutter/material.dart';

import '../format.dart';
import '../services/erg_price_history.dart';
import '../services/network_controller.dart';
import '../services/privacy_service.dart';
import '../services/public_wallet_sync.dart';
import '../services/token_pricer.dart';
import '../services/wallet_service.dart';
import 'home/erg_price_feed.dart';
import 'home/home_data.dart';
import 'home/home_models.dart';
import 'home/overview_model.dart';
import 'home/overview_screen.dart';
import 'home/wallet_tools_sheet.dart';
import 'home/watched_actions.dart';

/// The launch screen: every wallet on this device — seed wallets, watched
/// addresses and watched accounts — with its balance, and the total across
/// them. Nothing here needs an unlock: locked wallets show their public
/// snapshot. Tapping a wallet opens its page; that is where a key is asked
/// for, if it needs one.
///
/// This is the only wallet list in the app. Creating, restoring and
/// watching start here; renaming and removing live in each wallet's own
/// settings. The screen itself is [OverviewScreen]; this reads the overview
/// model, the pricer and the network into its figures.
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
    this.onNetwork,
    this.priceFeed,
    this.notice,
    this.noticeIsError = false,
    this.onAction,
  });

  final WalletsOverviewModel model;

  /// Send, Receive, Swap and More from the overview's own row.
  final ValueChanged<WalletAction>? onAction;
  final ValueChanged<WalletRef> onOpen;
  final VoidCallback onCreate;
  final VoidCallback onRestore;
  final VoidCallback onWatchAddress;
  final VoidCallback onWatchAccount;
  final VoidCallback onSettings;

  /// The network line, while a node answers: its settings.
  final VoidCallback? onNetwork;

  /// ERG's day of prices for the strip under the total.
  final ErgPriceFeed? priceFeed;

  /// A parked link waiting for an unlock, or a startup error.
  final String? notice;
  final bool noticeIsError;

  void _add(AddWalletChoice choice) => switch (choice) {
        AddWalletChoice.create => onCreate(),
        AddWalletChoice.restore => onRestore(),
        AddWalletChoice.watchAddress => onWatchAddress(),
        AddWalletChoice.watchAccount => onWatchAccount(),
      };

  Future<void> _refresh() async {
    await Future.wait<void>([model.refresh(), ?priceFeed?.refresh()]);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        model,
        privacyService,
        tokenPricer,
        networkController,
        walletService.metadataChanges,
        ?priceFeed,
      ]),
      builder: (context, _) {
        final hidden = privacyService.hideBalances;
        final data = overviewData(model, hidden: hidden, history: priceFeed?.history);
        final offline = networkOffline();
        return OverviewScreen(
          data: data,
          onOpenWallet: onOpen,
          onReorder: model.reorder,
          onAdd: _add,
          onSettings: onSettings,
          onToggleHidden: () => privacyService.setHideBalances(!hidden),
          // With no node the line looks again; otherwise it opens the
          // network settings.
          onNetwork: offline ? networkController.probe : onNetwork,
          networkAction: offline ? 'Retry' : null,
          onRefresh: _refresh,
          footnote: data.wallets.isEmpty
              ? null
              : [
                  if (data.wallets.length > 1) 'Long-press a wallet to change the order.',
                  lockedWalletsExplainer,
                ].join(' '),
          notice: notice,
          noticeIsError: noticeIsError,
          onAction: onAction,
          onStopWatching: (ref) => stopWatching(context, ref),
        );
      },
    );
  }
}

/// The overview's figures for the model's current rows.
///
/// The total is the sum of what the rows show; a row whose balance is
/// unknown is left out of it and counted as not loaded, never added as
/// zero. What is pending is split against each figure it sits under
/// ([PendingBalance.under]), so the total's line counts every other
/// wallet's funds, and every stealth and mixing pocket, as confirmed.
OverviewData overviewData(WalletsOverviewModel model, {required bool hidden, ErgPriceHistory? history}) {
  final entries = model.entries();
  final totals = overviewTotals(entries);
  final now = DateTime.now();
  WalletSummary summary(OverviewEntry e) {
    final value = holdingsFiat(e.balanceNano, e.tokens);
    return WalletSummary(
      ref: e.ref,
      name: e.name,
      nanoErg: e.balanceNano,
      loading: e.loading,
      unavailable: e.unavailable,
      fiatValue: value.fiat,
      tokenCount: e.tokensKnown ? e.tokens.where((t) => t.amount > 0).map((t) => t.id).toSet().length : null,
      publicTokensOnly: e.publicTokensOnly && !e.watched,
      pockets: [if (e.stealthNano > 0) PocketBalance(pocket: Pocket.stealth, nanoErg: e.stealthNano)],
      // A locked wallet cannot rescan for stealth funds, so that figure is
      // as old as its last scan.
      pocketsAsOf: e.state == OverviewRowState.locked && e.stealthAsOf != null ? formatSyncAge(e.stealthAsOf) : null,
      pending: e.pending,
      otherAddresses: e.elsewhere,
      unlocked: e.state == OverviewRowState.unlocked,
      asOf: e.asOf == null ? null : formatSyncAge(now.subtract(e.asOf!)),
      address: e.address,
    );
  }

  final known = totals.total.known > 0;
  final value = known ? holdingsFiat(totals.total.totalNano, totals.tokens) : (fiat: null, unpriced: 0);
  return OverviewData(
    wallets: [
      for (final e in entries)
        if (!e.watched) summary(e),
    ],
    watched: [
      for (final e in entries)
        if (e.watched) summary(e),
    ],
    currency: homeCurrency(),
    network: overviewNetwork(),
    totalNano: known ? totals.total.totalNano : null,
    loading: !known && model.refreshing,
    notLoaded: totals.total.unknown,
    totalFiat: value.fiat,
    unpricedCount: value.unpriced,
    pricesNote: pricesNote(),
    pending: totals.pending,
    price: ergPriceView(history),
    hidden: hidden,
  );
}
