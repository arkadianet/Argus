import 'package:argus_wallet/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 9, 2, 12, 0, 0);

  test('formatSyncAge is empty with no timestamp', () {
    expect(formatSyncAge(null, now: now), '');
  });

  test('formatSyncAge says just now under a minute', () {
    expect(formatSyncAge(now.subtract(const Duration(seconds: 20)), now: now), 'just now');
  });

  test('formatSyncAge counts minutes then hours', () {
    expect(formatSyncAge(now.subtract(const Duration(minutes: 3)), now: now), '3m ago');
    expect(formatSyncAge(now.subtract(const Duration(hours: 2, minutes: 5)), now: now), '2h ago');
  });

  test('formatSyncAge counts days beyond a day', () {
    expect(formatSyncAge(now.subtract(const Duration(days: 3)), now: now), '3d ago');
  });
}
