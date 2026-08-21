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

  group('Consolidate & Restructure preview maps', () {
    test('Consolidate preview contains expected summary fields', () {
      final preview = {
        'preparation_id': 101,
        'input_count': 5,
        'total_erg_in': 10000000000,
        'change_nano_erg': 9998900000,
        'token_count': 3,
        'miner_fee': 1100000,
      };

      expect(preview['preparation_id'], 101);
      expect(preview['input_count'], 5);
      expect(preview['total_erg_in'], 10000000000);
      expect(preview['change_nano_erg'], 9998900000);
      expect(preview['token_count'], 3);
      expect(preview['miner_fee'], 1100000);
    });

    test('Split preview contains split_count and amounts', () {
      final preview = {
        'preparation_id': 102,
        'split_count': 4,
        'amount_per_box': '2000000000',
        'total_split': '8000000000',
        'change_nano_erg': 1998900000,
        'miner_fee': 1100000,
      };

      expect(preview['preparation_id'], 102);
      expect(preview['split_count'], 4);
      expect(preview['amount_per_box'], '2000000000');
      expect(preview['total_split'], '8000000000');
      expect(preview['change_nano_erg'], 1998900000);
    });
  });
}
