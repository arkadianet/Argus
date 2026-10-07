import 'package:flutter/material.dart';
import '../format.dart';
import '../services/amm_service.dart' show ammService;
import '../services/network_controller.dart';
import '../services/privacy_service.dart';
import '../services/token_metadata.dart';
import '../services/token_pricer.dart';
import '../services/verified_tokens.dart';
import '../services/wallet_service.dart';
import '../services/wallet_sync_controller.dart';
import '../theme/argus_theme.dart';
import 'send_screen.dart';
import 'swap_hub_screen.dart';
import 'token_avatar.dart';
import 'widgets/asset_tile.dart';
import 'widgets/pending_balance_line.dart';
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
  bool _grid = true;
  final _search = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    privacyService.addListener(_privacyChanged);
  }

  void _privacyChanged() {
    if (privacyService.hideBalances && _search.text.isNotEmpty) _clearSearch();
  }

  @override
  void dispose() {
    privacyService.removeListener(_privacyChanged);
    _search.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _search.clear();
    setState(() => _query = '');
  }

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
    // Swapping signs; a watched wallet's holdings offer only a look.
    onSwap: widget.args.watchOnly
        ? null
        : (t) => Navigator.push(
            context,
            fadeRoute(
              SwapHubScreen(initialTab: coerceVenue(SwapVenue.spectrum), initialFrom: t.id),
              settings: RouteSettings(arguments: widget.args),
            ),
          ),
    swappable: widget.args.watchOnly ? null : ammService.hasPool(token.id),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Assets'),
      actions: [
        if (_collectibles)
          IconButton(
            tooltip: _grid ? 'Show collectible list' : 'Show collectible grid',
            icon: Icon(_grid ? Icons.view_list_outlined : Icons.grid_view),
            onPressed: () => setState(() => _grid = !_grid),
          ),
        IconButton(
          tooltip:
              'Clear collectible cache (saved holdings keep their metadata)',
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
        final collectibleCount = holdings.where((t) => t.isCollectible).length;
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  if (textScale > 1.4)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ChoiceChip(
                          label: const Text('All'),
                          selected: !_collectibles,
                          onSelected: (_) =>
                              setState(() => _collectibles = false),
                        ),
                        ChoiceChip(
                          label: const Text('Collectibles'),
                          selected: _collectibles,
                          onSelected: (_) =>
                              setState(() => _collectibles = true),
                        ),
                      ],
                    )
                  else
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: false, label: Text('All')),
                          ButtonSegment(
                            value: true,
                            label: Text('Collectibles'),
                          ),
                        ],
                        selected: {_collectibles},
                        onSelectionChanged: (s) =>
                            setState(() => _collectibles = s.single),
                      ),
                    ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _search,
                    decoration: InputDecoration(
                      labelText: 'Search name or token ID',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              onPressed: _clearSearch,
                              icon: const Icon(Icons.close, size: 18),
                            ),
                    ),
                    enabled: !hidden,
                    onChanged: (q) =>
                        setState(() => _query = q.trim().toLowerCase()),
                  ),
                  const SizedBox(height: 10),
                  if (!hidden)
                    Text(
                      _collectibles
                          ? '$collectibleCount identified ${collectibleCount == 1 ? 'collectible' : 'collectibles'} · previews load only when you choose'
                          : '${holdings.length} token IDs${unknown > 0 ? ' · $unknown with incomplete metadata' : ''}',
                      style: TextStyle(color: ArgusColors.of(context).muted),
                    ),
                  if (live.publicSnapshotOnly || live.stealthBalanceUnknown)
                    const Text('Public holdings only'),
                  if (live.balanceNano == null)
                    const Text('Holdings not loaded'),
                  if (live.lastSyncedAt != null)
                    Text(
                      'Holdings last synced ${formatSyncAge(live.lastSyncedAt)}',
                    ),
                  PendingBalanceLine(pending: live.pending, hidden: hidden),
                ],
              ),
            ),
            Expanded(
              child: hidden
                  ? const Center(child: Text('Assets hidden'))
                  : rows.isEmpty && (_collectibles || _query.isNotEmpty)
                  ? _EmptyAssets(
                      searching: _query.isNotEmpty,
                      unknown: unknown,
                      onClearSearch: _clearSearch,
                    )
                  : _collectibles && _grid
                  ? GridView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
                      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 260 * textScale,
                        mainAxisExtent:
                            270 +
                            (textScale - 1).clamp(0, double.infinity) * 110,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                      ),
                      itemCount: rows.length,
                      itemBuilder: (context, index) => _CollectibleCard(
                        token: rows[index],
                        onTap: () => _open(rows[index]),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
                      itemCount:
                          rows.length +
                          (!_collectibles && _query.isEmpty ? 1 : 0),
                      itemBuilder: (context, index) {
                        final hasErg = !_collectibles && _query.isEmpty;
                        if (index == 0 && hasErg)
                          return AssetTile.erg(
                            balanceNano: live.totalNanoWithStealth,
                            fiatText: networkController.fiatText(
                              live.totalNanoWithStealth,
                            ),
                          );
                        final token = rows[index - (hasErg ? 1 : 0)];
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

class _EmptyAssets extends StatelessWidget {
  const _EmptyAssets({
    required this.searching,
    required this.unknown,
    required this.onClearSearch,
  });
  final bool searching;
  final int unknown;
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              searching ? Icons.search_off : Icons.collections_outlined,
              size: 36,
              color: ArgusColors.of(context).muted,
            ),
            const SizedBox(height: 12),
            Text(
              searching
                  ? 'No assets match your search'
                  : 'No identified collectibles in loaded holdings',
              textAlign: TextAlign.center,
            ),
            if (searching)
              TextButton(
                onPressed: onClearSearch,
                child: const Text('Clear search'),
              )
            else if (unknown > 0) ...[
              const SizedBox(height: 8),
              const Text(
                'Some tokens have incomplete metadata. Open them in All to inspect their details.',
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

/// Collectible browsing remains local and text-first. Artwork is requested
/// only through the explicit consent action in the individual details sheet.
class _CollectibleCard extends StatelessWidget {
  const _CollectibleCard({required this.token, required this.onTap});
  final TokenBalance token;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: colors.inset,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Center(
                    child: TokenAvatar(
                      tokenId: token.id,
                      label: tokenTicker(token),
                      radius: 28,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      token.label,
                      textDirection: TextDirection.ltr,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  if (cautionedToken(token.id) != null) ...[
                    const SizedBox(width: 4),
                    const Tooltip(
                      message: 'Caution: this token is flagged',
                      child: Icon(
                        Icons.warning_amber_rounded,
                        size: 18,
                        color: rust,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Text(
                token.classification,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colors.muted),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Held: ${holdingAmountText(token)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right, size: 18, color: colors.muted),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
