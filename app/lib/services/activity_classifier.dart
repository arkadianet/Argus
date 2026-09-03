import '../format.dart';

/// What a history entry did, from the wallet's point of view.
enum ActivityKind { received, sent, swap, selfTransfer, contract }

/// Mainnet P2PK addresses are 51 base58 characters starting with 9; anything
/// longer is a script (pool, bank, dApp contract).
bool isContractAddress(String? address) {
  if (address == null || address.isEmpty) return false;
  return !(address.startsWith('9') && address.length == 51);
}

List<Map> _tokens(Map<String, dynamic> tx, String key) =>
    (tx[key] as List?)?.whereType<Map>().toList() ?? const [];

ActivityKind classifyActivity(Map<String, dynamic> tx) {
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
    };

/// `1.50 SigUSD` for one token, `3 tokens` for several, null for none.
String? tokenSummary(
  List<Map> tokens, {
  required String? Function(String id) name,
  required int Function(String id) decimals,
}) {
  if (tokens.isEmpty) return null;
  if (tokens.length > 1) return '${tokens.length} tokens';
  final t = tokens.single;
  final id = t['token_id']?.toString() ?? '';
  final amount = (t['amount'] as num?)?.toInt() ?? 0;
  final n = name(id);
  final label = n != null && n.isNotEmpty ? n : '${id.substring(0, id.length < 4 ? id.length : 4)}…';
  return '${formatTokenAmount(amount, decimals(id))} $label';
}

/// Second line of an activity row: tokens and ERG that moved, e.g.
/// `1 SigUSD + 0.7496 ERG`, omitting a zero ERG leg.
String activityLine(
  Map<String, dynamic> tx, {
  required String? Function(String id) name,
  required int Function(String id) decimals,
  bool hidden = false,
}) {
  if (hidden) return '••••';
  final nano = (tx['value_nano_erg'] as num?)?.toInt() ?? 0;
  final tokens = nano < 0 || (nano == 0 && _tokens(tx, 'tokens_sent').isNotEmpty)
      ? _tokens(tx, 'tokens_sent')
      : _tokens(tx, 'tokens_received');
  final parts = <String>[
    if (tokenSummary(tokens, name: name, decimals: decimals) case final t?) t,
    if (nano != 0) formatErg(nano.abs(), unit: true, maxFrac: 4),
  ];
  return parts.isEmpty ? formatErg(0, unit: true) : parts.join(' + ');
}
