import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/privacy_service.dart';
import 'package:argus_wallet/services/public_wallet_sync.dart';
import 'package:argus_wallet/services/stealth_service.dart';
import 'package:argus_wallet/services/wallet_database_service.dart';
import 'package:argus_wallet/services/watch_account_service.dart';
import 'package:argus_wallet/services/watch_only_service.dart';
import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/home_finders.dart';
import 'support/home_harness.dart';
import 'support/render_harness.dart';

// Opt-in screenshots of the overview and wallet pages (A1–A4) as the app
// wires them, for a person to look at: ARGUS_RENDER=1 flutter test
// test/ui_render_test.dart writes them to ui-renders/, and the redesigned
// screens in Harbor and the default dark palette to ui-renders/wired/.
// Without the variable each scenario still runs as a layout check at phone
// size and at large text, where an overflow fails it.

const vanity = '9evoke9Rk4VQ7pMfXa1nG2sT8wLcYe3HdJ5uBq6ZhNv0xKmPoW';
const zero = '9fRAxbQ2mTe8LwZk5Ny7cVh3PdG6uJs1BqX4aKoHnYtMv9WEeR';
const savingsZero = '9gNq4TuKd8VbXo2WcM6sYh1PeR7aLj3FzQ5mHnGk9tBvC0iDu';
const watchedAddress = '9iWatchHq3Nb7Kx2Ty5Vm8Gc1Rz4Fd6Ls9Pw0Ja3Ue7Mo2Yk';
const accountKey =
    '0488b21e04220c2217000000009216e49a70865823eff5381d6fd33ac96743af1f3051dc4cc8edd66a29a740860326cfc301b0c8d4d815ac721e0551304417e6133c2c9137f9f22c33895a3e1650';
const tokenA =
    '03faf2cb329f2e90d6d23b58d91bbb6c046aa143261cc21f52fbe2824bfcbf04';
const tokenB =
    '8b08cdd5449a9592a9e79711d7d79249d7a03c535d17efaee83e216e80a44c4b';
const tokenC =
    '0cd8c9f416e5b1ca9f986a7f10a84191dfb85941619e49e53c0dc30ebf83324b';
const tokenD =
    '1fd6e032e8476c4aa54c18c1a308dce83940e8f4a28f576440513ed7326ad489';

Map<String, dynamic> tokens(List<(String, int)> held) => {
  'tokens': [
    for (final (id, amount) in held) {'id': id, 'amount': amount},
  ],
};

void main() {
  final api = HomeApi()
    ..derived = ((i) => switch (i) {
      0 => zero,
      275 => vanity,
      _ => '9hDerived$i',
    })
    ..watchDerived = ((i) => i == 0 ? watchedAddress : '9iAccount$i');

  setUpAll(() async {
    RustLib.initMock(api: api);
    await loadAppFonts();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'argus_watch_only_addresses': '["$watchedAddress"]',
    });
    await watchOnlyService.load();
    await privacyService.load();
    stealthService.scanEnabled = false;
    api.balances
      ..clear()
      ..[zero] = {
        'balance_nano_erg': 3200000000,
        ...tokens([(tokenA, 150), (tokenB, 2), (tokenC, 1), (tokenD, 9)]),
      }
      ..[vanity] = {
        'balance_nano_erg': 9314000000,
        ...tokens([(tokenA, 25)]),
      }
      ..[watchedAddress] = {
        'balance_nano_erg': 25421629296273,
        ...tokens([(tokenB, 40)]),
      };
    api.histories
      ..clear()
      ..[vanity] = [
        {
          'tx_id': 'a1',
          'height': 1500000,
          'timestamp': 1759700000000,
          'value_nano_erg': 2500000000,
        },
        {
          'tx_id': 'a2',
          'height': 1499000,
          'timestamp': 1759600000000,
          'value_nano_erg': -1000000000,
        },
      ]
      ..[watchedAddress] = [
        {
          'tx_id': 'w1',
          'height': 1500010,
          'timestamp': 1759710000000,
          'value_nano_erg': 1000000000000,
        },
      ];
    api.discovery = {
      'addresses': [
        {
          'index': 0,
          'address': zero,
          'balance_nano_erg': 3200000000,
          ...tokens([(tokenA, 150), (tokenB, 2), (tokenC, 1), (tokenD, 9)]),
        },
      ],
      'next_unused_index': 1,
    };
    // Snapshot figures stay as written: no public refresh replaces them.
    publicWalletSync.setForeground(false);
    final account = WatchAccount(accountKey, label: 'Ledger account')
      ..snapshot = WatchAccountSnapshot(
        [watchedAddress, '9iAccount1'],
        '9iAccount2',
        4200000000,
        {tokenA: 12},
        [
          {
            'tx_id': 'x1',
            'height': 1500020,
            'timestamp': 1759720000000,
            'value_nano_erg': 4200000000,
          },
        ],
        1,
      );
    watchAccountService.accounts
      ..clear()
      ..add(account);
  });

  tearDown(() {
    publicWalletSync.setForeground(true);
    watchAccountService.accounts.clear();
    stealthService.scanEnabled = true;
  });

  /// Two seed wallets: the pinned "9evoke9", last seen with funds on index
  /// 0 as well, and "Savings", never synced on this device.
  Future<void> seedWallets(WidgetTester tester, FakeKeystore keystore) async {
    keystore.install(tester);
    await tester.runAsync(() async {
      await saveWallet(
        'w-evoke',
        name: '9evoke9',
        address0: zero,
        pinnedIndex: 275,
        pinnedAddress: vanity,
      );
      await saveWallet('w-savings', name: 'Savings', address0: savingsZero);
      await WalletDatabaseService.savePublicSnapshot('w-evoke', {
        'wallet_id': 'w-evoke',
        'primary_address': vanity,
        'frontier_addresses': [zero],
        'used_addresses': [
          {'index': 0, 'address': zero},
        ],
        'balance_nano_erg': 12514000000,
        'tokens': [
          {'id': tokenA, 'amount': 175, 'decimals': 0},
          {'id': tokenB, 'amount': 2, 'decimals': 0},
          {'id': tokenC, 'amount': 1, 'decimals': 0},
          {'id': tokenD, 'amount': 9, 'decimals': 0},
        ],
        'address_holdings': [
          {
            'address': zero,
            'index': 0,
            'balance_nano_erg': 3200000000,
            ...tokens([(tokenA, 150), (tokenB, 2), (tokenC, 1), (tokenD, 9)]),
          },
          {
            'address': vanity,
            'index': null,
            'balance_nano_erg': 9314000000,
            ...tokens([(tokenA, 25)]),
          },
        ],
        'public_only': true,
        'last_sync_timestamp': DateTime.now()
            .subtract(const Duration(hours: 3))
            .millisecondsSinceEpoch,
      }, () => true);
    });
  }

  for (final scale in [1.0, 2.0]) {
    final tag = scale == 1 ? '' : '@2x';

    testWidgets('overview with every kind of wallet$tag', (tester) async {
      await seedWallets(
        tester,
        FakeKeystore(wallets: ['w-evoke', 'w-savings']),
      );
      await pumpHome(tester, textScale: scale);
      expect(textPlainContaining('TOTAL BALANCE'), findsOneWidget);
      expect(textPlainContaining('on another address'), findsOneWidget);
      await renderPng(tester, 'overview$tag');
      await tester.scrollUntilVisible(
        find.byKey(const Key('overview-add-wallet')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await renderPng(tester, 'overview-bottom$tag');
      await disposeHome(tester);
    });

    testWidgets('overview with no wallets$tag', (tester) async {
      SharedPreferences.setMockInitialValues({
        'argus_watch_only_addresses': '[]',
      });
      await watchOnlyService.load();
      watchAccountService.accounts.clear();
      FakeKeystore(wallets: const []).install(tester);
      await pumpHome(tester, textScale: scale);
      expect(find.byKey(const Key('overview-create')), findsOneWidget);
      await renderPng(tester, 'overview-empty$tag');
      await disposeHome(tester);
    });

    testWidgets('a cancelled biometric prompt leaves the gate$tag', (
      tester,
    ) async {
      final keystore = FakeKeystore(wallets: ['w-evoke', 'w-savings']);
      await seedWallets(tester, keystore);
      await pumpHome(tester, textScale: scale);
      await tester.tap(find.byKey(const ValueKey('overview-row-seed-w-evoke')));
      await tester.pumpAndSettle();
      expect(keystore.prompts, 1);
      expect(find.byKey(const Key('gate-unlock')), findsOneWidget);
      await renderPng(tester, 'wallet-locked$tag');
      await tester.tap(find.byKey(const Key('gate-use-pin')));
      await tester.pumpAndSettle();
      await renderPng(tester, 'wallet-locked-pin$tag');
      await disposeHome(tester);
    });

    testWidgets('an unlocked wallet with funds on another address$tag', (
      tester,
    ) async {
      final keystore = FakeKeystore(wallets: ['w-evoke', 'w-savings'])
        ..biometricResult = 'wrap-key';
      await seedWallets(tester, keystore);
      await pumpHome(tester, textScale: scale);
      await tester.tap(find.byKey(const ValueKey('overview-row-seed-w-evoke')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('wallet-balance')), findsOneWidget);
      await renderPng(tester, 'wallet-unlocked$tag');
      await tester.ensureVisible(find.byKey(const Key('funds-elsewhere')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('funds-elsewhere')));
      await tester.pumpAndSettle();
      await renderPng(tester, 'wallet-address-breakdown$tag');
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Recent activity'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await renderPng(tester, 'wallet-unlocked-lower$tag');
      await tester.tap(find.widgetWithText(NavigationDestination, 'Discover'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('discover-ageusd')), findsOneWidget);
      await renderPng(tester, 'wallet-discover-tab$tag');
      await tester.tap(find.widgetWithText(NavigationDestination, 'Settings'));
      await tester.pumpAndSettle();
      await renderPng(tester, 'wallet-settings-tab$tag');
      await tester.tap(find.text('Name, addresses and backup'));
      await tester.pumpAndSettle();
      await renderPng(tester, 'wallet-settings-page$tag');
      await tester.scrollUntilVisible(
        find.text('Remove wallet'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await renderPng(tester, 'wallet-settings-page-lower$tag');
      await disposeHome(tester);
    });

    testWidgets('a watched address on the standard page$tag', (tester) async {
      await seedWallets(
        tester,
        FakeKeystore(wallets: ['w-evoke', 'w-savings']),
      );
      await pumpHome(tester, textScale: scale);
      final row = find.byKey(
        const ValueKey('overview-row-watchedAddress-$watchedAddress'),
      );
      await tester.scrollUntilVisible(
        row,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      await renderPng(tester, 'watched-address$tag');
      await tester.scrollUntilVisible(
        find.text('Recent activity'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await renderPng(tester, 'watched-address-lower$tag');
      await tester.tap(find.widgetWithText(NavigationDestination, 'Activity'));
      await tester.pumpAndSettle();
      await renderPng(tester, 'watched-address-activity$tag');
      await tester.tap(find.widgetWithText(NavigationDestination, 'Settings'));
      await tester.pumpAndSettle();
      await renderPng(tester, 'watched-address-settings$tag');
      await disposeHome(tester);
    });

    testWidgets('a watched account on the standard page$tag', (tester) async {
      await seedWallets(
        tester,
        FakeKeystore(wallets: ['w-evoke', 'w-savings']),
      );
      await pumpHome(tester, textScale: scale);
      final row = find.byKey(
        const ValueKey('overview-row-watchedAccount-$accountKey'),
      );
      await tester.scrollUntilVisible(
        row,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      await renderPng(tester, 'watched-account$tag');
      await tester.scrollUntilVisible(
        find.text('First address'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await renderPng(tester, 'watched-account-lower$tag');
      await disposeHome(tester);
    });
  }

  testWidgets('overview with balances hidden, dark', (tester) async {
    await seedWallets(tester, FakeKeystore(wallets: ['w-evoke', 'w-savings']));
    await privacyService.setHideBalances(true);
    addTearDown(() => privacyService.setHideBalances(false));
    await pumpHome(tester, dark: true);
    expect(plainOf(tester, find.byKey(const Key('overview-total'))), '•••••• ERG');
    expect(textPlain('Funds on another address'), findsOneWidget);
    await renderPng(tester, 'overview-hidden-dark');
    await disposeHome(tester);
  });

  // The redesigned home as the app wires it, from the same mock node: the
  // overview, an unlocked wallet and its address breakdown, the locked page
  // after a cancelled fingerprint prompt, and a watched address, in Harbor
  // (teal) and the default dark palette. Written to ui-renders/wired/.
  for (final (palette, look) in [(harborPalette, 'teal'), (watchfulPalette, 'dark')]) {
    testWidgets('wired screens, $look', (tester) async {
      final keystore = FakeKeystore(wallets: ['w-evoke', 'w-savings']);
      await seedWallets(tester, keystore);
      await pumpHome(tester, palette: palette);
      expect(tester.takeException(), isNull);
      await renderPng(tester, 'wired/overview-$look-1x');

      // A cancelled prompt: the locked page, with Unlock and Use PIN.
      await tester.tap(find.byKey(const ValueKey('overview-row-seed-w-evoke')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('gate-unlock')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await renderPng(tester, 'wired/locked-$look-1x');

      // Unlocked from the gate: the wallet page.
      keystore.biometricResult = 'wrap-key';
      await tester.tap(find.byKey(const Key('gate-unlock')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('wallet-balance')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await renderPng(tester, 'wired/wallet-$look-1x');
      await tester.tap(find.byKey(const Key('funds-elsewhere')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('holding-$vanity')), findsOneWidget);
      await renderPng(tester, 'wired/breakdown-$look-1x');
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();

      // Back to every wallet, and into the watched address.
      await tester.tap(find.byTooltip('All wallets'));
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('overview-row-watchedAddress-$watchedAddress'));
      await tester.scrollUntilVisible(row, 300, scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('watch-action-send')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await renderPng(tester, 'wired/watched-$look-1x');
      await disposeHome(tester);
    });
  }
}
