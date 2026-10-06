import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/pending_balance.dart';
import 'package:argus_wallet/services/privacy_service.dart';
import 'package:argus_wallet/services/public_wallet_sync.dart';
import 'package:argus_wallet/services/stealth_service.dart';
import 'package:argus_wallet/services/wallet_database_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/watch_account_service.dart';
import 'package:argus_wallet/services/watch_only_service.dart';
import 'package:argus_wallet/ui/home/overview_model.dart';
import 'package:argus_wallet/ui/home/watched_wallet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/home_harness.dart';

// What the mempool does to a balance shows wherever the balance does: on
// the overview's total and rows, and under the wallet page's balance, for
// seed and watched wallets alike. The line splits the figure above it, so
// its confirmed side is that figure less what is pending.

const erg = 1000000000;
const watched = '9watchedAddressWithAPendingPaymentxxxxxxxxxxxxxxxxxx';
const lockedZero = '9lockedWalletIndexZeroxxxxxxxxxxxxxxxxxxxxxxxxxxxxx';

/// A node whose answers carry the mempool split `get_balance` and the sync
/// reads return.
class PendingApi extends HomeApi {
  /// Per address, for `get_balance`.
  final summaries = <String, PendingBalance>{};

  /// For the unlocked wallet's sync read.
  PendingBalance? walletSummary;

  @override
  Future<String> crateApiGetBalance({
    required String address,
    String? nodeUrl,
  }) async {
    final raw =
        jsonDecode(
              await super.crateApiGetBalance(address: address, nodeUrl: nodeUrl),
            )
            as Map<String, dynamic>;
    final split = summaries[address];
    return jsonEncode({...raw, 'summary': ?split?.toJson()});
  }

  @override
  Future<String> crateApiGetSyncInputs({
    required List<String> addresses,
    String? nodeUrl,
  }) async {
    final raw =
        jsonDecode(
              await super.crateApiGetSyncInputs(
                addresses: addresses,
                nodeUrl: nodeUrl,
              ),
            )
            as Map<String, dynamic>;
    return jsonEncode({...raw, 'summary': ?walletSummary?.toJson()});
  }
}

void main() {
  final api = PendingApi();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'argus_watch_only_addresses': '[]',
    });
    await watchOnlyService.load();
    await privacyService.load();
    stealthService.scanEnabled = false;
    // Snapshot figures stay as saved: no public refresh in these tests.
    publicWalletSync.setForeground(false);
    api.balances.clear();
    api.summaries.clear();
    api.walletSummary = null;
    watchAccountService.accounts.clear();
  });
  tearDown(() async {
    watchAccountService.accounts.clear();
    stealthService.scanEnabled = true;
    publicWalletSync.setForeground(true);
    if (walletService.isUnlocked) await walletService.lock();
  });

  test('rows and the total split what is pending against their figures', () {
    final live = WalletInfo(
      walletId: 'live',
      name: 'Live',
      createdAt: DateTime(2026),
      address0: 'z',
    );
    final locked = WalletInfo(
      walletId: 'locked',
      name: 'Locked',
      createdAt: DateTime(2026),
      address0: 'y',
    );
    final account = WatchAccount('account')
      ..snapshot = WatchAccountSnapshot(
        ['a0'],
        'a0',
        3 * erg,
        const {},
        const [],
        0,
        pending: const PendingBalance(
          confirmedNano: 4 * erg,
          pendingOutNano: erg,
          transactions: 1,
        ),
      );
    final rows = buildOverviewEntries(
      wallets: [live, locked],
      lastKnown: {
        'locked': LastKnownBalance(
          balanceNano: 5 * erg,
          stealthNano: erg,
          age: const Duration(minutes: 3),
        ),
      },
      lastPending: {
        'locked': const PendingBalance(
          confirmedNano: 4 * erg,
          pendingInNano: erg,
          transactions: 1,
        ),
      },
      unlockedWalletId: 'live',
      // 10 public (2.5 of it arriving), 2 stealth, 3 in the mixing pool.
      active: const ActiveWalletFigures(
        walletId: 'live',
        balanceNano: 10 * erg,
        syncing: false,
        stealthNano: 2 * erg,
        stealthUnknown: false,
        mixNano: 3 * erg,
        tokens: [],
        holdings: [],
        pending: PendingBalance(
          confirmedNano: 7500000000,
          pendingInNano: 2500000000,
          transactions: 1,
        ),
      ),
      watchedAddresses: const [watched],
      watchedHoldings: {
        watched: WatchedHoldings.fromBalance({
          'balance_nano_erg': 2 * erg,
          'tokens': [],
          'summary': const PendingBalance(
            confirmedNano: 2 * erg,
          ).toJson(),
        }),
      },
      accounts: [account],
    );
    final byId = {for (final r in rows) r.ref.id: r};

    // The unlocked wallet's headline holds its stealth and mixing pockets,
    // which are in blocks: 15 ERG, 2.5 of it pending.
    final active = byId['live']!;
    expect(active.balanceNano, 15 * erg);
    expect(active.pending!.pendingDeltaNano, 2500000000);
    expect(active.pending!.confirmedNano, 12500000000);
    expect(active.pending!.netNano, active.balanceNano);
    expect(
      pendingBalanceText(active.pending),
      '+2.5 ERG pending · 12.5 confirmed',
    );

    // A locked wallet's split is read back from its snapshot and shown
    // against the figure saved with it, stealth included.
    final lockedRow = byId['locked']!;
    expect(lockedRow.balanceNano, 6 * erg);
    expect(lockedRow.pending!.confirmedNano, 5 * erg);
    expect(lockedRow.pending!.netNano, 6 * erg);

    // A watched address with nothing pending says nothing.
    expect(byId[watched]!.pending!.hasPending, isFalse);
    expect(pendingBalanceText(byId[watched]!.pending), isNull);

    // A watched account's scan carries its own split.
    final accountRow = byId['account']!;
    expect(accountRow.pending!.pendingDeltaNano, -erg);
    expect(accountRow.pending!.netNano, 3 * erg);

    // The total: every row's movement, against the sum of the rows.
    final totals = overviewTotals(rows);
    expect(totals.total.totalNano, (15 + 6 + 2 + 3) * erg);
    expect(totals.pending!.pendingDeltaNano, 2500000000 + erg - erg);
    expect(totals.pending!.netNano, totals.total.totalNano);
    expect(totals.pending!.transactions, 3);
  });

  test('a total with no split anywhere has no pending line', () {
    final rows = buildOverviewEntries(
      wallets: [
        WalletInfo(
          walletId: 'old',
          name: 'Old',
          createdAt: DateTime(2026),
          address0: 'x',
        ),
      ],
      lastKnown: {
        'old': const LastKnownBalance(balanceNano: erg, age: Duration.zero),
      },
      unlockedWalletId: null,
    );
    expect(rows.single.pending, isNull);
    expect(overviewTotals(rows).pending, isNull);
  });

  testWidgets(
    'the overview shows pending on a locked row, a watched row and the total',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'argus_watch_only_addresses': jsonEncode([watched]),
      });
      await watchOnlyService.load();
      api.balances[watched] = {'balance_nano_erg': 3 * erg, 'tokens': []};
      api.summaries[watched] = const PendingBalance(
        confirmedNano: 2 * erg,
        pendingInNano: erg,
        transactions: 1,
      );
      FakeKeystore(wallets: ['pend-locked']).install(tester);
      await tester.runAsync(() async {
        await saveWallet('pend-locked', name: 'Savings', address0: lockedZero);
        await WalletDatabaseService.savePublicSnapshot('pend-locked', {
          'wallet_id': 'pend-locked',
          'primary_address': lockedZero,
          'balance_nano_erg': 4 * erg,
          'pending': const PendingBalance(
            confirmedNano: 5 * erg,
            pendingOutNano: erg,
            transactions: 1,
          ).toJson(),
          'tokens': [],
          'public_only': true,
          'last_sync_timestamp': DateTime.now().millisecondsSinceEpoch,
        }, () => true);
      });
      await pumpHome(tester);

      final locked = find.byKey(const ValueKey('overview-row-seed-pend-locked'));
      expect(
        find.descendant(
          of: locked,
          matching: find.text('−1 ERG pending · 5 confirmed'),
        ),
        findsOneWidget,
      );
      final row = find.byKey(
        const ValueKey('overview-row-watchedAddress-$watched'),
      );
      expect(
        find.descendant(
          of: row,
          matching: find.text('+1 ERG pending · 2 confirmed'),
        ),
        findsOneWidget,
      );
      // −1 and +1 cancel out in the total, but two transactions are still
      // pending: the line stays, without a figure.
      expect(
        find.descendant(
          of: find.byKey(const Key('overview-total-pending')),
          matching: find.text('Pending · 7 confirmed'),
        ),
        findsOneWidget,
      );

      // Hidden balances say something is pending, not how much.
      await tester.runAsync(() => privacyService.setHideBalances(true));
      addTearDown(() => privacyService.setHideBalances(false));
      await tester.pumpAndSettle();
      expect(find.text('•••• ERG pending'), findsNWidgets(3));
      expect(find.textContaining('confirmed'), findsNothing);
      await disposeHome(tester);
    },
  );

  testWidgets('a watched address page shows pending under its balance', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'argus_watch_only_addresses': jsonEncode([watched]),
    });
    await watchOnlyService.load();
    api.balances[watched] = {'balance_nano_erg': 3 * erg, 'tokens': []};
    api.summaries[watched] = const PendingBalance(
      confirmedNano: 2 * erg,
      pendingInNano: erg,
      transactions: 1,
    );
    FakeKeystore(wallets: const []).install(tester);
    await pumpHome(tester);
    final row = find.byKey(
      const ValueKey('overview-row-watchedAddress-$watched'),
    );
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byType(WatchedWalletPage), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('wallet-balance-pending')),
        matching: find.text('+1 ERG pending · 2 confirmed'),
      ),
      findsOneWidget,
    );
    await disposeHome(tester);
  });

  testWidgets('an unlocked wallet page shows pending under its balance', (
    tester,
  ) async {
    final keystore = FakeKeystore(wallets: ['pend-live'])
      ..biometricResult = 'wrap-key';
    keystore.install(tester);
    await tester.runAsync(
      () => saveWallet('pend-live', name: 'Daily', address0: 'addr0'),
    );
    api.balances['addr0'] = {'balance_nano_erg': 10 * erg, 'tokens': []};
    api.walletSummary = const PendingBalance(
      confirmedNano: 12 * erg,
      pendingOutNano: 2 * erg,
      transactions: 1,
    );
    await pumpHome(tester);
    await tester.tap(find.byKey(const ValueKey('overview-row-seed-pend-live')));
    await tester.pumpAndSettle();
    expect(walletService.isUnlocked, isTrue);
    expect(tester.widget<Text>(find.byKey(const Key('wallet-balance'))).data, '10');
    expect(
      find.descendant(
        of: find.byKey(const Key('wallet-balance-pending')),
        matching: find.text('−2 ERG pending · 12 confirmed'),
      ),
      findsOneWidget,
    );
    await disposeHome(tester);
  });
}
