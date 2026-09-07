import '../format.dart';
import 'mix_service.dart';
import 'wallet_service.dart';

/// Name and decimals of a token, or null when nothing has looked it up.
typedef TokenMetaLookup = ({String? name, int decimals})? Function(String id);

({String? name, int decimals})? _cachedMeta(String id) {
  final m = walletService.cachedTokenMeta(id);
  return m == null ? null : (name: m.name, decimals: m.decimals);
}

/// The amount a mix moves, in words: "1 ERG", or for a token ring the ring
/// amount in the token's own unit. A token nobody has looked up yet is
/// named by the start of its id.
String mixAmountText(MixRecord r, {TokenMetaLookup? meta}) =>
    ringAmountText(r.denomination, r.ringTokenId, r.ringTokenAmount, meta: meta);

/// [mixAmountText] for a ring that is not a record yet.
String ringAmountText(int value, String? tokenId, int? tokenAmount, {TokenMetaLookup? meta}) {
  if (tokenId == null || tokenId.isEmpty || tokenAmount == null) return formatErg(value, maxFrac: 4);
  final m = (meta ?? _cachedMeta)(tokenId);
  final name = (m?.name ?? '').isNotEmpty ? m!.name! : '${tokenId.substring(0, tokenId.length < 8 ? tokenId.length : 8)}…';
  return '${formatTokenAmount(tokenAmount, m?.decimals ?? 0)} $name';
}

/// What one mix event is called in the activity list.
String mixEventLabel(String action, {required int denomination, required int round, String? amountText}) {
  final amount = amountText ?? formatErg(denomination, maxFrac: 4);
  return switch (action) {
    'entered_as_alice' || 'entered_as_bob' => 'Entered a mix with $amount',
    'remixed_as_bob' || 'remixed_as_alice' => 'Mix round ${round + 1}',
    'joined' => 'Mix round ${round + 1}',
    'withdrawn' => 'Mix finished: $amount delivered',
    'reclaimed' => 'Mix withdrawn early: $amount back',
    'recovered' => 'Mix found from seed',
    _ => 'Mix: $action',
  };
}

/// Where a mix's money goes, from its destination tree: a pay-to-public-key
/// tree is the wallet's public address, anything else is one of its stealth
/// addresses. A recovered mix may not know yet.
String mixDestinationText(MixRecord r) {
  final tree = r.destinationErgoTree;
  if (tree.isEmpty) return 'the destination you chose';
  return tree.startsWith('0008cd') ? 'your public address' : 'a stealth address of yours';
}

/// The finished card's second line: where the money is now and what the
/// card still means, so nobody goes looking for a missing balance.
String mixFinishedText(MixRecord r) {
  final amount = mixAmountText(r);
  final where = mixDestinationText(r);
  final went = r.phaseKind == 'reclaimed'
      ? '$amount went back to $where, minus the mixing tokens.'
      : '$amount went to $where.';
  final label = r.phaseKind == 'reclaimed' ? 'Mix reclaimed' : 'Mix finished';
  return '$went It counts in this wallet\'s balance and shows in Activity as "$label". '
      'Remove only clears this card.';
}

/// The activity row of a finished mix's last transaction, for the detail
/// screen; null while the mix has no transaction to show.
Map<String, dynamic>? mixFinalRow(MixRecord r) {
  final rows = mixActivityRowsFor([r]);
  return rows.isEmpty ? null : rows.first;
}

/// Activity rows for every mix event with a transaction, newest first.
/// The amount is shown as the mix's denomination leaving on entry and
/// arriving on withdrawal or reclaim; rounds move nothing in or out.
List<Map<String, dynamic>> mixActivityRowsFor(List<MixRecord> records, {TokenMetaLookup? meta}) {
  final rows = <Map<String, dynamic>>[];
  for (final r in records) {
    for (final e in r.events) {
      final txId = e['tx_id']?.toString() ?? '';
      final action = e['action']?.toString() ?? '';
      if (txId.isEmpty) continue;
      final round = (e['round'] as num?)?.toInt() ?? 0;
      final sign = switch (action) {
        'entered_as_alice' || 'entered_as_bob' => -1,
        'withdrawn' || 'reclaimed' => 1,
        _ => 0,
      };
      // A token ring moves its token with the sliver of ERG the box holds.
      final token = r.isTokenRing && sign != 0
          ? [
              {'token_id': r.ringTokenId, 'amount': r.ringTokenAmount ?? 0}
            ]
          : const <Map<String, dynamic>>[];
      rows.add({
        'tx_id': txId,
        'height': (e['height'] as num?)?.toInt() ?? 0,
        'timestamp': ((e['at'] as num?)?.toInt() ?? 0) * 1000,
        'value_nano_erg': sign * r.denomination,
        'token_ids': [if (token.isNotEmpty) r.ringTokenId!],
        'tokens_received': sign > 0 ? token : const [],
        'tokens_sent': sign < 0 ? token : const [],
        // A broadcast is not an inclusion: a row is confirmed only once a
        // snapshot has seen its box, or the transaction was looked up.
        'confirmed': ((e['height'] as num?)?.toInt() ?? 0) > 0,
        'mix': true,
        'mix_id': r.mixId,
        'mix_label': mixEventLabel(action, denomination: r.denomination, round: round, amountText: mixAmountText(r, meta: meta)),
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
          ? 'Mix finished · ${mixAmountText(r)} delivered'
          : 'Mix withdrawn early · ${mixAmountText(r)} back',
      finished: r,
    );
  }
  final live = records.where((r) => r.inPool || r.pending).toList();
  if (live.isEmpty) return null;
  if (live.length == 1) {
    final r = live.single;
    final amount = mixAmountText(r);
    final what = switch (r.phaseKind) {
      'pending' => 'funded, not entered',
      'half_posted' => 'waiting for a partner',
      _ => r.readyToWithdraw ? 'ready to withdraw' : 'mixing',
    };
    final checked = r.lastCheckedAt == null ? '' : ' · checked ${formatSyncAge(r.lastCheckedAt)}';
    return (
      text: '$amount · round ${r.roundsDone} of about ${r.roundsTarget} · $what$checked',
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
