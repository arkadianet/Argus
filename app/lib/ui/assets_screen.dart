import 'package:flutter/material.dart';
import '../format.dart';
import '../services/network_controller.dart';
import '../services/privacy_service.dart';
import '../services/token_pricer.dart';
import '../services/wallet_service.dart';
import '../services/wallet_sync_controller.dart';
import '../theme/argus_theme.dart';
import 'send_screen.dart';
import 'widgets/asset_tile.dart';
import 'widgets/token_detail_sheet.dart';

/// A text-first, lazy view of holdings. Opening it never hydrates metadata.
class AssetsScreen extends StatefulWidget {
  const AssetsScreen({super.key, required this.args});
  final WalletRouteArgs args;
  @override
  State<AssetsScreen> createState() => _AssetsScreenState();
}

class _AssetsScreenState extends State<AssetsScreen> {
  bool _collectibles = false;
  String _query = '';
  void _open(TokenBalance token) => showTokenDetailSheet(
    context,
    token: token,
    explorerUrl: networkController.explorerToken(token.id),
    onSend: (t) => Navigator.push(
      context,
      fadeRoute(
        SendScreen(initialAssetId: t.id),
        settings: RouteSettings(arguments: widget.args),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Assets'),
      actions: [
        IconButton(
          tooltip: 'Clear collectible data',
          icon: const Icon(Icons.delete_outline),
          onPressed: walletService.clearCollectibleData,
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: Listenable.merge([
        networkController,
        privacyService,
        tokenPricer,
        walletSyncController,
        walletService.metadataChanges,
      ]),
      builder: (context, _) {
        final live = walletSyncController;
        final hidden = privacyService.hideBalances;
        final holdings = live.displayTokens
            .map(walletService.displayMetadata)
            .toList();
        final rows = holdings
            .where(
              (t) =>
                  (!_collectibles || t.isCollectible) &&
                  (t.label.toLowerCase().contains(_query) ||
                      t.id.toLowerCase().contains(_query)),
            )
            .toList();
        final unknown = holdings
            .where((t) => t.metadataState != MetadataState.complete)
            .length;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('All')),
                      ButtonSegment(value: true, label: Text('Collectibles')),
                    ],
                    selected: {_collectibles},
                    onSelectionChanged: (s) =>
                        setState(() => _collectibles = s.single),
                  ),
                  TextField(
                    decoration: const InputDecoration(
                      labelText: 'Search name or token ID',
                    ),
                    enabled: !hidden,
                    onChanged: (q) => setState(() => _query = q.toLowerCase()),
                  ),
                  if (!hidden) Text('$unknown unclassified or incomplete'),
                  if (live.publicSnapshotOnly || live.stealthBalanceUnknown)
                    const Text('Public holdings only'),
                  if (live.balanceNano == null)
                    const Text('Holdings not loaded'),
                  if (live.lastSyncedAt != null)
                    Text(
                      'Holdings last synced ${formatSyncAge(live.lastSyncedAt)}',
                    ),
                ],
              ),
            ),
            Expanded(
              child: hidden
                  ? const Center(child: Text('Assets hidden'))
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
                      itemCount: rows.length + 1,
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          if (!_collectibles)
                            return AssetTile.erg(
                              balanceNano: live.totalNanoWithStealth,
                              fiatText: networkController.fiatText(
                                live.totalNanoWithStealth,
                              ),
                            );
                          return rows.isEmpty
                              ? const Padding(
                                  padding: EdgeInsets.all(16),
                                  child: Text(
                                    'No identified collectibles in loaded holdings',
                                  ),
                                )
                              : const SizedBox.shrink();
                        }
                        final token = rows[index - 1];
                        return AssetTile.token(
                          token,
                          onTap: () => _open(token),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    ),
  );
}
