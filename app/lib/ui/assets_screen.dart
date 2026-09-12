import 'package:flutter/material.dart';

import '../services/network_controller.dart';
import '../services/privacy_service.dart';
import '../services/token_pricer.dart';
import '../services/wallet_service.dart';
import '../services/wallet_sync_controller.dart';
import '../theme/argus_theme.dart';
import 'send_screen.dart';
import 'widgets/asset_tile.dart';
import 'widgets/empty_state.dart';
import 'widgets/soft_card.dart';
import 'widgets/token_detail_sheet.dart';

/// Full asset list for the dashboard's "View all" link: ERG plus every held
/// token and NFT. Tapping a token opens its detail sheet.
class AssetsScreen extends StatelessWidget {
  const AssetsScreen({super.key, required this.args});

  final WalletRouteArgs args;

  void _openToken(BuildContext context, TokenBalance t) {
    showTokenDetailSheet(
      context,
      token: t,
      explorerUrl: networkController.explorerToken(t.id),
      onSend: (token) => Navigator.push(
        context,
        fadeRoute(
          SendScreen(initialAssetId: token.id),
          settings: RouteSettings(arguments: args),
        ),
      ),
    );
  }

  /// Uses one live snapshot for sections and emptiness as wallet holdings change.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Assets')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          networkController,
          privacyService,
          tokenPricer,
          walletSyncController,
        ]),
        builder: (context, _) {
          final live = walletSyncController;
          final holdings = live.displayTokens;
          final balance = live.totalNanoWithStealth;
          final fungible = holdings.where((t) => !t.isNft).toList();
          final nfts = holdings.where((t) => t.isNft).toList();
          final hidden = privacyService.hideBalances;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              _section('ERG'),
              SoftCard(
                padding: EdgeInsets.zero,
                child: AssetTile.erg(
                  balanceNano: balance,
                  fiatText: networkController.fiatText(balance),
                  hidden: hidden,
                ),
              ),
              if (fungible.isNotEmpty) ...[
                _section('Tokens (${fungible.length})'),
                SoftCard(
                  padding: EdgeInsets.zero,
                  child: DividedColumn(
                    children: [
                      for (final t in fungible)
                        AssetTile.token(
                          t,
                          fiatText: tokenPricer.fiatTextFor(tokenId: t.id, amount: t.amount, decimals: t.decimals),
                          hidden: hidden,
                          onTap: () => _openToken(context, t),
                        ),
                    ],
                  ),
                ),
              ],
              if (nfts.isNotEmpty) ...[
                _section('NFTs (${nfts.length})'),
                SoftCard(
                  padding: EdgeInsets.zero,
                  child: DividedColumn(
                    children: [
                      for (final t in nfts)
                        AssetTile.token(
                          t,
                          hidden: hidden,
                          onTap: () => _openToken(context, t),
                        ),
                    ],
                  ),
                ),
              ],
              if (holdings.isEmpty) ...[
                const SizedBox(height: 16),
                const SoftCard(
                  child: EmptyState(
                    compact: true,
                    icon: Icons.token_outlined,
                    title: 'No tokens yet',
                    body: 'Tokens and NFTs sent to any of your addresses appear here automatically.',
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _section(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 12),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: 'Newsreader',
          fontWeight: FontWeight.w600,
          fontSize: 20,
        ),
      ),
    );
  }
}
