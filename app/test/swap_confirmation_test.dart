import 'package:argus_wallet/services/amm_service.dart';
import 'package:argus_wallet/ui/swap_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('review shows the token debit separately from ERG fees', () {
    const build = AmmSwapBuild(preparationId: 1, inputAmount: 12345,
      inputToken: 'token', outputAmount: 2000000000, outputToken: '',
      minOutput: 1900000000, minerFee: 1100000, totalErgCost: 2200000);
    final row = swapInputRow(build, symbol: 'SigUSD', decimals: 2);
    expect(row.label, 'You pay');
    expect(row.value, '123.45 SigUSD');
  });
}
