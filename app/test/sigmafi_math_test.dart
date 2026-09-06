import 'package:argus_wallet/services/sigmafi_math.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('repayment adds the interest to the loan, rounding up', () {
    expect(repaymentFor(10000000000, 500), 10500000000);
    expect(repaymentFor(199, 500), 209); // 9.95 rounds up
    expect(repaymentFor(100, 0), 100);
  });

  test('interest is the premium over the loan, in percent', () {
    expect(interestPercent(10000000000, 10500000000), closeTo(5.0, 1e-9));
    expect(interestPercent(0, 5), 0);
  });

  test('apr scales the interest to a year of two-minute blocks', () {
    expect(aprPercent(5.0, 21600), closeTo(60.833, 0.01));
    expect(aprPercent(4.0, 259200), closeTo(4.0556, 0.001));
    expect(aprPercent(5.0, 0), 0);
  });

  test('days and blocks convert at 720 blocks a day', () {
    expect(blocksForDays(30), 21600);
    expect(daysForBlocks(21600), 30);
    expect(daysForBlocks(720 * 365), 365);
  });

  test('fees follow the contract: 0.5% to SigmaFi, 0.4% to the interface', () {
    expect(devFee(10000000000), 50000000);
    expect(uiFee(10000000000), 40000000);
    expect(devFee(199999), 999);
    expect(lenderCost(10000000000), 10090000000);
  });

  test('a term must be over 30 blocks and under the storage rent period', () {
    expect(termError(30), isNotNull);
    expect(termError(31), isNull);
    expect(termError(1051200), isNotNull);
    expect(termError(1051199), isNull);
  });
}
