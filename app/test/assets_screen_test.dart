import 'dart:io';

import 'package:argus_wallet/services/privacy_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/wallet_sync_controller.dart';
import 'package:argus_wallet/ui/assets_screen.dart';
import 'package:argus_wallet/ui/widgets/asset_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'remote_preview_test.dart' show NoPreviewHttp;

void main() {
  final artwork = TokenBalance(
    id: 'a' * 64,
    amount: 1,
    name: 'Mountain artwork',
    declaredAssetKind: DeclaredAssetKind.picture,
    metadataState: MetadataState.complete,
    iconUrl: 'https://issuer.example/beacon',
  );
  final unknown = TokenBalance(id: 'b' * 64, amount: 1, name: 'Unknown token');
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await privacyService.load();
    walletSyncController.reset();
    walletSyncController.tokens = [artwork, unknown];
    walletSyncController.balanceNano = 1000000000;
  });
  tearDown(walletSyncController.reset);

  Future<void> mount(WidgetTester tester, {double textScale = 1}) =>
      tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: AssetsScreen(
            args: WalletRouteArgs(
              senderAddress: 's',
              receiveAddress: 's',
              changeAddress: 's',
              tokens: [artwork, unknown],
            ),
          ),
        ),
      );

  testWidgets('collectibles remain usable on a small screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester, textScale: 2);
    await tester.tap(find.text('Collectibles'));
    await tester.pump();
    expect(find.byType(GridView), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Mountain artwork'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'collectible grid and list are local-only and exclude unclassified tokens',
    (tester) async {
      final deny = NoPreviewHttp(), previous = HttpOverrides.current;
      HttpOverrides.global = deny;
      addTearDown(() => HttpOverrides.global = previous);
      await mount(tester);
      await tester.tap(find.text('Collectibles'));
      await tester.pump();
      expect(find.byType(GridView), findsOneWidget);
      expect(find.text('Mountain artwork'), findsOneWidget);
      expect(find.text('Unknown token'), findsNothing);
      expect(find.textContaining('1 identified collectible'), findsOneWidget);
      await tester.tap(find.byTooltip('Show collectible list'));
      await tester.pump();
      expect(find.byType(GridView), findsNothing);
      expect(find.byType(AssetTile), findsOneWidget);
      await tester.tap(find.byTooltip('Show collectible grid'));
      await tester.pump();
      expect(find.byType(GridView), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(deny.calls, 0);
    },
  );

  testWidgets(
    'search trims whitespace and offers clear action for no results',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text('Collectibles'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '  MOUNTAIN  ');
      await tester.pump();
      expect(find.text('Mountain artwork'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'absent');
      await tester.pump();
      expect(find.text('No assets match your search'), findsOneWidget);
      await tester.tap(find.text('Clear search'));
      await tester.pump();
      expect(find.text('Mountain artwork'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
    },
  );

  testWidgets('hidden holdings conceal grid, counts and search text', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('Collectibles'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Mountain');
    await tester.pump();
    await privacyService.setHideBalances(true);
    await tester.pump();
    expect(find.text('Assets hidden'), findsOneWidget);
    expect(find.text('Mountain artwork'), findsNothing);
    expect(find.textContaining('identified collectible'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });
}
