import 'package:argus_wallet/ui/mix_screen.dart' show waitingHint;
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 6, 12);
  List<Map<String, dynamic>> at(Duration ago) => [
        {'at': now.subtract(ago).millisecondsSinceEpoch ~/ 1000, 'action': 'entered_as_alice', 'round': 0},
      ];

  test('under an hour says nothing', () {
    expect(waitingHint(at(const Duration(minutes: 40)), now), '');
    expect(waitingHint(const [], now), '');
    expect(waitingHint([{'action': 'x'}], now), '', reason: 'no time on the event');
    expect(waitingHint(at(const Duration(hours: -3)), now), '', reason: 'a clock set backwards');
  });

  test('hours, then days, then the nudge after two days', () {
    expect(waitingHint(at(const Duration(hours: 3)), now), ' Waiting 3 hours.');
    expect(waitingHint(at(const Duration(hours: 1)), now), ' Waiting 1 hour.');
    expect(waitingHint(at(const Duration(hours: 25)), now), ' Waiting 1 day.');
    expect(waitingHint(at(const Duration(days: 3)), now), ' Waiting 3 days. The pool is thin; Reclaim takes it back, minus the mixing tokens.');
  });
}
