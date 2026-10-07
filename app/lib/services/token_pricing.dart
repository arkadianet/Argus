import 'oracle_feeds.dart';
import 'oracle_pool.dart';
import 'sigmausd_service.dart';
import 'verified_tokens.dart';

/// Where fiat prices come from. The user picks one in Display settings.
enum PriceSource {
  oracle('Oracle pools', 'On-chain: ERG from the SigmaUSD oracle pool (the price SigmaUSD settles at), gold from the Dexy gold oracle, wrapped majors from the AVL multi-oracle while it is current, everything else from Spectrum pools. An old price is shown with its age, never as current. Reads only your node.'),
  spectrum('Spectrum pools', 'On-chain: ERG priced from the ERG/SigUSD pool, tokens and LP shares from Spectrum pools. Reads only your node.'),
  coingecko('CoinGecko', 'ERG and wrapped majors from api.coingecko.com, tokens from Spectrum pools. One request naming ERG and a few majors.');

  const PriceSource(this.label, this.blurb);
  final String label;
  final String blurb;

  static PriceSource fromId(String? id) =>
      PriceSource.values.firstWhere((s) => s.name == id, orElse: () => PriceSource.oracle);
}

class DexyIds {
  static const gold = '6122f7289e7bb2df2de273e09d4b2756cda6aeb0f40438dc9d257688f45183ad';
  static const use = 'a55b8735ed1a99e46c2c89f8994aacdf4b1109bdcf682f1e5b34479c6e392669';
}

/// Rosen-wrapped majors and the external price that tracks them 1:1.
class WrappedOrigin {
  const WrappedOrigin(this.feed, this.coingeckoId, this.ticker);
  final String feed;
  final String coingeckoId;
  final String ticker;
}

const wrappedOrigins = <String, WrappedOrigin>{
  '7a51950e5f548549ec1aa63ffdc38279505b11e7e803d01bcf8347e0123c88b0': WrappedOrigin('BTC_USD', 'bitcoin', 'BTC'),
  '203ef3066a912f35c488487cc2cb94bdb0d30680dab22551c7e6fdbc70dfcc8e': WrappedOrigin('ETH_USD', 'ethereum', 'ETH'),
  '050322548722d36f094e341f59ed93eb22118b363eb4efe8c461a52c4d93e2c3': WrappedOrigin('BNB_USD', 'binancecoin', 'BNB'),
  '48132396ebd00831e603c73cf01e01f248dd1966d2cc976caf52ef76f7ac6e36': WrappedOrigin('DOGE_USD', 'dogecoin', 'DOGE'),
  'e023c5f382b6e96fbd878f6811aac73345489032157ad5affb84aefd4956c297': WrappedOrigin('ADA_USD', 'cardano', 'ADA'),
  '581d7df25808881b2b8b9b4e03e2f637c46a94f74a69a5da36434125bacb4e08': WrappedOrigin('FIRO_USD', 'firo', 'FIRO'),
};

/// CoinGecko ids one request must cover for [source] to price everything it can.
List<String> coingeckoIdsFor(PriceSource source) => [
      'ergo',
      if (source == PriceSource.coingecko) ...wrappedOrigins.values.map((o) => o.coingeckoId),
    ];

/// Pools shallower than this are ignored: a price nobody can trade at is
/// not a price. A token-to-token pool's depth is its ERG-equivalent side.
const poolDepthFloorErg = 50.0;

class TokenPrice {
  const TokenPrice({
    required this.usd,
    required this.via,
    this.depthErg,
    this.countsInTotal = true,
    this.staleAge,
    this.decimals,
  });

  /// A price whose only source has stopped publishing: shown with its age
  /// on the row, never counted in totals.
  const TokenPrice.stale({required this.usd, required String source, required String age, this.decimals})
      : via = '$source, $age old',
        depthErg = null,
        countsInTotal = false,
        staleAge = age;

  /// USD per whole token (decimals applied).
  final double usd;

  /// The token's decimals [usd] is per whole token at, from the one token
  /// lookup. A holding is valued by its base units at this scale
  /// ([holdingUsd]), so one recorded before its token's scale was learned,
  /// or in another wallet's older snapshot, cannot be valued at a wrong
  /// one. Null for a price whose scale nothing reported; such a holding
  /// falls back to its own decimals.
  final int? decimals;

  /// Human label of the source, e.g. "SigmaUSD oracle", "Spectrum pool",
  /// "peg"; a stale price says its age here too.
  final String via;

  /// ERG side of the pool the price came from, when pool-derived.
  final double? depthErg;

  /// False for pool-priced tokens that are not on the verified list and for
  /// stale prices: shown on the row, excluded from portfolio totals.
  final bool countsInTotal;

  /// How old a stale price is ("22 days"); null when current.
  final String? staleAge;

  /// Why the price is left out of totals, when it is.
  String get excludedBecause => staleAge != null ? 'stale' : 'unverified';
}

/// One pool-derived price from the Rust pricing core (`wallet-amm`).
class PoolQuote {
  const PoolQuote({
    required this.nanoErgPerUnit,
    required this.depthNano,
    required this.trusted,
    this.poolId,
    this.viaTokenId,
  });

  /// nanoERG per base unit, no decimals applied.
  final double nanoErgPerUnit;

  /// ERG-side depth of the shallowest pool the price rests on.
  final int depthNano;

  /// Every token the price rests on is on the verified list.
  final bool trusted;
  final String? poolId;

  /// Set when the token has no ERG pool deep enough of its own and was
  /// priced through its pool with this token.
  final String? viaTokenId;

  factory PoolQuote.fromJson(Map<String, dynamic> j) => PoolQuote(
        nanoErgPerUnit: (j['nano_erg_per_unit'] as num).toDouble(),
        depthNano: (j['depth_nano'] as num).toInt(),
        trusted: j['trusted'] == true,
        poolId: j['pool_id'] as String?,
        viaTokenId: j['via_token_id'] as String?,
      );
}

/// Every price the Spectrum pool set supports, from `pricingPoolPrices`.
class PoolPriceBook {
  const PoolPriceBook({this.tokens = const {}, this.lpTokens = const {}});

  /// Token id → price.
  final Map<String, PoolQuote> tokens;

  /// LP token id → one unit's share of both reserves.
  final Map<String, PoolQuote> lpTokens;

  static const empty = PoolPriceBook();

  factory PoolPriceBook.fromJson(Map<String, dynamic> j) {
    Map<String, PoolQuote> quotes(Object? m) => {
          for (final e in ((m as Map?) ?? const {}).entries)
            e.key as String: PoolQuote.fromJson((e.value as Map).cast<String, dynamic>()),
        };
    return PoolPriceBook(tokens: quotes(j['tokens']), lpTokens: quotes(j['lp_tokens']));
  }
}

/// What the Rust pricing core needs besides the pools: the depth floor and
/// which tokens may count towards totals.
Map<String, Object> poolPricingOptions() => {
      'min_depth_nano': (poolDepthFloorErg * 1e9).round(),
      'trusted_token_ids': [
        for (final t in verifiedTokens)
          if (t.isVerified) t.id,
      ],
    };

class PricingInputs {
  const PricingInputs({
    required this.source,
    this.oracle,
    this.oracles = const {},
    this.tipHeight,
    this.coingeckoUsd = const {},
    this.poolPrices = PoolPriceBook.empty,
    this.sigRsvPriceNano,
    required this.decimalsOf,
    this.nameOf,
  });

  final PriceSource source;

  /// The AVL multi-oracle: gold and the wrapped majors, used only while
  /// [OracleSnapshot.isStale] says it is current.
  final OracleSnapshot? oracle;

  /// The single-rate oracle pools read this refresh: SigmaUSD and Dexy USD
  /// (nanoERG per dollar), Dexy gold (nanoERG per kilogram).
  final Map<OracleFeed, OracleReading> oracles;

  /// The chain tip, for how old each reading is. Unknown means none can be
  /// judged stale.
  final int? tipHeight;

  /// coingecko id → USD.
  final Map<String, double> coingeckoUsd;

  /// Pool prices in ERG, computed in Rust from the Spectrum pool set.
  final PoolPriceBook poolPrices;

  /// nanoERG per SigRSV from the AgeUSD bank state.
  final int? sigRsvPriceNano;

  /// A token's decimals from the one token lookup, or null when nothing
  /// knows its scale. A pool quote is per base unit: such a token is left
  /// unpriced, and so out of totals, rather than priced per base unit as if
  /// that were a whole token.
  final int? Function(String tokenId) decimalsOf;

  /// A token's display name for "via" labels; null falls back to its id.
  final String? Function(String tokenId)? nameOf;
}

class PricingResult {
  const PricingResult({required this.ergUsd, required this.ergVia, required this.prices, this.ergStaleAge});
  final double? ergUsd;

  /// Where the ERG rate came from; says how old it is when it is stale.
  final String? ergVia;
  final Map<String, TokenPrice> prices;

  /// How old the ERG rate is when no source for it is current ("3 h").
  final String? ergStaleAge;

  bool get ergStale => ergStaleAge != null;

  TokenPrice? operator [](String id) => prices[id];
}

double _pow10(int n) {
  var r = 1.0;
  for (var i = 0; i < n; i++) {
    r *= 10;
  }
  return r;
}

/// USD per whole token for a pool quote.
double _quoteUsd(PoolQuote q, int decimals, double ergUsd) => q.nanoErgPerUnit * _pow10(decimals) / 1e9 * ergUsd;

/// One source's value for a feed, with how old it is.
class _Quote {
  const _Quote(this.usd, this.via, this.ageBlocks, {required this.fresh});
  final double usd;
  final String via;

  /// Null when the tip is unknown and age cannot be told.
  final int? ageBlocks;
  final bool fresh;
}

/// The first current quote in preference order; when none is current, the
/// youngest, to be shown as stale with its age. Null when there is none.
_Quote? _pick(List<_Quote> quotes) {
  for (final q in quotes) {
    if (q.fresh) return q;
  }
  if (quotes.isEmpty) return null;
  return quotes.reduce((a, b) => (b.ageBlocks ?? 0) < (a.ageBlocks ?? 0) ? b : a);
}

/// The whole pricing policy, pure so every branch is testable. Pool
/// arithmetic and pool choice happen in Rust (`wallet-amm`); this decides
/// which source wins for each token and converts to USD.
///
/// No price is presented as current when its source has stopped: a stale
/// quote is used only when nothing current exists, says its age, and never
/// counts towards a total.
PricingResult priceTokens(PricingInputs inp) {
  // A box seen at some height proves the chain is at least that tall, so
  // ages can be told even before the node height is known.
  final tip = [
    inp.tipHeight ?? 0,
    for (final r in inp.oracles.values) r.height,
  ].reduce((a, b) => a > b ? a : b);
  final int? knownTip = tip > 0 ? tip : null;

  _Quote? fromFeed(OracleFeed feed, double Function(OracleReading) usd) {
    final r = inp.oracles[feed];
    if (r == null) return null;
    final age = knownTip == null ? null : r.ageAt(knownTip);
    return _Quote(usd(r), feed.label, age, fresh: age == null || age <= feed.staleAfterBlocks);
  }

  final avl = inp.oracle;
  final avlAge = avl == null || knownTip == null ? null : (knownTip > avl.poolHeight ? knownTip - avl.poolHeight : 0);
  final avlFresh = avl != null && !avl.isStale(knownTip);
  _Quote? fromAvl(String feed, {double scale = 1}) {
    final v = avl?[feed];
    if (v == null || v <= 0) return null;
    return _Quote(v * scale, 'AVL oracle', avlAge, fresh: avlFresh);
  }

  double? ergUsd;
  String? ergVia;
  String? ergStaleAge;
  switch (inp.source) {
    case PriceSource.oracle:
      // The SigmaUSD pool first: it is the rate SigmaUSD itself settles at.
      final pick = _pick([
        if (fromFeed(OracleFeed.sigmaUsd, usdPerErg) case final q?) q,
        if (fromFeed(OracleFeed.dexyUsd, usdPerErg) case final q?) q,
        if (fromAvl('ERG_USD') case final q?) q,
      ]);
      if (pick != null) {
        ergUsd = pick.usd;
        if (pick.fresh) {
          ergVia = pick.via;
        } else {
          ergStaleAge = ageText(pick.ageBlocks ?? 0);
          ergVia = '${pick.via}, $ergStaleAge old';
        }
      }
    case PriceSource.spectrum:
      final sig = inp.poolPrices.tokens[SigmaUsdTokens.sigUsd];
      if (sig != null && sig.nanoErgPerUnit > 0) {
        // nanoERG per SigUSD cent → USD per ERG.
        ergUsd = 1e9 / (sig.nanoErgPerUnit * 100);
        ergVia = 'Spectrum ERG/SigUSD';
      }
    case PriceSource.coingecko:
      ergUsd = inp.coingeckoUsd['ergo'];
      ergVia = 'CoinGecko';
  }
  if (ergUsd == null || ergUsd <= 0) {
    return const PricingResult(ergUsd: null, ergVia: null, prices: {});
  }
  final usdPerErgNow = ergUsd;

  final prices = <String, TokenPrice>{};
  // Prices from a feed or a peg are per whole token by definition; their
  // scale still comes from the lookup, for valuing holdings at it.
  TokenPrice priced(String id, _Quote q) => q.fresh
      ? TokenPrice(usd: q.usd, via: q.via, decimals: inp.decimalsOf(id))
      : TokenPrice.stale(usd: q.usd, source: q.via, age: ageText(q.ageBlocks ?? 0), decimals: inp.decimalsOf(id));

  prices[SigmaUsdTokens.sigUsd] = TokenPrice(usd: 1, via: 'USD peg', decimals: inp.decimalsOf(SigmaUsdTokens.sigUsd));
  prices[DexyIds.use] = TokenPrice(usd: 1, via: 'USD peg', decimals: inp.decimalsOf(DexyIds.use));
  final rsv = inp.sigRsvPriceNano;
  if (rsv != null && rsv > 0) {
    prices[SigmaUsdTokens.sigRsv] = TokenPrice(
      usd: rsv / 1e9 * usdPerErgNow,
      via: 'AgeUSD bank',
      decimals: inp.decimalsOf(SigmaUsdTokens.sigRsv),
    );
  }

  // DexyGold is one milligram of gold: the Dexy oracle quotes nanoERG per
  // kilogram, the AVL oracle USD per troy ounce. The fresher current one
  // wins.
  final gold = [
    if (fromFeed(OracleFeed.dexyGold, (r) => r.rate / 1e6 / 1e9 * usdPerErgNow) case final q?) q,
    if (inp.source == PriceSource.oracle)
      if (fromAvl('XAU_USD', scale: 1 / mgPerTroyOunce) case final q?) q,
  ]..sort((a, b) => (a.ageBlocks ?? 0).compareTo(b.ageBlocks ?? 0));
  if (_pick(gold) case final q?) prices[DexyIds.gold] = priced(DexyIds.gold, q);

  // Wrapped majors: the AVL oracle only while it is current; otherwise
  // their Spectrum pools below, and a stale oracle price only as a last
  // resort, with its age.
  final staleMajors = <String, _Quote>{};
  for (final entry in wrappedOrigins.entries) {
    switch (inp.source) {
      case PriceSource.oracle:
        final q = fromAvl(entry.value.feed);
        if (q == null) continue;
        if (q.fresh) {
          prices[entry.key] = priced(entry.key, q);
        } else {
          staleMajors[entry.key] = q;
        }
      case PriceSource.coingecko:
        final usd = inp.coingeckoUsd[entry.value.coingeckoId];
        if (usd != null && usd > 0) {
          prices[entry.key] = TokenPrice(usd: usd, via: 'CoinGecko', decimals: inp.decimalsOf(entry.key));
        }
      case PriceSource.spectrum:
        break;
    }
  }

  // An LP token is worth its share of both reserves, which beats the price
  // of any pool that happens to trade the LP token itself.
  for (final e in inp.poolPrices.lpTokens.entries) {
    if (prices.containsKey(e.key)) continue;
    final decimals = inp.decimalsOf(e.key);
    if (decimals == null) continue;
    prices[e.key] = TokenPrice(
      usd: _quoteUsd(e.value, decimals, usdPerErgNow),
      via: 'Spectrum LP share',
      depthErg: e.value.depthNano / 1e9,
      countsInTotal: e.value.trusted,
      decimals: decimals,
    );
  }

  for (final e in inp.poolPrices.tokens.entries) {
    if (prices.containsKey(e.key)) continue;
    // Pool quotes are per base unit: without the token's scale there is no
    // price per token, only a guess.
    final decimals = inp.decimalsOf(e.key);
    if (decimals == null) continue;
    final q = e.value;
    final viaId = q.viaTokenId;
    final via = viaId == null
        ? 'Spectrum pool'
        : 'Spectrum pools via ${inp.nameOf?.call(viaId) ?? '${viaId.substring(0, 8)}…'}';
    prices[e.key] = TokenPrice(
      usd: _quoteUsd(q, decimals, usdPerErgNow),
      via: via,
      depthErg: q.depthNano / 1e9,
      countsInTotal: q.trusted,
      decimals: decimals,
    );
  }

  for (final e in staleMajors.entries) {
    prices.putIfAbsent(e.key, () => priced(e.key, e.value));
  }
  return PricingResult(ergUsd: usdPerErgNow, ergVia: ergVia, prices: prices, ergStaleAge: ergStaleAge);
}

/// Fiat summary of one wallet's holdings.
class HoldingsValue {
  const HoldingsValue({required this.usd, required this.priced, required this.unpriced, required this.excluded});

  /// ERG plus every counted token, in USD.
  final double usd;
  final int priced;

  /// Tokens with no price at all: no source prices them, or nothing knows
  /// their scale.
  final int unpriced;

  /// Tokens with a pool price that is not counted (unverified).
  final int excluded;
}

HoldingsValue holdingsValue({
  required int? ergNano,
  required Iterable<({String id, int amount, int decimals})> tokens,
  required PricingResult result,
}) {
  final ergUsd = result.ergUsd;
  if (ergUsd == null) return const HoldingsValue(usd: 0, priced: 0, unpriced: 0, excluded: 0);
  var usd = (ergNano ?? 0) / 1e9 * ergUsd;
  var priced = 0;
  var unpriced = 0;
  var excluded = 0;
  for (final t in tokens) {
    final p = result[t.id];
    if (p == null) {
      unpriced++;
      continue;
    }
    if (!p.countsInTotal) {
      excluded++;
      continue;
    }
    priced++;
    usd += t.amount / _pow10(p.decimals ?? t.decimals) * p.usd;
  }
  return HoldingsValue(usd: usd, priced: priced, unpriced: unpriced, excluded: excluded);
}

/// USD value of one holding, or null when unpriced. [amount] is base
/// units; they are scaled by the price's own decimals when it has them,
/// else by the holding's [decimals].
double? holdingUsd({required int amount, required int decimals, required TokenPrice? price}) =>
    price == null ? null : amount / _pow10(price.decimals ?? decimals) * price.usd;
