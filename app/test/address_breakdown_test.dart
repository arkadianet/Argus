import 'package:argus_wallet/services/address_holdings.dart';
import 'package:argus_wallet/services/wallet_database_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/ui/home/address_breakdown.dart';
import 'package:argus_wallet/ui/home/overview_model.dart';
import 'package:argus_wallet/ui/home/wallet_sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// A4 on screen: the pinned address stays the identity, the balance is the
// whole wallet, and a quiet line leads to where the rest sits.

AddressHolding h(String address, int nano, {int? index, List<(String, int)> tokens = const []}) =>
    AddressHolding(
      address: address,
      index: index,
      nanoErg: nano,
      tokens: [for (final (id, amount) in tokens) (id: id, amount: amount)],
    );

const vanity = '9evoke9Rk4VQ7pMfXa1nG2sT8wLcYe3HdJ5uBq6ZhNv0xKmPoW';
const zero = '9fRAxbQ2mTe8LwZk5Ny7cVh3PdG6uJs1BqX4aKoHnYtMv9WEeR';

void main() {
  test('the breakdown lists the identity first, then funded addresses by index', () {
    final rows = breakdownRows([
      h('late', 1, index: 9),
      h('empty', 0, index: 1),
      h('pinned', 5, index: 275),
      h('zero', 2, index: 0),
      h('unknown', 3),
    ], identity: 'pinned');
    expect([for (final r in rows.listed) r.address], ['pinned', 'zero', 'late', 'unknown']);
    expect(rows.emptyOthers, 1);
  });

  test('the overview row says what a locked wallet keeps elsewhere', () {
    final wallet = WalletInfo(
      walletId: 'w9',
      name: '9evoke9',
      createdAt: DateTime(2026),
      address0: 'zero',
      pinnedAddressIndex: 275,
      pinnedAddress: 'vanity',
    );
    final known = LastKnownBalance(
      balanceNano: 12,
      age: const Duration(hours: 3),
      addressHoldings: [h('vanity', 9), h('zero', 3, tokens: [('a', 1)])],
    );
    final row = buildOverviewEntries(
      wallets: [wallet],
      lastKnown: {'w9': known},
      unlockedWalletId: null,
    ).single;
    expect(row.address, 'vanity');
    expect(row.balanceNano, 12, reason: 'the whole wallet, not the pinned address');
    expect(row.elsewhere!.nanoErg, 3);
    expect(row.elsewhere!.tokenCount, 1);
  });

  test('a wallet with everything on its identity shows no line', () {
    final wallet = WalletInfo(walletId: 'w1', name: 'One', createdAt: DateTime(2026), address0: 'zero');
    final row = buildOverviewEntries(
      wallets: [wallet],
      lastKnown: {
        'w1': LastKnownBalance(
          balanceNano: 5,
          age: Duration.zero,
          addressHoldings: [h('zero', 5), h('one', 0, index: 1)],
        ),
      },
      unlockedWalletId: null,
    ).single;
    expect(row.elsewhere, isNull);
  });

  Future<void> card(WidgetTester tester, {required bool hidden}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final holdings = withWalletIndexes(
      [
        h(vanity, 9314000000, tokens: [('a', 25)]),
        h(zero, 3200000000, tokens: [('a', 150), ('b', 2), ('c', 1), ('d', 9)]),
        h('9empty', 0, index: 1),
      ],
      address0: zero,
      pinnedAddress: vanity,
      pinnedIndex: 275,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => WalletBalanceCard(
              label: 'BALANCE',
              balanceNano: 12514000000,
              hidden: hidden,
              onToggleHidden: () {},
              identity: const WalletIdentityLine(address: vanity, pinnedIndex: 275),
              elsewhere: fundsElsewhere(holdings, identity: vanity),
              onElsewhere: () => showAddressBreakdownSheet(
                context,
                walletName: '9evoke9',
                holdings: holdings,
                identity: vanity,
                hidden: hidden,
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('the line leads to a per-address breakdown with the pinned one marked', (
    tester,
  ) async {
    await card(tester, hidden: false);
    expect(find.text('12.514'), findsOneWidget, reason: 'the whole wallet');
    expect(find.text('#275'), findsOneWidget);
    await tester.tap(find.text('incl. 3.2 ERG · 4 tokens on 1 other address'));
    await tester.pumpAndSettle();
    expect(find.text('Where 9evoke9 holds funds'), findsOneWidget);
    final pinned = find.byKey(const ValueKey('holding-$vanity'));
    final first = find.byKey(const ValueKey('holding-$zero'));
    expect(find.descendant(of: pinned, matching: find.text('#275')), findsOneWidget);
    expect(find.descendant(of: pinned, matching: find.text('Shown as this wallet')), findsOneWidget);
    expect(find.descendant(of: pinned, matching: find.text('9.314 ERG')), findsOneWidget);
    expect(find.descendant(of: pinned, matching: find.text('1 token')), findsOneWidget);
    expect(find.descendant(of: first, matching: find.text('#0')), findsOneWidget);
    expect(find.descendant(of: first, matching: find.text('3.2 ERG')), findsOneWidget);
    expect(find.descendant(of: first, matching: find.text('4 tokens')), findsOneWidget);
    expect(find.descendant(of: first, matching: find.text('Shown as this wallet')), findsNothing);
    expect(find.text('1 other known address holds nothing.'), findsOneWidget);
    expect(tester.getTopLeft(pinned).dy, lessThan(tester.getTopLeft(first).dy));
  });

  testWidgets('with balances hidden the line and the breakdown show no amounts', (tester) async {
    await card(tester, hidden: true);
    expect(find.text('••••••'), findsOneWidget);
    await tester.tap(find.text('incl. funds on 1 other address'));
    await tester.pumpAndSettle();
    expect(find.text('•••• ERG'), findsNWidgets(2));
    expect(find.textContaining('3.2'), findsNothing);
    expect(find.textContaining('tokens'), findsNothing);
  });
}
