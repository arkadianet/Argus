import 'dart:io';
import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/preview/preview_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/ui/widgets/remote_preview.dart';
import 'package:argus_wallet/ui/widgets/token_detail_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'preview_policy_test.dart' show cid;

class PreviewApi extends RustLibApi {
  @override
  Future<BigInt> crateApiWalletRestore({
    required String encryptedSeedJson,
    String? wrapKey,
  }) async => BigInt.one;
  @override
  Future<void> crateApiWalletLock({required BigInt handleId}) async {}
  @override
  void crateApiCancelTokenMetadata() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class NoPreviewHttp extends HttpOverrides {
  int calls = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    calls++;
    throw StateError('Unexpected media client');
  }
}

void main() {
  setUpAll(() => RustLib.initMock(api: PreviewApi()));
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await previewSettings.load();
    networkController.activeUrl = 'https://node.example';
    await walletService.restoreWallet('mock', walletId: 'preview-wallet');
  });
  tearDown(() async => walletService.lock());
  Future<void> configure() => previewSettings.setGateway(
    'https://gateway.example',
    lookup: (_) async => [InternetAddress('8.8.8.8')],
  );
  TokenBalance token({String? url, int stealth = 0}) => TokenBalance(
    id: 'a' * 64,
    amount: 1,
    stealthAmount: stealth,
    iconUrl: url ?? 'ipfs://$cid',
    declaredAssetKind: DeclaredAssetKind.picture,
    mediaState: MediaState.notLoaded,
    metadataState: MetadataState.complete,
  );
  Future<void> mount(WidgetTester tester, TokenBalance holding) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RemotePreview(token: holding)),
        ),
      );
  testWidgets('no gateway means no action and a route to settings', (
    tester,
  ) async {
    await mount(tester, token());
    expect(find.text('Load preview'), findsNothing);
    expect(
      find.text('No gateway configured. Previews are unavailable.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Remote preview settings'));
    await tester.pumpAndSettle();
    expect(find.text('Never load remote previews'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });
  testWidgets('kill switch suppresses action even with gateway', (
    tester,
  ) async {
    await configure();
    await previewSettings.setNever(true);
    await mount(tester, token());
    expect(find.text('Load preview'), findsNothing);
    expect(find.text('Remote previews disabled.'), findsOneWidget);
  });
  testWidgets(
    'per-item consent names gateway and stealth linkage before any client',
    (tester) async {
      await configure();
      final deny = NoPreviewHttp(), previous = HttpOverrides.current;
      HttpOverrides.global = deny;
      addTearDown(() => HttpOverrides.global = previous);
      await mount(tester, token(stealth: 1));
      expect(deny.calls, 0);
      await tester.tap(find.text('Load preview'));
      await tester.pumpAndSettle();
      expect(
        find.text('Load preview through gateway.example?'),
        findsOneWidget,
      );
      expect(
        find.textContaining('IP address and which artwork'),
        findsOneWidget,
      );
      expect(
        find.textContaining('may link this private holding'),
        findsOneWidget,
      );
      expect(deny.calls, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(deny.calls, 0);
    },
  );
  testWidgets('issuer HTTPS stays inert through copy and settings taps', (
    tester,
  ) async {
    await configure();
    final deny = NoPreviewHttp(), previous = HttpOverrides.current;
    HttpOverrides.global = deny;
    addTearDown(() => HttpOverrides.global = previous);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData')
          copied = (call.arguments as Map)['text'] as String;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    const issuer = 'https://issuer.example/beacon';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TokenDetailSheet(
            token: token(url: issuer),
            explorerUrl: 'https://explorer.example',
          ),
        ),
      ),
    );
    expect(find.text('Load preview'), findsNothing);
    expect(
      find.textContaining('issuer would choose who learns you looked'),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('Copy media URI as text'));
    await tester.tap(find.text('Copy media URI as text'));
    expect(copied, issuer);
    await tester.ensureVisible(find.text('Remote preview settings'));
    await tester.tap(find.text('Remote preview settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Load preview'), findsNothing);
    expect(deny.calls, 0);
  });
  for (final change in ['lock', 'switch', 'background', 'kill', 'gateway']) {
    testWidgets(
      '$change while consent is open prevents request after approval',
      (tester) async {
        await configure();
        final deny = NoPreviewHttp(), previous = HttpOverrides.current;
        HttpOverrides.global = deny;
        addTearDown(() => HttpOverrides.global = previous);
        await mount(tester, token());
        await tester.tap(find.text('Load preview'));
        await tester.pumpAndSettle();
        switch (change) {
          case 'lock':
            await walletService.lock();
          case 'switch':
            await walletService.restoreWallet('mock', walletId: 'second');
          case 'background':
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.paused,
            );
          case 'kill':
            await previewSettings.setNever(true);
          case 'gateway':
            await previewSettings.setGateway('');
        }
        await tester.tap(find.widgetWithText(TextButton, 'Load preview'));
        await tester.pumpAndSettle();
        expect(deny.calls, 0);
        if (change == 'background')
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
      },
    );
  }
  testWidgets('locked and offline details offer no load action', (
    tester,
  ) async {
    await configure();
    await walletService.lock();
    await mount(tester, token());
    expect(find.text('Load preview'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await walletService.restoreWallet('mock', walletId: 'preview-wallet');
    networkController.activeUrl = null;
    await mount(tester, token());
    expect(find.text('Load preview'), findsNothing);
  });
}
