import 'package:argus_wallet/services/duckpools_math.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 2 ERG of collateral counting as 400 SigUSD cents (4.00 SigUSD), a loan
  // that owes 200 cents on a 140% line: liquidation opens below 280 cents.
  const value = 400, liq = 280, erg = 2000000000, owed = 200, threshold = 1400;

  test('prices per whole unit of collateral', () {
    expect(collateralUnitPrice(collateralValue: value, collateralAmount: erg, collateralDecimals: 9), 200);
    expect(liquidationUnitPrice(liquidationValue: liq, collateralAmount: erg, collateralDecimals: 9), 140);
    expect(collateralUnitPrice(collateralValue: value, collateralAmount: 0, collateralDecimals: 9), 0);
  });

  test('how far the price can fall', () {
    expect(dropToLiquidationPercent(collateralValue: value, liquidationValue: liq), closeTo(30, 1e-9));
    expect(dropToLiquidationPercent(collateralValue: 100, liquidationValue: 120), 0);
  });

  test('health after a price move', () {
    expect(healthAfterPriceChange(14286, -30), closeTo(10000, 1));
    expect(healthAfterPriceChange(20000, -50), 10000);
    expect(healthAfterPriceChange(20000, 10), 22000);
  });

  test('interest, loan-to-value, dates', () {
    expect(interestOver(owed: 100000, aprBps: 500, days: 365), 5000);
    expect(interestOver(owed: 100000, aprBps: 500, days: 30), 411);
    expect(maxLoanToValuePercent(1400), closeTo(71.43, 0.01));
    expect(maxLoanToValuePercent(0), 0);
    final now = DateTime.utc(2026, 9, 6);
    expect(blockDate(720, now), DateTime.utc(2026, 9, 7));
    expect(blockDate(forcedLiquidationBlocks, now).difference(now).inDays, 91);
  });

  test('collateral to reach a health', () {
    expect(collateralValueForHealth(owed: owed, threshold: threshold, targetHealthBps: 15000), 420);
    // 420 needed, 400 held: 20 more cents of value, at 200 cents per ERG.
    expect(extraCollateralForHealth(owed: owed, threshold: threshold, targetHealthBps: 15000, collateralValue: value, collateralAmount: erg), 100000000);
    expect(extraCollateralForHealth(owed: owed, threshold: threshold, targetHealthBps: 12000, collateralValue: value, collateralAmount: erg), 0);
  });
}
