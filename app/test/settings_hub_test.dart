import 'package:argus_wallet/services/watch_only_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/ui/home/overview_model.dart';
import 'package:argus_wallet/ui/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('com.argus.wallet/secure_storage');

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  void listWallets(WidgetTester tester, List<String> ids) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _channel,
      (call) async => call.method == 'listWalletIds' ? ids : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null),
    );
  }

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: home));
    await tester.pumpAndSettle();
  }

  testWidgets('without a wallet the hub is app-wide only', (tester) async {
    listWallets(tester, const []);
    await pump(tester, const SettingsScreen());
    for (final text in ['Security', 'Offline signing', 'Network', 'Display', 'Address book', 'About Argus']) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    // Wallets are listed, switched, created and watched on the overview;
    // there is no second wallet list here.
    for (final text in ['Manage', 'Watch-only', 'THIS WALLET', 'No wallet selected']) {
      expect(find.text(text), findsNothing, reason: text);
    }
  });

  testWidgets("a seed wallet's hub leads to its own settings and back to all wallets", (
    tester,
  ) async {
    listWallets(tester, const ['hub-wallet']);
    await tester.runAsync(
      () => walletService.saveWalletInfo('hub-wallet', name: 'Savings', createdAt: DateTime(2026)),
    );
    var shownAll = 0;
    await pump(
      tester,
      SettingsScreen(walletId: 'hub-wallet', onShowAllWallets: () => shownAll++),
    );
    expect(find.text('THIS WALLET'), findsOneWidget);
    expect(find.text('Name, addresses and backup'), findsOneWidget);
    expect(find.text('Security'), findsOneWidget);
    expect(find.text('Savings'), findsWidgets);
    await tester.tap(find.text('All wallets'));
    expect(shownAll, 1);
  });

  testWidgets('a watched address can be renamed and unwatched from its settings', (
    tester,
  ) async {
    listWallets(tester, const []);
    SharedPreferences.setMockInitialValues({
      'argus_watch_only_addresses': '["9watched"]',
    });
    await watchOnlyService.load();
    String? removed;
    await pump(
      tester,
      SettingsScreen(
        watched: const WalletRef.watchedAddress('9watched'),
        onWalletRemoved: (id) => removed = id,
      ),
    );
    expect(find.text('THIS ADDRESS'), findsOneWidget);
    await tester.tap(find.text('Name'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Cold storage');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Cold storage'), findsWidgets);
    await tester.tap(find.text('Stop watching').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Stop watching'));
    await tester.pumpAndSettle();
    expect(watchOnlyService.addresses, isEmpty);
    expect(removed, '9watched');
  });
}
