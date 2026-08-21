import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SendPreview.fromJson', () {
    final valid = {
      'preparation_id': 9,
      'recipient': '9abc',
      'amount_nano_erg': 1000000000,
      'miner_fee': 1100000,
      'change_nano_erg': 2000000,
      'input_count': 1,
    };

    test('requires all confirmation fields', () {
      final preview = SendPreview.fromJson(valid);
      expect(preview.preparationId, 9);
      expect(preview.recipient, '9abc');
      expect(preview.amountNanoErg, 1000000000);
      expect(preview.minerFee, 1100000);
      expect(preview.changeNanoErg, 2000000);
      expect(preview.inputCount, 1);
    });

    test('rejects missing or empty recipient', () {
      expect(
        () => SendPreview.fromJson({...valid, 'recipient': ''}),
        throwsFormatException,
      );
      final missing = Map<String, dynamic>.from(valid)..remove('recipient');
      expect(() => SendPreview.fromJson(missing), throwsFormatException);
    });

    test('rejects missing numeric fields', () {
      for (final key in [
        'preparation_id',
        'amount_nano_erg',
        'miner_fee',
        'change_nano_erg',
        'input_count',
      ]) {
        final missing = Map<String, dynamic>.from(valid)..remove(key);
        expect(() => SendPreview.fromJson(missing), throwsFormatException, reason: key);
      }
    });

    test('keeps token fields when present', () {
      final preview = SendPreview.fromJson({
        ...valid,
        'token_id': 'tok',
        'token_amount': 5,
      });
      expect(preview.tokenId, 'tok');
      expect(preview.tokenAmount, 5);
    });

    test('parses advanced input_boxes for the UTXO preview', () {
      final preview = SendPreview.fromJson({
        ...valid,
        'input_boxes': [
          {
            'box_id': '0123456789abcdef',
            'value_nano_erg': '2700000000',
            'creation_height': 100,
            'assets': [],
          },
          {
            'box_id': 'fedcba9876543210',
            'value_nano_erg': 1000000,
            'creation_height': 99,
            'assets': [
              {'token_id': 'nft-token-id', 'amount': '1'},
            ],
          },
        ],
      });
      expect(preview.inputBoxes, isNotEmpty);
      expect(preview.inputBoxes.length, 2);
      expect(preview.inputBoxes[0].boxId, '0123456789abcdef');
      expect(preview.inputBoxes[0].valueNanoErg, BigInt.parse('2700000000'));
      expect(preview.inputBoxes[0].creationHeight, 100);
      expect(preview.inputBoxes[0].assets, isEmpty);
      expect(preview.inputBoxes[1].valueNanoErg, BigInt.from(1000000));
      expect(preview.inputBoxes[1].assets.single.tokenId, 'nft-token-id');
      expect(preview.inputBoxes[1].assets.single.amount, BigInt.one);
    });

    test('input_boxes defaults to empty when absent (legacy preparation)', () {
      final preview = SendPreview.fromJson(valid);
      expect(preview.inputBoxes, isEmpty);
    });

    test('InputBoxInput.fromErgoBox parses camelCase node box response', () {
      final box = InputBoxInput.fromErgoBox({
        'boxId': 'node_box_id_123',
        'value': '3500000000',
        'creationHeight': 1050200,
        'assets': [
          {'tokenId': 'token_abc', 'amount': '500'},
        ],
      }, address: '9addr');
      expect(box.boxId, 'node_box_id_123');
      expect(box.valueNanoErg, BigInt.parse('3500000000'));
      expect(box.creationHeight, 1050200);
      expect(box.assets.length, 1);
      expect(box.assets.single.tokenId, 'token_abc');
      expect(box.assets.single.amount, BigInt.from(500));
      expect(box.address, '9addr');
    });
  });

  group('parseErgToNano', () {
    test('parses whole and fractional ERG', () {
      expect(parseErgToNano('1'), 1000000000);
      expect(parseErgToNano('1.0'), 1000000000);
      expect(parseErgToNano('0.001'), 1000000);
      expect(parseErgToNano('0.000000001'), 1);
      expect(parseErgToNano('.5'), 500000000);
    });

    test('rejects invalid input and extra precision', () {
      expect(parseErgToNano(''), isNull);
      expect(parseErgToNano('abc'), isNull);
      expect(parseErgToNano('1.2.3'), isNull);
      expect(parseErgToNano('-1'), isNull);
      expect(parseErgToNano('0.0000000001'), isNull);
    });
  });

  group('parseDecimalToBase', () {
    test('respects token decimals', () {
      expect(parseDecimalToBase('1', 0), 1);
      expect(parseDecimalToBase('1.50', 2), 150);
      expect(parseDecimalToBase('0.001', 3), 1);
    });

    test('rejects extra fractional digits', () {
      expect(parseDecimalToBase('1.001', 2), isNull);
      expect(parseDecimalToBase('x', 2), isNull);
    });

    test('rejects decimals outside 0-18', () {
      expect(parseDecimalToBase('1', -1), isNull);
      expect(parseDecimalToBase('1', 19), isNull);
    });

    test('rejects values that overflow signed 64-bit', () {
      expect(parseDecimalToBase('99999999999', 18), isNull);
    });
  });

  group('validatePin', () {
    test('enforces length', () {
      expect(validatePin('12345'), isNotNull);
      expect(validatePin('123456'), isNull);
      expect(validatePin('a' * 32), isNull);
      expect(validatePin('a' * 33), isNotNull);
    });
  });

  group('mnemonicWords', () {
    test('normalizes case and whitespace', () {
      expect(
        mnemonicWordsEqual('  Slow   SILLY start  ', 'slow silly start'),
        isTrue,
      );
      expect(mnemonicWords('one two').length, 2);
    });
  });

  group('isAbsoluteHttpUrl', () {
    test('accepts only http(s) with a host', () {
      expect(isAbsoluteHttpUrl('https://ergo-node.eutxo.de'), isTrue);
      expect(isAbsoluteHttpUrl('http://127.0.0.1:9053'), isTrue);
      expect(isAbsoluteHttpUrl('ftp://x'), isFalse);
      expect(isAbsoluteHttpUrl('not a url'), isFalse);
    });
  });

  group('explorerTransactionUrl', () {
    test('opens SigmaSpace and official explorer pages', () {
      expect(
        explorerTransactionUrl('https://api.sigmaspace.io', 'abc'),
        'https://sigmaspace.io/en/transaction/abc',
      );
      expect(
        explorerTransactionUrl('https://api.ergoplatform.com', 'abc'),
        'https://explorer.ergoplatform.com/en/transactions/abc',
      );
    });
  });

  group('normalizeNodeUrl', () {
    test('accepts a bare ip:port as http', () {
      expect(normalizeNodeUrl('104.131.9.252:9053'), 'http://104.131.9.252:9053');
    });

    test('keeps https hosts', () {
      expect(normalizeNodeUrl('https://node.sigmaspace.io/'), 'https://node.sigmaspace.io');
    });
  });

  group('WalletRouteArgs.copyWith', () {
    test('keeps tokens and spendable when replacing the transaction', () {
      final token = TokenBalance(id: 't', amount: 1);
      final base = WalletRouteArgs(
        senderAddress: 'a',
        receiveAddress: 'b',
        changeAddress: 'c',
        historyAddresses: const ['a'],
        tokens: [token],
        spendableNano: 9,
      );
      final next = base.copyWith(transaction: {'tx_id': 'x'});
      expect(next.tokens.single.id, 't');
      expect(next.spendableNano, 9);
      expect(next.transaction?['tx_id'], 'x');
    });
  });
}
