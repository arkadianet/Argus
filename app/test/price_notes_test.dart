// What the overview and the ERG row say about the price when a refresh
// came back without a rate: nothing while the last good prices are recent,
// their age once they are not, and "unavailable · retrying" when there is
// no rate to show at all.

import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/token_pricer.dart';
import 'package:argus_wallet/services/token_pricing.dart';
import 'package:argus_wallet/ui/home/home_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late PricingResult before;
  setUp(() => before = tokenPricer.result);
  tearDown(() {
    tokenPricer
      ..result = before
      ..pricesAreOld = false
      ..stale = false
      ..asOf = null;
    networkController.setErgRate(fiatPerErg: null, usdPerErg: null);
  });

  void pricedAt(DateTime asOf, {required bool old}) {
    tokenPricer
      ..result = const PricingResult(ergUsd: 0.31, ergVia: 'SigmaUSD oracle', prices: {})
      ..pricesAreOld = old
      ..stale = old
      ..asOf = asOf;
    networkController.setErgRate(fiatPerErg: 0.44, usdPerErg: 0.31);
  }

  test('a failed refresh a moment after a good one flags nothing', () {
    pricedAt(DateTime.now().subtract(const Duration(seconds: 20)), old: true);
    final view = ergPriceView(null);
    expect(view.staleNote, isNull, reason: 'not "as of just now"');
    expect(pricesNote(), isNull);
    final row = ergAssetRow(10 * 1000000000, view);
    expect(row.priceNote, isNull);
    expect(row.fiatValue, closeTo(4.4, 1e-9), reason: 'the row keeps its value');
  });

  test('prices past the threshold say how old they are', () {
    pricedAt(DateTime.now().subtract(TokenPricer.oldAfter + const Duration(minutes: 5)), old: true);
    expect(ergPriceView(null).staleNote, startsWith('as of'));
    expect(pricesNote(), startsWith('prices as of'));
  });

  test('with no rate at all the row says the price is unavailable', () {
    networkController.setErgRate(fiatPerErg: null, usdPerErg: null);
    final row = ergAssetRow(10 * 1000000000, ergPriceView(null));
    expect(row.fiatValue, isNull);
    expect(row.priceNote, startsWith('unavailable'));
  });
}
