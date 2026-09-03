import 'package:argus_wallet/services/ttl_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('serves the cached value inside the ttl and refetches after', () async {
    var now = DateTime(2026, 1, 1);
    var calls = 0;
    final c = TtlCache<String, int>(ttl: const Duration(seconds: 30), clock: () => now);
    expect(await c.get('k', () async => ++calls), 1);
    expect(await c.get('k', () async => ++calls), 1);
    now = now.add(const Duration(seconds: 31));
    expect(await c.get('k', () async => ++calls), 2);
  });

  test('fresh bypasses the cache', () async {
    var calls = 0;
    final c = TtlCache<String, int>(ttl: const Duration(minutes: 1));
    await c.get('k', () async => ++calls);
    expect(await c.get('k', () async => ++calls, fresh: true), 2);
  });

  test('a failed refresh falls back to the stale value', () async {
    var now = DateTime(2026, 1, 1);
    final c = TtlCache<String, int>(ttl: const Duration(seconds: 1), clock: () => now);
    await c.get('k', () async => 7);
    now = now.add(const Duration(seconds: 5));
    expect(await c.get('k', () async => throw Exception('down')), 7);
  });

  test('a failure with nothing cached propagates', () async {
    final c = TtlCache<String, int>(ttl: const Duration(seconds: 1));
    expect(c.get('k', () async => throw Exception('down')), throwsException);
  });

  test('concurrent callers share one fetch', () async {
    var calls = 0;
    final c = TtlCache<String, int>(ttl: const Duration(minutes: 1));
    final a = c.get('k', () async { calls++; await Future<void>.delayed(const Duration(milliseconds: 10)); return 1; });
    final b = c.get('k', () async { calls++; return 2; });
    expect(await Future.wait([a, b]), [1, 1]);
    expect(calls, 1);
  });
}
