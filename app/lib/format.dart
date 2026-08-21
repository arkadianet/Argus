String formatScaled(int amount, int decimals, {int? maxFrac}) {
  final sign = amount < 0 ? '-' : '';
  return _format_scaled(BigInt.from(amount.abs()), decimals, maxFrac, sign);
}

/// BigInt overload of [formatScaled] for on-chain amounts that may exceed
/// 64-bit range (e.g. box values, token amounts).
String formatScaledBigInt(BigInt amount, int decimals, {int? maxFrac}) {
  final sign = amount < BigInt.zero ? '-' : '';
  final abs = amount < BigInt.zero ? BigInt.zero - amount : amount;
  return _format_scaled(abs, decimals, maxFrac, sign);
}

String _format_scaled(BigInt abs, int decimals, int? maxFrac, String sign) {
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
