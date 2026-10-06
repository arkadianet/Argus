import 'package:flutter/material.dart';

import '../../format.dart';
import '../../services/address_holdings.dart';
import '../../services/address_label_service.dart';
import '../../services/dexy_service.dart';
import '../../services/duckpools_service.dart';
import '../../services/mix_service.dart';
import '../../services/network_controller.dart';
import '../../services/pockets.dart';
import '../../services/privacy_service.dart';
import '../../services/sigmafi_service.dart';
import '../../services/sigmausd_service.dart';
import '../../services/token_pricer.dart';
import '../../services/wallet_service.dart';
import '../../services/wallet_sync_controller.dart';
import '../../theme/argus_theme.dart';
import '../offline_banner.dart';
import '../swap_hub_screen.dart';
import '../widgets/action_row.dart';
import '../widgets/asset_tile.dart';
import '../widgets/discover_sheet.dart';
import '../widgets/mix_strip.dart';
import 'address_breakdown.dart';
import 'value_lines.dart';
import 'wallet_sections.dart';

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
    required this.openFeature,
    required this.explainFeature,
    required this.exploreAll,
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
  final ValueChanged<DiscoverFeature> openFeature;
  final ValueChanged<DiscoverFeature> explainFeature;
  final VoidCallback exploreAll;
}

/// The unlocked seed wallet's Wallet tab: its balance, its actions, what it
/// holds, what it did, and what it can do. One section per widget; this
/// only gathers each section's figures and lays them out in order.
///
/// The portfolio total and the list of wallets are not here: they live on
/// the overview, one level up.
class WalletLedger extends StatelessWidget {
  const WalletLedger({
    super.key,
    required this.sync,
    required this.wallet,
    required this.actions,
  });

  final WalletSyncController sync;

  /// The wallet list's record of this wallet: its name, index 0 and pin.
  final WalletInfo? wallet;
  final WalletLedgerActions actions;

  static const assetCap = 4;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        sync,
        mixService,
        duckpoolsService,
        sigmafiService,
        privacyService,
        addressLabelService,
        networkController,
        tokenPricer,
        walletService.metadataChanges,
      ]),
      builder: (context, _) {
        final hidden = privacyService.hideBalances;
        // Stealth holdings are part of what the wallet owns, so they belong
        // in the asset list; each tile knows how much of it is stealth.
        final holdings = sync.displayTokens
            .map(walletService.displayMetadata)
            .toList();
        final fungible = holdings.where((t) => !t.isCollectible).toList();
        final nfts = holdings.where((t) => t.isCollectible).toList();
        Widget tokenTile(TokenBalance t) => AssetTile.token(
          t,
          fiatText: t.isCollectible
              ? null
              : tokenPricer.fiatTextFor(
                  tokenId: t.id,
                  amount: t.amount,
                  decimals: t.decimals,
                ),
          hidden: hidden,
          onTap: () => actions.openToken(t),
        );
        final assets = <Widget>[
          AssetTile.erg(
            // Display surface: stealth ERG is included, as it is in the
            // balance card above and in the token tiles below. Send and
            // coin selection still use sync.balanceNano.
            balanceNano: sync.totalNanoWithStealth,
            fiatText: networkController.fiatText(sync.totalNanoWithStealth),
            hidden: hidden,
            onTap: actions.viewAssets,
          ),
          ...fungible.map(tokenTile),
          ...nfts.map(tokenTile),
        ];
        return RefreshIndicator(
          onRefresh: () => sync.refresh(discover: true),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              const OfflineBanner(),
              _balanceCard(context, hidden),
              const SizedBox(height: 12),
              HomeActionRow(
                actions: [
                  HomeAction(
                    icon: Icons.north_east,
                    label: 'Send',
                    onTap: () => actions.go('/send'),
                  ),
                  HomeAction(
                    icon: Icons.south_west,
                    label: 'Receive',
                    onTap: () => actions.go('/receive'),
                  ),
                  HomeAction(
                    icon: Icons.swap_horiz,
                    label: 'Swap',
                    onTap: () => actions.swap(SwapVenue.spectrum),
                  ),
                  HomeAction(
                    icon: Icons.blender_outlined,
                    label: 'Mix',
                    onTap: () => actions.go('/mix'),
                  ),
                ],
              ),
              MixStrip(onOpen: () => actions.go('/mix')),
              const SizedBox(height: 28),
              AssetsSection(
                title: 'Assets',
                tiles: assets.take(assetCap).toList(),
                total: assets.length,
                onViewAll: actions.viewAssets,
              ),
              const SizedBox(height: 28),
              RecentActivitySection(
                rows: sync.displayActivity.take(5).toList(),
                hidden: hidden,
                onOpen: actions.openTx,
                onViewAll: actions.showActivity,
                emptyActionLabel: 'Show my address',
                onEmptyAction: () => actions.go('/receive'),
              ),
              const SizedBox(height: 28),
              DiscoverSection(
                cards: _discoverCards(hidden),
                onExplain: actions.explainFeature,
                onExploreAll: actions.exploreAll,
              ),
              const SizedBox(height: 28),
              ToolsSection(
                features: const [
                  DiscoverFeature.tokens,
                  DiscoverFeature.utxos,
                  DiscoverFeature.mix,
                ],
                onOpen: actions.openFeature,
                onExplain: actions.explainFeature,
              ),
              if (sync.usedAddresses.isNotEmpty) ...[
                const SizedBox(height: 28),
                AddressesSection(
                  rows: sync.usedAddresses,
                  hidden: hidden,
                  labelFor: addressLabelService.labelFor,
                  onTap: actions.labelAddress,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// This wallet's balance — public, stealth and mixing pockets together —
  /// under the address it is shown as, with funds on its other addresses
  /// called out when there are any.
  Widget _balanceCard(BuildContext context, bool hidden) {
    final w = wallet;
    final mixNano = mixService.inMixNano + mixService.mixedNano;
    final total = sync.totalNanoWithStealth;
    // Stealth ERG and money in the mixing pool are the wallet's too; only
    // send and coin selection use the spendable figure. The headline must
    // never be smaller than the pockets it is broken down into.
    final headline = total == null ? null : total + mixNano;
    final pockets = walletPockets(
      publicNano: sync.balanceNano,
      stealthNano: sync.stealthNano,
      stealthUnknown: sync.stealthScanning && sync.stealthBalanceUnknown,
      mixedNano: mixService.mixedNano,
      inMixNano: mixService.inMixNano,
    );
    // The identity is the wallet's own record (the pinned address, else
    // index 0), not today's receive address, which moves in fresh mode.
    final identity = w?.displayAddress ?? sync.receiveAddress;
    final holdings = withWalletIndexes(
      sync.addressHoldings,
      address0: w?.address0,
      pinnedAddress: w?.pinnedAddress,
      pinnedIndex: w?.pinnedAddressIndex,
    );
    final elsewhere = fundsElsewhere(holdings, identity: identity);
    final online = networkController.activeUrl != null;
    final synced = sync.statusLabel(online: online) == 'Synced';
    return WalletBalanceCard(
      label: 'BALANCE',
      balanceNano: headline,
      loading: sync.balanceNano == null && sync.isSyncing,
      hidden: hidden,
      onToggleHidden: () => privacyService.setHideBalances(!hidden),
      valueLine: headline == null
          ? null
          : headlineValueLine(
              ergNano: headline,
              tokens: [
                for (final t in sync.displayTokens)
                  (id: t.id, amount: t.amount, decimals: t.decimals),
              ],
              hidden: hidden,
            ),
      breakdownLine: pocketBreakdown(pockets, hidden: hidden),
      // The stealth and mixing pockets in the headline are in blocks, so
      // the split counts them as confirmed and adds up to the headline.
      pending: headline == null ? null : sync.pending?.under(headline),
      identity: identity == null
          ? null
          : WalletIdentityLine(
              address: identity,
              pinnedIndex: w?.pinnedAddressIndex,
            ),
      elsewhere: elsewhere,
      onElsewhere: elsewhere == null
          ? null
          : () => showAddressBreakdownSheet(
              context,
              walletName: w?.name ?? 'This wallet',
              holdings: holdings,
              identity: identity,
              hidden: hidden,
            ),
      footer: WalletStatusStrip(
        status: SyncStatusLine.wallet(
          sync: sync,
          online: online,
          statusColor: synced
              ? moss
              : (sync.isStale ? rust : accentOf(context)),
          height: networkController.height,
          fragmented: sync.utxoCount > utxoFragmentationThreshold,
        ),
        pinIssue: sync.pinIssue,
        onPinIssue: actions.showSettings,
        onStatus: () => actions.go('/utxos'),
        onNetwork: actions.showSettings,
      ),
    );
  }

  /// "You hold 12.5 SigUSD · 3 SigRSV" when the wallet has a position in
  /// any of [ids]; null otherwise so the card keeps its marketing line.
  String? _positionLine({required List<String> ids, required bool hidden}) {
    final held = <String>[];
    for (final t in sync.tokens) {
      if (!ids.contains(t.id) || t.amount <= 0) continue;
      held.add(
        hidden
            ? '•••• ${t.label}'
            : '${formatTokenAmountGrouped(t.amount, t.decimals)} ${t.label}',
      );
    }
    if (held.isEmpty) return null;
    return 'You hold ${held.take(2).join(' · ')}';
  }

  List<DiscoverCardData> _discoverCards(bool hidden) {
    final duckpools = [
      duckpoolsService.positionLine(formatTokenAmountGrouped),
      duckpoolsService.loanLine(formatTokenAmountGrouped),
    ].whereType<String>().join(' · ');
    return [
      if (discoverAvailable(DiscoverFeature.dexy))
        DiscoverCardData(
          DiscoverFeature.dexy,
          subtitle: _positionLine(
            ids: [
              for (final v in DexyVariant.values) ...[v.tokenId, v.lpTokenId],
            ],
            hidden: hidden,
          ),
        ),
      DiscoverCardData(
        DiscoverFeature.ageusd,
        subtitle: _positionLine(
          ids: const [SigmaUsdTokens.sigUsd, SigmaUsdTokens.sigRsv],
          hidden: hidden,
        ),
      ),
      const DiscoverCardData(DiscoverFeature.spectrum),
      DiscoverCardData(
        DiscoverFeature.duckpools,
        subtitle: duckpools.isEmpty ? null : duckpools,
      ),
      DiscoverCardData(
        DiscoverFeature.sigmafi,
        subtitle: sigmafiService.positionLine(),
      ),
      DiscoverCardData(
        DiscoverFeature.mix,
        subtitle: mixService.enabled && mixService.active.isNotEmpty
            ? '${mixService.active.length} ${mixService.active.length == 1 ? 'mix' : 'mixes'} in the pool.'
            : null,
      ),
      const DiscoverCardData(DiscoverFeature.tokens),
      const DiscoverCardData(DiscoverFeature.utxos),
      const DiscoverCardData(DiscoverFeature.liquidity),
      const DiscoverCardData(DiscoverFeature.dapps),
      const DiscoverCardData(DiscoverFeature.rosen),
    ];
  }
}
