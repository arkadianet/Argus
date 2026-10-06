import 'package:argus_wallet/services/storage_rent.dart';
import 'package:argus_wallet/services/utxo_plans.dart';
import 'package:argus_wallet/services/utxo_tools_controller.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:flutter_test/flutter_test.dart';

InputBoxInput box(
  String id, {
  String address = 'A',
  int nano = 1000000000,
  int height = 1000000,
  List<InputAsset> assets = const [],
}) => InputBoxInput(
  boxId: id,
  address: address,
  valueNanoErg: BigInt.from(nano),
  creationHeight: height,
  assets: assets,
);

BoxRent rent(
  String id, {
  int blocksUntilDue = 500000,
  RentCharge charge = RentCharge.fee,
}) => BoxRent(
  boxId: id,
  valueNano: 0,
  creationHeight: 0,
  sizeBytes: 110,
  feeNano: 137500000,
  charge: charge,
  chargeNano: 0,
  dueHeight: 0,
  blocksUntilDue: blocksUntilDue,
  collectableNow: blocksUntilDue <= 1,
);

final nft = [InputAsset(tokenId: 'nft', amount: BigInt.one)];

void main() {
  group('suggested cleanup', () {
    test('a tidy wallet with nothing due needs no cleanup', () {
      final boxes = [box('a'), box('b'), box('c')];
      expect(suggestCleanup(boxes: boxes), isNull);
      expect(suggestCleanup(boxes: boxes, rent: {'a': rent('a')}), isNull);
    });

    test(
      'a tidy wallet moves only its flagged boxes, funded by the largest ERG box',
      () {
        final boxes = [
          box('due', nano: 1000000, assets: nft, height: 600000),
          box('small', nano: 2000000000),
          box('big', nano: 9000000000),
          box('elsewhere', address: 'B', nano: 50000000000),
        ];
        final s = suggestCleanup(
          boxes: boxes,
          rent: {'due': rent('due', blocksUntilDue: 100)},
        )!;
        expect(s.address, 'A');
        expect(s.boxIds, ['due', 'big']);
        expect(s.forRent, isTrue);
        expect(s.dueSoonCount, 1);
        expect(s.atRiskCount, 0);
        expect(s.leftAtAddress, 1);
        expect(s.totalNano, BigInt.from(9001000000));
        expect(s.afterFeesNano, BigInt.from(9001000000 - 2200000));
        expect(s.tokens, {'nft': BigInt.one});
      },
    );

    test('at-risk boxes are counted once, ahead of boxes merely due', () {
      final boxes = [
        box('risky', nano: 1000000, assets: nft),
        box('due', nano: 3000000000, height: 500000),
        box('fund', nano: 5000000000),
      ];
      final s = suggestCleanup(
        boxes: boxes,
        rent: {
          'risky': rent(
            'risky',
            blocksUntilDue: 10,
            charge: RentCharge.wholeBox,
          ),
          'due': rent('due', blocksUntilDue: 20000),
        },
      )!;
      expect(s.atRiskCount, 1);
      expect(s.dueSoonCount, 1);
      expect(s.rentResetCount, 2);
      expect(s.boxIds.toSet(), {'risky', 'due', 'fund'});
    });

    test('only boxes at one address are merged, never across addresses', () {
      final boxes = [
        box('a1'),
        box('a2'),
        box('a3'),
        box('b1', address: 'B', nano: 1000000, assets: nft),
        box('b2', address: 'B', nano: 4000000000),
      ];
      final s = suggestCleanup(
        boxes: boxes,
        rent: {'b1': rent('b1', charge: RentCharge.wholeBox)},
      )!;
      expect(s.address, 'B');
      expect(s.boxIds, ['b1', 'b2']);
      expect(s.boxes.every((b) => b.address == 'B'), isTrue);
    });

    test('the address with the most flagged boxes wins over the biggest', () {
      final boxes = [
        for (var i = 0; i < 10; i++) box('a$i'),
        box('b1', address: 'B', height: 1),
        box('b2', address: 'B', height: 2),
        box('b3', address: 'B'),
      ];
      final s = suggestCleanup(
        boxes: boxes,
        rent: {
          'a0': rent('a0', blocksUntilDue: 5),
          'b1': rent('b1', blocksUntilDue: 5),
          'b2': rent('b2', blocksUntilDue: 5),
        },
      )!;
      expect(s.address, 'B');
    });

    test('mixed, reserved and moving boxes stay put', () {
      final boxes = [
        box('due', nano: 1000000, assets: nft),
        box('mixed', nano: 9000000000),
      ];
      final flagged = {'due': rent('due', charge: RentCharge.wholeBox)};
      expect(
        suggestCleanup(boxes: boxes, rent: flagged, exclude: {'mixed'}),
        isNull,
      );
      expect(suggestCleanup(boxes: boxes, rent: flagged)!.boxIds, [
        'due',
        'mixed',
      ]);
    });

    test('a lone flagged token box borrows the largest other box', () {
      final boxes = [
        box('due', nano: 1000000, assets: nft),
        box(
          'other',
          nano: 2000000000,
          assets: [InputAsset(tokenId: 'sig', amount: BigInt.from(5))],
        ),
      ];
      final s = suggestCleanup(
        boxes: boxes,
        rent: {'due': rent('due', blocksUntilDue: 1)},
      )!;
      expect(s.boxIds, ['due', 'other']);
      expect(s.tokens.keys, ['nft', 'sig']);
    });

    test('a cleanup that cannot pay its fees is not proposed', () {
      final boxes = [
        box('d1', nano: 1000000, assets: nft),
        box('d2', nano: 1000000),
      ];
      expect(
        suggestCleanup(
          boxes: boxes,
          rent: {'d1': rent('d1', charge: RentCharge.wholeBox)},
        ),
        isNull,
      );
    });

    test(
      'a fragmented wallet merges up to the input cap, dust and old first',
      () {
        final boxes = [
          for (var i = 0; i < 150; i++)
            box(
              'x${i.toString().padLeft(3, '0')}',
              nano: i < 40 ? 50000000 : 2000000000,
              height: 1000000 + i,
            ),
          box('whale', nano: 900000000000, height: 1500000),
          box('other', address: 'B'),
          box('other2', address: 'B'),
        ];
        final s = suggestCleanup(boxes: boxes)!;
        expect(s.address, 'A');
        expect(s.forRent, isFalse);
        expect(s.boxes.length, consolidationMaxInputs);
        // Dust first, then by age; the address's largest ERG box funds it.
        expect(s.boxIds.take(40), [
          for (var i = 0; i < 40; i++) 'x${i.toString().padLeft(3, '0')}',
        ]);
        expect(s.boxIds.last, 'whale');
        expect(s.leftAtAddress, 151 - consolidationMaxInputs);
      },
    );

    test('below the home-screen threshold, box count alone is no reason', () {
      final boxes = [
        for (var i = 0; i < utxoFragmentationThreshold; i++) box('b$i'),
      ];
      expect(suggestCleanup(boxes: boxes), isNull);
      expect(suggestCleanup(boxes: [...boxes, box('one-more')]), isNotNull);
    });
  });

  test('the rent filter keeps flagged boxes only', () {
    final tools = UtxoToolsController()
      ..setBoxes([box('a'), box('b'), box('c')]);
    expect(tools.rentFlaggedCount, 0);
    tools.setRent({
      'a': rent('a', charge: RentCharge.wholeBox),
      'b': rent('b', blocksUntilDue: 900000),
      'c': rent('c', blocksUntilDue: 1),
    });
    tools.setFilter(UtxoFilter.rent);
    expect(tools.filtered.map((b) => b.boxId), ['a', 'c']);
    expect(tools.rentFlaggedCount, 2);
    // A failed refresh hides the Rent chip, so its filter cannot linger.
    tools.setRent(const {});
    expect(tools.filter, UtxoFilter.all);
    expect(tools.filtered, hasLength(3));
  });
}
