import 'package:argus_wallet/ui/widgets/amount_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fiat text converts to ERG text at the rate', () {
    expect(fiatToErgText('2.00', rate: 0.5), '4');
    expect(fiatToErgText('1', rate: 3), '0.333333333');
    expect(fiatToErgText('', rate: 3), '');
    expect(fiatToErgText('abc', rate: 3), isNull);
  });

  test('ERG text converts to fiat text with two decimals', () {
    expect(ergToFiatText('4', rate: 0.5), '2.00');
    expect(ergToFiatText('0.001', rate: 1.2), '0.00');
    expect(ergToFiatText('', rate: 1), '');
  });

  test('jpy uses no decimals', () {
    expect(ergToFiatText('2', rate: 150, decimals: 0), '300');
  });
}
