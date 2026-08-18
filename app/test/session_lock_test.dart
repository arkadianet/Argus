import 'package:argus_wallet/services/session_lock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('paused then resumed within grace does not lock', () {
    fakeAsync((async) {
      var locked = 0;
      final lock = SessionLock(
        onLock: () => locked++,
        grace: const Duration(milliseconds: 200),
      );
      lock.onLifecycle(AppLifecycleState.paused);
      async.elapse(const Duration(milliseconds: 100));
      lock.onLifecycle(AppLifecycleState.resumed);
      async.elapse(const Duration(milliseconds: 300));
      expect(locked, 0);
      lock.dispose();
    });
  });

  test('paused past grace locks once', () {
    fakeAsync((async) {
      var locked = 0;
      final lock = SessionLock(
        onLock: () => locked++,
        grace: const Duration(milliseconds: 200),
      );
      lock.onLifecycle(AppLifecycleState.paused);
      async.elapse(const Duration(milliseconds: 250));
      expect(locked, 1);
      lock.dispose();
    });
  });

  test('hidden is treated as background', () {
    fakeAsync((async) {
      var locked = 0;
      final lock = SessionLock(
        onLock: () => locked++,
        grace: const Duration(milliseconds: 50),
      );
      lock.onLifecycle(AppLifecycleState.hidden);
      async.elapse(const Duration(milliseconds: 80));
      expect(locked, 1);
      lock.dispose();
    });
  });

  test('suppressed background does not lock', () {
    fakeAsync((async) {
      var locked = 0;
      final lock = SessionLock(
        onLock: () => locked++,
        grace: const Duration(milliseconds: 50),
      );
      lock.suppress();
      lock.onLifecycle(AppLifecycleState.paused);
      async.elapse(const Duration(milliseconds: 80));
      expect(locked, 0);
      lock.release();
      lock.dispose();
    });
  });

  test('inactive does not lock', () {
    fakeAsync((async) {
      var locked = 0;
      final lock = SessionLock(
        onLock: () => locked++,
        grace: const Duration(milliseconds: 50),
      );
      lock.onLifecycle(AppLifecycleState.inactive);
      async.elapse(const Duration(milliseconds: 80));
      expect(locked, 0);
      lock.dispose();
    });
  });
}
