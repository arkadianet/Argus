import 'package:argus_wallet/services/mix_activity.dart';
import 'package:argus_wallet/services/mix_service.dart';
import 'package:flutter_test/flutter_test.dart';

MixRecord rec({
  int mixId = 0,
  String kind = 'full_owned',
  int done = 1,
  int target = 3,
  List<Map<String, dynamic>> events = const [],
  bool acknowledged = false,
  DateTime? checked,
}) =>
    MixRecord(
      acknowledged: acknowledged,
      lastCheckedAt: checked,
      state: {
        'mix_id': mixId,
        'ring': {'value': 1000000000, 'token_id': null, 'token_amount': null},
        'level': 30,
        'rounds_target': target,
        'rounds_done': done,
        'round': 0,
        'phase': {'kind': kind, if (kind == 'half_posted' || kind == 'full_owned') 'box_id': 'b'},
        'destination_ergo_tree': '00',
        'created_at': 1,
        'updated_at': 1,
        'events': events,
      },
    );

void main() {
  test('every mix event with a transaction becomes an activity row, newest first', () {
    final rows = mixActivityRowsFor([
      rec(kind: 'withdrawn', done: 3, events: [
        {'at': 100, 'action': 'entered_as_alice', 'round': 0, 'tx_id': 'e', 'height': 10},
        {'at': 200, 'action': 'joined', 'round': 0, 'tx_id': null},
        {'at': 300, 'action': 'remixed_as_bob', 'round': 1, 'tx_id': 'r', 'height': 20},
        {'at': 400, 'action': 'withdrawn', 'round': 1, 'tx_id': 'w'},
      ]),
    ]);
    expect(rows.map((r) => r['tx_id']), ['w', 'r', 'e'], reason: 'unstamped newest by time, then by height');
    expect(rows.first['value_nano_erg'], 1000000000, reason: 'withdrawal brings the money back');
    expect(rows.last['value_nano_erg'], -1000000000, reason: 'entry sends it out');
    expect(rows[1]['value_nano_erg'], 0);
    expect(rows.first['mix_label'], 'Mix finished: 1 ERG delivered');
    expect(rows[1]['mix_label'], 'Mix round 2');
    expect(rows.last['mix_label'], 'Entered a mix with 1 ERG');
    expect(rows.every((r) => r['mix'] == true), isTrue);
  });

  test('mix rows replace the history\'s view of the same transaction and sort in', () {
    final history = [
      {'tx_id': 'e', 'height': 10, 'timestamp': 1000, 'value_nano_erg': -1122100000},
      {'tx_id': 'x', 'height': 15, 'timestamp': 1500, 'value_nano_erg': 5},
    ];
    final mix = [
      {'tx_id': 'e', 'height': 10, 'timestamp': 1000, 'value_nano_erg': -1000000000, 'mix': true},
      {'tx_id': 'r', 'height': 20, 'timestamp': 2000, 'value_nano_erg': 0, 'mix': true},
    ];
    final out = mergeMixActivity(history, mix);
    expect(out.map((r) => r['tx_id']), ['r', 'x', 'e']);
    expect(out.last['mix'], isTrue, reason: 'the mix row wins over the plain send');
    expect(mergeMixActivity(history, const []), same(history));
  });

  test('the home strip says one line, or nothing', () {
    expect(mixStripSummary(const []), isNull);
    expect(mixStripSummary([rec(kind: 'withdrawn', acknowledged: true)]), isNull, reason: 'seen and done');

    final one = mixStripSummary([rec(kind: 'half_posted', done: 1, target: 3)]);
    expect(one!.text, '1 ERG · round 1 of 3 · waiting for a counterpart');
    expect(one.finished, isNull);

    final ready = mixStripSummary([rec(done: 3, target: 3, checked: DateTime.now())]);
    expect(ready!.text, startsWith('1 ERG · round 3 of 3 · ready to withdraw · checked'));

    final many = mixStripSummary([
      rec(mixId: 0, kind: 'half_posted'),
      rec(mixId: 1, done: 3, target: 3),
      rec(mixId: 2, kind: 'pending'),
      rec(mixId: 3, done: 1),
    ]);
    expect(many!.text, '4 mixes · 1 mixing, 1 waiting, 1 ready to withdraw, 1 not entered');

    final finished = mixStripSummary([rec(mixId: 5, kind: 'withdrawn'), rec(mixId: 6, kind: 'half_posted')]);
    expect(finished!.text, 'Mix finished · 1 ERG delivered');
    expect(finished.finished!.mixId, 5, reason: 'announced until dismissed, ahead of live mixes');
  });
}
