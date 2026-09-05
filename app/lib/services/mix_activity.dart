import '../format.dart';
import 'mix_service.dart';

/// What one mix event is called in the activity list.
String mixEventLabel(String action, {required int denomination, required int round}) {
  final amount = formatErg(denomination, maxFrac: 4);
  return switch (action) {
    'entered_as_alice' || 'entered_as_bob' => 'Entered a mix with $amount',
    'remixed_as_bob' || 'remixed_as_alice' => 'Mix round ${round + 1}',
    'joined' => 'Mix round ${round + 1}',
    'withdrawn' => 'Mix finished: $amount delivered',
    'reclaimed' => 'Mix reclaimed: $amount back',
    'recovered' => 'Mix found from seed',
    _ => 'Mix: $action',
  };
}

/// Activity rows for every mix event with a transaction, newest first.
/// The amount is shown as the mix's denomination leaving on entry and
/// arriving on withdrawal or reclaim; rounds move nothing in or out.
List<Map<String, dynamic>> mixActivityRowsFor(List<MixRecord> records) {
  final rows = <Map<String, dynamic>>[];
  for (final r in records) {
    for (final e in r.events) {
      final txId = e['tx_id']?.toString() ?? '';
      final action = e['action']?.toString() ?? '';
      if (txId.isEmpty) continue;
      final round = (e['round'] as num?)?.toInt() ?? 0;
      final nano = switch (action) {
        'entered_as_alice' || 'entered_as_bob' => -r.denomination,
        'withdrawn' || 'reclaimed' => r.denomination,
        _ => 0,
      };
      rows.add({
        'tx_id': txId,
        'height': (e['height'] as num?)?.toInt() ?? 0,
        'timestamp': ((e['at'] as num?)?.toInt() ?? 0) * 1000,
        'value_nano_erg': nano,
        'token_ids': const <String>[],
        'tokens_received': const [],
        'tokens_sent': const [],
        // A broadcast is not an inclusion: a row is confirmed only once a
        // snapshot has seen its box, or the transaction was looked up.
        'confirmed': ((e['height'] as num?)?.toInt() ?? 0) > 0,
        'mix': true,
        'mix_id': r.mixId,
        'mix_label': mixEventLabel(action, denomination: r.denomination, round: round),
      });
    }
  }
  rows.sort(compareActivityRows);
  return rows;
}

/// Newest first, as one total order: rows not yet in a block (height 0)
/// come first, then by height descending, and rows on the same height (or
/// all pending) by timestamp descending.
int compareActivityRows(Map<String, dynamic> a, Map<String, dynamic> b) {
  int rank(Map<String, dynamic> r) {
    final h = (r['height'] as num?)?.toInt() ?? 0;
    return h > 0 ? h : 0x7fffffff;
  }

  final byHeight = rank(b).compareTo(rank(a));
  if (byHeight != 0) return byHeight;
  final ta = (a['timestamp'] as num?)?.toInt() ?? 0;
  final tb = (b['timestamp'] as num?)?.toInt() ?? 0;
  return tb.compareTo(ta);
}

/// Mix rows take precedence over the address history's view of the same
/// transaction (an entry spends a wallet box, so the history shows it as a
/// plain send), and the rest of the history is kept.
List<Map<String, dynamic>> mergeMixActivity(
  List<Map<String, dynamic>> history,
  List<Map<String, dynamic>> mixRows,
) {
  if (mixRows.isEmpty) return history;
  final mixIds = {for (final r in mixRows) r['tx_id']?.toString()};
  final out = [...mixRows, ...history.where((t) => !mixIds.contains(t['tx_id']?.toString()))];
  out.sort(compareActivityRows);
  return out;
}

/// The one line the home screen shows about mixes, or null when there is
/// nothing to say. `finished` is a mix that ended and has not been seen.
({String text, MixRecord? finished})? mixStripSummary(List<MixRecord> records) {
  final unseen = records.where((r) => r.finished && !r.acknowledged).toList();
  if (unseen.isNotEmpty) {
    final r = unseen.first;
    return (
      text: r.phaseKind == 'withdrawn'
          ? 'Mix finished · ${formatErg(r.denomination, maxFrac: 4)} delivered'
          : 'Mix reclaimed · ${formatErg(r.denomination, maxFrac: 4)} back',
      finished: r,
    );
  }
  final live = records.where((r) => r.inPool || r.pending).toList();
  if (live.isEmpty) return null;
  if (live.length == 1) {
    final r = live.single;
    final amount = formatErg(r.denomination, maxFrac: 4);
    final what = switch (r.phaseKind) {
      'pending' => 'funded, not entered',
      'half_posted' => 'waiting for a counterpart',
      _ => r.readyToWithdraw ? 'ready to withdraw' : 'mixing',
    };
    final checked = r.lastCheckedAt == null ? '' : ' · checked ${formatSyncAge(r.lastCheckedAt)}';
    return (
      text: '$amount · round ${r.roundsDone} of ${r.roundsTarget} · $what$checked',
      finished: null,
    );
  }
  final waiting = live.where((r) => r.phaseKind == 'half_posted').length;
  final ready = live.where((r) => r.readyToWithdraw).length;
  final pending = live.where((r) => r.pending).length;
  final parts = <String>[
    if (waiting > 0) '$waiting waiting',
    if (ready > 0) '$ready ready to withdraw',
    if (pending > 0) '$pending not entered',
  ];
  final rest = live.length - waiting - ready - pending;
  if (rest > 0) parts.insert(0, '$rest mixing');
  return (text: '${live.length} mixes · ${parts.join(', ')}', finished: null);
}
