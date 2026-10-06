import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/public_wallet_sync.dart';
import 'package:argus_wallet/services/stealth_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/watch_account_service.dart';
import 'package:argus_wallet/services/watch_only_service.dart';
import 'package:argus_wallet/ui/utxo_management_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/home_finders.dart';
import 'support/home_harness.dart';

/// A node whose sync reads report [utxos] boxes for the wallet.
class BoxCountApi extends HomeApi {
  int utxos = 1;

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
    return jsonEncode({...raw, 'utxo_count': utxos});
  }
}

// The balance card's status line opens the UTXO tools; while the wallet is
// fragmented, its "Fragmented" indicator opens the suggested cleanup.
void main() {
  final api = BoxCountApi();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'argus_watch_only_addresses': '[]',
    });
    await watchOnlyService.load();
    watchAccountService.accounts.clear();
    stealthService.scanEnabled = false;
    publicWalletSync.setForeground(false);
  });
  tearDown(() async {
    stealthService.scanEnabled = true;
    publicWalletSync.setForeground(true);
    if (walletService.isUnlocked) await walletService.lock();
  });

  Future<void> openWallet(WidgetTester tester) async {
    final keystore = FakeKeystore(wallets: ['frag-w'])
      ..biometricResult = 'wrap-key';
    keystore.install(tester);
    await tester.runAsync(
      () => saveWallet('frag-w', name: 'Daily', address0: 'addr0'),
    );
    await pumpHome(
      tester,
      routes: {
        '/utxos': (_) => Scaffold(appBar: AppBar(), body: const Text('UTXO tools')),
        UtxoManagementScreen.cleanupRoute: (_) =>
            Scaffold(appBar: AppBar(), body: const Text('Cleanup review')),
      },
    );
    await tester.tap(find.byKey(const ValueKey('overview-row-seed-frag-w')));
    await tester.pumpAndSettle();
    expect(walletService.isUnlocked, isTrue);
  }

  testWidgets('a fragmented wallet links its indicator to the cleanup', (
    tester,
  ) async {
    api.utxos = utxoFragmentationThreshold + 1;
    await openWallet(tester);
    final indicator = find.byKey(const Key('utxo-fragmented'));
    expect(
      find.descendant(
        of: indicator,
        matching: textPlain('${utxoFragmentationThreshold + 1} UTXOs · Fragmented'),
      ),
      findsOneWidget,
    );
    await tester.tap(indicator);
    await tester.pumpAndSettle();
    expect(find.text('Cleanup review'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    // The status line above it still opens the UTXO tools.
    final status = find.byKey(const Key('wallet-status'));
    expect(find.descendant(of: status, matching: textPlainContaining('UTXOs')), findsNothing,
        reason: 'while fragmented the count leads its own line');
    await tester.tap(status);
    await tester.pumpAndSettle();
    expect(find.text('UTXO tools'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await disposeHome(tester);
  });

  testWidgets('a tidy wallet has no cleanup link', (tester) async {
    api.utxos = 3;
    await openWallet(tester);
    expect(find.byKey(const Key('utxo-fragmented')), findsNothing);
    final status = find.byKey(const Key('wallet-status'));
    expect(find.descendant(of: status, matching: textPlainContaining('3 UTXOs')), findsOneWidget);
    await tester.tap(status);
    await tester.pumpAndSettle();
    expect(find.text('UTXO tools'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await disposeHome(tester);
  });
}
