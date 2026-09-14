import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/watch_only_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const storedAddress = '9hY16vzHmmfyVBwKeFGHvb2bMFsG94A1u7To1QWtUokACyFVENQ';

class WatchApi extends RustLibApi {
  bool valid = false;
  @override
  Future<String?> crateApiNormalizeWatchInput({required String input}) async =>
      valid ? (input == "key" ? storedAddress : input) : null;
  @override
  Future<bool> crateApiValidateErgoAddress({required String address}) async => valid;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = WatchApi();
  setUpAll(() => RustLib.initMock(api: api));

  test('normalizes before saving and deduplicates key against address', () async {
    SharedPreferences.setMockInitialValues({});
    final service = WatchOnlyService();
    api.valid = true;
    expect(await service.add(' key '), isTrue);
    expect(service.addresses, [storedAddress]);
    expect(await service.add(storedAddress), isFalse);
    api.valid = false;
    expect(await service.add('invalid'), isFalse);
    expect(service.addresses, [storedAddress]);
  });

  test('false validation cannot drop stored addresses on load or unrelated save', () async {
    const key = 'argus_watch_only_addresses';
    SharedPreferences.setMockInitialValues({key: jsonEncode([storedAddress, 'other'])});
    final service = WatchOnlyService();
    api.valid = false;
    await service.load();
    expect(service.addresses, [storedAddress, 'other']);
    await service.remove('other');
    expect(jsonDecode((await SharedPreferences.getInstance()).getString(key)!), [storedAddress]);
    final reloaded = WatchOnlyService();
    await reloaded.load();
    expect(reloaded.addresses, [storedAddress]);
  });
}
