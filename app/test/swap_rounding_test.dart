import 'package:argus_wallet/services/dexy_service.dart';
import 'package:argus_wallet/services/swap_rounding.dart';
import 'package:argus_wallet/ui/dexy/dexy_sheets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Live DexyGold pool, 2026-09-04: 3229.996 ERG against 6002 DexyGold, 0.3% fee.
  final rErg = BigInt.from(3229996138623);
  final rGold = BigInt.from(6002);

  test('1 ERG for 1 DexyGold: the exact input is ~0.54 ERG and the rest is flagged', () {
    final r = swapRoundingFor(input: 1000000000, output: 1, reservesIn: rErg, reservesOut: rGold, feeNum: 997, feeDenom: 1000)!;
    expect(r.exactInput, closeTo(539700000, 1500000));
    expect(r.leftover, 1000000000 - r.exactInput);
  });

  test('no hint when the leftover is under half a percent', () {
    // 0.5400 ERG buys 1 DexyGold with ~0.0003 ERG spare.
    expect(swapRoundingFor(input: 540000000, output: 1, reservesIn: rErg, reservesOut: rGold, feeNum: 997, feeDenom: 1000), isNull);
  });

  test('no hint when the output is zero or the input already minimal', () {
    expect(swapRoundingFor(input: 100000000, output: 0, reservesIn: rErg, reservesOut: rGold, feeNum: 997, feeDenom: 1000), isNull);
  });

  test('Dexy swap sheet builds the hint from the preview reserves, ERG side only', () {
    final q = DexySwapPreview.fromJson({
      'input_amount': 1000000000, 'output_amount': 1, 'min_output': 1, 'price_impact_pct': 0.0,
      'fee_pct': 0.3, 'miner_fee_nano': 1100000, 'output_token_name': 'DexyGold', 'can_execute': true,
      'lp_erg_reserves': 3229996138623, 'lp_dexy_reserves': 6002,
    });
    expect(dexySwapRounding(q, ergInput: true), isNotNull);
    expect(dexySwapRounding(q, ergInput: false), isNull);
  });
}
