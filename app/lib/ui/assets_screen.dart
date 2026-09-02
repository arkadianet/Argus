import 'package:flutter/material.dart';

import '../services/network_controller.dart';
import '../services/privacy_service.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'send_screen.dart';
import 'widgets/asset_tile.dart';
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

  @override
  Widget build(BuildContext context) {
    final fungible = args.tokens.where((t) => !t.isNft).toList();
    final nfts = args.tokens.where((t) => t.isNft).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Assets')),
      body: ListenableBuilder(
        listenable: Listenable.merge([networkController, privacyService]),
        builder: (context, _) {
          final hidden = privacyService.hideBalances;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              _section('ERG'),
              SoftCard(
                padding: EdgeInsets.zero,
                child: AssetTile.erg(
                  balanceNano: args.spendableNano,
                  fiatText: networkController.fiatText(args.spendableNano),
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
              if (args.tokens.isEmpty) ...[
                const SizedBox(height: 16),
                SoftCard(
                  child: Text(
                    'No tokens yet. Tokens you receive appear here.',
                    style: Theme.of(context).textTheme.bodyMedium,
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
