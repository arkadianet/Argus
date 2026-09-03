import 'oracle_pool.dart';
import 'sigmausd_service.dart';
import 'verified_tokens.dart';

/// Where fiat prices come from. The user picks one in Display settings.
enum PriceSource {
  oracle('Oracle pool', 'On-chain: AVL multi-oracle for ERG, gold and wrapped majors, Spectrum pools for the rest. Reads only your node.'),
  spectrum('Spectrum pools', 'On-chain: ERG priced from the ERG/SigUSD pool, tokens from their ERG pools. Reads only your node.'),
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
/// not a price.
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

class PricingInputs {
  const PricingInputs({
    required this.source,
    this.oracle,
    this.coingeckoUsd = const {},
    this.pools = const [],
    this.sigRsvPriceNano,
    this.dexyGoldRateNano,
    required this.decimalsOf,
  });

  final PriceSource source;
  final OracleSnapshot? oracle;

  /// coingecko id → USD.
  final Map<String, double> coingeckoUsd;

  /// Spectrum pool maps as returned by the AMM service (`pool_type`,
  /// `erg_reserves`, `token_y: {token_id, amount}`).
  final List<Map<String, dynamic>> pools;

  /// nanoERG per SigRSV from the AgeUSD bank state.
  final int? sigRsvPriceNano;

  /// nanoERG per DexyGold (1 mg) from the Dexy oracle.
  final int? dexyGoldRateNano;

  final int Function(String tokenId) decimalsOf;
}

class PricingResult {
  const PricingResult({required this.ergUsd, required this.ergVia, required this.prices});
  final double? ergUsd;
  final String? ergVia;
  final Map<String, TokenPrice> prices;

  TokenPrice? operator [](String id) => prices[id];
}

/// Deepest ERG-side pool for [tokenId] as (ergReserves, tokenReserves).
(int, int)? deepestErgPool(List<Map<String, dynamic>> pools, String tokenId) {
  (int, int)? best;
  for (final p in pools) {
    if (p['pool_type'] == 'T2T') continue;
    final y = p['token_y'] as Map?;
    if (y?['token_id'] != tokenId) continue;
    final erg = (p['erg_reserves'] as num?)?.toInt() ?? 0;
    final tok = (y?['amount'] as num?)?.toInt() ?? 0;
    if (erg <= 0 || tok <= 0) continue;
    if (best == null || erg > best.$1) best = (erg, tok);
  }
  return best;
}

double _pow10(int n) {
  var r = 1.0;
  for (var i = 0; i < n; i++) {
    r *= 10;
  }
  return r;
}

/// The whole pricing policy, pure so every branch is testable.
PricingResult priceTokens(PricingInputs inp) {
  double? ergUsd;
  String? ergVia;
  switch (inp.source) {
    case PriceSource.oracle:
      ergUsd = inp.oracle?['ERG_USD'];
      ergVia = 'Oracle pool';
    case PriceSource.spectrum:
      final pool = deepestErgPool(inp.pools, SigmaUsdTokens.sigUsd);
      if (pool != null) {
        ergUsd = (pool.$2 / 100) / (pool.$1 / 1e9);
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

  for (final p in inp.pools) {
    if (p['pool_type'] == 'T2T') continue;
    final id = (p['token_y'] as Map?)?['token_id'] as String?;
    if (id == null || prices.containsKey(id)) continue;
    final pool = deepestErgPool(inp.pools, id);
    if (pool == null) continue;
    final depthErg = pool.$1 / 1e9;
    if (depthErg < poolDepthFloorErg) continue;
    final perToken = depthErg / (pool.$2 / _pow10(inp.decimalsOf(id)));
    prices[id] = TokenPrice(
      usd: perToken * ergUsd,
      via: 'Spectrum pool',
      depthErg: depthErg,
      countsInTotal: isVerifiedToken(id),
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
