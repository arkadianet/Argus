String formatScaled(int amount, int decimals, {int? maxFrac}) {
  final sign = amount < 0 ? '-' : '';
  final abs = BigInt.from(amount.abs());
  if (decimals <= 0) return '$sign$abs';
  var scale = BigInt.one;
  for (var i = 0; i < decimals; i++) {
    scale *= BigInt.from(10);
  }
  final whole = abs ~/ scale;
  var frac = (abs % scale).toString().padLeft(decimals, '0');
  final keep = (maxFrac ?? decimals).clamp(0, decimals);
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

String formatTokenAmount(int amount, int decimals) => formatScaled(amount, decimals);

String shorten(String value, {int head = 8, int tail = 6}) {
  if (value.length <= head + tail + 1) return value;
  return '${value.substring(0, head)}…${value.substring(value.length - tail)}';
}
