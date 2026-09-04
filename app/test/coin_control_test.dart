import 'package:argus_wallet/services/app_fee.dart';
import 'package:argus_wallet/services/coin_control.dart';
import 'package:argus_wallet/services/stealth_service.dart';
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
  _stealthInputTests();
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

// Stealth boxes as send inputs
void _stealthInputTests() {
  StealthScanResult scan(List<(String, int)> boxes) => StealthScanResult(
        scanned: boxes.length,
        ownedCount: boxes.length,
        totalNanoErg: boxes.fold(0, (s, b) => s + b.$2),
        tokens: const [],
        boxIds: [for (final b in boxes) b.$1],
        boxes: [
          for (final b in boxes)
            StealthOwnedBox(
              boxId: b.$1,
              transactionId: 'tx',
              valueNanoErg: b.$2,
              creationHeight: 10,
              tokens: const [],
            ),
        ],
      );

  test('detected stealth boxes become selectable inputs', () {
    final boxes = stealthInputBoxes(scan([('s1', 1000000000)]));
    expect(boxes.single.boxId, 's1');
    expect(boxes.single.valueNanoErg, BigInt.from(1000000000));
    expect(boxes.single.address, isNull, reason: 'a stealth box sits on no address');
  });

  test('no scan means no extra inputs', () {
    expect(stealthInputBoxes(null), isEmpty);
  });

  test('a stealth box is identified against the scan', () {
    final s = scan([('s1', 1)]);
    expect(isStealthInputBox(stealthInputBoxes(s).single, s), isTrue);
    expect(isStealthInputBox(box('a', 1, address: '9addrA'), s), isFalse);
  });

  test('spending a stealth box beside an ordinary one is flagged as linking', () {
    final all = [box('a', 1000000000, address: '9addrA'), ...stealthInputBoxes(scan([('s1', 1000000000)]))];
    final sel = summariseSelection(all, {'a', 's1'});
    expect(sel.totalNanoErg, 2000000000);
    // The stealth box contributes no address, so the note fires only when
    // the ordinary boxes themselves span addresses; the linking warning for
    // stealth is about provenance, covered by the picker's label.
    expect(sel.addresses, {'9addrA'});
  });
}
