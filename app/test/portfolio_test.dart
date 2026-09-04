import 'package:argus_wallet/services/portfolio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  _lockedWalletAddressTests();
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

// Locked wallets refresh live from the addresses they already know
void _lockedWalletAddressTests() {
  test('queries every known address, not just the display one', () {
    final a = lockedWalletAddresses(
      knownAddresses: const ['9one', '9two'],
      displayAddress: '9one',
    );
    expect(a, ['9one', '9two'], reason: 'a one-address query understates the wallet');
  });

  test('adds the display address when the snapshot has not seen it', () {
    expect(
      lockedWalletAddresses(knownAddresses: const ['9one'], displayAddress: '9three'),
      ['9one', '9three'],
    );
  });

  test('a wallet never unlocked here still gets its display address', () {
    expect(lockedWalletAddresses(knownAddresses: const [], displayAddress: '9only'), ['9only']);
  });

  test('nothing to query when there is neither', () {
    expect(lockedWalletAddresses(knownAddresses: const [], displayAddress: null), isEmpty);
    expect(lockedWalletAddresses(knownAddresses: const [''], displayAddress: ''), isEmpty);
  });

  test('duplicates are not queried twice', () {
    expect(
      lockedWalletAddresses(knownAddresses: const ['9one', '9one'], displayAddress: '9one'),
      ['9one'],
    );
  });
}
