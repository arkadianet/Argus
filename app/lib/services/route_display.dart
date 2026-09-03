import '../format.dart';

/// Price impact of paying [ergIn] for [tokensOut] against a pool holding
/// [ergReserves] / [tokenReserves]: how far the effective price sits above
/// the spot price, in percent. Null when the pool has no depth.
double? priceImpactPct({
  required int ergIn,
  required int tokensOut,
  required int ergReserves,
  required int tokenReserves,
}) {
  if (ergReserves <= 0 || tokenReserves <= 0 || tokensOut <= 0 || ergIn <= 0) return null;
  // Reserve-based, so an integer output of a low-decimal token does not
  // report its rounding as impact.
  return ergIn / (ergReserves + ergIn) * 100;
}

/// Above this, a route is flagged so the user reads the number.
const priceImpactWarnPct = 3.0;

String? impactWarning(double? pct) {
  if (pct == null || pct <= priceImpactWarnPct) return null;
  return 'High price impact: ${pct.toStringAsFixed(1)}%. This pool is shallow '
      'for that amount; a smaller send or another route would cost less.';
}

/// `pool 123.46 ERG`, or empty when unknown.
String liquidityLabel(int? ergReservesNano) =>
    ergReservesNano == null ? '' : 'pool ${formatErg(ergReservesNano, maxFrac: 2)}';
