import 'package:flutter/material.dart';

import '../../features.dart';

import '../../theme/argus_theme.dart';
import '../swap_hub_screen.dart';

/// Everything the Discover row and page can open.
enum DiscoverFeature { dexy, ageusd, spectrum, liquidity, duckpools, sigmafi, rosen, dapps, mix, tokens, utxos }

/// Whether a feature is offered right now: a paused protocol keeps its
/// explainer but appears on no card and in no list.
bool discoverAvailable(DiscoverFeature f, {bool dexy = dexyEnabled}) => f != DiscoverFeature.dexy || dexy;

/// What a feature is, what you can do with it, and what to watch for.
class DiscoverExplainer {
  const DiscoverExplainer({
    required this.title,
    required this.blurb,
    required this.icon,
    required this.what,
    required this.can,
    required this.risks,
    required this.go,
    this.venue,
    this.route,
  });

  final String title;

  /// One line for a card or a list row.
  final String blurb;
  final IconData icon;
  final String what;
  final List<String> can;
  final List<String> risks;

  /// The button that opens the feature.
  final String go;

  /// A swap venue lives in the Swap tab; everything else has a route.
  final SwapVenue? venue;
  final String? route;
}

const discoverExplainers = <DiscoverFeature, DiscoverExplainer>{
  DiscoverFeature.dexy: DiscoverExplainer(
    title: 'Dexy',
    blurb: 'Trade, provide liquidity, and mint gold- and dollar-pegged tokens.',
    icon: Icons.all_inclusive,
    venue: SwapVenue.dexy,
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
  DiscoverFeature.ageusd: DiscoverExplainer(
    title: 'AgeUSD',
    blurb: 'The decentralized stablecoin on Ergo: SigUSD and SigRSV.',
    icon: Icons.attach_money,
    venue: SwapVenue.ageusd,
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
  DiscoverFeature.spectrum: DiscoverExplainer(
    title: 'DEX',
    blurb: 'Permissionless token swaps on Spectrum pools.',
    icon: Icons.swap_horiz,
    venue: SwapVenue.spectrum,
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
  DiscoverFeature.liquidity: DiscoverExplainer(
    title: 'Liquidity',
    blurb: 'Put ERG and a token into a Spectrum pool and earn its fees.',
    icon: Icons.waves,
    route: '/liquidity',
    what: 'A liquidity pool holds two assets and lets anyone swap between them. Whoever supplies the pair receives LP tokens for their share and earns a cut of every swap fee. Taking the LP tokens back returns the share, at whatever ratio the pool has moved to.',
    can: [
      'Add ERG plus a token to an existing pool and receive LP tokens',
      'Remove liquidity and get both sides back',
      'See your share and what it is worth today',
    ],
    risks: [
      'When the two prices diverge, the position is worth less than holding both (impermanent loss)',
      'Fees only outrun that loss in pools with real volume',
      'A pool of a worthless token leaves you with that token',
    ],
    go: 'Open liquidity',
  ),
  DiscoverFeature.duckpools: DiscoverExplainer(
    title: 'Duckpools',
    blurb: 'Lend and borrow on Ergo against ERG or token collateral.',
    icon: Icons.water_outlined,
    route: '/duckpools',
    what: 'Duckpools is a lending protocol. Lenders put an asset into a pool and earn interest from borrowers, who lock collateral worth more than the loan. Orders are placed on chain and filled by the pool\'s bots, usually within a few blocks.',
    can: [
      'Lend ERG, SigUSD or other pool assets and earn interest',
      'Borrow against collateral, with the liquidation line shown in plain terms',
      'Repay part or all of a loan, or add collateral to move the line',
      'Find orders left on chain by a wallet reinstalled elsewhere',
    ],
    risks: [
      'A loan whose collateral falls below the threshold is liquidated with a penalty',
      'Interest accrues every block and the rate moves with pool use',
      'An order the bots do not fill can be refunded after its refund height',
    ],
    go: 'Open Duckpools',
  ),
  DiscoverFeature.sigmafi: DiscoverExplainer(
    title: 'SigmaFi',
    blurb: 'Peer-to-peer loans against collateral: lend, or ask.',
    icon: Icons.handshake_outlined,
    route: '/sigmafi',
    what: 'SigmaFi is a bond market between people. A borrower posts a request with collateral, a repayment amount and a term; a lender who likes the terms fills it. There is no pool and no interest rate curve: every loan is a deal two people agreed to.',
    can: [
      'Lend by filling a request whose collateral and return you like',
      'Ask for a loan by posting collateral and the terms you offer',
      'Repay before maturity and get the collateral back',
    ],
    risks: [
      'A loan not repaid by maturity lets the lender take the collateral',
      'Collateral is priced by you, not by an oracle: check it against the market',
      'Requests sit on chain until filled or cancelled, and cost a fee to post',
    ],
    go: 'Open SigmaFi',
  ),
  DiscoverFeature.rosen: DiscoverExplainer(
    title: 'Rosen bridge',
    blurb: 'Send ERG and tokens to Cardano, Bitcoin, Ethereum and more.',
    icon: Icons.swap_calls,
    route: '/rosen',
    what: 'Rosen is a bridge run by a federation of guards. You lock an asset on Ergo with the destination chain and address attached; the guards watch for it and release the wrapped asset on the other side.',
    can: [
      'Send ERG or a supported token to another chain',
      'See the bridge fee and the network fee before you confirm',
      'Track the transfer until it lands',
    ],
    risks: [
      'The guards hold the locked funds: this is trust in a federation, not a contract',
      'A wrong destination address on the other chain cannot be undone',
      'Transfers take minutes to hours depending on the chains',
    ],
    go: 'Open Rosen',
  ),
  DiscoverFeature.dapps: DiscoverExplainer(
    title: 'dApp browser',
    blurb: 'Open any Ergo dApp with this wallet standing in for Nautilus.',
    icon: Icons.language,
    route: '/dapps',
    what: 'Ergo dApps talk to a wallet through the EIP-12 connector that Nautilus made standard. Argus answers the same calls, so a site sees a connected wallet, reads your addresses and boxes, and asks you to sign what it builds.',
    can: [
      'Connect to SigmaFi, Duckpools, ErgoDEX, Rosen and any other EIP-12 site',
      'Review every transaction a site proposes before signing it',
      'Switch between a desktop and a mobile view of the site',
    ],
    risks: [
      'A site can ask you to sign anything: read the confirm sheet, not the site',
      'Only https sites are allowed, and a site that changes origin is cut off',
      'Connecting reveals your addresses and balances to that site',
    ],
    go: 'Open the browser',
  ),
  DiscoverFeature.mix: DiscoverExplainer(
    title: 'Mix',
    blurb: 'Private ERG through the ErgoMixer pool.',
    icon: Icons.blender_outlined,
    route: '/mix',
    what: 'A mix moves a fixed amount of ERG through rounds with strangers in the public ErgoMixer pool until nothing on chain ties what comes out to what went in. The rounds run on their own; the money lands at a stealth address of yours or your public one.',
    can: [
      'Mix a fixed amount at a mixing level of your choice',
      'Watch each round and withdraw at any time',
      'Recover a mix from your seed on another phone',
    ],
    risks: [
      'Each round waits for a partner; a mix takes days and the pool is thin today',
      'Entering costs an operator fee on top of the miner fees',
      'The node Argus talks to sees which boxes are yours: mix through your own node',
    ],
    go: 'Open Mix',
  ),
  DiscoverFeature.tokens: DiscoverExplainer(
    title: 'Tokens',
    blurb: 'Issue a token or an NFT, or burn tokens you hold.',
    icon: Icons.token_outlined,
    route: '/tokens',
    what: 'Any Ergo transaction can create a new token: its id is the id of the first input box, its name, decimals and description live in the registers of the box that carries it (EIP-4). An NFT is a token with one unit and a link to its media.',
    can: [
      'Issue a fungible token with a name, decimals and supply',
      'Issue an NFT pointing at an image, audio or video',
      'Burn tokens you hold so they leave circulation',
    ],
    risks: [
      'A token\'s name is not unique: anyone can issue one with the same name',
      'Burning is final; the supply cannot be restored',
      'Issuing costs a miner fee and locks the minimum box value with the token',
    ],
    go: 'Open tokens',
  ),
  DiscoverFeature.utxos: DiscoverExplainer(
    title: 'UTXO management',
    blurb: 'Consolidate, split and restructure the boxes your money sits in.',
    icon: Icons.grid_view_outlined,
    route: '/utxos',
    what: 'On Ergo your balance is a set of boxes, each a separate coin. Many small boxes make every send bigger and slower to build; one huge box links everything you own in one place. This tool reshapes them.',
    can: [
      'Consolidate many small boxes into one',
      'Split a box into several of a chosen size',
      'Restructure holdings so tokens sit in boxes of their own',
    ],
    risks: [
      'Every reshape is a transaction: it costs a miner fee and is public',
      'Consolidating links every box it spends to one owner',
      'A box below the minimum value cannot be made',
    ],
    go: 'Open UTXO management',
  ),
};

/// What a protocol is, what you can do with it, and what to watch for,
/// with one button to go there.
Future<void> showDiscoverSheet(BuildContext context, {required DiscoverFeature feature, required VoidCallback onGo}) {
  final e = discoverExplainers[feature]!;
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
