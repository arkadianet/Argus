import 'package:argus_wallet/services/wallet_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  WalletInfo w(String id) => WalletInfo(walletId: id, name: id, createdAt: DateTime(2026));

  test('wallets follow the saved order, unlisted ones keep their place after', () {
    final stored = [w('a'), w('b'), w('c'), w('d')];
    expect(orderWallets(stored, const []).map((x) => x.walletId), ['a', 'b', 'c', 'd']);
    expect(orderWallets(stored, const ['c', 'a']).map((x) => x.walletId), ['c', 'a', 'b', 'd']);
    expect(orderWallets(stored, const ['d', 'zzz', 'b']).map((x) => x.walletId), ['d', 'b', 'a', 'c'],
        reason: 'an id no longer stored is ignored');
  });
}
