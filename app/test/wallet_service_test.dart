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
  });

  group('validatePin', () {
    test('enforces length', () {
      expect(validatePin('12345'), isNotNull);
      expect(validatePin('123456'), isNull);
      expect(validatePin('a' * 32), isNull);
      expect(validatePin('a' * 33), isNotNull);
    });
  });
}
