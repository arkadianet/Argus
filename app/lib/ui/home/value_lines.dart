import '../../services/network_controller.dart';
import '../../services/token_pricer.dart';
import '../../services/token_pricing.dart';

typedef Holding = ({String id, int amount, int decimals});

/// "≈ $1,234.56 USD · 2 unpriced · prices stale" under a headline figure:
/// ERG plus every priced token, and what the figure leaves out. Masked
/// rather than omitted while balances are hidden, so the line does not
/// jump when they are shown again.
String? headlineValueLine({
  required int? ergNano,
  required Iterable<Holding> tokens,
  required bool hidden,
}) {
  final code = networkController.fiatCode.toUpperCase();
  if (hidden) return '≈ ${networkController.fiatSymbol}•••• $code';
  final value = holdingsValue(
    ergNano: ergNano,
    tokens: tokens,
    result: tokenPricer.result,
  );
  final fiat = tokenPricer.fiatTextForUsd(
    tokenPricer.result.ergUsd == null ? null : value.usd,
  );
  // Each caveat stands on its own: an unpriced wallet must still be told
  // that the figure omits what nobody could price.
  final parts = <String>[
    if (fiat != null) '$fiat $code',
    if (fiat != null && value.unpriced + value.excluded > 0)
      '${value.unpriced + value.excluded} unpriced',
    if (fiat != null && tokenPricer.stale) 'prices stale',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// "≈ $12.30" for one wallet row: ERG plus whatever tokens it holds, since a
/// row showing only its ERG value understates a wallet worth mostly tokens.
String? rowValueText({
  required int? ergNano,
  required Iterable<Holding> tokens,
  required bool hidden,
}) {
  if (ergNano == null || hidden) return null;
  if (tokenPricer.result.ergUsd == null)
    return networkController.fiatText(ergNano);
  final usd = holdingsValue(
    ergNano: ergNano,
    tokens: tokens,
    result: tokenPricer.result,
  ).usd;
  return tokenPricer.fiatTextForUsd(usd);
}
