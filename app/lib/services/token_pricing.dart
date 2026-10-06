import 'oracle_pool.dart';
import 'sigmausd_service.dart';
import 'verified_tokens.dart';

/// Where fiat prices come from. The user picks one in Display settings.
enum PriceSource {
  oracle('Oracle pool', 'On-chain: AVL multi-oracle for ERG, gold and wrapped majors, Spectrum pools for the rest. Reads only your node.'),
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
  const TokenPrice({required this.usd, required this.via, this.depthErg, this.countsInTotal = true});

  /// USD per whole token (decimals applied).
  final double usd;

  /// Human label of the source, e.g. "Oracle pool", "Spectrum pool", "peg".
  final String via;

  /// ERG side of the pool the price came from, when pool-derived.
  final double? depthErg;

  /// False for pool-priced tokens that are not on the verified list: shown
  /// on the row, excluded from portfolio totals.
  final bool countsInTotal;
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
    this.coingeckoUsd = const {},
    this.poolPrices = PoolPriceBook.empty,
    this.sigRsvPriceNano,
    this.dexyGoldRateNano,
    required this.decimalsOf,
    this.nameOf,
  });

  final PriceSource source;
  final OracleSnapshot? oracle;

  /// coingecko id → USD.
  final Map<String, double> coingeckoUsd;

  /// Pool prices in ERG, computed in Rust from the Spectrum pool set.
  final PoolPriceBook poolPrices;

  /// nanoERG per SigRSV from the AgeUSD bank state.
  final int? sigRsvPriceNano;

  /// nanoERG per DexyGold (1 mg) from the Dexy oracle.
  final int? dexyGoldRateNano;

  final int Function(String tokenId) decimalsOf;

  /// A token's display name for "via" labels; null falls back to its id.
  final String? Function(String tokenId)? nameOf;
}

class PricingResult {
  const PricingResult({required this.ergUsd, required this.ergVia, required this.prices});
  final double? ergUsd;
  final String? ergVia;
  final Map<String, TokenPrice> prices;

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

/// The whole pricing policy, pure so every branch is testable. Pool
/// arithmetic and pool choice happen in Rust (`wallet-amm`); this decides
/// which source wins for each token and converts to USD.
PricingResult priceTokens(PricingInputs inp) {
  double? ergUsd;
  String? ergVia;
  switch (inp.source) {
    case PriceSource.oracle:
      ergUsd = inp.oracle?['ERG_USD'];
      ergVia = 'Oracle pool';
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
    return PricingResult(ergUsd: null, ergVia: null, prices: const {});
  }

  final prices = <String, TokenPrice>{};
  prices[SigmaUsdTokens.sigUsd] = const TokenPrice(usd: 1, via: 'USD peg');
  prices[DexyIds.use] = const TokenPrice(usd: 1, via: 'USD peg');
  final rsv = inp.sigRsvPriceNano;
  if (rsv != null && rsv > 0) {
    prices[SigmaUsdTokens.sigRsv] = TokenPrice(usd: rsv / 1e9 * ergUsd, via: 'AgeUSD bank');
  }
  final gold = inp.dexyGoldRateNano;
  if (gold != null && gold > 0) {
    prices[DexyIds.gold] = TokenPrice(usd: gold / 1e9 * ergUsd, via: 'Dexy gold oracle');
  }

  for (final entry in wrappedOrigins.entries) {
    double? usd;
    String? via;
    switch (inp.source) {
      case PriceSource.oracle:
        usd = inp.oracle?[entry.value.feed];
        via = 'Oracle pool';
      case PriceSource.coingecko:
        usd = inp.coingeckoUsd[entry.value.coingeckoId];
        via = 'CoinGecko';
      case PriceSource.spectrum:
        break;
    }
    if (usd != null && usd > 0) prices[entry.key] = TokenPrice(usd: usd, via: via!);
  }

  // An LP token is worth its share of both reserves, which beats the price
  // of any pool that happens to trade the LP token itself.
  for (final e in inp.poolPrices.lpTokens.entries) {
    if (prices.containsKey(e.key)) continue;
    prices[e.key] = TokenPrice(
      usd: _quoteUsd(e.value, inp.decimalsOf(e.key), ergUsd),
      via: 'Spectrum LP share',
      depthErg: e.value.depthNano / 1e9,
      countsInTotal: e.value.trusted,
    );
  }

  for (final e in inp.poolPrices.tokens.entries) {
    if (prices.containsKey(e.key)) continue;
    final q = e.value;
    final viaId = q.viaTokenId;
    final via = viaId == null
        ? 'Spectrum pool'
        : 'Spectrum pools via ${inp.nameOf?.call(viaId) ?? '${viaId.substring(0, 8)}…'}';
    prices[e.key] = TokenPrice(
      usd: _quoteUsd(q, inp.decimalsOf(e.key), ergUsd),
      via: via,
      depthErg: q.depthNano / 1e9,
      countsInTotal: q.trusted,
    );
  }
  return PricingResult(ergUsd: ergUsd, ergVia: ergVia, prices: prices);
}

/// Fiat summary of one wallet's holdings.
class HoldingsValue {
  const HoldingsValue({required this.usd, required this.priced, required this.unpriced, required this.excluded});

  /// ERG plus every counted token, in USD.
  final double usd;
  final int priced;

  /// Tokens with no price at all.
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
    usd += t.amount / _pow10(t.decimals) * p.usd;
  }
  return HoldingsValue(usd: usd, priced: priced, unpriced: unpriced, excluded: excluded);
}

/// USD value of one holding, or null when unpriced.
double? holdingUsd({required int amount, required int decimals, required TokenPrice? price}) =>
    price == null ? null : amount / _pow10(decimals) * price.usd;
