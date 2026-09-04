import 'package:argus_wallet/services/dexy_service.dart';
import 'package:argus_wallet/ui/dexy/dexy_sheets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  _redeemNoteTests();
  _rateGuardTests();
  test('whole-unit token: 1 ERG buys 1 DexyGold and says what stays', () {
    final note = mintRoundingNote(ergTyped: 1, baseUnits: 1, decimals: 0, ergPerToken: 0.542, shortName: 'DexyGold');
    expect(note, 'DexyGold mints in whole units: 1 for 0.5420 ERG, 0.4580 ERG stays in your wallet');
  });

  test('less than one unit is explained', () {
    final note = mintRoundingNote(ergTyped: 0.3, baseUnits: 0, decimals: 0, ergPerToken: 0.542, shortName: 'DexyGold');
    expect(note, contains('less than one DexyGold'));
  });

  test('an exact multiple needs no note', () {
    expect(mintRoundingNote(ergTyped: 1.084, baseUnits: 2, decimals: 0, ergPerToken: 0.542, shortName: 'DexyGold'), isNull);
  });

  test('USE with three decimals rounds to a step and reports the sliver', () {
    // 1 ERG at 3.5 ERG/USE → 0.285 USE (285 base units) costs 0.9975 ERG.
    final note = mintRoundingNote(ergTyped: 1, baseUnits: 285, decimals: 3, ergPerToken: 3.5, shortName: 'USE');
    expect(note, contains('steps of 1/1000'));
    expect(note, contains('0.0025 ERG stays'));
  });

  test('cost rows list token cost, box minimum, both fees and a total that includes the Argus fee', () {
    final p = DexyMintPreview(
      ergCostNano: 541909519,
      txFeeNano: 1100000,
      totalCostNano: 541909519 + 1100000 + 1000000,
      tokenAmount: 1,
      tokenName: 'DexyGold',
      canExecute: true,
    );
    final rows = mintCostRows(p, shortName: 'DexyGold');
    expect(rows.map((r) => r.$1), ['DexyGold cost', 'Token box minimum', 'Miner fee', 'Argus fee', 'Total']);
    expect(rows.last.$2, '0.545109519 ERG');
    expect(rows[3].$2, '0.0011');
  });
}

// Rate guard (added after a USE mint sheet opened against DexyGold state)
void _rateGuardTests() {
  test('mintRateFor refuses a state from the other variant', () {
    final gold = DexyState.fromJson({'state': {}, 'rates': {'variant': 'gold', 'erg_per_token': 0.5454}});
    expect(mintRateFor(gold, DexyVariant.gold), 0.5454);
    expect(mintRateFor(gold, DexyVariant.usd), 0);
  });
}

// Redeem rounding note
void _redeemNoteTests() {
  DexyLpPreview mk({required int dexyOut, required double exact, required int next, required int lp}) => DexyLpPreview.fromJson({
        'action': 'redeem', 'lp_amount': lp, 'erg_out': 978654073, 'dexy_out': dexyOut,
        'dexy_share_exact': exact, 'lp_for_next_unit': next, 'redemption_fee_pct': 2.0,
        'miner_fee_nano': 1100000, 'can_execute': true,
      });

  test('DexyGold: explains the floored unit and the LP for one more', () {
    final note = redeemRoundingNote(mk(dexyOut: 1, exact: 1.818, next: 517, lp: 470), DexyVariant.gold)!;
    expect(note, contains('1.82 DexyGold'));
    expect(note, contains('1 is returned'));
    expect(note, contains('517 LP tokens would return 2'));
  });

  test('no note when the rounding is negligible', () {
    expect(redeemRoundingNote(mk(dexyOut: 2, exact: 2.004, next: 776, lp: 518), DexyVariant.gold), isNull);
  });

  test('no next-unit hint when the user cannot reach it with their LP', () {
    final note = redeemRoundingNote(mk(dexyOut: 1, exact: 1.818, next: 517, lp: 600), DexyVariant.gold)!;
    expect(note, isNot(contains('would return')));
  });
}
