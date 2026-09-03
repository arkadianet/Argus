import 'package:argus_wallet/services/sigmausd_service.dart';
import 'package:argus_wallet/services/verified_tokens.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registry ids are well-formed and unique', () {
    final ids = verifiedTokens.map((t) => t.id).toList();
    expect(ids.toSet().length, ids.length);
    for (final id in ids) {
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(id), isTrue, reason: id);
    }
  });

  test('protocol constants agree with the registry', () {
    expect(isVerifiedToken(SigmaUsdTokens.sigUsd), isTrue);
    expect(isVerifiedToken(SigmaUsdTokens.sigRsv), isTrue);
    expect(dexyIdsMatchRegistry(), isTrue);
  });

  test('look-alikes are flagged, real ones and unrelated names are not', () {
    final fake = impersonatedToken(tokenId: 'c891f9f39b3a3648a969a8f2f744a4d05478c568ed35fe38e7671bc8832b2c93', name: 'SigUSD');
    expect(fake?.ticker, 'SigUSD');
    expect(impersonatedToken(tokenId: SigmaUsdTokens.sigUsd, name: 'SigUSD'), isNull);
    expect(impersonatedToken(tokenId: 'abc', name: 'My NFT #4'), isNull);
    expect(impersonatedToken(tokenId: 'abc', name: 'rsn'), isNotNull);
  });

  test('labels name the project only when it differs', () {
    final labels = verifiedTokenLabels();
    expect(labels['8b08cdd5449a9592a9e79711d7d79249d7a03c535d17efaee83e216e80a44c4b'], 'RSN (Rosen Bridge)');
    expect(labels['0cd8c9f416e5b1ca9f986a7f10a84191dfb85941619e49e53c0dc30ebf83324b'], 'COMET');
  });

  test('cautioned tokens are known but not verified', () {
    const neta = '472c3d4ecaa08fb7392ff041ee2e6af75f4a558810a74b28600549d5392810e8';
    expect(isVerifiedToken(neta), isFalse);
    expect(cautionedToken(neta)?.note, contains('abandoned'));
    expect(verifiedTokenLabels().containsKey(neta), isFalse);
    expect(impersonatedToken(tokenId: neta, name: 'NETA'), isNull);
  });

  test('Rosen map entries are present and well-formed', () {
    expect(isVerifiedToken('e023c5f382b6e96fbd878f6811aac73345489032157ad5affb84aefd4956c297'), isTrue); // rsADA
    expect(isVerifiedToken('886b7721bef42f60c6317d37d8752da8aca01898cae7dae61808c4a14225edc8'), isTrue); // GluonW GAU
    expect(verifiedToken('203ef3066a912f35c488487cc2cb94bdb0d30680dab22551c7e6fdbc70dfcc8e')?.project, 'Rosen Bridge'); // rsETH
    expect(verifiedTokens.length, greaterThan(50));
  });
}
