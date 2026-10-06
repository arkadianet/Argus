import 'token_amounts.dart';
import 'wallet_service.dart';

export 'token_amounts.dart';

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

/// The sanitised issuer name, or the start of the id. Never identity: the
/// verified tick and the impersonation warning key on the id.
String tokenLabel(String id, {TokenBalance? held}) =>
    tokenMetaFor(id, held: held)?.label ?? held?.label ?? shortTokenId(id);

/// [tokenLabel] for text that will be saved. It leaves out this session's
/// explicitly loaded descriptors, which are memory-only by design: a name
/// learned that way must not outlive the session inside a stored record.
String storedTokenLabel(String id, {TokenBalance? held}) =>
    walletService.cachedTokenMeta(id)?.label ??
    held?.label ??
    shortTokenId(id);

/// The sanitised issuer name, or null when nothing has named the token.
String? tokenName(String id, {TokenBalance? held}) {
  final name = (tokenMetaFor(id, held: held)?.name ?? held?.name)?.trim();
  return name == null || name.isEmpty ? null : name;
}

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

/// A holding's amount in its own scale, "1,234.5", or "5,000 raw units"
/// when nothing knows its decimals. [units] stands in for the amount, for
/// a part of the holding such as what sits in stealth boxes.
String holdingAmountText(TokenBalance t, {int? units}) {
  final amount = BigInt.from(units ?? t.amount);
  return hasKnownScale(t)
      ? formatUnits(amount, t.decimals)
      : rawUnitsText(amount);
}

/// [text], typed as an amount at [was] decimals, rewritten at [now] so it
/// still stands for the same base units: "150" typed as raw units becomes
/// "1.5" once the token turns out to have two decimals. The lookup can
/// learn a scale while a figure sits in a field, and the same text would
/// otherwise silently mean a different amount. Null when [text] does not
/// parse at [was]; the caller clears the field rather than guess.
String? rescaleAmountText(String text, int was, int now) {
  final units = parseDecimalToBase(text, was);
  return units == null
      ? null
      : formatUnits(BigInt.from(units), now, grouped: false);
}

/// [units] of token [id]: "1,234.5 SigUSD", or — when no layer knows the
/// token's decimals — "1,234,500 raw units of 03faf2cb…".
String tokenAmountText(
  BigInt units,
  String id, {
  TokenBalance? held,
  bool grouped = true,
}) => unitsWithLabel(
  units,
  tokenDecimals(id, held: held),
  tokenLabel(id, held: held),
  grouped: grouped,
);
