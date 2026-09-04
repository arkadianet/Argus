/// Total across every wallet and watched address the home screen shows.
class PortfolioTotal {
  const PortfolioTotal({required this.totalNano, required this.known, required this.unknown});
  final int totalNano;
  final int known;
  final int unknown;
}

PortfolioTotal portfolioTotal(Iterable<int?> balances) {
  var total = 0;
  var known = 0;
  var unknown = 0;
  for (final b in balances) {
    if (b == null || b < 0) {
      unknown++;
    } else {
      known++;
      total += b;
    }
  }
  return PortfolioTotal(totalNano: total, known: known, unknown: unknown);
}

String portfolioSubtitle({required int wallets, required int watched, required int unknown}) {
  final parts = <String>['$wallets ${wallets == 1 ? 'wallet' : 'wallets'}'];
  if (watched > 0) parts.add('$watched watched');
  if (unknown > 0) parts.add('$unknown not loaded');
  return parts.join(' · ');
}

/// Addresses to query for a wallet that is not the active one.
///
/// Viewing a balance needs no authorisation: the addresses are public and
/// were already recorded when this wallet was last unlocked. What a locked
/// wallet cannot do is derive *new* addresses, so a payment to an address
/// discovered after its last unlock is not counted until it is unlocked
/// again. Everything already known refreshes live.
List<String> lockedWalletAddresses({
  required List<String> knownAddresses,
  required String? displayAddress,
}) {
  final out = <String>[];
  for (final a in knownAddresses) {
    if (a.isNotEmpty && !out.contains(a)) out.add(a);
  }
  final d = displayAddress;
  if (d != null && d.isNotEmpty && !out.contains(d)) out.add(d);
  return out;
}
