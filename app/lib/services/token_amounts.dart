import '../format.dart';

// Pure formatting for token amounts, shared by the lookup-backed helpers in
// token_metadata.dart and by code that is given names and scales directly.

/// The start of a token id, as every screen shows a token with no name.
String shortTokenId(String id) =>
    id.length > 8 ? '${id.substring(0, 8)}…' : id;

/// What an amount of a token with unknown decimals is called on screen.
const rawUnitsLabel = 'raw units';

/// "1 raw unit" / "5,000 raw units": base units, said to be base units.
String rawUnitsText(BigInt units) =>
    '${formatUnits(units, 0)} ${units == BigInt.one ? 'raw unit' : rawUnitsLabel}';

/// [units] of a token called [label], scaled by [decimals]: "1.5 SigUSD".
/// With [decimals] null — nothing knows the token's scale — the base units
/// the chain carries are shown as what they are: "150 raw units of SigUSD",
/// never as if they were whole tokens.
String unitsWithLabel(
  BigInt units,
  int? decimals,
  String label, {
  bool grouped = true,
}) => decimals == null
    ? '${rawUnitsText(units)} of $label'
    : '${formatUnits(units, decimals, grouped: grouped)} $label';

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
