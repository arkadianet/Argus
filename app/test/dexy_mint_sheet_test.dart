import 'package:argus_wallet/services/dexy_service.dart';
import 'package:argus_wallet/ui/dexy/dexy_sheets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
