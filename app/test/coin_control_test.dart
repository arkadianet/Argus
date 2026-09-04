import 'package:argus_wallet/services/app_fee.dart';
import 'package:argus_wallet/services/coin_control.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:flutter_test/flutter_test.dart';

InputBoxInput box(String id, int nano, {String? address, List<(String, int)> assets = const []}) =>
    InputBoxInput(
      boxId: id,
      valueNanoErg: BigInt.from(nano),
      creationHeight: 1,
      address: address,
      assets: [
        for (final a in assets)
          InputAsset(tokenId: a.$1, amount: BigInt.from(a.$2)),
      ],
    );

void main() {
  final all = [
    box('a', 1000000000, address: '9addrA'),
    box('b', 500000000, address: '9addrA'),
    box('c', 3000000000, address: '9addrB', assets: [('sig', 250)]),
  ];

  test('summarises only the chosen boxes', () {
    final s = summariseSelection(all, {'a', 'c'});
    expect(s.count, 2);
    expect(s.totalNanoErg, 4000000000);
    expect(s.tokens['sig'], BigInt.from(250));
    expect(s.addresses, {'9addrA', '9addrB'});
  });

  test('warns when a selection links separate addresses', () {
    expect(selectionPrivacyNote(summariseSelection(all, {'a', 'c'})), contains('links those'));
    // Same address: nothing new is revealed.
    expect(selectionPrivacyNote(summariseSelection(all, {'a', 'b'})), isNull);
    expect(selectionPrivacyNote(summariseSelection(all, {'a'})), isNull);
  });

  test('reports a shortfall before the build fails', () {
    final check = checkSelection(
      selection: summariseSelection(all, {'b'}),
      amountNanoErg: 1000000000,
      feeNanoErg: minerFeeDefaultNano,
      appFeeNanoErg: argusFeeNano,
    );
    expect(check.covers, isFalse);
    expect(check.shortfallNano, greaterThan(0));
  });

  test('change is what is left after the amount and both fees', () {
    final check = checkSelection(
      selection: summariseSelection(all, {'a'}),
      amountNanoErg: 500000000,
      feeNanoErg: minerFeeDefaultNano,
      appFeeNanoErg: argusFeeNano,
    );
    expect(check.covers, isTrue);
    expect(check.changeNano, 1000000000 - 500000000 - minerFeeDefaultNano - argusFeeNano);
  });

  test('an empty selection means automatic selection', () {
    final s = summariseSelection(all, {});
    expect(s.isEmpty, isTrue);
    expect(selectionSummary(s), contains('Argus will pick'));
  });
}
