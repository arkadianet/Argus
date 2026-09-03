import 'package:flutter/material.dart';

import '../../theme/argus_theme.dart';
import '../swap_hub_screen.dart';

class _Explainer {
  const _Explainer({required this.title, required this.what, required this.can, required this.risks, required this.go});
  final String title;
  final String what;
  final List<String> can;
  final List<String> risks;
  final String go;
}

const _explainers = {
  SwapVenue.dexy: _Explainer(
    title: 'Dexy',
    what: 'Dexy issues tokens pegged to an outside price by an oracle: DexyGold tracks a milligram of gold, USE tracks one US dollar. New tokens are minted from a bank contract at the oracle rate; a liquidity pool lets you trade them against ERG at market.',
    can: [
      'Mint USE or DexyGold from the bank when minting is open',
      'Swap ERG for either token on the liquidity pool, and back',
      'Provide ERG plus the token as liquidity and earn pool fees',
      'Send USE or DexyGold to anyone; Argus buys the shortfall on the cheapest route',
    ],
    risks: [
      'The peg depends on the oracle and the bank reserve staying healthy',
      'Pool swaps move the price; check the impact line before confirming',
      'Liquidity positions lose value when the two sides diverge',
    ],
    go: 'Open Dexy',
  ),
  SwapVenue.ageusd: _Explainer(
    title: 'AgeUSD',
    what: 'AgeUSD is the original Ergo stablecoin design. SigUSD is pegged to the dollar and backed by ERG held in a bank contract. SigRSV is the reserve token that absorbs ERG price moves and earns the protocol fee in return.',
    can: [
      'Mint SigUSD with ERG when the reserve ratio allows',
      'Redeem SigUSD back to ERG at the oracle rate',
      'Mint or redeem SigRSV to take a leveraged position on ERG',
      'Send SigUSD to anyone; Argus mints the shortfall from the bank',
    ],
    risks: [
      'Minting and redeeming pause when the reserve ratio leaves its band',
      'SigRSV is volatile by design and can fall faster than ERG',
      'A 2% protocol fee applies to every mint and redeem',
    ],
    go: 'Open AgeUSD',
  ),
  SwapVenue.spectrum: _Explainer(
    title: 'Spectrum DEX',
    what: 'Spectrum is a permissionless exchange made of liquidity pools. Anyone can list a token by creating a pool; prices come from the ratio of the two sides, so every swap moves the price a little.',
    can: [
      'Swap ERG for any listed token, or one token for another',
      'See pool depth and price impact before you confirm',
      'Send a listed token to anyone; Argus buys it from the pool on the way',
    ],
    risks: [
      'Anyone can create a pool: check the token id, not just the name',
      'Thin pools give bad prices for large amounts',
      'Argus signs the swap directly with the pool contract; there is no order book or refund',
    ],
    go: 'Open the DEX',
  ),
};

/// What a protocol is, what you can do with it, and what to watch for,
/// with one button to go there.
Future<void> showDiscoverSheet(BuildContext context, {required SwapVenue venue, required VoidCallback onGo}) {
  final e = _explainers[venue]!;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(cardRadius))),
    builder: (ctx) {
      final colors = ArgusColors.of(ctx);
      Widget bullets(List<String> items) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final t in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 7, right: 10),
                        child: Container(width: 5, height: 5, decoration: BoxDecoration(color: accentOf(context), shape: BoxShape.circle)),
                      ),
                      Expanded(child: Text(t, style: const TextStyle(fontSize: 14, height: 1.4))),
                    ],
                  ),
                ),
            ],
          );
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(e.title, style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 10),
              Text(e.what, style: const TextStyle(fontSize: 14.5, height: 1.45)),
              const SizedBox(height: 18),
              Text('WHAT YOU CAN DO', style: Theme.of(ctx).textTheme.titleSmall?.copyWith(color: colors.muted)),
              const SizedBox(height: 8),
              bullets(e.can),
              const SizedBox(height: 12),
              Text('WATCH FOR', style: Theme.of(ctx).textTheme.titleSmall?.copyWith(color: colors.muted)),
              const SizedBox(height: 8),
              bullets(e.risks),
              const SizedBox(height: 22),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  onGo();
                },
                child: Text(e.go),
              ),
            ],
          ),
        ),
      );
    },
  );
}
