import 'package:argus_wallet/services/ergopay_summary.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final json = {
    'tx_id': 'abc',
    'inputs': [
      {'box_id': 'b1', 'value_nano_erg': 2000000000, 'tokens': [], 'address': '9me', 'owned': true},
    ],
    'outputs': [
      {'address': '9you', 'value_nano_erg': 1000000000, 'tokens': [{'id': 'tok', 'amount': 4}], 'kind': 'recipient'},
      {'address': '9me', 'value_nano_erg': 998900000, 'tokens': [], 'kind': 'change'},
      {'address': 'fee', 'value_nano_erg': 1100000, 'tokens': [], 'kind': 'fee'},
    ],
    'fee_nano_erg': 1100000,
    'sent_nano_erg': 1000000000,
    'change_nano_erg': 998900000,
    'spend_nano_erg': 1001100000,
    'input_nano_erg': 2000000000,
    'inputs_known': true,
    'all_inputs_owned': true,
    'tokens_out': [{'id': 'tok', 'amount': 4}],
    'tokens_back': [],
    'data_inputs': 0,
  };

  test('parses totals and recipients', () {
    final s = ErgoPaySummary.fromJson(json);
    expect(s.feeNano, 1100000);
    expect(s.sentNano, 1000000000);
    expect(s.spendNano, 1001100000);
    expect(s.recipients.single.address, '9you');
    expect(s.tokensOut.single.amount, 4);
    expect(s.inputsKnown, isTrue);
  });

  test('confirm rows name the token from wallet metadata', () {
    final s = ErgoPaySummary.fromJson(json);
    final rows = s.confirmRows(tokens: [TokenBalance(id: 'tok', amount: 9, name: 'Tok', decimals: 1)]);
    final labels = rows.map((r) => r.label).toList();
    expect(labels, contains('You spend'));
    expect(labels, contains('Miner fee'));
    expect(rows.firstWhere((r) => r.label == 'Tokens out').value, '0.4 Tok');
    expect(rows.firstWhere((r) => r.label == 'You spend').value, '1.0011 ERG');
  });

  test('unknown inputs drop the spend row and flag it', () {
    final s = ErgoPaySummary.fromJson({...json, 'inputs_known': false, 'spend_nano_erg': null});
    final rows = s.confirmRows(tokens: const []);
    expect(rows.map((r) => r.label), isNot(contains('You spend')));
    expect(s.warning, isNotNull);
  });

  test('inputs not owned by the wallet raise a warning', () {
    final s = ErgoPaySummary.fromJson({...json, 'all_inputs_owned': false});
    expect(s.warning, contains('not from this wallet'));
  });
}
