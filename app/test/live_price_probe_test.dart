// A probe of the live price services, off unless ARGUS_LIVE is set: each
// source the pricer reads, against a real node and CoinGecko, in AUD, and
// one whole refresh per source with every rate it publishes on the way.
//
//   ARGUS_LIVE=1 ARGUS_NODE=https://node.kadia.io flutter test test/live_price_probe_test.dart

import 'dart:io';

import 'package:argus_wallet/services/oracle_feeds.dart';
import 'package:argus_wallet/services/oracle_pool.dart';
import 'package:argus_wallet/services/token_pricer.dart';
import 'package:argus_wallet/services/token_pricing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final live = Platform.environment['ARGUS_LIVE'] != null;
  final node = Platform.environment['ARGUS_NODE'] ?? 'https://node.kadia.io';

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('each source, live', () async {
    for (final feed in OracleFeed.values) {
      try {
        final r = await fetchOracleReading(node, feed);
        debugPrint('reading ${feed.name}: rate=${r?.rate} height=${r?.height}');
      } catch (e) {
        debugPrint('reading ${feed.name}: FAILED $e');
      }
    }
    try {
      final s = await OraclePoolClient().fetch(node);
      debugPrint('oracle snapshot: ${s == null ? 'null' : 'ok'}');
    } catch (e) {
      debugPrint('oracle snapshot: FAILED $e');
    }
    for (final src in PriceSource.values) {
      try {
        final g = await fetchCoingecko(coingeckoIdsFor(src), ['usd', 'aud']);
        debugPrint('coingecko ${src.name}: ergo=${g['ergo']}');
      } catch (e) {
        debugPrint('coingecko ${src.name}: FAILED $e');
      }
    }
  }, skip: !live);

  test('one refresh per source, live, in AUD', () async {
    for (final src in [PriceSource.oracle, PriceSource.coingecko]) {
      final rates = <String>[];
      final pricer = TokenPricer(PricerDeps(
        nodeUrl: () => node,
        tipHeight: () => null,
        fiatCode: () => 'AUD',
        oracle: (n) => OraclePoolClient().fetch(n),
        coingecko: (ids, vs) => fetchCoingecko(ids, vs),
        pools: () async => null,
        poolPrices: (_) async => throw UnimplementedError(),
        sigRsvPriceNano: () async => null,
        onRate: (fiatPerErg, usd) => rates.add('fiat=$fiatPerErg usd=$usd'),
        metadataChanges: ChangeNotifier(),
      ));
      pricer.source = src;
      await pricer.refresh(force: true);
      debugPrint('${src.name}: rates published $rates');
      debugPrint('${src.name}: ergUsd=${pricer.result.ergUsd} via=${pricer.result.ergVia} '
          'old=${pricer.pricesAreOld} stale=${pricer.stale} displayRateKnown=${pricer.displayRateKnown} '
          'fiatPerUsd=${pricer.fiatPerUsd} error=${pricer.lastError}');
    }
  }, skip: !live);
}
