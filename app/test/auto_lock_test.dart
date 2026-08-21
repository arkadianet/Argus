import 'package:argus_wallet/services/session_lock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('loadGrace reads persisted timeout', () async {
    SharedPreferences.setMockInitialValues({'argus_auto_lock_seconds': 30});
    final lock = SessionLock(onLock: () {});
    await lock.loadGrace();
    expect(lock.grace, const Duration(seconds: 30));
  });

  test('loadGrace defaults to 2 seconds when unset', () async {
    final lock = SessionLock(onLock: () {});
    await lock.loadGrace();
    expect(lock.grace, const Duration(seconds: 2));
  });

  test('setGrace persists and applies', () async {
    final lock = SessionLock(onLock: () {});
    await lock.setGrace(const Duration(seconds: 60));
    expect(lock.grace, const Duration(seconds: 60));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('argus_auto_lock_seconds'), 60);
  });
}
