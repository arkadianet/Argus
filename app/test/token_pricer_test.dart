import 'package:argus_wallet/services/amm_service.dart';
import 'package:argus_wallet/services/oracle_pool.dart';
import 'package:argus_wallet/services/sigmausd_service.dart';
import 'package:argus_wallet/services/token_pricer.dart';
import 'package:argus_wallet/services/token_pricing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const rsBtc = '7a51950e5f548549ec1aa63ffdc38279505b11e7e803d01bcf8347e0123c88b0';

class _Fakes {
  String fiat = 'usd';
  int? tip = 1000;
  int oracleCalls = 0;
  int geckoCalls = 0;
  List<String>? lastGeckoVs;
  double? rate;
  double? usdRate;
  bool oracleFails = false;

  late final PricerDeps deps = PricerDeps(
    nodeUrl: () => 'http://node',
    tipHeight: () => tip,
    fiatCode: () => fiat,
    oracle: (_) async {
      oracleCalls++;
      if (oracleFails) throw Exception('boom');
      return OracleSnapshot(epoch: 1, poolHeight: 990, operators: 3, usd: {'ERG_USD': 0.5, 'BTC_USD': 80000});
    },
    coingecko: (ids, vs) async {
      geckoCalls++;
      lastGeckoVs = vs;
      return {
        'ergo': {'usd': 0.4, 'eur': 0.36},
        'bitcoin': {'usd': 81000},
      };
    },
    pools: () async => AmmPoolSet(truncated: false, pools: [
      {
        'pool_type': 'N2T',
        'erg_reserves': 1000 * 1000000000,
        'token_y': {'token_id': SigmaUsdTokens.sigUsd, 'amount': 30000},
      },
    ], tokens: const {}),
    sigRsvPriceNano: () async => 4000000,
    dexyGoldRateNano: () async => null,
    onRate: (f, u) {
      rate = f;
      usdRate = u;
    },
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defaults to the oracle source and publishes the ERG rate', () async {
    final f = _Fakes();
    final p = TokenPricer(f.deps);
    await p.load();
    expect(p.source, PriceSource.oracle);
    await p.refresh();
    expect(p.result.ergUsd, 0.5);
    expect(p.priceOf(rsBtc)!.usd, 80000);
    expect(f.rate, 0.5);
    expect(f.geckoCalls, 0, reason: 'USD display needs no CoinGecko call');
    expect(p.stale, isFalse);
  });

  test('switching source persists and re-prices from the new source', () async {
    final f = _Fakes();
    final p = TokenPricer(f.deps);
    await p.setSource(PriceSource.spectrum);
    expect(p.result.ergUsd, closeTo(0.3, 1e-9));
    expect(p.result.ergVia, 'Spectrum ERG/SigUSD');
    expect(f.oracleCalls, 0);

    final again = TokenPricer(f.deps);
    await again.load();
    expect(again.source, PriceSource.spectrum);
  });

  test('non-USD display converts through the CoinGecko cross rate', () async {
    final f = _Fakes()..fiat = 'eur';
    final p = TokenPricer(f.deps);
    await p.refresh();
    expect(f.lastGeckoVs, ['usd', 'eur']);
    expect(p.fiatPerUsd, closeTo(0.9, 1e-9));
    expect(f.rate, closeTo(0.45, 1e-9));
    expect(f.usdRate, 0.5);
  });

  test('CoinGecko source prices ERG and majors from the API', () async {
    final f = _Fakes();
    final p = TokenPricer(f.deps);
    await p.setSource(PriceSource.coingecko);
    expect(p.result.ergUsd, 0.4);
    expect(p.priceOf(rsBtc)!.usd, 81000);
    expect(f.oracleCalls, 0);
  });

  test('a failed oracle fetch leaves no rate and records the error', () async {
    final f = _Fakes()..oracleFails = true;
    final p = TokenPricer(f.deps);
    await p.refresh();
    expect(p.result.ergUsd, isNull);
    expect(f.rate, isNull);
    expect(p.lastError, contains('oracle'));
  });

  test('stale oracle is flagged but still priced', () async {
    final f = _Fakes()..tip = 990 + 200;
    final p = TokenPricer(f.deps);
    await p.refresh();
    expect(p.stale, isTrue);
    expect(p.result.ergUsd, 0.5);
  });

  test('refresh is throttled unless forced', () async {
    final f = _Fakes();
    final p = TokenPricer(f.deps);
    await p.refresh();
    await p.refresh();
    expect(f.oracleCalls, 1);
    await p.refresh(force: true);
    expect(f.oracleCalls, 2);
  });
}
