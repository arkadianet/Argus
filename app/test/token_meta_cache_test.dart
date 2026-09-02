import 'package:argus_wallet/services/wallet_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('token metadata survives a restart', () async {
    final first = WalletService();
    first.rememberTokenMeta(TokenBalance(
      id: 'tok',
      amount: 1,
      name: 'Tok',
      decimals: 2,
      emissionAmount: 1000,
      iconUrl: 'https://x/icon.png',
    ));
    await first.persistTokenMeta();

    final second = WalletService();
    await second.loadTokenMeta();
    // Rust is not initialised in tests, so a cache miss would throw.
    final meta = await second.tokenMeta('tok', 7);

    expect(meta.amount, 7);
    expect(meta.name, 'Tok');
    expect(meta.decimals, 2);
    expect(meta.emissionAmount, 1000);
    expect(meta.iconUrl, 'https://x/icon.png');
  });

  test('loadTokenMeta tolerates a corrupt entry', () async {
    SharedPreferences.setMockInitialValues({'argus_token_meta_v1': 'not json'});
    final svc = WalletService();
    await svc.loadTokenMeta();
    expect(svc.cachedTokenMetaCount, 0);
  });
}
