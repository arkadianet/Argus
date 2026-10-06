import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/format.dart';
import 'package:argus_wallet/services/privacy_service.dart';
import 'package:argus_wallet/services/public_wallet_sync.dart';
import 'package:argus_wallet/services/stealth_service.dart';
import 'package:argus_wallet/services/wallet_database_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/watch_account_service.dart';
import 'package:argus_wallet/services/watch_only_service.dart';
import 'package:argus_wallet/ui/home/overview_model.dart';
import 'package:argus_wallet/ui/settings_screen.dart';
import 'package:argus_wallet/ui/wallets_overview_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/home_harness.dart';

// A1: the app opens on an overview of every wallet on the device, with
// balances that need no unlock and the total across them.

const vanity = '9vanityPinnedAddressAtIndex275xxxxxxxxxxxxxxxxxxxxx';
const zero = '9zeroAddressOfThePinnedWalletxxxxxxxxxxxxxxxxxxxxxxx';
const watched = '9watchedAddressForTheOverviewTestsxxxxxxxxxxxxxxxxxx';

Map<String, dynamic> snapshot(String id, int nano, {int ageMinutes = 1}) => {
      'wallet_id': id,
      'primary_address': vanity,
      'frontier_addresses': [zero],
      'balance_nano_erg': nano,
      'tokens': [],
      'address_holdings': [
        {'address': zero, 'index': 0, 'balance_nano_erg': 3000000000, 'tokens': []},
        {'address': vanity, 'balance_nano_erg': nano - 3000000000, 'tokens': []},
      ],
      'public_only': true,
      'public_refreshed_at':
          DateTime.now().subtract(Duration(minutes: ageMinutes)).millisecondsSinceEpoch,
      'last_sync_timestamp':
          DateTime.now().subtract(Duration(minutes: ageMinutes)).millisecondsSinceEpoch,
    };

void main() {
  final api = HomeApi();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'argus_watch_only_addresses': '["$watched"]',
    });
    await watchOnlyService.load();
    await privacyService.load();
    stealthService.scanEnabled = false;
    // One scheduler for the whole test run: each launch starts due.
    publicWalletSync.resetSchedule();
    api.balances
      ..clear()
      ..[watched] = {'balance_nano_erg': 2500000000, 'tokens': []};
    api.balanceCalls.clear();
    watchAccountService.accounts
      ..clear()
      ..add(
        WatchAccount('overview-account', label: 'Cold account')
          ..snapshot = WatchAccountSnapshot([watched], watched, 1000000000, {}, [], -1),
      );
  });
  tearDown(() async {
    watchAccountService.accounts.clear();
    stealthService.scanEnabled = true;
    publicWalletSync.setForeground(true);
    if (walletService.isUnlocked) await walletService.lock();
  });

  Future<void> wallets(
    WidgetTester tester, {
    Map<String, dynamic>? pinnedSnapshot,
  }) async {
    FakeKeystore(wallets: ['ov-pinned', 'ov-plain']).install(tester);
    await tester.runAsync(() async {
      await saveWallet('ov-pinned', name: 'Vanity', address0: zero, pinnedIndex: 275, pinnedAddress: vanity);
      await saveWallet('ov-plain', name: 'Plain', address0: '9plain');
      if (pinnedSnapshot != null) {
        await WalletDatabaseService.savePublicSnapshot('ov-pinned', pinnedSnapshot, () => true);
      }
    });
  }

  testWidgets('every kind of wallet, its balance, and the total across them', (tester) async {
    publicWalletSync.setForeground(false);
    await wallets(tester, pinnedSnapshot: snapshot('ov-pinned', 12000000000));
    await pumpHome(tester);
    expect(walletService.isUnlocked, isFalse);
    for (final name in ['Vanity', 'Plain', 'Watched address', 'Cold account']) {
      expect(find.text(name), findsOneWidget, reason: name);
    }
    // 12 + 2.5 + 1 ERG; the never-synced wallet is counted as not loaded.
    expect(
      tester.widget<Text>(find.byKey(const Key('overview-total'))).data,
      formatErg(15500000000, unit: false, maxFrac: 4),
    );
    expect(find.textContaining('1 not loaded'), findsOneWidget);
    // The pinned wallet is shown as its pinned address, with what index 0
    // holds called out under it.
    final row = find.byKey(const ValueKey('overview-row-seed-ov-pinned'));
    expect(find.descendant(of: row, matching: find.text(shorten(vanity, head: 6, tail: 6))), findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.text('incl. 3 ERG on 1 other address')),
      findsOneWidget,
    );
    await disposeHome(tester);
  });

  testWidgets('hidden balances mask the total and every row', (tester) async {
    publicWalletSync.setForeground(false);
    await privacyService.setHideBalances(true);
    addTearDown(() => privacyService.setHideBalances(false));
    await wallets(tester, pinnedSnapshot: snapshot('ov-pinned', 12000000000));
    await pumpHome(tester);
    expect(tester.widget<Text>(find.byKey(const Key('overview-total'))).data, '••••••');
    expect(find.text('12'), findsNothing);
    expect(find.text('2.5'), findsNothing);
    expect(find.text('••••'), findsNWidgets(3), reason: 'every row with a known balance');
    expect(find.text('incl. funds on 1 other address'), findsOneWidget);
    expect(find.textContaining('3 ERG'), findsNothing);
    await disposeHome(tester);
  });

  testWidgets('no wallets yet: create, restore and both ways to watch', (tester) async {
    SharedPreferences.setMockInitialValues({'argus_watch_only_addresses': '[]'});
    await watchOnlyService.load();
    watchAccountService.accounts.clear();
    FakeKeystore(wallets: const []).install(tester);
    await pumpHome(tester);
    expect(find.textContaining('No wallets yet'), findsOneWidget);
    for (final key in ['overview-create', 'overview-restore', 'overview-watch-address', 'overview-watch-xpub']) {
      expect(find.byKey(Key(key)), findsOneWidget, reason: key);
    }
    await tester.tap(find.byKey(const Key('overview-watch-xpub')));
    await tester.pumpAndSettle();
    expect(find.text(watchAccountDisclosure), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('overview-watch-address')));
    await tester.pumpAndSettle();
    expect(find.text('Watch an address'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await disposeHome(tester);
  });

  testWidgets('settings open from the overview, app-wide only', (tester) async {
    publicWalletSync.setForeground(false);
    await wallets(tester);
    await pumpHome(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('THIS WALLET'), findsNothing);
    expect(find.text('Network'), findsOneWidget);
    await disposeHome(tester);
  });

  testWidgets('locked wallets refresh from public data at launch, with no unlock', (tester) async {
    // A snapshot older than the five-minute floor, and a node that now
    // reports more on both addresses.
    await wallets(tester, pinnedSnapshot: snapshot('ov-pinned', 12000000000, ageMinutes: 60));
    api.balances[zero] = {'balance_nano_erg': 4000000000, 'tokens': []};
    api.balances[vanity] = {'balance_nano_erg': 9500000000, 'tokens': []};
    await pumpHome(tester);
    expect(walletService.isUnlocked, isFalse);
    expect(api.balanceCalls, containsAll([zero, vanity]));
    final row = find.byKey(const ValueKey('overview-row-seed-ov-pinned'));
    expect(find.descendant(of: row, matching: find.text('13.5')), findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.text('incl. 4 ERG on 1 other address')),
      findsOneWidget,
    );
    await disposeHome(tester);
  });

  testWidgets('a pinned wallet never synced here is read at index 0 as well', (tester) async {
    await wallets(tester);
    api.balances[zero] = {'balance_nano_erg': 4000000000, 'tokens': []};
    api.balances[vanity] = {'balance_nano_erg': 9500000000, 'tokens': []};
    await pumpHome(tester);
    expect(api.balanceCalls, containsAll([zero, vanity]));
    final known = await tester.runAsync(() => WalletDatabaseService.lastKnownBalance('ov-pinned'));
    expect(known!.balanceNano, 13500000000);
    await disposeHome(tester);
  });

  testWidgets('dragging a wallet saves the new order', (tester) async {
    publicWalletSync.setForeground(false);
    await wallets(tester);
    final model = WalletsOverviewModel();
    addTearDown(model.dispose);
    await tester.runAsync(model.loadWallets);
    expect(model.wallets.map((w) => w.walletId), ['ov-pinned', 'ov-plain']);
    await tester.runAsync(() => model.reorder(1, 0));
    expect(model.wallets.map((w) => w.walletId), ['ov-plain', 'ov-pinned']);
    expect(await tester.runAsync(walletService.walletOrder), ['ov-plain', 'ov-pinned']);
  });

  test('the overview total is the sum of what its rows show', () {
    final rows = [
      OverviewEntry(ref: const WalletRef.seed('a'), name: 'a', state: OverviewRowState.locked, balanceNano: 5),
      OverviewEntry(ref: const WalletRef.seed('b'), name: 'b', state: OverviewRowState.locked),
      OverviewEntry(
        ref: const WalletRef.watchedAddress('c'),
        name: 'c',
        state: OverviewRowState.watched,
        balanceNano: 7,
        tokens: const [(id: 't', amount: 1, decimals: 0)],
      ),
    ];
    final totals = overviewTotals(rows);
    expect(totals.total.totalNano, 12);
    expect(totals.total.unknown, 1);
    expect(totals.wallets, 2);
    expect(totals.watched, 1);
    expect(totals.tokens.single.id, 't');
  });

  test("an unlocked wallet's row carries its live figures, stealth and mixes included", () {
    final w = WalletInfo(walletId: 'live', name: 'Live', createdAt: DateTime(2026), address0: 'z');
    final row = buildOverviewEntries(
      wallets: [w],
      lastKnown: const {},
      unlockedWalletId: 'live',
      active: const ActiveWalletFigures(
        walletId: 'live',
        balanceNano: 10,
        syncing: false,
        stealthNano: 2,
        stealthUnknown: false,
        mixNano: 3,
        tokens: [],
        holdings: [],
      ),
    ).single;
    expect(row.state, OverviewRowState.unlocked);
    expect(row.balanceNano, 15);
    expect(row.stealthNano, 2);
  });

  testWidgets('the overview is the only wallet list: no wallet icon, no Manage', (tester) async {
    publicWalletSync.setForeground(false);
    await wallets(tester);
    await pumpHome(tester);
    expect(find.byType(WalletsOverviewScreen), findsOneWidget);
    expect(find.byTooltip('Wallets'), findsNothing);
    expect(find.text('Manage'), findsNothing);
    await disposeHome(tester);
  });
}
