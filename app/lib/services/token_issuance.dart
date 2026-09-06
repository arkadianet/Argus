/// Validation for issuing a token, shared by the form and its tests.
library;

/// The problem with an issuance as typed, or null when it is fine.
String? issuanceError({
  required String name,
  required String amountText,
  required int decimals,
  required bool nft,
  String contentHashHex = '',
  String url = '',
}) {
  if (name.trim().isEmpty) return 'Give the token a name';
  if (name.trim().length > 64) return 'Name is too long (64 characters at most)';
  if (decimals < 0 || decimals > 18) return 'Decimals must be between 0 and 18';
  final amount = parseIssuanceAmount(amountText, decimals);
  if (amount == null) return 'Enter the amount to issue';
  if (amount <= BigInt.zero) return 'Amount must be above zero';
  if (amount > BigInt.parse('9223372036854775807')) return 'Amount is beyond what a box can hold';
  if (nft) {
    if (decimals != 0) return 'An NFT has no decimals';
    if (amount != BigInt.one) return 'An NFT is one unit';
    final h = contentHashHex.trim().toLowerCase();
    if (h.isNotEmpty && !RegExp(r'^[0-9a-f]{64}$').hasMatch(h)) return 'Content hash must be 64 hex characters (SHA-256)';
    if (url.trim().isNotEmpty && !RegExp(r'^(https?|ipfs)://').hasMatch(url.trim())) return 'Link must start with https:// or ipfs://';
  }
  return null;
}

/// The supply in base units: `amountText` scaled by `decimals`, exactly.
BigInt? parseIssuanceAmount(String amountText, int decimals) {
  final t = amountText.trim().replaceAll(',', '');
  if (t.isEmpty || !RegExp(r'^\d*\.?\d*$').hasMatch(t) || t == '.') return null;
  final parts = t.split('.');
  final whole = parts[0].isEmpty ? '0' : parts[0];
  final frac = parts.length > 1 ? parts[1] : '';
  if (frac.length > decimals) return null;
  return BigInt.tryParse(whole + frac.padRight(decimals, '0'));
}

/// The word the user must type before a burn goes ahead.
const burnConfirmWord = 'BURN';
