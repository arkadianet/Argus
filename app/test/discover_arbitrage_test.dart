import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/main.dart' show appPage;
import 'package:argus_wallet/services/public_wallet_sync.dart';
import 'package:argus_wallet/services/stealth_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/watch_account_service.dart';
import 'package:argus_wallet/services/watch_only_service.dart';
import 'package:argus_wallet/ui/arbitrage_screen.dart';
import 'package:argus_wallet/ui/widgets/discover_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/home_harness.dart';

// Arbitrage has no place on the wallet page of its own: it is reached from
// the Discover tab, under Tools, whose row opens its explainer and whose
// button opens the screen.

void main() {
  final api = HomeApi();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() async {
    SharedPreferences.setMockInitialValues({'argus_watch_only_addresses': '[]'});
    await watchOnlyService.load();
    watchAccountService.accounts.clear();
    stealthService.scanEnabled = false;
    publicWalletSync.setForeground(false);
  });
  tearDown(() async {
    publicWalletSync.setForeground(true);
    stealthService.scanEnabled = true;
    if (walletService.isUnlocked) await walletService.lock();
  });

  test('every Discover entry opens a page the app routes to', () {
    expect(discoverTools, contains(DiscoverFeature.arbitrage));
    expect(discoverAvailable(DiscoverFeature.arbitrage), isTrue);
    final arbitrage = discoverExplainers[DiscoverFeature.arbitrage]!;
    expect(appPage(arbitrage.route), isA<ArbitrageScreen>());
    for (final feature in DiscoverFeature.values) {
      final route = discoverExplainers[feature]!.route;
      if (route != null) {
        expect(appPage(route), isNotNull, reason: '$feature opens $route');
      }
    }
  });

  testWidgets('Discover, Tools, Arbitrage opens the arbitrage screen', (
    tester,
  ) async {
    FakeKeystore(wallets: ['arb-w'])
      ..biometricResult = 'wrap-key'
      ..install(tester);
    await tester.runAsync(() => saveWallet('arb-w', name: 'Daily', address0: 'addr0'));
    await pumpHome(
      tester,
      routes: {
        '/arbitrage': (_) => const Scaffold(body: Text('arbitrage opened')),
      },
    );
    await tester.tap(find.byKey(const ValueKey('overview-row-seed-arb-w')));
    await tester.pumpAndSettle();
    expect(walletService.isUnlocked, isTrue);

    await tester.tap(find.widgetWithText(NavigationDestination, 'Discover'));
    await tester.pumpAndSettle();
    final row = find.byKey(const Key('discover-arbitrage'));
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.descendant(
        of: find.byKey(const Key('discover-list')),
        matching: find.byType(Scrollable),
      ),
    );
    // Listed with the tools, after every protocol.
    final tools = tester.getTopLeft(find.text('TOOLS', skipOffstage: false));
    expect(tester.getTopLeft(row).dy, greaterThan(tools.dy));

    await tester.tap(row);
    await tester.pumpAndSettle();
    final open = find.text('Open arbitrage');
    expect(open, findsOneWidget);
    // Below the explainer's risks, past the fold on a phone.
    await tester.ensureVisible(open);
    await tester.pumpAndSettle();
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(find.text('arbitrage opened'), findsOneWidget);
    await disposeHome(tester);
  });
}
