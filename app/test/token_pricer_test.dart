import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:argus_wallet/services/amm_service.dart';
import 'package:argus_wallet/services/erg_price_history.dart';
import 'package:argus_wallet/services/oracle_feeds.dart';
import 'package:argus_wallet/services/oracle_pool.dart';
import 'package:argus_wallet/services/sigmausd_service.dart';
import 'package:argus_wallet/services/token_pricer.dart';
import 'package:argus_wallet/services/token_pricing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const rsBtc = '7a51950e5f548549ec1aa63ffdc38279505b11e7e803d01bcf8347e0123c88b0';
const lpToken = '303f39026572bcb4060b51fafc93787a236bb243744babaa99fceb833d61e198';

/// A pool box of the ERG/SigUSD pool at [height] pricing ERG at [usd].
Map<String, dynamic> _sigUsdPoolBox(int height, double usd) => {
      'boxId': 'b$height',
      'value': 100000 * 1000000000,
      'inclusionHeight': height,
      'assets': [
        {'tokenId': 'nft', 'amount': 1},
        {'tokenId': 'lp', 'amount': 9},
        {'tokenId': SigmaUsdTokens.sigUsd, 'amount': (usd * 100000 * 100).round()},
      ],
    };

class _Fakes {
  String fiat = 'usd';
  int? tip = 1000;
  int oracleCalls = 0;
  int geckoCalls = 0;
  int poolPriceCalls = 0;
  int boxPageCalls = 0;
  int chartCalls = 0;
  String? lastBoxToken;
  List<String>? lastGeckoVs;
  double? rate;
  double? usdRate;
  bool oracleFails = false;
  bool readingsFail = false;
  int readingCalls = 0;
  Completer<void>? poolGate;

  /// Blocks behind the tip of each single-rate pool's newest box; a feed
  /// left out has no box. SigmaUSD quotes 0.50 USD (2 ERG per dollar).
  Map<OracleFeed, int> readingAges = {OracleFeed.sigmaUsd: 1};
  DateTime now = DateTime.utc(2026, 10, 6, 12);

  /// The node's box history, newest first; null makes it fail like a node
  /// without the extra index.
  List<Map<String, dynamic>>? boxHistory = [
    _sigUsdPoolBox(990, 0.32),
    _sigUsdPoolBox(700, 0.31),
    _sigUsdPoolBox(100, 0.25), // 30 hours before the tip
  ];

  late final PricerDeps deps = PricerDeps(
    clock: () => now,
    oracleReading: (node, feed) async {
      readingCalls++;
      if (readingsFail) throw Exception('pool box unreadable');
      final age = readingAges[feed];
      if (age == null) return null;
      return OracleReading(rate: 2000000000, height: (tip ?? 1000) - age);
    },
    boxPage: (node, token, offset, limit) async {
      boxPageCalls++;
      lastBoxToken = token;
      final h = boxHistory;
      if (h == null) throw const HistoryUnavailable('This node cannot serve price history: it needs the extra index.');
      return h.skip(offset).take(limit).toList();
    },
    coingeckoChart: (fiat, days) async {
      chartCalls++;
      final at = now.millisecondsSinceEpoch;
      return {
        'prices': [
          [at - 26 * 3600000, 0.40],
          [at - 3600000, 0.44],
        ],
      };
    },
    poolPrices: (set) async {
      poolPriceCalls++;
      return PoolPriceBook(
        tokens: {
          // The fake pool set's 1000 ERG : 300 SigUSD.
          SigmaUsdTokens.sigUsd: const PoolQuote(
            nanoErgPerUnit: 1e12 / 30000,
            depthNano: 1000000000000,
            trusted: true,
            poolId: 'sig-pool',
          ),
        },
        lpTokens: {
          lpToken: const PoolQuote(nanoErgPerUnit: 2e9, depthNano: 1000000000000, trusted: true),
        },
      );
    },
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
    pools: () async {
      if (poolGate != null) await poolGate!.future;
      return AmmPoolSet(
        truncated: false,
        pools: [
          {
            'pool_type': 'N2T',
            'erg_reserves': 1000 * 1000000000,
            'token_y': {'token_id': SigmaUsdTokens.sigUsd, 'amount': 30000},
          },
        ],
        tokens: const {},
      );
    },
    sigRsvPriceNano: () async => 4000000,
    onRate: (f, u) {
      rate = f;
      usdRate = u;
    },
  );
}

void main() {
  test(
    'REVIEW: changing source during a gated branch refreshes new prices',
    () async {
      final f = _Fakes()..poolGate = Completer<void>();
      final p = TokenPricer(f.deps);
      final old = p.refresh();
      await Future<void>.delayed(Duration.zero);
      final changed = p.setSource(PriceSource.coingecko);
      await Future<void>.delayed(Duration.zero);
      expect(p.result.ergUsd, isNull);
      f.poolGate!.complete();
      await Future.wait([old, changed]);
      expect(f.geckoCalls, 1);
      expect(p.result.ergUsd, 0.4);
      expect(p.refreshing, isFalse);
    },
  );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'BATCH A: oracle prices publish while pools are still pending',
    () async {
      final f = _Fakes()..poolGate = Completer<void>();
      final p = TokenPricer(f.deps);
      final op = p.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(p.refreshing, isTrue);
      expect(p.result.ergUsd, 0.5);
      expect(f.rate, 0.5);
      expect(p.priceOf(rsBtc)?.usd, 80000);
      f.poolGate!.complete();
      await op;
      expect(p.refreshing, isFalse);
    },
  );

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

  test('the ERG rate comes from the SigmaUSD pool, and survives the AVL oracle failing', () async {
    final f = _Fakes()..oracleFails = true;
    final p = TokenPricer(f.deps);
    await p.refresh();
    expect(p.result.ergUsd, 0.5);
    expect(p.result.ergVia, 'SigmaUSD oracle');
    expect(p.lastError, contains('oracle'));
  });

  test('when no oracle answers there is no rate and the errors are recorded', () async {
    final f = _Fakes()
      ..oracleFails = true
      ..readingsFail = true;
    final p = TokenPricer(f.deps);
    await p.refresh();
    expect(p.result.ergUsd, isNull);
    expect(f.rate, isNull);
    expect(p.lastError, contains('SigmaUSD oracle'));
  });

  test('a stopped AVL oracle no longer flags a current ERG rate as stale', () async {
    // The AVL pool box (height 990) is 200 blocks old; SigmaUSD is current.
    final f = _Fakes()..tip = 990 + 200;
    final p = TokenPricer(f.deps);
    await p.refresh();
    expect(p.stale, isFalse);
    expect(p.result.ergVia, 'SigmaUSD oracle');
    expect(p.priceOf(rsBtc)!.via, 'AVL oracle, 6 h old', reason: 'the major says its own age');
    expect(p.priceOf(rsBtc)!.countsInTotal, isFalse);
    expect(p.sourceLine, 'Oracle pools · ERG via SigmaUSD oracle');
  });

  test('with every ERG source stopped, the rate is shown stale with its age', () async {
    final f = _Fakes()
      ..tip = 990 + 200
      ..readingAges = {OracleFeed.sigmaUsd: 150};
    final p = TokenPricer(f.deps);
    await p.refresh();
    expect(p.stale, isTrue);
    expect(p.result.ergUsd, 0.5);
    expect(p.result.ergVia, 'SigmaUSD oracle, 5 h old');
    // The settings row is cut to two lines; "stale" leads so it survives.
    expect(p.sourceLine, 'Oracle pools · stale · ERG via SigmaUSD oracle, 5 h old');
  });

  test('the Oracle source says what it reads', () {
    final blurb = PriceSource.oracle.blurb;
    expect(PriceSource.oracle.label, 'Oracle pools');
    expect(blurb, contains('ERG from the SigmaUSD oracle pool'));
    expect(blurb, contains('gold from the Dexy gold oracle'));
    expect(blurb, contains('AVL multi-oracle while it is current'));
    expect(blurb, contains('never as current'));
    final p = TokenPricer(_Fakes().deps);
    expect(p.sourceLine, 'Oracle pools', reason: 'no rate yet, no source details');
  });

  test('gold is read under every source, the dollar pools only under the Oracle source', () async {
    final f = _Fakes();
    final p = TokenPricer(f.deps);
    await p.refresh();
    expect(f.readingCalls, OracleFeed.values.length);
    final g = _Fakes();
    await TokenPricer(g.deps).setSource(PriceSource.spectrum);
    expect(g.readingCalls, 1);
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

  test('the pool set is priced by the Rust core and LP tokens get a price', () async {
    final f = _Fakes();
    final p = TokenPricer(f.deps);
    await p.refresh();
    expect(f.poolPriceCalls, 1);
    // 2 ERG per LP unit at the oracle's $0.50.
    expect(p.priceOf(lpToken)!.usd, closeTo(1.0, 1e-12));
    expect(p.priceOf(lpToken)!.via, 'Spectrum LP share');
    expect(p.usdOf(lpToken, 10, 0), closeTo(10, 1e-9));
  });

  test('a failed pool pricing keeps the other sources and says why', () async {
    final f = _Fakes();
    final deps = PricerDeps(
      nodeUrl: f.deps.nodeUrl,
      tipHeight: f.deps.tipHeight,
      fiatCode: f.deps.fiatCode,
      oracle: f.deps.oracle,
      coingecko: f.deps.coingecko,
      pools: f.deps.pools,
      poolPrices: (_) async => throw Exception('bridge down'),
      sigRsvPriceNano: f.deps.sigRsvPriceNano,
      oracleReading: f.deps.oracleReading,
      onRate: f.deps.onRate,
    );
    final p = TokenPricer(deps);
    await p.refresh();
    expect(p.result.ergUsd, 0.5);
    expect(p.priceOf(lpToken), isNull);
    expect(p.lastError, contains('pools'));
  });

  group('ERG price history', () {
    test('Spectrum source reads the pool the price book used, with a 24h change', () async {
      final f = _Fakes();
      final p = TokenPricer(f.deps);
      await p.setSource(PriceSource.spectrum);
      final h = await p.ergPriceHistory(PriceWindow.day);
      expect(h.available, isTrue);
      expect(f.lastBoxToken, 'sig-pool', reason: 'the deepest SigUSD pool, not a hardcoded one');
      expect(h.sourceLabel, 'Spectrum ERG/SigUSD');
      expect(h.approximateTimes, isTrue);
      // In force a day ago (720 blocks before the tip): 0.25; newest 0.32.
      expect(h.change24hPct, closeTo(28, 1e-6));
      expect(h.points.first.at, f.now.subtract(const Duration(hours: 24)));
      expect(h.points.last.price, closeTo(0.32, 1e-9));
    });

    test('Oracle source reads the SigmaUSD pool past boxes', () async {
      final raw = jsonDecode(File('test/fixtures/sigmausd_oracle_pool_history.json').readAsStringSync()) as Map;
      final f = _Fakes()
        ..tip = 1888757
        ..boxHistory = [for (final b in raw['items'] as List) (b as Map).cast<String, dynamic>()];
      final h = await TokenPricer(f.deps).ergPriceHistory(PriceWindow.day);
      expect(f.lastBoxToken, OracleFeed.sigmaUsd.nft);
      expect(h.available, isTrue);
      expect(h.sourceLabel, 'SigmaUSD oracle');
      expect(h.points.last.price, closeTo(0.32011, 0.00001));
      expect(h.stale, isFalse);
      expect(h.change24hPct, isNull, reason: 'sixteen recorded boxes do not reach back a day');
    });

    test('is cached for the refresh period, with no polling', () async {
      final f = _Fakes();
      final p = TokenPricer(f.deps);
      await p.setSource(PriceSource.spectrum);
      await p.ergPriceHistory(PriceWindow.day);
      final calls = f.boxPageCalls;
      await p.ergPriceHistory(PriceWindow.day);
      expect(f.boxPageCalls, calls);
      f.now = f.now.add(TokenPricer.refreshTtl);
      await p.ergPriceHistory(PriceWindow.day);
      expect(f.boxPageCalls, greaterThan(calls));
    });

    test('CoinGecko source uses its market chart in the display currency', () async {
      final f = _Fakes();
      final p = TokenPricer(f.deps);
      await p.setSource(PriceSource.coingecko);
      final h = await p.ergPriceHistory(PriceWindow.day);
      expect(f.chartCalls, 1);
      expect(f.boxPageCalls, 0, reason: 'the node is not asked under this source');
      expect(h.change24hPct, closeTo(10, 1e-9));
      expect(h.approximateTimes, isFalse);
    });

    test('a node without the extra index degrades to a reason, briefly cached', () async {
      final f = _Fakes()..boxHistory = null;
      final p = TokenPricer(f.deps);
      await p.setSource(PriceSource.spectrum);
      final h = await p.ergPriceHistory(PriceWindow.week);
      expect(h.available, isFalse);
      expect(h.points, isEmpty);
      expect(h.unavailableReason, contains('extra index'));
      final calls = f.boxPageCalls;
      await p.ergPriceHistory(PriceWindow.week);
      expect(f.boxPageCalls, calls, reason: 'not hammered');
      f.now = f.now.add(const Duration(seconds: 31));
      f.boxHistory = [_sigUsdPoolBox(990, 0.3)];
      expect((await p.ergPriceHistory(PriceWindow.week)).available, isTrue, reason: 'asked again soon');
    });

    test('no node, no history', () async {
      final f = _Fakes();
      final deps = PricerDeps(
        nodeUrl: () => null,
        tipHeight: f.deps.tipHeight,
        fiatCode: f.deps.fiatCode,
        oracle: f.deps.oracle,
        coingecko: f.deps.coingecko,
        pools: f.deps.pools,
        poolPrices: f.deps.poolPrices,
        sigRsvPriceNano: f.deps.sigRsvPriceNano,
        oracleReading: f.deps.oracleReading,
        onRate: f.deps.onRate,
        clock: () => f.now,
        boxPage: f.deps.boxPage,
      );
      final h = await TokenPricer(deps).ergPriceHistory(PriceWindow.day);
      expect(h.available, isFalse);
      expect(h.unavailableReason, contains('No node'));
    });
  });
}
