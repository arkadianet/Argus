import 'package:argus_wallet/format.dart';
import 'package:argus_wallet/services/stealth_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/ui/send_recipients.dart';
import 'package:flutter_test/flutter_test.dart';

/// A real mainnet-shaped stealth string: 'stealth' + Base58 of a 33-byte key
/// plus a 4-byte checksum. Checksum validity is a Rust concern; these tests
/// cover the pure-Dart shape check the form uses before it gets there.
const stealthAddr =
    'stealth2Zc5nJHNTZmnKSyfnCsQrkVW42s9dhoNUmm5bxLrDBnwuGSaSQ';
const ergoAddr = '9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8';

void main() {
  group('recipient recognition', () {
    test('a stealth string is a recipient but not an Ergo address', () {
      expect(looksLikeStealthAddress(stealthAddr), isTrue);
      expect(looksLikeErgoAddress(stealthAddr), isFalse);
      expect(looksLikeRecipient(stealthAddr), isTrue);
    });

    test('an ordinary P2PK address is still accepted', () {
      expect(looksLikeRecipient(ergoAddr), isTrue);
      expect(looksLikeStealthAddress(ergoAddr), isFalse);
    });

    test('surrounding whitespace is tolerated', () {
      expect(looksLikeStealthAddress('  $stealthAddr\n'), isTrue);
    });

    test('rejects a bare prefix, wrong prefix and non-Base58 characters', () {
      expect(looksLikeStealthAddress('stealth'), isFalse);
      expect(looksLikeStealthAddress('Stealth$stealthAddr'), isFalse);
      expect(looksLikeStealthAddress('stealth0OIl0OIl0OIl'), isFalse);
      expect(looksLikeRecipient(''), isFalse);
      expect(looksLikeRecipient('not an address'), isFalse);
    });

    test('rejects a stealth string of the wrong length', () {
      expect(looksLikeStealthAddress('stealth${'a' * 20}'), isFalse);
      expect(looksLikeStealthAddress('stealth${'a' * 80}'), isFalse);
    });
  });

  group('buildRecipients', () {
    test('marks a stealth recipient and keeps the published string', () {
      final out = buildRecipients(
        [RecipientDraft(address: stealthAddr, ergText: '1')],
        tokens: const [],
      );
      expect(out.single['address'], stealthAddr);
      expect(out.single['stealth'], isTrue);
      expect(hasStealthRecipient(out), isTrue);
    });

    test('leaves an ordinary recipient unmarked', () {
      final out = buildRecipients(
        [RecipientDraft(address: ergoAddr, ergText: '1')],
        tokens: const [],
      );
      expect(out.single.containsKey('stealth'), isFalse);
      expect(hasStealthRecipient(out), isFalse);
    });

    test('the error names both accepted forms', () {
      expect(
        () => buildRecipients(
          [RecipientDraft(address: 'nope', ergText: '1')],
          tokens: const [],
        ),
        throwsA(isA<SendFormException>().having(
          (e) => e.message,
          'message',
          contains('stealth'),
        )),
      );
    });

    test('a stealth recipient can still carry a token', () {
      final usd = TokenBalance(id: 'usd', amount: 500, name: 'USD', decimals: 2);
      final out = buildRecipients(
        [
          RecipientDraft(
            address: stealthAddr,
            ergText: '0.001',
            tokenId: 'usd',
            tokenAmountText: '1',
          )
        ],
        tokens: [usd],
      );
      expect(out.single['stealth'], isTrue);
      expect(out.single['token_amount'], 100);
    });
  });

  group('StealthScanResult', () {
    test('parses the Rust scan payload', () {
      final r = StealthScanResult.fromJson({
        'scanned': 20,
        'owned_count': 2,
        'total_nano_erg': 1500000000,
        'tokens': [
          {'token_id': 'aa', 'amount': '7'},
        ],
        'boxes': [
          {'box_id': 'b1'},
          {'box_id': 'b2'},
        ],
      });
      expect(r.scanned, 20);
      expect(r.ownedCount, 2);
      expect(r.totalNanoErg, 1500000000);
      expect(r.tokens.single.id, 'aa');
      expect(r.tokens.single.amount, BigInt.from(7));
      expect(r.boxIds, ['b1', 'b2']);
      expect(r.isEmpty, isFalse);
    });

    test('an empty payload is an empty result, not a crash', () {
      final r = StealthScanResult.fromJson(const {});
      expect(r.isEmpty, isTrue);
      expect(r.totalNanoErg, 0);
      expect(r.tokens, isEmpty);
    });

    test('token amounts beyond 64 bits survive as BigInt', () {
      final r = StealthScanResult.fromJson({
        'tokens': [
          {'token_id': 'big', 'amount': '18446744073709551615'},
        ],
      });
      expect(r.tokens.single.amount, BigInt.parse('18446744073709551615'));
    });
  });

  group('mergeStealthTokens', () {
    final usd = TokenBalance(id: 'usd', amount: 500, name: 'USD', decimals: 2);

    test('adds a stealth-only token to the list', () {
      final merged = mergeStealthTokens(
        [usd],
        [TokenBalance(id: 'aa', amount: 7, stealthAmount: 7)],
      );
      expect(merged.length, 2);
      final aa = merged.firstWhere((t) => t.id == 'aa');
      expect(aa.hasStealth, isTrue);
      expect(aa.stealthAmount, 7);
    });

    test('sums a token held both ways and keeps its metadata', () {
      final merged = mergeStealthTokens(
        [usd],
        [TokenBalance(id: 'usd', amount: 250, stealthAmount: 250)],
      );
      expect(merged.single.amount, 750);
      expect(merged.single.stealthAmount, 250);
      expect(merged.single.name, 'USD');
      expect(merged.single.decimals, 2);
    });

    test('no stealth tokens leaves the list untouched', () {
      final merged = mergeStealthTokens([usd], const []);
      expect(merged.single.id, 'usd');
      expect(merged.single.amount, 500);
      expect(merged.single.hasStealth, isFalse);
    });
  });

  group('shortStealth', () {
    test('keeps the marker visible and elides the middle', () {
      final short = shortStealth(stealthAddr);
      expect(short.startsWith('stealth'), isTrue);
      expect(short.contains('…'), isTrue);
      expect(short.length, lessThan(stealthAddr.length));
    });

    test('a short string is returned unchanged', () {
      expect(shortStealth('stealth1'), 'stealth1');
    });
  });
}
