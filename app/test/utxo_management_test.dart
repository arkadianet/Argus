import 'package:argus_wallet/services/wallet_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UTXO models & parsing', () {
    test('InputBoxInput parses assets and nanoERG correctly', () {
      final box = InputBoxInput.fromJson({
        'box_id': 'box_abc_123',
        'value_nano_erg': '2500000000',
        'creation_height': 1205100,
        'assets': [
          {'token_id': 'token_sigusd', 'amount': '5000'},
          {'token_id': 'token_nft', 'amount': '1'},
        ],
      });

      expect(box.boxId, 'box_abc_123');
      expect(box.valueNanoErg, BigInt.parse('2500000000'));
      expect(box.creationHeight, 1205100);
      expect(box.assets.length, 2);
      expect(box.assets[0].tokenId, 'token_sigusd');
      expect(box.assets[0].amount, BigInt.from(5000));
      expect(box.assets[1].tokenId, 'token_nft');
      expect(box.assets[1].amount, BigInt.one);
    });

    test('InputBoxInput handles missing or empty assets gracefully', () {
      final box = InputBoxInput.fromJson({
        'box_id': 'box_erg_only',
        'value_nano_erg': 1000000000,
        'creation_height': 1200000,
      });

      expect(box.boxId, 'box_erg_only');
      expect(box.valueNanoErg, BigInt.from(1000000000));
      expect(box.assets, isEmpty);
    });
  });

  group('UTXO management previews', () {
    test('parses consolidation payload', () {
      final preview = ConsolidatePreview.fromJson({
        'preparation_id': 101,
        'input_count': 5,
        'total_erg_in': 10000000000,
        'change_nano_erg': 9998900000,
        'token_count': 3,
        'miner_fee': 1100000,
      });

      expect(preview.preparationId, 101);
      expect(preview.inputCount, 5);
      expect(preview.totalErgIn, 10000000000);
      expect(preview.changeNanoErg, 9998900000);
      expect(preview.tokenCount, 3);
      expect(preview.minerFee, minerFeeNano);
    });

    test('parses numeric ERG split amounts without losing their value', () {
      final preview = SplitPreview.fromJson({
        'preparation_id': 102,
        'split_count': 4,
        'amount_per_box': 2000000000,
        'total_split': '8000000000',
        'change_nano_erg': 1998900000,
        'miner_fee': 1100000,
      });

      expect(preview.preparationId, 102);
      expect(preview.splitCount, 4);
      expect(preview.amountPerBox, BigInt.from(2000000000));
      expect(preview.totalSplit, BigInt.from(8000000000));
      expect(preview.changeNanoErg, 1998900000);
    });

    test('parses and validates token split identifiers', () {
      final preview = SplitPreview.fromJson({
        'preparation_id': 103,
        'split_count': 2,
        'token_id': 'token_abc',
        'amount_per_box': '25',
        'total_split': '50',
        'change_nano_erg': 1000000,
        'miner_fee': 1100000,
      });

      expect(preview.tokenId, 'token_abc');
      expect(preview.amountPerBox, BigInt.from(25));
      expect(
        () => SplitPreview.fromJson({
          'preparation_id': 103,
          'split_count': 2,
          'token_id': '',
          'amount_per_box': '25',
          'total_split': '50',
          'change_nano_erg': 1000000,
          'miner_fee': 1100000,
        }),
        throwsFormatException,
      );
    });

    test('parses restructure payload', () {
      final preview = RestructurePreview.fromJson({
        'preparation_id': 104,
        'input_count': 3,
        'output_count': 2,
        'total_erg_in': 5000000000,
        'allocated_erg': 3000000000,
        'change_nano_erg': 1998900000,
        'has_change': true,
        'miner_fee': 1100000,
      });

      expect(preview.preparationId, 104);
      expect(preview.inputCount, 3);
      expect(preview.outputCount, 2);
      expect(preview.hasChange, isTrue);
    });
  });
}
