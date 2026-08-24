import 'package:flutter/material.dart';

import '../format.dart';
import '../services/network_controller.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';

/// Full asset list for the dashboard's "View all" link. Lists ERG plus all
/// held tokens (fungible and NFTs) using the same soft card styling.
class AssetsScreen extends StatelessWidget {
  const AssetsScreen({super.key, required this.args});

  final WalletRouteArgs args;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).brightness == Brightness.dark
        ? watchfulMuted
        : ledgerMuted;
    final fungible = args.tokens.where((t) => !t.isNft).toList();
    final nfts = args.tokens.where((t) => t.isNft).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Assets')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          _section(context, 'ERG'),
          ListenableBuilder(
            listenable: networkController,
            builder: (context, _) => _card(
              context,
              _row(
                context,
                ticker: 'ERG',
                name: 'Ergo',
                amount: formatErg(args.spendableNano, unit: false, maxFrac: 4),
                fiat: _ergFiat(args.spendableNano),
                muted: muted,
                isErg: true,
              ),
            ),
          ),
          if (fungible.isNotEmpty) ...[
            _section(context, 'Tokens'),
            _card(
              context,
              Column(
                children: [
                  for (var i = 0; i < fungible.length; i++) ...[
                    if (i > 0) const Divider(height: 1, indent: 68),
                    _tokenRow(context, fungible[i], muted),
                  ],
                ],
              ),
            ),
          ],
          if (nfts.isNotEmpty) ...[
            _section(context, 'NFTs'),
            _card(
              context,
              Column(
                children: [
                  for (var i = 0; i < nfts.length; i++) ...[
                    if (i > 0) const Divider(height: 1, indent: 68),
                    _tokenRow(context, nfts[i], muted, isNft: true),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String? _ergFiat(int? nano) => networkController.fiatText(nano);

  Widget _section(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 4),
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

  Widget _card(BuildContext context, Widget child) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: dark ? const Color(0xFF262C29) : const Color(0xFFEDE4D3),
        ),
      ),
      child: child,
    );
  }

  Widget _tokenRow(BuildContext context, TokenBalance t, Color muted,
      {bool isNft = false}) {
    final name = t.name?.trim();
    final hasName = name != null && name.isNotEmpty;
    final ticker = hasName
        ? (name.contains(' ') ? name.split(' ').first : name)
        : (t.id.length > 6 ? t.id.substring(0, 6).toUpperCase() : t.id);
    return _row(
      context,
      ticker: ticker,
      name: hasName ? name : shorten(t.id, head: 10, tail: 6),
      amount: isNft ? '1' : formatTokenAmountGrouped(t.amount, t.decimals),
      fiat: null,
      muted: muted,
    );
  }

  Widget _row(
    BuildContext context, {
    required String ticker,
    required String name,
    required String amount,
    required String? fiat,
    required Color muted,
    bool isErg = false,
  }) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: isErg
                ? iris.withValues(alpha: dark ? 0.25 : 0.2)
                : (dark ? watchfulSurface : bannerTint),
            child: Text(
              isErg ? 'Σ' : (ticker.isNotEmpty ? ticker[0].toUpperCase() : '?'),
              style: TextStyle(
                fontFamily: 'Newsreader',
                fontWeight: FontWeight.w600,
                fontSize: 16,
                color: dark ? bone : (isErg ? ledgerInk : ledgerMuted),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(ticker,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15)),
                const SizedBox(height: 2),
                Text(name,
                    style: TextStyle(fontSize: 12.5, color: muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('$amount $ticker',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w500, fontSize: 14.5)),
                const SizedBox(height: 2),
                Text(fiat ?? '',
                    style: TextStyle(fontSize: 12, color: muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
