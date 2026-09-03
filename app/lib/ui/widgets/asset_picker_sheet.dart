import 'package:flutter/material.dart';

import '../../format.dart';
import '../../services/token_router.dart';
import '../../services/verified_tokens.dart';
import '../../services/wallet_service.dart';
import '../../theme/argus_theme.dart';
import '../token_avatar.dart';
import 'asset_tile.dart';

/// What the send screen should send: ERG, a held token, or a token to buy.
class AssetChoice {
  const AssetChoice.erg() : id = null, buy = null;
  const AssetChoice.held(String this.id) : buy = null;
  const AssetChoice.buy(BuyableToken this.buy) : id = null;

  final String? id;
  final BuyableToken? buy;

  /// Send-screen asset id: null for ERG, token id, or `buy:<id>`.
  String? get assetId => buy != null ? 'buy:${buy!.id}' : id;
}

/// Bottom sheet listing ERG, the wallet's tokens, and every token the
/// router can buy on the way, with a search box.
class AssetPickerSheet extends StatefulWidget {
  const AssetPickerSheet({super.key, required this.held, required this.buyable, this.current});

  final List<TokenBalance> held;
  final List<BuyableToken> buyable;
  final String? current;

  @override
  State<AssetPickerSheet> createState() => _AssetPickerSheetState();
}

class _AssetPickerSheetState extends State<AssetPickerSheet> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _match(String name, String id) {
    final q = _search.text.trim().toLowerCase();
    return q.isEmpty || name.toLowerCase().contains(q) || id.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    final heldIds = widget.held.map((t) => t.id).toSet();
    final held = widget.held.where((t) => _match(t.label, t.id)).toList();
    final buy = widget.buyable.where((b) => !heldIds.contains(b.id) && _match(b.name, b.id)).toList();
    final heldBuyable = widget.buyable.where((b) => heldIds.contains(b.id)).toList();
    final showErg = _match('ERG Ergo', '');
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              children: [
                Expanded(child: Text('Choose asset', style: Theme.of(context).textTheme.titleLarge)),
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: TextField(
              controller: _search,
              autofocus: false,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'Search name or token id',
                prefixIcon: Icon(Icons.search, size: 20),
                isDense: true,
              ),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
              children: [
                if (showErg)
                  AssetTile.erg(
                    balanceNano: null,
                    showChevron: false,
                    onTap: () => Navigator.pop(context, const AssetChoice.erg()),
                  ),
                if (held.isNotEmpty) _header(context, 'In your wallet'),
                for (final t in held)
                  AssetTile.token(
                    t,
                    showChevron: false,
                    onTap: () {
                      // A held token the router can top up goes through
                      // buy-and-send so a shortfall is covered automatically.
                      final b = heldBuyable.where((b) => b.id == t.id).firstOrNull;
                      Navigator.pop(context, b != null ? AssetChoice.buy(b) : AssetChoice.held(t.id));
                    },
                  ),
                if (buy.isNotEmpty) _header(context, 'Buy on the way'),
                for (final b in buy)
                  InkWell(
                    onTap: () => Navigator.pop(context, AssetChoice.buy(b)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(
                        children: [
                          TokenAvatar(label: b.name),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(child: Text(b.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15), maxLines: 1, overflow: TextOverflow.ellipsis)),
                                    if (isVerifiedToken(b.id)) ...[
                                      const SizedBox(width: 4),
                                      Icon(Icons.verified, size: 15, color: accentOf(context)),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(shorten(b.id, head: 10, tail: 6), style: TextStyle(fontSize: 12.5, color: colors.muted)),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: colors.chip,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text('via ${b.protocol}', style: TextStyle(fontSize: 11, color: colors.muted)),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (!showErg && held.isEmpty && buy.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('No asset matches that search.', textAlign: TextAlign.center, style: TextStyle(color: colors.muted)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        child: Text(text.toUpperCase(), style: Theme.of(context).textTheme.titleSmall?.copyWith(color: ArgusColors.of(context).muted)),
      );
}

Future<AssetChoice?> showAssetPicker(BuildContext context, {required List<TokenBalance> held, required List<BuyableToken> buyable, String? current}) {
  return showModalBottomSheet<AssetChoice>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(cardRadius))),
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.85,
      child: AssetPickerSheet(held: held, buyable: buyable, current: current),
    ),
  );
}
