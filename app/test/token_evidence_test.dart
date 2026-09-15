import 'dart:io';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/ui/send_recipients.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TokenBalance token({
    int? emission,
    int amount = 1,
    DeclaredAssetKind kind = DeclaredAssetKind.none,
    MetadataState state = MetadataState.complete,
    DecimalsEvidence decimals = DecimalsEvidence.valid,
  }) => TokenBalance(
    id: 'token',
    amount: amount,
    emissionAmount: emission,
    decimals: 0,
    supplyEvidence: emission == null
        ? SupplyEvidence.unknown
        : SupplyEvidence.originalEmission,
    decimalsEvidence: decimals,
    declaredAssetKind: kind,
    metadataState: state,
  );
  test(
    'classification table uses original emission, never current holding',
    () {
      expect(token(emission: 21000000000).isCollectible, isFalse);
      expect(token().isCollectible, isFalse);
      expect(token(emission: 1).classification, 'Single-unit token');
      expect(
        token(emission: 1, decimals: DecimalsEvidence.unknown).isCollectible,
        isFalse,
      );
      expect(
        token(emission: 20, kind: DeclaredAssetKind.picture).classification,
        'Declared artwork · multiple units',
      );
      expect(
        token(kind: DeclaredAssetKind.picture).classification,
        'Declared artwork · supply unconfirmed',
      );
      expect(
        token(emission: 10, kind: DeclaredAssetKind.collection).classification,
        'Collection token',
      );
      expect(
        token(kind: DeclaredAssetKind.unsupported).classification,
        'Declared NFT · unsupported type',
      );
      for (final state in [MetadataState.invalid, MetadataState.conflict]) {
        expect(
          token(
            emission: 1,
            kind: DeclaredAssetKind.picture,
            state: state,
          ).isCollectible,
          isFalse,
        );
      }
    },
  );
  test(
    'classification and media status cannot change transaction identity or quantities',
    () {
      const address = '9hXQzT1jJdfLmMGA4rH5QMW2EK9QVnWYyRvVGHKP8pqvS2tVK9t';
      for (final amount in [1, 23]) {
        final baseline = buildRecipients(
          [
            RecipientDraft(
              address: address,
              ergText: '0.001',
              tokenId: 'token',
              tokenAmountText: '1',
            ),
          ],
          tokens: [token(amount: amount)],
        );
        for (final kind in DeclaredAssetKind.values) {
          for (final state in MetadataState.values) {
            final result = buildRecipients(
              [
                RecipientDraft(
                  address: address,
                  ergText: '0.001',
                  tokenId: 'token',
                  tokenAmountText: '1',
                ),
              ],
              tokens: [
                token(amount: amount, emission: 1, kind: kind, state: state),
              ],
            );
            expect(result, baseline);
          }
        }
      }
    },
  );
  test('spending code has no dependency on classification evidence', () {
    for (final path in [
      'lib/ui/send_screen.dart',
      'lib/ui/send_recipients.dart',
      'lib/ui/token_tools_screen.dart',
      'lib/ui/liquidity_screen.dart',
      'lib/services/token_router.dart',
    ]) {
      final source = File(path).readAsStringSync();
      for (final field in [
        'isCollectible',
        'isNft',
        'declaredAssetKind',
        'supplyEvidence',
        'mediaState',
      ]) {
        expect(
          source.contains(field),
          isFalse,
          reason: '$path must not depend on $field',
        );
      }
    }
  });
  test('control and bidi overrides cannot escape bounded issuer text', () {
    const hostile = 'Real\u202e\u2066\u0000\u0001\u007f\u0085Name';
    expect(issuerText(hostile), 'RealName');
    expect(TokenBalance(id: 'id', amount: 1, name: hostile).label, 'RealName');
    expect(issuerText('a' * 10000).length, 256);
    expect(issuerText('a' * 10000, limit: 4096).length, 4096);
  });
}
