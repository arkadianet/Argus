import 'package:argus_wallet/services/route_display.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('price impact from reserves and an exact-output quote', () {
    // Pool 100 ERG / 100 000 tokens, spot 0.001 ERG per token; paying 0.011
    // ERG for 10 tokens is 0.0011 each: 10% over spot.
    final pct = priceImpactPct(ergIn: 11000000, tokensOut: 10, ergReserves: 100000000000, tokenReserves: 100000);
    expect(pct, closeTo(10.0, 0.01));
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
