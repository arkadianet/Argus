String formatScaled(int amount, int decimals, {int? maxFrac}) {
  final sign = amount < 0 ? '-' : '';
  return _formatScaled(BigInt.from(amount.abs()), decimals, maxFrac, sign);
}

/// BigInt overload of [formatScaled] for on-chain amounts that may exceed
/// 64-bit range (e.g. box values, token amounts).
String formatScaledBigInt(BigInt amount, int decimals, {int? maxFrac}) {
  final sign = amount < BigInt.zero ? '-' : '';
  final abs = amount < BigInt.zero ? BigInt.zero - amount : amount;
  return _formatScaled(abs, decimals, maxFrac, sign);
}

String _formatScaled(BigInt abs, int decimals, int? maxFrac, String sign) {
  if (decimals <= 0) return '$sign$abs';
  var scale = BigInt.one;
  for (var i = 0; i < decimals; i++) {
    scale *= BigInt.from(10);
  }
  final whole = abs ~/ scale;
  var frac = (abs % scale).toString().padLeft(decimals, '0');
  final keep = (maxFrac ?? decimals).clamp(0, decimals).toInt();
  if (keep < decimals) frac = frac.substring(0, keep);
  frac = frac.replaceFirst(RegExp(r'0+$'), '');
  if (frac.isEmpty) return '$sign$whole';
  return '$sign$whole.$frac';
}

String formatErg(int? nano, {int maxFrac = 9, bool unit = true}) {
  if (nano == null) return '—';
  final n = formatScaled(nano, 9, maxFrac: maxFrac);
  return unit ? '$n ERG' : n;
}

String formatNanoErg(BigInt nano, {int maxFrac = 9, bool unit = true}) {
  final n = formatScaledBigInt(nano, 9, maxFrac: maxFrac);
  return unit ? '$n ERG' : n;
}

String formatTokenAmount(int amount, int decimals) => formatScaled(amount, decimals);

/// Token amount with thousands separators in the whole part,
/// e.g. "61,630.618".
String formatTokenAmountGrouped(int amount, int decimals) {
  final raw = formatScaled(amount, decimals);
  final dot = raw.indexOf('.');
  final whole = dot == -1 ? raw : raw.substring(0, dot);
  final frac = dot == -1 ? '' : raw.substring(dot);
  final neg = whole.startsWith('-');
  final digits = neg ? whole.substring(1) : whole;
  final buf = StringBuffer(neg ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  return '$buf$frac';
}

String formatTokenAmountBigInt(BigInt amount, int decimals) =>
    formatScaledBigInt(amount, decimals);

String shorten(String value, {int head = 8, int tail = 6}) {
  if (value.length <= head + tail + 1) return value;
  return '${value.substring(0, head)}…${value.substring(value.length - tail)}';
}

bool looksLikeErgoAddress(String value) {
  return RegExp(r'^9[1-9A-HJ-NP-Za-km-z]{50,60}$').hasMatch(value.trim());
}

class PaymentRequest {
  final String address;
  final String? amountErg;
  const PaymentRequest({required this.address, this.amountErg});
}

PaymentRequest? parseErgoUri(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;
  if (text.toLowerCase().startsWith('ergo:')) {
    text = text.substring(5);
  }
  final parts = text.split('?');
  final address = parts[0].trim();
  if (!looksLikeErgoAddress(address)) return null;
  String? amount;
  if (parts.length > 1) {
    try {
      amount = Uri.splitQueryString(parts[1])['amount'];
    } catch (_) {
      return null;
    }
  }
  return PaymentRequest(address: address, amountErg: amount);
}

String formatHeight(int? height) {
  if (height == null || height <= 0) return 'Unconfirmed';
  return '#$height';
}

/// "1856438" → "1,856,438".
String formatWithCommas(int value) {
  final s = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buffer.write(',');
    buffer.write(s[i]);
  }
  return buffer.toString();
}

String formatTxTime(int? timestampMs) {
  if (timestampMs == null || timestampMs <= 0) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs, isUtc: true).toLocal();
  final y = dt.year.toString().padLeft(4, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  return '$y-$m-$d $hh:$mm';
}

String dayKey(int? timestampMs) {
  if (timestampMs == null || timestampMs <= 0) return 'Unknown day';
  final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs, isUtc: true).toLocal();
  return '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
}

/// Activity-list timestamp, e.g. "Today, 8:21 am", "Yesterday, 3:47 pm",
/// "Aug 20, 11:02 am".
String formatActivityTime(int? timestampMs) {
  if (timestampMs == null || timestampMs <= 0) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs, isUtc: true).toLocal();
  final now = DateTime.now();
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final minute = dt.minute.toString().padLeft(2, '0');
  final period = dt.hour < 12 ? 'am' : 'pm';
  final time = '$hour12:$minute $period';
  final todayStart = DateTime.utc(now.year, now.month, now.day);
  final dayStart = DateTime.utc(dt.year, dt.month, dt.day);
  final dayDiff = todayStart.difference(dayStart).inDays;
  if (dayDiff == 0) return 'Today, $time';
  if (dayDiff == 1) return 'Yesterday, $time';
  if (dt.year != now.year) {
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }
  return '${months[dt.month - 1]} ${dt.day}, $time';
}

/// Human-readable relative time (e.g. "2 min ago", "1h ago", "yesterday").
String formatRelativeTime(DateTime? when, {DateTime? now}) {
  if (when == null) return '';
  final reference = now ?? DateTime.now();
  final diff = reference.difference(when);
  if (diff.isNegative) return 'Just now';
  if (diff.inSeconds < 5) return 'Just now';
  if (diff.inMinutes < 1) return '${diff.inSeconds}s ago';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  final dayDiff = DateTime.utc(reference.year, reference.month, reference.day)
      .difference(DateTime.utc(when.year, when.month, when.day))
      .inDays;
  if (dayDiff == 1) return 'Yesterday';
  if (dayDiff < 7) return '${dayDiff} days ago';
  return '${when.month}/${when.day}/${when.year}';
}

/// Relative age of the last successful sync: 'just now', '3m ago', '2h ago',
/// '3d ago'. Empty when there has been none.
String formatSyncAge(DateTime? at, {DateTime? now}) {
  if (at == null) return '';
  final diff = (now ?? DateTime.now()).difference(at);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}
