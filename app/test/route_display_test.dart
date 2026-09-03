import 'package:argus_wallet/services/route_display.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('price impact from reserves and an exact-output quote', () {
    // 10 ERG into a 100 ERG pool moves the price by 10/110.
    final pct = priceImpactPct(ergIn: 10000000000, tokensOut: 10, ergReserves: 100000000000, tokenReserves: 100000);
    expect(pct, closeTo(9.09, 0.01));
    // A whole-token output that floors must not read as impact.
    expect(priceImpactPct(ergIn: 150000000, tokensOut: 1, ergReserves: 1000000000000, tokenReserves: 10000)!, lessThan(0.02));
    expect(priceImpactPct(ergIn: 1, tokensOut: 1, ergReserves: 0, tokenReserves: 1), isNull);
  });

  test('warning text only above the threshold', () {
    expect(impactWarning(0.5), isNull);
    expect(impactWarning(3.0), isNull);
    expect(impactWarning(3.01), contains('3.0%'));
    expect(impactWarning(12.4), contains('12.4%'));
  });

  test('liquidity label is short', () {
    expect(liquidityLabel(123456789000), 'pool 123.45 ERG');
    expect(liquidityLabel(null), '');
  });
}
