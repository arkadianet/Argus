import 'package:argus_wallet/services/mix_service.dart';
import 'package:argus_wallet/ui/mix_screen.dart' show waitingHint, mixPhaseText, mixCanLeave;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an unconfirmed withdrawal is described as awaiting confirmation', () {
    final record = MixRecord(state: {
      'phase': {'kind': 'withdrawn'},
      'previous': {'phase': {'kind': 'full_owned', 'box_id': 'live'}},
    });
    expect(mixPhaseText(record), 'Withdrawal sent. Waiting for confirmation.');
    expect(mixCanLeave(record), isFalse,
        reason: 'leave() would throw: the withdrawn phase has no box to spend');
  });

  test('a mix in the pool can be withdrawn', () {
    final live = MixRecord(state: {
      'phase': {'kind': 'full_owned', 'box_id': 'b'},
    });
    expect(mixCanLeave(live), isTrue);
    final half = MixRecord(state: {
      'phase': {'kind': 'half_posted', 'box_id': 'h'},
    });
    expect(mixCanLeave(half), isTrue);
    expect(mixCanLeave(MixRecord(state: {'phase': {'kind': 'withdrawn'}})), isFalse);
  });

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
    expect(waitingHint(at(const Duration(days: 3)), now), ' Waiting 3 days. The pool is thin; Withdraw now takes it back, minus the mixing tokens.');
  });
}
