import 'package:argus_wallet/ui/dashboard_screen.dart';
import 'package:argus_wallet/ui/transactions_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 9, 7, 12, 0, 0);

  test('a routine poll waits the full interval', () {
    expect(shouldPoll(now: t0.add(const Duration(seconds: 19)), lastPollAt: t0, hasPending: false), isFalse);
    expect(shouldPoll(now: t0.add(const Duration(seconds: 20)), lastPollAt: t0, hasPending: false), isTrue);
  });

  test('with something unconfirmed the poll runs every few seconds', () {
    expect(shouldPoll(now: t0.add(const Duration(seconds: 4)), lastPollAt: t0, hasPending: true), isFalse);
    expect(shouldPoll(now: t0.add(const Duration(seconds: 5)), lastPollAt: t0, hasPending: true), isTrue);
  });

  test('the activity signature changes when a row confirms or arrives', () {
    final pending = [
      {'tx_id': 'a', 'height': 0},
      {'tx_id': 'b', 'height': 5},
    ];
    final confirmed = [
      {'tx_id': 'a', 'height': 9},
      {'tx_id': 'b', 'height': 5},
    ];
    expect(activitySignature(pending), isNot(activitySignature(confirmed)));
    expect(activitySignature(pending), activitySignature(List.of(pending)));
    expect(activitySignature([{'tx_id': 'c'}, ...pending]), isNot(activitySignature(pending)));
  });
}
