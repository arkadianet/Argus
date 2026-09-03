import 'package:argus_wallet/services/privacy_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('hideBalances defaults to false', () async {
    SharedPreferences.setMockInitialValues({});
    final svc = PrivacyService();
    await svc.load();
    expect(svc.hideBalances, isFalse);
  });

  test('hideBalances persists across a reload', () async {
    SharedPreferences.setMockInitialValues({});
    final first = PrivacyService();
    await first.setHideBalances(true);

    final second = PrivacyService();
    await second.load();
    expect(second.hideBalances, isTrue);
  });

  test('blockScreenshots defaults to on and persists when turned off', () async {
    SharedPreferences.setMockInitialValues({});
    final first = PrivacyService();
    await first.load();
    expect(first.blockScreenshots, isTrue);
    await first.setBlockScreenshots(false);

    final second = PrivacyService();
    await second.load();
    expect(second.blockScreenshots, isFalse);
  });
}
