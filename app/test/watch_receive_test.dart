import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/stealth_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/watch_only_service.dart';
import 'package:argus_wallet/ui/receive_screen.dart';
import 'package:argus_wallet/ui/wallets_overview_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

const watched = '9hY16vzHmmfyVBwKeFGHvb2bMFsG94A1u7To1QWtUokACyFVENQ';

class ReceiveApi extends RustLibApi {
  @override
  Future<String> crateApiGetBalance({required String address, String? nodeUrl}) async =>
      '{"balance_nano_erg":0,"tokens":[]}';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() => RustLib.initMock(api: ReceiveApi()));
  testWidgets('watched Receive opens while locked and overrides active wallet scope', (tester) async {
    SharedPreferences.setMockInitialValues({
      'argus_watch_only_addresses': jsonEncode([watched]),
    });
    await watchOnlyService.load();
    stealthService.reset();
    // Stale identities from a different wallet must never appear here.
    stealthService.debugSetIdentities([], {0: 'stealth-unrelated'});
    const channel = MethodChannel('com.argus.wallet/secure_storage');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async => call.method == 'listWalletIds' ? <String>[] : null);
    addTearDown(() {
      stealthService.reset();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });
    expect(walletService.isUnlocked, isFalse);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => WalletArgsScope(
        args: const WalletRouteArgs(senderAddress: 'other', receiveAddress: 'other', changeAddress: 'other'),
        child: child!,
      ),
      home: WalletOverviewScreen(initializeWalletService: () async {}),
      routes: {'/receive': (_) => const ReceiveScreen()},
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Receive'));
    await tester.pumpAndSettle();
    expect(find.byType(ReceiveScreen), findsOneWidget);
    expect(tester.widget<QrImageView>(find.byType(QrImageView)).semanticsLabel, watched);
    expect(find.textContaining('Fresh addresses'), findsNothing);
    expect(find.byKey(const Key('stealth-qr')), findsNothing);
    expect(find.byKey(const Key('stealth-identity-add')), findsNothing);
    expect(find.text('USED ADDRESSES'), findsNothing);
    await tester.enterText(find.byKey(const Key('receive-amount')), '1.25');
    await tester.pump();
    expect(tester.widget<QrImageView>(find.byType(QrImageView)).semanticsLabel, 'ergo:$watched?amount=1.25');
    await tester.scrollUntilVisible(find.text('Copy address'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Copy address'));
    await tester.pump();
    expect(find.text('Address copied'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
