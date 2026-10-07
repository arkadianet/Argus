import 'dart:async';
import 'package:argus_wallet/services/network_controller.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'support/failing_preferences.dart';
import 'dart:convert';
import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/watch_account_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AccountApi extends RustLibApi {
  bool available = false;
  Completer<String>? historyGate;
  @override
  Future<String> crateApiGetBalance({
    required String address,
    String? nodeUrl,
  }) async => '{"balance_nano_erg":0,"tokens":[]}';
  @override
  Future<String> crateApiGetTransactionHistory({
    required String address,
    required List<String> walletAddresses,
    String? nodeUrl,
    required BigInt limit,
    required BigInt offset,
  }) async => historyGate == null ? '[]' : historyGate!.future;

  @override
  Future<List<String>> crateApiDeriveWatchAddresses({
    required String input,
    required int start,
    required int count,
  }) async {
    if (!available) throw StateError('bridge unavailable');
    return List.generate(count, (i) => '${start + i}');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = AccountApi();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    api.available = false;
    api.historyGate = null;
  });
  test('failed account add does not appear saved or start refresh', () async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesStorePlatform.instance = FailingPreferences({});
    api.available = true;
    final service = WatchAccountService();
    addTearDown(service.dispose);
    var notifications = 0;
    service.addListener(() => notifications++);
    await expectLater(service.add('key'), throwsStateError);
    expect(service.accounts, isEmpty);
    expect(notifications, 0);
  });

  test('failed frontier save makes refresh unavailable', () async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesStorePlatform.instance = FailingPreferences({});
    api.available = true;
    final service = WatchAccountService();
    addTearDown(service.dispose);
    final account = WatchAccount('key');
    service.accounts.add(account);
    await service.refresh(account);
    expect(account.snapshot, isNull);
    expect(account.error, contains('Could not save watched accounts'));
    expect(account.busy, isFalse);
  });

  test('node switch away and back rejects an in-flight scan', () async {
    SharedPreferences.setMockInitialValues({});
    api.available = true;
    api.historyGate = Completer<String>();
    final network = NetworkController()..activeUrl = 'a';
    final service = WatchAccountService(network: network);
    addTearDown(service.dispose);
    addTearDown(network.dispose);
    final account = WatchAccount('key');
    service.accounts.add(account);
    final refresh = service.refresh(account);
    await Future<void>.delayed(Duration.zero);
    for (final node in ['b', 'a']) {
      network.activeUrl = node;
      network.setErgRate(fiatPerErg: 1, usdPerErg: 1);
    }
    api.historyGate!.complete('[]');
    await refresh;
    expect(account.snapshot, isNull);
    expect(account.error, contains('Node changed during scan'));
  });

  test('failed account removal throws and retains persisted account', () async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesStorePlatform.instance = FailingPreferences({
      'flutter.${WatchAccountService.storageKey}': jsonEncode([
        {'key': 'saved-key', 'highestUsed': 32},
      ]),
    });
    final service = WatchAccountService();
    addTearDown(service.dispose);
    await service.load();
    var notifications = 0;
    service.addListener(() => notifications++);
    await expectLater(
      service.remove(service.accounts.single),
      throwsStateError,
    );
    expect(service.accounts.single.key, 'saved-key');
    expect(notifications, 0);
    final restored = WatchAccountService();
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.accounts.single.highestUsed, 32);
  });

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

  test('a label is kept with the key, and a failed save keeps the old one', () async {
    SharedPreferences.setMockInitialValues({
      WatchAccountService.storageKey: jsonEncode([
        {'kind': 'extendedPublicKey', 'key': 'labelled', 'highestUsed': 3},
      ]),
    });
    final service = WatchAccountService();
    addTearDown(service.dispose);
    await service.load();
    expect(service.accounts.single.label, isNull);
    await service.setLabel(service.accounts.single, '  Ledger  ');
    final restored = WatchAccountService();
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.accounts.single.label, 'Ledger');
    expect(restored.accounts.single.highestUsed, 3);
    // Clearing the name drops it from storage again.
    await restored.setLabel(restored.accounts.single, ' ');
    expect(restored.accounts.single.label, isNull);
    final cleared = WatchAccountService();
    addTearDown(cleared.dispose);
    await cleared.load();
    expect(cleared.accounts.single.label, isNull);
    // A write the store refuses leaves the previous name in place.
    await cleared.setLabel(cleared.accounts.single, 'Kept');
    SharedPreferencesStorePlatform.instance = FailingPreferences({});
    addTearDown(() => SharedPreferences.setMockInitialValues({}));
    await expectLater(cleared.setLabel(cleared.accounts.single, 'Lost'), throwsStateError);
    expect(cleared.accounts.single.label, 'Kept');
  });
}
