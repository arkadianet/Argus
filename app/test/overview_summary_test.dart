import 'package:argus_wallet/ui/wallets_overview_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('counts wallets and watch-only addresses in the headline', () {
    expect(overviewHeadline(wallets: 2, watchOnly: 0), '2 wallets');
    expect(overviewHeadline(wallets: 1, watchOnly: 3), '1 wallet · 3 watch-only');
    expect(overviewHeadline(wallets: 0, watchOnly: 1), '1 watch-only address');
  });

  test('visible total adds known wallet and watch-only balances', () {
    expect(overviewTotalLine(known: 0, total: 0), 'Total balance unavailable');
    expect(overviewTotalLine(known: 2, total: 2500000000), 'Visible total  2.5 ERG');
  });
}
