import 'package:argus_wallet/services/wallet_database_service.dart';
import 'package:argus_wallet/services/wallet_sync_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'C: public-only status survives the existing active cache gateway',
    () async {
      SharedPreferences.setMockInitialValues({});
      await const LiveWalletSyncGateway().saveCachedState({
        'wallet_id': 'locked',
        'primary_address': 'known',
        'used_addresses': <Map<String, dynamic>>[],
        'balance_nano_erg': 7,
        'tokens': <Map<String, dynamic>>[],
        'transactions': <Map<String, dynamic>>[],
        'utxo_count': 0,
        'public_only': true,
      });
      final saved = await WalletDatabaseService.loadCachedState(
        expectedWalletId: 'locked',
      );
      expect(saved!['public_only'], isTrue);
    },
  );
}
