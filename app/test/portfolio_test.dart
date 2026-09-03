import 'package:argus_wallet/services/portfolio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sums only the balances it knows and reports how many were unknown', () {
    final p = portfolioTotal([100, null, 250]);
    expect(p.totalNano, 350);
    expect(p.unknown, 1);
    expect(p.known, 2);
  });

  test('subtitle counts wallets and watched addresses', () {
    expect(portfolioSubtitle(wallets: 3, watched: 1, unknown: 0), '3 wallets · 1 watched');
    expect(portfolioSubtitle(wallets: 1, watched: 0, unknown: 0), '1 wallet');
    expect(portfolioSubtitle(wallets: 2, watched: 0, unknown: 1), '2 wallets · 1 not loaded');
  });
}
