import 'package:argus_wallet/services/token_issuance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('issuance amounts scale exactly by decimals', () {
    expect(parseIssuanceAmount('1000', 0), BigInt.from(1000));
    expect(parseIssuanceAmount('1.5', 2), BigInt.from(150));
    expect(parseIssuanceAmount('1,000,000.25', 2), BigInt.from(100000025));
    expect(parseIssuanceAmount('1.234', 2), isNull, reason: 'more decimals than the token has');
    expect(parseIssuanceAmount('abc', 2), isNull);
  });

  test('an issuance is checked for name, amount, decimals and NFT shape', () {
    expect(issuanceError(name: 'Argus', amountText: '100', decimals: 2, nft: false), isNull);
    expect(issuanceError(name: ' ', amountText: '100', decimals: 2, nft: false), contains('name'));
    expect(issuanceError(name: 'A', amountText: '0', decimals: 0, nft: false), contains('above zero'));
    expect(issuanceError(name: 'A', amountText: '1', decimals: 19, nft: false), contains('Decimals'));
    expect(issuanceError(name: 'Art', amountText: '1', decimals: 0, nft: true), isNull);
    expect(issuanceError(name: 'Art', amountText: '2', decimals: 0, nft: true), contains('one unit'));
    expect(issuanceError(name: 'Art', amountText: '1', decimals: 1, nft: true), contains('no decimals'));
    expect(issuanceError(name: 'Art', amountText: '1', decimals: 0, nft: true, contentHashHex: 'zz'), contains('hash'));
    expect(issuanceError(name: 'Art', amountText: '1', decimals: 0, nft: true, url: 'ftp://x'), contains('Link'));
    expect(issuanceError(name: 'Art', amountText: '1', decimals: 0, nft: true, contentHashHex: 'a' * 64, url: 'ipfs://x'), isNull);
  });
}
