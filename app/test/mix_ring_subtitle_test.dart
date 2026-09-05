import 'package:argus_wallet/ui/mix_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a ring line names the fee as a share of the amount and flags an expensive one', () {
    // Live figures on 2026-09-05: 0.12 ERG batch plus 0.1% of the amount.
    expect(
      ringSubtitle(value: 1000000000, waiting: 1, operatorFee: 121000000),
      '1 waiting: you could join at once · fees 0.121 ERG (12%), expensive for this amount',
    );
    expect(
      ringSubtitle(value: 10000000000, waiting: 0, operatorFee: 130000000),
      'Nobody waiting: you would post the first box · fees 0.13 ERG (1.3%)',
    );
    expect(
      ringSubtitle(value: 100000000000, waiting: 2, operatorFee: 220000000),
      '2 waiting: you could join at once · fees 0.22 ERG (0.2%)',
    );
    expect(
      ringSubtitle(value: 1000000000, waiting: 0, operatorFee: null),
      'Nobody waiting: you would post the first box',
      reason: 'no batch chosen yet',
    );
  });
}
