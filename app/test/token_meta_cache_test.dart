import 'dart:convert';

import 'package:argus_wallet/services/wallet_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the legacy app-wide table is still readable', () async {
    // Written by builds before descriptors were stored per wallet. It is
    // never written again, but names known then must not vanish.
    SharedPreferences.setMockInitialValues({
      'argus_token_meta_v2': jsonEncode({
        'tok': {
          'name': 'Tok',
          'decimals': 2,
          'emissionAmount': 1000,
          'iconUrl': 'https://x/icon.png',
        },
      }),
    });
    final svc = WalletService();
    await svc.loadTokenMeta();
    // Rust is not initialised in tests, so a cache miss would throw.
    final meta = await svc.tokenMeta('tok', 7);

    expect(meta.amount, 7);
    expect(meta.name, 'Tok');
    expect(meta.decimals, 2);
    expect(meta.emissionAmount, 1000);
    expect(meta.iconUrl, 'https://x/icon.png');
  });

  test('legacy records carry no evidence, so they load as partial', () async {
    SharedPreferences.setMockInitialValues({
      'argus_token_meta_v2': jsonEncode({
        'tok': {'name': 'Tok', 'decimals': 0},
      }),
    });
    final svc = WalletService();
    await svc.loadTokenMeta();
    final meta = await svc.tokenMeta('tok', 1);
    expect(meta.metadataState, MetadataState.partial,
        reason: 'a name without provenance is not a complete descriptor');
  });

  test('persisting without an active wallet writes nothing', () async {
    // Descriptors are wallet-scoped; there is no app-wide table to fall back
    // to, so a write with no wallet selected must be a no-op rather than
    // landing somewhere shared.
    final svc = WalletService();
    svc.rememberTokenMeta(TokenBalance(id: 'tok', amount: 0, name: 'Tok'));
    await svc.persistTokenMeta();

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getKeys().where((k) => k.startsWith('argus_token_descriptors_v1_')),
      isEmpty,
    );
  });

  test('loadTokenMeta tolerates a corrupt entry', () async {
    SharedPreferences.setMockInitialValues({'argus_token_meta_v2': 'not json'});
    final svc = WalletService();
    await svc.loadTokenMeta();
    expect(svc.cachedTokenMetaCount, 0);
  });
}
