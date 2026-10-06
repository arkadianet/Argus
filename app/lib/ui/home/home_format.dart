import 'dart:math' as math;

import '../../format.dart';
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
String otherAddressLine(OtherAddressFunds funds, {required bool hidden, bool compact = false}) {
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

/// "+2.5 ERG pending", or the token count alone when no ERG moves. The
/// short form, beside a figure already in ERG, leaves the unit out.
String pendingLine(PendingFunds pending, {required bool hidden, bool short = false}) {
  final unit = short ? '' : '${nbsp}ERG';
  final parts = <String>[
    if (pending.nanoErg != 0)
      hidden ? '$maskedFigure$unit' : '${signedSummaryAmount(BigInt.from(pending.nanoErg), 9)}$unit',
    if (pending.tokenCount > 0) countLabel(pending.tokenCount, 'token'),
  ];
  return '${parts.join(' · ')}${nbsp}pending';
}

/// Splits "25,529.34" into "25,529" and ".34" so the fraction can be set
/// quieter than the whole part.
(String, String) splitFraction(String figure) {
  final dot = figure.indexOf('.');
  return dot == -1 ? (figure, '') : (figure.substring(0, dot), figure.substring(dot));
}
