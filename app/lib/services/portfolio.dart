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
