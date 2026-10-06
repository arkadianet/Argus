import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/coin_control.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ListingApi extends RustLibApi {
  final asked = <({List<String> addresses, bool confirmedOnly})>[];
  @override
  Future<BigInt> crateApiWalletRestore({
    required String encryptedSeedJson,
    String? wrapKey,
  }) async => BigInt.one;
  @override
  Future<void> crateApiWalletLock({required BigInt handleId}) async {}

  @override
  Future<String> crateApiMempoolListSpendableBoxes({
    required BigInt handleId,
    required List<String> addresses,
    String? nodeUrl,
    required bool confirmedOnly,
  }) async {
    asked.add((addresses: addresses, confirmedOnly: confirmedOnly));
    return jsonEncode([
      {
        'box_id': 'settled',
        'value_nano_erg': '50000000',
        'creation_height': 100,
        'assets': [],
        'address': 'addr0',
        'confirmed': true,
      },
      if (!confirmedOnly)
        {
          'box_id': 'change',
          'value_nano_erg': '698900000',
          'creation_height': 120,
          'assets': [
            {'token_id': 'tok', 'amount': '4'},
          ],
          'address': 'addr0',
          'confirmed': false,
        },
    ]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final api = ListingApi();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    api.asked.clear();
  });

  group('coin control listing', () {
    setUp(() => walletService.restoreWallet('mock', walletId: 'listing-test'));
    tearDown(() => walletService.lock());

    test('lists what the core offers, with unconfirmed boxes marked', () async {
      final boxes = await walletService.listUnspentBoxes([
        'addr0',
        '',
      ], nodeUrl: '');
      expect(api.asked.single.addresses, ['addr0']);
      expect(api.asked.single.confirmedOnly, isFalse);
      expect(boxes.map((b) => (b.boxId, b.confirmed)), [
        ('settled', true),
        ('change', false),
      ]);
      expect(boxes.last.assets.single.amount, BigInt.from(4));
      expect(boxes.first.address, 'addr0');

      final chosen = summariseSelection(boxes, {'settled', 'change'});
      expect(chosen.unconfirmedCount, 1);
      expect(chosen.totalNanoErg, 748900000);
      expect(
        selectionConfirmationNote(chosen),
        'One of these boxes is still confirming. This transaction can confirm '
        'only after the one that created it, and fails if that one is dropped.',
      );
      expect(
        selectionConfirmationNote(summariseSelection(boxes, {'settled'})),
        isNull,
      );
    });

    test('the mix funding finder can ask for confirmed boxes only', () async {
      final boxes = await walletService.listUnspentBoxes(
        ['addr0'],
        nodeUrl: null,
        confirmedOnly: true,
      );
      expect(api.asked.single.confirmedOnly, isTrue);
      expect(boxes.map((b) => b.boxId), ['settled']);
    });
  });

  test('older listings without the flag read as confirmed', () {
    final box = InputBoxInput.fromJson({
      'box_id': 'b',
      'value_nano_erg': '1',
      'creation_height': 1,
      'assets': [],
    });
    expect(box.confirmed, isTrue);
  });
}
