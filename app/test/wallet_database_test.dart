import 'package:argus_wallet/services/wallet_database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> save(String id, int nano) => WalletDatabaseService.saveCachedState(
        walletId: id, primaryAddress: 'a', usedAddresses: const [], balanceNano: nano, tokens: const [], transactions: const [], utxoCount: 0);

  test('snapshots are kept per wallet', () async {
    await save('w1', 100);
    await save('w2', 200);
    expect((await WalletDatabaseService.loadCachedState(expectedWalletId: 'w1'))?['balance_nano_erg'], 100);
    expect((await WalletDatabaseService.loadCachedState(expectedWalletId: 'w2'))?['balance_nano_erg'], 200);
    expect(await WalletDatabaseService.loadCachedState(expectedWalletId: 'w3'), isNull);
  });

  test('last known balance reports amount and age', () async {
    await save('w1', 100);
    final known = await WalletDatabaseService.lastKnownBalance('w1');
    expect(known?.balanceNano, 100);
    expect(known!.age, lessThan(const Duration(seconds: 5)));
    expect(await WalletDatabaseService.lastKnownBalance('nope'), isNull);
  });

  test('deleting a wallet drops its snapshot', () async {
    await save('w1', 100);
    await WalletDatabaseService.clearWallet('w1');
    expect(await WalletDatabaseService.loadCachedState(expectedWalletId: 'w1'), isNull);
  });
}
