import 'package:flutter/material.dart';

import '../../format.dart';
import '../../services/address_holdings.dart';
import '../../services/address_label_service.dart';
import '../../services/dexy_service.dart';
import '../../services/duckpools_service.dart';
import '../../services/mix_activity.dart';
import '../../services/mix_service.dart';
import '../../services/network_controller.dart';
import '../../services/pockets.dart';
import '../../services/privacy_service.dart';
import '../../services/sigmafi_service.dart';
import '../../services/sigmausd_service.dart';
import '../../services/token_pricer.dart';
import '../../services/wallet_service.dart';
import '../../services/wallet_sync_controller.dart';
import '../swap_hub_screen.dart';
import '../utxo_management_screen.dart';
import '../widgets/discover_sheet.dart';
import 'address_breakdown.dart';
import 'discover_view.dart';
import 'erg_price_feed.dart';
import 'home_data.dart';
import 'home_models.dart';
import 'wallet_page.dart';

/// What the wallet tab's taps do. The home screen owns navigation, the
/// unlock state and the other tabs, so it supplies these.
class WalletLedgerActions {
  const WalletLedgerActions({
    required this.go,
    required this.swap,
    required this.showActivity,
    required this.showSettings,
    required this.viewAssets,
    required this.openTx,
    required this.openToken,
    required this.labelAddress,
    required this.lock,
  });

  /// Pushes a named route with this wallet's arguments ('/send', '/mix'...).
  final void Function(String route) go;
  final void Function(SwapVenue venue) swap;
  final VoidCallback showActivity;
  final VoidCallback showSettings;
  final VoidCallback viewAssets;
  final ValueChanged<Map<String, dynamic>> openTx;
  final ValueChanged<TokenBalance> openToken;
  final ValueChanged<String> labelAddress;
  final VoidCallback lock;
}

/// The unlocked seed wallet's Wallet tab: its balance, its actions, what it
/// holds and what it did, read from the sync controller and the services
/// around it into one [WalletPageData] and laid out by [WalletPageView].
///
/// The portfolio total and the list of wallets are not here: they live on
/// the overview, one level up.
class WalletLedger extends StatelessWidget {
  const WalletLedger({
    super.key,
    required this.sync,
    required this.wallet,
    required this.actions,
    this.priceFeed,
  });

  final WalletSyncController sync;

  /// The wallet list's record of this wallet: its name, index 0 and pin.
  final WalletInfo? wallet;
  final WalletLedgerActions actions;

  /// ERG's day of prices, for the ERG row's 24h change.
  final ErgPriceFeed? priceFeed;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        sync,
        mixService,
        privacyService,
        addressLabelService,
        networkController,
        tokenPricer,
        walletService.metadataChanges,
        ?priceFeed,
      ]),
      builder: (context, _) {
        final hidden = privacyService.hideBalances;
        final w = wallet;
        // Stealth holdings are part of what the wallet owns, so they belong
        // in the asset list; each holding knows how much of it is stealth.
        final holdings = sync.displayTokens.map(walletService.displayMetadata).toList();
        // The identity is the wallet's own record (the pinned address, else
        // index 0), not today's receive address, which moves in fresh mode.
        final identity = w?.displayAddress ?? sync.receiveAddress;
        final addresses = withWalletIndexes(
          sync.addressHoldings,
          address0: w?.address0,
          pinnedAddress: w?.pinnedAddress,
          pinnedIndex: w?.pinnedAddressIndex,
        );
        final activity = sync.displayActivity;
        final shown = activity.take(WalletPageView.activityLimit).toList();
        final mix = mixStripSummary(mixService.records);
        final data = _data(holdings: holdings, identity: identity, addresses: addresses, shown: shown, mix: mix, hidden: hidden);
        void breakdown({required bool all}) => showAddressBreakdownSheet(
              context,
              walletName: w?.name ?? 'This wallet',
              holdings: addresses,
              identity: identity,
              hidden: hidden,
              listEmpty: all,
              labelFor: addressLabelService.labelFor,
              onLabel: actions.labelAddress,
              labels: addressLabelService,
            );
        return WalletPageView(
          data: data,
          onRefresh: () => sync.refresh(discover: true),
          onToggleHidden: () => privacyService.setHideBalances(!hidden),
          onAction: (a) => switch (a) {
            WalletAction.send => actions.go('/send'),
            WalletAction.receive => actions.go('/receive'),
            WalletAction.swap => actions.swap(SwapVenue.spectrum),
            WalletAction.sendOffline || WalletAction.more => null,
          },
          onTool: (tool) => switch (tool) {
            WalletTool.mix => actions.go('/mix'),
            WalletTool.tokens => actions.go('/tokens'),
            WalletTool.utxos => actions.go('/utxos'),
            WalletTool.addresses => breakdown(all: true),
            WalletTool.lock => actions.lock(),
          },
          onAsset: (id) {
            if (id == 'ERG') return actions.viewAssets();
            for (final t in holdings) {
              if (t.id == id) return actions.openToken(t);
            }
          },
          onAllAssets: actions.viewAssets,
          onActivity: (id) {
            for (final (i, tx) in shown.indexed) {
              if (activityRowId(tx, i) == id) return actions.openTx(tx);
            }
          },
          onAllActivity: actions.showActivity,
          // The status line leads to the UTXO tools; while the wallet is
          // fragmented, its own line goes straight to the suggested cleanup.
          onStatus: () => actions.go('/utxos'),
          onTidyUp: () => actions.go(UtxoManagementScreen.cleanupRoute),
          onOtherAddresses: () => breakdown(all: false),
          onReceive: () => actions.go('/receive'),
          onPinIssue: actions.showSettings,
          onMix: () => actions.go('/mix'),
          onDismissMix: mix?.finished == null ? null : () => mixService.acknowledge(mix!.finished!),
          onRetry: networkController.probe,
        );
      },
    );
  }

  WalletPageData _data({
    required List<TokenBalance> holdings,
    required String? identity,
    required List<AddressHolding> addresses,
    required List<Map<String, dynamic>> shown,
    required ({String text, MixRecord? finished})? mix,
    required bool hidden,
  }) {
    final w = wallet;
    final price = ergPriceView(priceFeed?.history);
    // Stealth ERG and money in the mixing pool are the wallet's too; only
    // send and coin selection use the spendable figure. The headline must
    // never be smaller than the pockets it is broken down into.
    final withStealth = sync.totalNanoWithStealth;
    final headline = withStealth == null ? null : withStealth + mixService.inMixNano + mixService.mixedNano;
    final value = holdingsFiat(headline, [
      for (final t in holdings) (id: t.id, amount: t.amount, decimals: t.decimals),
    ]);
    final online = networkController.activeUrl != null;
    final label = sync.statusLabel(online: online);
    final state = label == 'Synced'
        ? SyncState.synced
        : sync.isStale
            ? SyncState.stale
            : sync.isSyncing
                ? SyncState.syncing
                : label == 'Offline'
                    ? SyncState.offline
                    : SyncState.partial;
    // Kept while the next sync is in flight: "Syncing… · 5m ago".
    final age = formatSyncAge(sync.lastSyncedAt);
    return WalletPageData(
      wallet: WalletSummary(
        ref: WalletRef.seed(w?.walletId ?? sync.receiveAddress ?? ''),
        name: w?.name ?? 'Wallet',
        nanoErg: headline,
        loading: sync.balanceNano == null && sync.isSyncing,
        fiatValue: value.fiat,
        tokenCount: holdings.length,
        pockets: walletPockets(
          publicNano: sync.balanceNano,
          stealthNano: sync.stealthNano,
          stealthUnknown: sync.stealthScanning && sync.stealthBalanceUnknown,
          mixedNano: mixService.mixedNano,
          inMixNano: mixService.inMixNano,
        ),
        // The stealth and mixing pockets in the headline are in blocks, so
        // the split counts them as confirmed and adds up to the headline.
        pending: headline == null ? null : sync.pending?.under(headline),
        otherAddresses: fundsElsewhere(addresses, identity: identity),
        unlocked: true,
        address: identity,
        pinnedIndex: w?.pinnedAddressIndex,
      ),
      currency: homeCurrency(),
      status: NetworkStatus(
        state: state,
        blockHeight: networkController.height,
        age: age.isEmpty ? null : age,
        label: label,
      ),
      offline: networkOffline(),
      // ERG as held: public and stealth, which is what the asset list and
      // a send can see; the mixing pool's share is in the headline above.
      assets: withStealth == null ? const [] : assetRows(withStealth, holdings, price),
      assetCount: (withStealth == null ? 0 : 1) + holdings.length,
      activity: [for (final (i, tx) in shown.indexed) activityRow(tx, id: activityRowId(tx, i))],
      activityLoading: shown.isEmpty && sync.isSyncing && sync.lastSyncedAt == null,
      utxoCount: sync.utxoCount,
      fragmented: sync.utxoCount > utxoFragmentationThreshold,
      unpricedCount: value.unpriced,
      pricesNote: pricesNote(),
      hidden: hidden,
      pendingCount: sync.displayActivity.where(isPendingTx).length,
      pinIssue: sync.pinIssue,
      mix: mix == null ? null : MixLine(text: mix.text, finished: mix.finished != null),
    );
  }
}

/// The unlocked wallet's Discover tab: every protocol and tool, with the
/// wallet's own position in each where it has one.
class WalletDiscover extends StatelessWidget {
  const WalletDiscover({super.key, required this.sync, required this.onExplain});

  final WalletSyncController sync;
  final ValueChanged<DiscoverFeature> onExplain;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([sync, mixService, duckpoolsService, sigmafiService, privacyService]),
      builder: (context, _) {
        final hidden = privacyService.hideBalances;
        final duckpools = [
          duckpoolsService.positionLine(formatTokenAmountGrouped),
          duckpoolsService.loanLine(formatTokenAmountGrouped),
        ].whereType<String>().join(' · ');
        final active = mixService.active.length;
        // The wallet's own position, where it has one; with balances hidden
        // the blurb stands in, since a position is an amount.
        String? position(DiscoverFeature f) => hidden && f != DiscoverFeature.mix
            ? null
            : switch (f) {
                DiscoverFeature.dexy => _positionLine(ids: [
                    for (final v in DexyVariant.values) ...[v.tokenId, v.lpTokenId],
                  ]),
                DiscoverFeature.ageusd => _positionLine(ids: const [SigmaUsdTokens.sigUsd, SigmaUsdTokens.sigRsv]),
                DiscoverFeature.duckpools => duckpools.isEmpty ? null : duckpools,
                DiscoverFeature.sigmafi => sigmafiService.positionLine(),
                DiscoverFeature.mix =>
                  mixService.enabled && active > 0 ? '$active ${active == 1 ? 'mix' : 'mixes'} in the pool.' : null,
                _ => null,
              };
        List<DiscoverCardData> cards(List<DiscoverFeature> features) => [
              for (final f in features)
                if (discoverAvailable(f)) DiscoverCardData(f, subtitle: position(f)),
            ];
        return DiscoverView(onExplain: onExplain, protocols: cards(discoverProtocols), tools: cards(discoverTools));
      },
    );
  }

  /// "You hold 12.5 SigUSD · 3 SigRSV" when the wallet has a position in
  /// any of [ids]; null otherwise so the row keeps its blurb.
  String? _positionLine({required List<String> ids}) {
    final held = <String>[
      for (final t in sync.tokens)
        if (ids.contains(t.id) && t.amount > 0) '${formatTokenAmountGrouped(t.amount, t.decimals)} ${t.label}',
    ];
    if (held.isEmpty) return null;
    return 'You hold ${held.take(2).join(' · ')}';
  }
}
