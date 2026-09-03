import 'package:argus_wallet/services/oracle_pool.dart';
import 'package:argus_wallet/services/sigmausd_service.dart';
import 'package:argus_wallet/services/token_pricing.dart';
import 'package:flutter_test/flutter_test.dart';

const rsBtc = '7a51950e5f548549ec1aa63ffdc38279505b11e7e803d01bcf8347e0123c88b0';
const spf = '9a06d9e545a41fd51eeffc5e20d818073bf820c635e2a9d922269913e0de369d';
const scam = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';

Map<String, dynamic> n2t(String id, int ergNano, int tok) => {
      'pool_type': 'N2T',
      'erg_reserves': ergNano,
      'token_y': {'token_id': id, 'amount': tok},
    };

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
  test('oracle source: ERG from the ERG_USD feed, rsBTC from BTC_USD', () {
    final r = priceTokens(PricingInputs(source: PriceSource.oracle, oracle: oracle, decimalsOf: decimals));
    expect(r.ergUsd, 0.25);
    expect(r.ergVia, 'Oracle pool');
    expect(r[rsBtc]!.usd, 80000);
    expect(r[rsBtc]!.via, 'Oracle pool');
  });

  test('spectrum source: ERG from the SigUSD pool, wrapped majors only via their own pool', () {
    final pools = [
      n2t(SigmaUsdTokens.sigUsd, 1000 * 1000000000, 25000), // 1000 ERG : 250 SigUSD
      n2t(rsBtc, 800 * 1000000000, 1000000), // 800 ERG : 0.01 BTC
    ];
    final r = priceTokens(PricingInputs(source: PriceSource.spectrum, pools: pools, decimalsOf: decimals));
    expect(r.ergUsd, closeTo(0.25, 1e-9));
    expect(r.ergVia, 'Spectrum ERG/SigUSD');
    expect(r[rsBtc]!.usd, closeTo(20000, 1e-6));
    expect(r[rsBtc]!.via, 'Spectrum pool');
    expect(r[rsBtc]!.countsInTotal, isTrue);
  });

  test('spectrum source with no SigUSD pool prices nothing', () {
    final r = priceTokens(PricingInputs(source: PriceSource.spectrum, pools: [n2t(spf, 1e12.toInt(), 1)], decimalsOf: decimals));
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

  test('pegs and protocol rates apply under every source', () {
    for (final s in PriceSource.values) {
      final r = priceTokens(PricingInputs(
        source: s,
        oracle: oracle,
        coingeckoUsd: const {'ergo': 0.25},
        pools: [n2t(SigmaUsdTokens.sigUsd, 1000 * 1000000000, 25000)],
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

  test('pool prices use the deepest pool, respect the depth floor, and count only verified tokens', () {
    final pools = [
      n2t(spf, 10 * 1000000000, 1000000000), // 10 ERG, too shallow
      n2t(spf, 500 * 1000000000, 10000 * 1000000), // 500 ERG : 10,000 SPF → 0.05 ERG each
      n2t(spf, 200 * 1000000000, 1000 * 1000000), // shallower, would give 0.2
      n2t(scam, 1000 * 1000000000, 1000), // deep pool but unknown token
    ];
    final r = priceTokens(PricingInputs(source: PriceSource.oracle, oracle: oracle, pools: pools, decimalsOf: decimals));
    expect(r[spf]!.usd, closeTo(0.0125, 1e-9));
    expect(r[spf]!.depthErg, 500);
    expect(r[spf]!.countsInTotal, isTrue);
    expect(r[scam]!.countsInTotal, isFalse);
  });

  test('a token below the floor in every pool is unpriced', () {
    final r = priceTokens(PricingInputs(
      source: PriceSource.oracle,
      oracle: oracle,
      pools: [n2t(spf, 10 * 1000000000, 1000000000)],
      decimalsOf: decimals,
    ));
    expect(r[spf], isNull);
  });

  test('holdingsValue sums ERG and counted tokens and reports the rest', () {
    final r = priceTokens(PricingInputs(
      source: PriceSource.oracle,
      oracle: oracle,
      pools: [n2t(spf, 500 * 1000000000, 10000 * 1000000), n2t(scam, 1000 * 1000000000, 1000)],
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
