import '../format.dart';
import 'token_amounts.dart';

/// What a history entry did, from the wallet's point of view.
enum ActivityKind { received, sent, swap, selfTransfer, contract, mix }

/// Mainnet P2PK addresses are 51 base58 characters starting with 9; anything
/// longer is a script (pool, bank, dApp contract).
bool isContractAddress(String? address) {
  if (address == null || address.isEmpty) return false;
  return !(address.startsWith('9') && address.length == 51);
}

List<Map> _tokens(Map<String, dynamic> tx, String key) =>
    (tx[key] as List?)?.whereType<Map>().toList() ?? const [];

ActivityKind classifyActivity(Map<String, dynamic> tx) {
  if (tx['mix'] == true) return ActivityKind.mix;
  final nano = (tx['value_nano_erg'] as num?)?.toInt() ?? 0;
  final counterparty = tx['counterparty']?.toString();
  final tokensIn = _tokens(tx, 'tokens_received').isNotEmpty;
  final tokensOut = _tokens(tx, 'tokens_sent').isNotEmpty;
  if (counterparty == null || counterparty.isEmpty) {
    return nano > 0 ? ActivityKind.received : ActivityKind.selfTransfer;
  }
  if (isContractAddress(counterparty)) {
    if ((nano < 0 && tokensIn) || (nano > 0 && tokensOut)) return ActivityKind.swap;
    if (tokensIn && tokensOut) return ActivityKind.swap;
    if (nano > 0 && !tokensOut) return ActivityKind.received;
    if (nano < 0 && tokensOut) return ActivityKind.sent;
    return ActivityKind.contract;
  }
  return nano < 0 || (nano == 0 && tokensOut) ? ActivityKind.sent : ActivityKind.received;
}

String activityTitle(ActivityKind kind) => switch (kind) {
      ActivityKind.received => 'Received',
      ActivityKind.sent => 'Sent',
      ActivityKind.swap => 'Swapped',
      ActivityKind.selfTransfer => 'Moved',
      ActivityKind.contract => 'Contract',
      ActivityKind.mix => 'Mix',
    };

/// The most tokens a row names before summing up the rest.
const namedTokensPerRow = 2;

/// The tokens of one row, by name: `69 COMET`, `69 COMET + 1.5 SigUSD`, and
/// past [namedTokensPerRow], the first ones then `+ 3 more tokens`. Null for
/// none.
///
/// [name] and [decimals] are the token lookup's answers. A token with no
/// name shows its short id; one whose decimals nothing knows is shown in raw
/// units and says so. Named tokens come first, otherwise in the order the
/// transaction lists them, so the words a person can read are the ones the
/// row keeps.
String? tokenSummary(
  List<Map> tokens, {
  required String? Function(String id) name,
  required int? Function(String id) decimals,
}) {
  if (tokens.isEmpty) return null;
  String? named(String id) {
    final n = name(id)?.trim();
    return n == null || n.isEmpty ? null : n;
  }

  final entries = [
    for (final t in tokens)
      (
        id: t['token_id']?.toString() ?? '',
        amount: BigInt.from((t['amount'] as num?)?.toInt() ?? 0),
      ),
  ];
  final ordered = [
    ...entries.where((e) => named(e.id) != null),
    ...entries.where((e) => named(e.id) == null),
  ];
  final more = ordered.length - namedTokensPerRow;
  return [
    for (final e in ordered.take(namedTokensPerRow))
      unitsWithLabel(e.amount, decimals(e.id), named(e.id) ?? shortTokenId(e.id)),
    if (more > 0) '$more more ${more == 1 ? 'token' : 'tokens'}',
  ].join(' + ');
}

/// Second line of an activity row: what moved, e.g. `1 SigUSD + 0.7496
/// ERG`, omitting a zero ERG leg. A swap shows both legs, what went out and
/// what came back: `0.75 ERG → 69 COMET`.
String activityLine(
  Map<String, dynamic> tx, {
  required String? Function(String id) name,
  required int? Function(String id) decimals,
  bool hidden = false,
}) {
  if (hidden) return '••••';
  final nano = (tx['value_nano_erg'] as num?)?.toInt() ?? 0;
  final sent = _tokens(tx, 'tokens_sent');
  final received = _tokens(tx, 'tokens_received');
  String erg(int n) => formatErg(n.abs(), unit: true, maxFrac: 4);
  String? summary(List<Map> t) =>
      tokenSummary(t, name: name, decimals: decimals);

  if (classifyActivity(tx) == ActivityKind.swap) {
    final out = [if (summary(sent) case final t?) t, if (nano < 0) erg(nano)];
    final back = [
      if (summary(received) case final t?) t,
      if (nano > 0) erg(nano),
    ];
    if (out.isNotEmpty && back.isNotEmpty) {
      return '${out.join(' + ')} → ${back.join(' + ')}';
    }
  }
  final tokens = nano < 0 || (nano == 0 && sent.isNotEmpty) ? sent : received;
  final parts = <String>[
    if (summary(tokens) case final t?) t,
    if (nano != 0) erg(nano),
  ];
  return parts.isEmpty ? formatErg(0, unit: true) : parts.join(' + ');
}
