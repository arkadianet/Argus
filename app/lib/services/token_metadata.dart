import '../format.dart';
import 'wallet_service.dart';

// Display helpers over the one token lookup: `WalletService.cachedTokenMeta`
// (this wallet's descriptors, the public pool-token catalog, the curated
// registry, the legacy table) plus this session's explicit loads. Every
// screen that names a token or scales an amount by its id goes through
// these, so a name learned anywhere shows everywhere at once, and an amount
// nothing can scale says so instead of passing base units off as tokens.

/// What the app knows about [id] for display, or null when nothing does.
///
/// [held] is a holding the caller already has. It is used only when no
/// layer knows the token, which happens after "Clear collectible cache":
/// published holdings keep the name and scale they were published with.
TokenBalance? tokenMetaFor(String id, {TokenBalance? held}) {
  final known = walletService.displayTokenMeta(id);
  if (known != null) return known;
  if (held != null && hasKnownScale(held)) return held;
  return null;
}

/// The start of a token id, as every screen shows a token with no name.
String shortTokenId(String id) =>
    id.length > 8 ? '${id.substring(0, 8)}…' : id;

/// The sanitised issuer name, or the start of the id. Never identity: the
/// verified tick and the impersonation warning key on the id.
String tokenLabel(String id, {TokenBalance? held}) =>
    tokenMetaFor(id, held: held)?.label ?? held?.label ?? shortTokenId(id);

/// Whether [t]'s scale came from metadata rather than being the zero a
/// holding is built with when nothing knew its token. A token issued with
/// no decimals has a known zero; a malformed declaration is not known.
bool hasKnownScale(TokenBalance t) =>
    t.decimalsEvidence != DecimalsEvidence.invalid &&
    (t.decimalsEvidence == DecimalsEvidence.valid ||
        t.metadataState != MetadataState.unavailable ||
        t.name != null ||
        t.decimals > 0);

/// Decimals for [id], or null when no layer knows them. Amounts of such a
/// token are base units and are shown and entered as raw units.
int? tokenDecimals(String id, {TokenBalance? held}) {
  final m = tokenMetaFor(id, held: held);
  return m == null || !hasKnownScale(m) ? null : m.decimals;
}

/// What an amount of a token with unknown decimals is called on screen.
const rawUnitsLabel = 'raw units';

/// [units] of token [id]: "1,234.5 SigUSD", or — when no layer knows the
/// token's decimals — "1,234,500 raw units of 03faf2cb…".
String tokenAmountText(
  BigInt units,
  String id, {
  TokenBalance? held,
  bool grouped = true,
}) {
  final label = tokenLabel(id, held: held);
  final decimals = tokenDecimals(id, held: held);
  if (decimals == null) {
    return '${formatUnits(units, 0, grouped: grouped)} $rawUnitsLabel of $label';
  }
  return '${formatUnits(units, decimals, grouped: grouped)} $label';
}

/// [units] scaled by [decimals], exact at any size, with thousands
/// separators in the whole part when [grouped]: "61,630.618".
String formatUnits(BigInt units, int decimals, {bool grouped = true}) {
  final plain = formatScaledBigInt(units, decimals);
  if (!grouped) return plain;
  final dot = plain.indexOf('.');
  final whole = dot == -1 ? plain : plain.substring(0, dot);
  final frac = dot == -1 ? '' : plain.substring(dot);
  final neg = whole.startsWith('-');
  final digits = neg ? whole.substring(1) : whole;
  final out = StringBuffer(neg ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return '$out$frac';
}
