import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/ui/send_recipients.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final usd = TokenBalance(id: 'usd', amount: 500, name: 'USD', decimals: 2);
  final nft = TokenBalance(id: 'nft', amount: 1, name: 'Art', decimals: 0);
  const addr = '9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8';

  test('a plain ERG recipient becomes one entry in nanoERG', () {
    final out = buildRecipients(
      [RecipientDraft(address: addr, ergText: '1.5')],
      tokens: [usd],
    );
    expect(out, [
      {'address': addr, 'amount_nano_erg': 1500000000},
    ]);
  });

  test('a token recipient parses the amount in base units', () {
    final out = buildRecipients(
      [RecipientDraft(address: addr, ergText: '0.001', tokenId: 'usd', tokenAmountText: '2.5')],
      tokens: [usd],
    );
    expect(out.single['token_id'], 'usd');
    expect(out.single['token_amount'], 250);
  });

  test('an NFT always sends exactly one unit', () {
    final out = buildRecipients(
      [RecipientDraft(address: addr, ergText: '0.001', tokenId: 'nft')],
      tokens: [nft],
    );
    expect(out.single['token_amount'], 1);
  });

  test('rejects a malformed address with the recipient number', () {
    expect(
      () => buildRecipients(
        [
          RecipientDraft(address: addr, ergText: '1'),
          RecipientDraft(address: 'nope', ergText: '1'),
        ],
        tokens: const [],
      ),
      throwsA(isA<SendFormException>()
          .having((e) => e.message, 'message', contains('Recipient 2'))),
    );
  });

  test('rejects an ERG amount under the minimum box value', () {
    expect(
      () => buildRecipients([RecipientDraft(address: addr, ergText: '0.0001')], tokens: const []),
      throwsA(isA<SendFormException>()
          .having((e) => e.message, 'message', contains('0.001'))),
    );
  });

  test('rejects a missing token amount', () {
    expect(
      () => buildRecipients(
        [RecipientDraft(address: addr, ergText: '0.001', tokenId: 'usd', tokenAmountText: '')],
        tokens: [usd],
      ),
      throwsA(isA<SendFormException>()
          .having((e) => e.message, 'message', contains('token amount'))),
    );
  });

  test('rejects a token the wallet does not hold', () {
    expect(
      () => buildRecipients(
        [RecipientDraft(address: addr, ergText: '0.001', tokenId: 'ghost', tokenAmountText: '1')],
        tokens: [usd],
      ),
      throwsA(isA<SendFormException>()),
    );
  });

  test('rejects a token amount above the held balance', () {
    expect(
      () => buildRecipients(
        [RecipientDraft(address: addr, ergText: '0.001', tokenId: 'usd', tokenAmountText: '9')],
        tokens: [usd],
      ),
      throwsA(isA<SendFormException>()
          .having((e) => e.message, 'message', contains('hold'))),
    );
  });

  test('sums total ERG across recipients for the available check', () {
    final out = buildRecipients(
      [
        RecipientDraft(address: addr, ergText: '1'),
        RecipientDraft(address: addr, ergText: '2'),
      ],
      tokens: const [],
    );
    expect(totalNanoErg(out), 3000000000);
  });
}
