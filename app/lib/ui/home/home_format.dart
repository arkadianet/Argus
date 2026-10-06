import 'dart:math' as math;

import '../../format.dart';
import '../../services/token_amounts.dart';
import 'home_models.dart';

/// Figures for the overview and the wallet page.
///
/// Summary surfaces show at most two decimals at or above one unit and at
/// most four below it, so a balance reads at a glance; full precision
/// belongs to detail screens. A non-zero amount is never shown as "0":
/// below the usual precision it keeps its first two significant digits.
/// Amounts are truncated toward zero, as everywhere else in the app, so a
/// summary never shows more than is there. Every whole part is grouped
/// with thousands separators, which the beta's headline total lacked.
///
/// A figure and its unit are joined by a no-break space ([nbsp]) so a
/// line never ends on "≈" or starts with "ERG"; the brand fonts carry it.

/// What hidden-balances mode shows in place of a figure.
const maskedFigure = '••••';

/// The true minus sign: same width as the plus, unlike a hyphen.
const minusSign = '−';

/// No-break space, for keeping a figure with its unit or sign.
const nbsp = ' ';

/// [text] with no-break spaces made plain, for screen-reader labels.
String spoken(String text) => text.replaceAll(nbsp, ' ');

/// "25529" → "25,529"; leaves any sign and fraction alone.
String groupThousands(String number) {
  final negative = number.startsWith('-') || number.startsWith(minusSign);
  final unsigned = negative ? number.substring(1) : number;
  final dot = unsigned.indexOf('.');
  final whole = dot == -1 ? unsigned : unsigned.substring(0, dot);
  final fraction = dot == -1 ? '' : unsigned.substring(dot);
  final out = StringBuffer(negative ? number[0] : '');
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) out.write(',');
    out.write(whole[i]);
  }
  return '$out$fraction';
}

/// Unsigned summary figure for [raw] base units of an asset with
/// [decimals] places, e.g. 107713400000 at 9 places → "107.71".
String summaryAmount(BigInt raw, int decimals) {
  final abs = raw.abs();
  if (abs == BigInt.zero) return '0';
  final unit = BigInt.from(10).pow(decimals);
  final places = math.min(abs >= unit ? 2 : 4, decimals);
  var text = formatScaledBigInt(abs, decimals, maxFrac: places);
  if (text == '0') {
    // Below the usual precision: widen to the first two significant
    // digits rather than claim the wallet holds nothing.
    final digits = abs.toString().padLeft(decimals, '0');
    final firstSignificant = digits.indexOf(RegExp('[1-9]'));
    text = formatScaledBigInt(abs, decimals, maxFrac: math.min(decimals, firstSignificant + 2));
  }
  return groupThousands(text);
}

/// [summaryAmount] with an explicit sign, for amounts that moved.
String signedSummaryAmount(BigInt raw, int decimals) {
  if (raw == BigInt.zero) return '0';
  return '${raw.isNegative ? minusSign : '+'}${summaryAmount(raw, decimals)}';
}

/// Summary figure for nanoERG, without the unit.
String summaryErg(int nanoErg) => summaryAmount(BigInt.from(nanoErg), 9);

/// Full-precision ERG for detail surfaces, grouped.
String detailErg(int nanoErg) => groupThousands(formatScaled(nanoErg, 9));

/// "≈ A$11,951.52"; a value too small to show reads "< A$0.01" rather
/// than a misleading zero.
String fiatFigure(double value, FiatCurrency currency, {bool approximate = true}) {
  final smallest = math.pow(10, -currency.decimals).toDouble();
  if (value > 0 && value < smallest) {
    return '<$nbsp${currency.symbol}${smallest.toStringAsFixed(currency.decimals)}';
  }
  final text = groupThousands(value.abs().toStringAsFixed(currency.decimals));
  final sign = value < 0 ? minusSign : '';
  return '${approximate ? '≈$nbsp' : ''}$sign${currency.symbol}$text';
}

/// "+2.4%" / "−0.8%", one decimal; the sign carries the direction for
/// readers who cannot tell the colours apart.
String percentChange(double percent) {
  final rounded = (percent * 10).round() / 10;
  if (rounded == 0) return '0.0%';
  return '${rounded > 0 ? '+' : minusSign}${rounded.abs().toStringAsFixed(1)}%';
}

/// Unit price of one ERG; sub-ten-cent prices keep four places.
String ergPriceFigure(double fiatPerErg, FiatCurrency currency) {
  final places = currency.decimals == 0 ? 0 : (fiatPerErg < 0.1 ? 4 : currency.decimals);
  return '${currency.symbol}${groupThousands(fiatPerErg.toStringAsFixed(places))}';
}

/// "1 token", "50 tokens", the count kept with its noun.
String countLabel(int n, String singular, [String? plural]) =>
    '${groupThousands('$n')}$nbsp${n == 1 ? singular : (plural ?? '${singular}s')}';

/// The quiet line under a balance whose wallet holds funds away from its
/// primary address: "incl. 3.2 ERG · 4 tokens on 1 other address". The
/// compact form, for an overview row, drops "incl." and reads "another
/// address" for one. Hidden balances say only that there are funds there:
/// a token count tells an onlooker as much as an amount.
String otherAddressLine(FundsElsewhere funds, {required bool hidden, bool compact = false}) {
  final parts = <String>[
    if (!hidden && funds.nanoErg != 0) '${summaryErg(funds.nanoErg)}${nbsp}ERG',
    if (!hidden && funds.tokenCount > 0) countLabel(funds.tokenCount, 'token'),
  ];
  final where = compact && funds.addressCount == 1
      ? 'on another address'
      : 'on ${countLabel(funds.addressCount, 'other address', 'other addresses')}';
  if (parts.isEmpty) return compact ? 'Funds $where' : 'incl. funds $where';
  return compact ? '${parts.join(' · ')} $where' : 'incl.$nbsp${parts.join(' · ')} $where';
}

/// "incl. 2 ERG stealth · 3 ERG in mix": the parts of a balance that are
/// not on its public addresses, or null when there are none. A pocket
/// whose amount could not be read says so rather than show a zero. [asOf]
/// dates figures older than the balance, as a locked wallet's stealth
/// scan is.
String? pocketsLine(List<PocketBalance> pockets, {required bool hidden, String? asOf}) {
  final shown = pockets.where((p) => p.pocket != Pocket.public && (p.nanoErg > 0 || p.unknown)).toList();
  if (shown.isEmpty) return null;
  final parts = [
    for (final p in shown)
      p.unknown
          ? '${p.pocket.label.toLowerCase()} unknown'
          : '${hidden ? maskedFigure : summaryErg(p.nanoErg)}${nbsp}ERG ${p.pocket.label.toLowerCase()}',
  ];
  return 'incl.$nbsp${parts.join(' · ')}${asOf == null ? '' : ', as of $asOf'}';
}

/// What the mempool does to the balance above it: "+2.5 ERG pending ·
/// 105.21 confirmed"; "Pending · 105.21 confirmed" while a broadcast's
/// value is not known yet; "•••• ERG pending" with balances hidden; null
/// when nothing is pending. The split is the one [pendingBalanceText]
/// words, so the confirmed side is the figure above less what is pending,
/// and other wallets' funds, stealth and mixes count as confirmed. Only the
/// figures are set as every summary figure here is.
String? pendingText(PendingBalance? pending, {required bool hidden}) {
  if (pending == null || !pending.hasPending) return null;
  if (hidden) return '$maskedFigure${nbsp}ERG pending';
  final delta = pending.pendingDeltaNano;
  final lead = delta == 0 ? 'Pending' : '${signedSummaryAmount(BigInt.from(delta), 9)}${nbsp}ERG pending';
  return '$lead · ${summaryErg(pending.confirmedNano)} confirmed';
}

/// One leg of a transaction as a row shows it: "+2.5 ERG", "−69 COMET",
/// or "+150 raw units of SigUSD" when nothing knows the token's scale.
String legText(AmountLeg leg) {
  final unit = leg.unit;
  if (leg.amount == BigInt.zero) return '0$nbsp$unit';
  final sign = leg.amount.isNegative ? minusSign : '+';
  final decimals = leg.decimals;
  if (decimals == null) return '$sign${rawUnitsText(leg.amount.abs())} of $unit';
  return '$sign${summaryAmount(leg.amount, decimals)}$nbsp$unit';
}

/// When a transaction happened, as short as a home row can say it: the
/// time today ("10:08 pm"), "Yesterday", the day this year ("Oct 2"), and
/// the year as well before that. Empty when the time is not known. The
/// Activity tab keeps the full "Today, 10:08 pm" form.
String shortActivityTime(int? timestampMs, {DateTime? now}) {
  if (timestampMs == null || timestampMs <= 0) return '';
  final at = DateTime.fromMillisecondsSinceEpoch(timestampMs);
  final today = now ?? DateTime.now();
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  // Calendar days, not 24-hour spans: 11 pm the night before is
  // "Yesterday" at 8 am.
  final days = DateTime.utc(today.year, today.month, today.day)
      .difference(DateTime.utc(at.year, at.month, at.day))
      .inDays;
  if (days <= 0) {
    final hour = at.hour % 12 == 0 ? 12 : at.hour % 12;
    return '$hour:${at.minute.toString().padLeft(2, '0')}$nbsp${at.hour < 12 ? 'am' : 'pm'}';
  }
  if (days == 1) return 'Yesterday';
  final day = '${months[at.month - 1]}$nbsp${at.day}';
  return at.year == today.year ? day : '$day, ${at.year}';
}

/// Splits "25,529.34" into "25,529" and ".34" so the fraction can be set
/// quieter than the whole part.
(String, String) splitFraction(String figure) {
  final dot = figure.indexOf('.');
  return dot == -1 ? (figure, '') : (figure.substring(0, dot), figure.substring(dot));
}
