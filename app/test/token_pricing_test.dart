import 'package:argus_wallet/services/oracle_pool.dart';
import 'package:argus_wallet/services/sigmausd_service.dart';
import 'package:argus_wallet/services/token_pricing.dart';
import 'package:flutter_test/flutter_test.dart';

const rsBtc = '7a51950e5f548549ec1aa63ffdc38279505b11e7e803d01bcf8347e0123c88b0';
const spf = '9a06d9e545a41fd51eeffc5e20d818073bf820c635e2a9d922269913e0de369d';
const scam = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
const neta = '472c3d4ecaa08fb7392ff041ee2e6af75f4a558810a74b28600549d5392810e8';
const lp = '303f39026572bcb4060b51fafc93787a236bb243744babaa99fceb833d61e198';

/// A direct pool quote: [nanoPerUnit] nanoERG per base unit.
PoolQuote direct(double nanoPerUnit, {int depthErg = 1000, bool trusted = true}) =>
    PoolQuote(nanoErgPerUnit: nanoPerUnit, depthNano: depthErg * 1000000000, trusted: trusted, poolId: 'p');

final oracle = OracleSnapshot(epoch: 1, poolHeight: 100, operators: 3, usd: {
  'ERG_USD': 0.25,
  'BTC_USD': 80000,
  'XAU_USD': 4600,
});

int decimals(String id) => switch (id) {
      SigmaUsdTokens.sigUsd => 2,
      spf => 6,
      rsBtc => 8,
      _ => 0,
    };

void main() {
  _rowValueTests();
  test('oracle source: ERG from the ERG_USD feed, rsBTC from BTC_USD', () {
    final r = priceTokens(PricingInputs(source: PriceSource.oracle, oracle: oracle, decimalsOf: decimals));
    expect(r.ergUsd, 0.25);
    expect(r.ergVia, 'Oracle pool');
    expect(r[rsBtc]!.usd, 80000);
    expect(r[rsBtc]!.via, 'Oracle pool');
  });

  test('spectrum source: ERG from the SigUSD pool quote, wrapped majors only via their own pool', () {
    final book = PoolPriceBook(tokens: {
      // 1000 ERG : 250 SigUSD → 4 ERG per SigUSD, 0.04 ERG per cent.
      SigmaUsdTokens.sigUsd: direct(40000000),
      // 800 ERG : 0.01 BTC → 800_000 nanoERG per satoshi.
      rsBtc: direct(800000, depthErg: 800),
    });
    final r = priceTokens(PricingInputs(source: PriceSource.spectrum, poolPrices: book, decimalsOf: decimals));
    expect(r.ergUsd, closeTo(0.25, 1e-9));
    expect(r.ergVia, 'Spectrum ERG/SigUSD');
    expect(r[rsBtc]!.usd, closeTo(20000, 1e-6));
    expect(r[rsBtc]!.via, 'Spectrum pool');
    expect(r[rsBtc]!.depthErg, 800);
    expect(r[rsBtc]!.countsInTotal, isTrue);
  });

  test('spectrum source with no SigUSD quote prices nothing', () {
    final r = priceTokens(PricingInputs(
      source: PriceSource.spectrum,
      poolPrices: PoolPriceBook(tokens: {spf: direct(1)}),
      decimalsOf: decimals,
    ));
    expect(r.ergUsd, isNull);
    expect(r.prices, isEmpty);
  });

  test('coingecko source: ERG and origins from the id map', () {
    final r = priceTokens(PricingInputs(
      source: PriceSource.coingecko,
      coingeckoUsd: {'ergo': 0.3, 'bitcoin': 81000},
      decimalsOf: decimals,
    ));
    expect(r.ergUsd, 0.3);
    expect(r[rsBtc]!.usd, 81000);
    expect(r[rsBtc]!.via, 'CoinGecko');
  });

  test('pegs and protocol rates apply under every source and beat pool quotes', () {
    for (final s in PriceSource.values) {
      final r = priceTokens(PricingInputs(
        source: s,
        oracle: oracle,
        coingeckoUsd: const {'ergo': 0.25},
        poolPrices: PoolPriceBook(tokens: {SigmaUsdTokens.sigUsd: direct(40000000), DexyIds.use: direct(1)}),
        sigRsvPriceNano: 4000000, // 0.004 ERG
        dexyGoldRateNano: 400000000000, // 400 ERG per mg
        decimalsOf: decimals,
      ));
      expect(r[SigmaUsdTokens.sigUsd]!.usd, 1, reason: s.name);
      expect(r[DexyIds.use]!.usd, 1, reason: s.name);
      expect(r[SigmaUsdTokens.sigRsv]!.usd, closeTo(0.001, 1e-9), reason: s.name);
      expect(r[DexyIds.gold]!.usd, closeTo(100, 1e-6), reason: s.name);
    }
  });

  test('pool quotes convert per whole token and keep depth and trust', () {
    final book = PoolPriceBook(tokens: {
      spf: direct(50, depthErg: 500), // 50 nanoERG per unit → 0.05 ERG per SPF (6 decimals)
      scam: direct(1000000000, trusted: false),
    });
    final r = priceTokens(PricingInputs(source: PriceSource.oracle, oracle: oracle, poolPrices: book, decimalsOf: decimals));
    expect(r[spf]!.usd, closeTo(0.0125, 1e-9));
    expect(r[spf]!.depthErg, 500);
    expect(r[spf]!.countsInTotal, isTrue);
    expect(r[scam]!.countsInTotal, isFalse);
  });

  test('a token priced through another token says which', () {
    final book = PoolPriceBook(tokens: {
      'tok': const PoolQuote(nanoErgPerUnit: 2, depthNano: 120000000000, trusted: true, viaTokenId: SigmaUsdTokens.sigUsd),
      'tok2': const PoolQuote(nanoErgPerUnit: 2, depthNano: 120000000000, trusted: false, viaTokenId: scam),
    });
    final r = priceTokens(PricingInputs(
      source: PriceSource.oracle,
      oracle: oracle,
      poolPrices: book,
      decimalsOf: (_) => 0,
      nameOf: (id) => id == SigmaUsdTokens.sigUsd ? 'SigUSD' : null,
    ));
    expect(r['tok']!.via, 'Spectrum pools via SigUSD');
    expect(r['tok']!.depthErg, 120);
    expect(r['tok2']!.via, 'Spectrum pools via ffffffff…');
    expect(r['tok2']!.countsInTotal, isFalse);
  });

  test('LP tokens are valued at their share of both reserves', () {
    final book = PoolPriceBook(
      tokens: {lp: direct(1)},
      lpTokens: {lp: const PoolQuote(nanoErgPerUnit: 400000000, depthNano: 600000000000, trusted: true, poolId: 'pool')},
    );
    final r = priceTokens(PricingInputs(source: PriceSource.oracle, oracle: oracle, poolPrices: book, decimalsOf: (_) => 0));
    // 0.4 ERG per LP unit at $0.25.
    expect(r[lp]!.usd, closeTo(0.1, 1e-12));
    expect(r[lp]!.via, 'Spectrum LP share', reason: 'the share beats a pool trading the LP token');
    expect(r[lp]!.depthErg, 600);
    expect(r[lp]!.countsInTotal, isTrue);
  });

  test('an LP share of an unverified pool is shown but kept out of totals', () {
    final book = PoolPriceBook(lpTokens: {lp: const PoolQuote(nanoErgPerUnit: 4, depthNano: 1, trusted: false)});
    final r = priceTokens(PricingInputs(source: PriceSource.oracle, oracle: oracle, poolPrices: book, decimalsOf: (_) => 0));
    final v = holdingsValue(ergNano: 0, tokens: [(id: lp, amount: 1000, decimals: 0)], result: r);
    expect(r[lp], isNotNull);
    expect(v.excluded, 1);
    expect(v.usd, 0);
  });

  test('the Rust price book parses', () {
    final book = PoolPriceBook.fromJson({
      'tokens': {
        spf: {'nano_erg_per_unit': 50.5, 'depth_nano': 500000000000, 'route': 'direct', 'pool_id': 'deep', 'trusted': true},
        'tok': {
          'nano_erg_per_unit': 2,
          'depth_nano': 120000000000,
          'route': 'hop',
          'via_token_id': SigmaUsdTokens.sigUsd,
          'pool_ids': ['t', 's'],
          'trusted': false,
        },
      },
      'lp_tokens': {
        lp: {'nano_erg_per_unit': 4e8, 'depth_nano': 600000000000, 'pool_id': 'p', 'x_token_id': null, 'y_token_id': spf, 'trusted': true},
      },
      'pools_used': 3,
      'pools_skipped': 0,
    });
    expect(book.tokens[spf]!.nanoErgPerUnit, 50.5);
    expect(book.tokens[spf]!.poolId, 'deep');
    expect(book.tokens[spf]!.viaTokenId, isNull);
    expect(book.tokens['tok']!.viaTokenId, SigmaUsdTokens.sigUsd);
    expect(book.tokens['tok']!.trusted, isFalse);
    expect(book.lpTokens[lp]!.depthNano, 600000000000);
  });

  test('the Rust core is told the floor and only verified tokens', () {
    final o = poolPricingOptions();
    expect(o['min_depth_nano'], 50000000000);
    final trusted = o['trusted_token_ids'] as List;
    expect(trusted, contains(SigmaUsdTokens.sigUsd));
    expect(trusted, contains(spf));
    expect(trusted, isNot(contains(neta)), reason: 'a cautioned token never counts');
  });

  test('holdingsValue sums ERG and counted tokens and reports the rest', () {
    final r = priceTokens(PricingInputs(
      source: PriceSource.oracle,
      oracle: oracle,
      poolPrices: PoolPriceBook(tokens: {spf: direct(50, depthErg: 500), scam: direct(1e12, trusted: false)}),
      decimalsOf: decimals,
    ));
    final v = holdingsValue(
      ergNano: 100 * 1000000000,
      tokens: [
        (id: SigmaUsdTokens.sigUsd, amount: 1000, decimals: 2), // $10
        (id: spf, amount: 200 * 1000000, decimals: 6), // 200 × 0.0125 = $2.5
        (id: scam, amount: 5, decimals: 0),
        (id: 'unknown', amount: 5, decimals: 0),
      ],
      result: r,
    );
    expect(v.usd, closeTo(25 + 10 + 2.5, 1e-9));
    expect(v.priced, 2);
    expect(v.excluded, 1);
    expect(v.unpriced, 1);
  });

  test('coingeckoIdsFor requests majors only for the CoinGecko source', () {
    expect(coingeckoIdsFor(PriceSource.oracle), ['ergo']);
    expect(coingeckoIdsFor(PriceSource.coingecko), contains('bitcoin'));
  });
}

// A wallet row's worth is ERG plus its tokens
void _rowValueTests() {
  test('token value is counted, not just the ERG', () {
    final r = priceTokens(PricingInputs(
      source: PriceSource.oracle,
      oracle: OracleSnapshot(epoch: 1, poolHeight: 1, operators: 3, usd: {'ERG_USD': 0.25}),
      decimalsOf: (_) => 2,
    ));
    // 100 ERG at $0.25 is $25; 10 SigUSD is $10 on top.
    final v = holdingsValue(
      ergNano: 100 * 1000000000,
      tokens: [(id: SigmaUsdTokens.sigUsd, amount: 1000, decimals: 2)],
      result: r,
    );
    expect(v.usd, closeTo(35, 1e-9));
  });

  test('a wallet holding only unpriced tokens still reports its ERG', () {
    final r = priceTokens(PricingInputs(
      source: PriceSource.oracle,
      oracle: OracleSnapshot(epoch: 1, poolHeight: 1, operators: 3, usd: {'ERG_USD': 0.25}),
      decimalsOf: (_) => 0,
    ));
    final v = holdingsValue(
      ergNano: 4 * 1000000000,
      tokens: [(id: 'unknown-token', amount: 70000, decimals: 0)],
      result: r,
    );
    expect(v.usd, closeTo(1, 1e-9));
    expect(v.unpriced, 1);
  });
}
