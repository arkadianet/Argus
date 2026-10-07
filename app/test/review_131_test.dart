// Fixes from the review of #131: stealth self-change read as the wallet's
// own, the network pill's hint when it retries, the overview's actions only
// with a wallet that holds keys, and the Addresses tab when nothing is
// known yet.

import 'package:argus_wallet/services/activity_classifier.dart';
import 'package:argus_wallet/services/stealth_change_book.dart';
import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/ui/home/home_glass.dart';
import 'package:argus_wallet/ui/home/home_hero.dart';
import 'package:argus_wallet/ui/home/home_models.dart';
import 'package:argus_wallet/ui/home/overview_screen.dart';
import 'package:argus_wallet/ui/home/wallet_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/render_harness.dart';

const _aud = FiatCurrency(symbol: r'A$', code: 'AUD');
/// P2PK addresses: 51 characters starting with 9.
final _mine = '9i${'M' * 49}';
final _payee = '9h${'P' * 49}';
const _change = 'StealthChangeP2SAddressOfOurOwn';
const _foreignStealth = 'StealthPaymentP2SAddressOfSomeoneElse';

int _nano(num erg) => (erg * 1e9).round();

/// A send of 2 ERG from the wallet, its change paid to [changeTo], which
/// is tagged a stealth script.
Map<String, dynamic> _send({required String changeTo}) => {
      'tx_id': 'tx',
      'io': {
        'inputs': [
          {'address': _mine, 'value': _nano(10), 'assets': <Object>[], 'mine': true},
        ],
        'outputs': [
          {'address': _payee, 'value': _nano(2), 'assets': <Object>[]},
          {'address': changeTo, 'value': _nano(7.99), 'assets': <Object>[], 'tag': 'stealth'},
        ],
        'miner_fee': _nano(0.01),
        'first_input': 'box',
        'complete': true,
      },
    };

void main() {
  group('stealth self-change', () {
    test('read as foreign it is a stealth payment out; read as ours it is change', () {
      final tx = _send(changeTo: _change);
      expect(walletActivity(tx)!.category, ActivityCategory.stealth, reason: 'the misreading the book corrects');

      final read = reownActivity(tx, {_change});
      final a = walletActivity(read)!;
      expect(a.category, ActivityCategory.sent);
      expect(a.erg, BigInt.from(-_nano(2.01)), reason: 'only the payment and the fee left');
      expect(read['value_nano_erg'], -_nano(2.01));
      expect(read['counterparty'], _payee);
    });

    test('a genuine stealth payment out stays one', () {
      final tx = _send(changeTo: _foreignStealth);
      final read = reownActivity(tx, {_change});
      expect(identical(read, tx), isTrue, reason: 'nothing to mark: the row comes back as it was');
      expect(walletActivity(read)!.category, ActivityCategory.stealth);
    });

    test('the book keeps what it is told across a restart, newest last, up to its limit', () async {
      SharedPreferences.setMockInitialValues({});
      final book = StealthChangeBook(limit: 2);
      await book.remember('a');
      await book.remember('b');
      await book.remember('c');
      expect(book.addresses, {'b', 'c'});
      final again = StealthChangeBook(limit: 2);
      await again.load();
      expect(again.addresses, {'b', 'c'});
    });
  });

  group('screens', () {
    setUpAll(loadRenderFonts);

    final watched = WalletSummary(
      ref: const WalletRef.watchedAddress('9hWatched'),
      name: '9hWatched…o9go',
      nanoErg: _nano(5),
      fiatValue: 2.2,
      tokenCount: 0,
    );
    final seed = WalletSummary(
      ref: const WalletRef.seed('main'),
      name: 'Main Wallet',
      nanoErg: _nano(5),
      fiatValue: 2.2,
      tokenCount: 0,
    );

    Widget overview(List<WalletSummary> wallets) => OverviewScreen(
          data: OverviewData(
            wallets: wallets,
            watched: [watched],
            currency: _aud,
            network: const NetworkStatus(state: SyncState.synced, blockHeight: 1, label: 'Connected'),
            totalNano: _nano(10),
          ),
          onAction: (_) {},
          onOpenWallet: (_) {},
        );

    testWidgets('the overview offers its actions only with a wallet that holds keys', (tester) async {
      await pumpRender(tester, overview(const []), palette: watchfulPalette);
      expect(find.byKey(const Key('overview-action-send')), findsNothing);
      await pumpRender(tester, overview([seed]), palette: watchfulPalette);
      expect(find.byKey(const Key('overview-action-send')), findsOneWidget);
    });

    testWidgets('the network pill is hinted as settings only when it goes there', (tester) async {
      const offline = NetworkStatus(state: SyncState.offline, label: 'No reachable nodes');
      await tester.pumpWidget(MaterialApp(
        theme: argusThemeFor(watchfulPalette),
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                KeyedSubtree(key: const Key('pill-Retry'), child: homeNetworkPill(context, offline, onTap: () {}, action: 'Retry')),
                KeyedSubtree(key: const Key('pill-settings'), child: homeNetworkPill(context, offline, onTap: () {})),
              ],
            ),
          ),
        ),
      ));
      String? hint(String key) => tester
          .widget<GlassPill>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(GlassPill)))
          .hint;
      expect(hint('pill-Retry'), isNull, reason: 'a tap looks again; it does not open the settings');
      expect(hint('pill-settings'), 'Network settings');
    });

    testWidgets('the Addresses tab of an account not yet scanned says so', (tester) async {
      final account = WalletSummary(
        ref: const WalletRef.watchedAccount('xpub'),
        name: 'Account',
        loading: true,
      );
      await pumpRender(
        tester,
        WalletPageScreen(
          title: 'Account',
          body: WalletPageView(
            data: WalletPageData(
              wallet: account,
              currency: _aud,
              watched: const WatchedDetails(status: ['Watch-only · cannot sign here'], canSend: false, canReceive: false),
            ),
            onAction: (_) {},
          ),
        ),
        palette: watchfulPalette,
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('wallet-page-tab-addresses')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('wallet-page-tab-addresses')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('wallet-no-addresses')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
