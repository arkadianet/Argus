import 'dart:convert';
import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/watch_account_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AccountApi extends RustLibApi {
  @override
  Future<List<String>> crateApiDeriveWatchAddresses({
    required String input,
    required int start,
    required int count,
  }) async => throw StateError('bridge unavailable');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => RustLib.initMock(api: AccountApi()));
  test(
    'load preserves extended keys and frontier without bridge validation',
    () async {
      SharedPreferences.setMockInitialValues({
        WatchAccountService.storageKey: jsonEncode([
          {'kind': 'extendedPublicKey', 'key': 'saved-key', 'highestUsed': 32},
          {'kind': 'extendedPublicKey', 'key': 'other', 'highestUsed': -1},
        ]),
      });
      final service = WatchAccountService();
      await service.load();
      expect(service.accounts.first.highestUsed, 32);
      await service.remove(service.accounts.last);
      await expectLater(service.add('invalid'), throwsStateError);
      final restored = WatchAccountService();
      await restored.load();
      expect(restored.accounts.single.key, 'saved-key');
      expect(restored.accounts.single.highestUsed, 32);
    },
  );
}
