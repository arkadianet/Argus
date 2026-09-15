import 'dart:io';
import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/wallet_sync_controller.dart';
import 'package:argus_wallet/ui/assets_screen.dart';
import 'package:argus_wallet/ui/widgets/asset_tile.dart';
import 'package:argus_wallet/ui/widgets/token_detail_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DenyTokenApi extends RustLibApi {
  int metadataRequests = 0;
  @override
  Future<String> crateApiGetTokenInfo({
    required String tokenId,
    String? explorerUrl,
  }) async {
    metadataRequests++;
    throw StateError('Automatic metadata request');
  }

  @override
  Future<String> crateApiInspectTokenMetadata({required String tokenId, required String providerUrl, required bool providerIsNode}) async {
    metadataRequests++;
    throw StateError('Automatic descriptor request');
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class DenyHttp extends HttpOverrides {
  int clients = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    clients++;
    throw StateError('Automatic HTTP client');
  }
}

void main() {
  final api = DenyTokenApi();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'sync hydration and prefetch make zero token-specific requests',
    () async {
      final service = WalletService();
      final tokens = await service.hydrateTokens([
        {'id': 'public', 'amount': 1},
        {'id': 'stealth', 'amount': 5},
      ]);
      await service.prefetchTokenMeta(['public', 'stealth', 'notification']);
      expect(tokens.length, 2);
      expect(api.metadataRequests, 0);
    },
  );
  testWidgets(
    'Assets, dashboard row and detail rebuild without HTTP or metadata requests',
    (tester) async {
      final http = DenyHttp();
      final previous = HttpOverrides.current;
      HttpOverrides.global = http;
      addTearDown(() => HttpOverrides.global = previous);
      final t = TokenBalance(
        id: 'hostile-token',
        amount: 1,
        name: 'Art\u202e\u0001',
        iconUrl: 'https://127.0.0.1/collect-viewer',
        declaredAssetKind: DeclaredAssetKind.picture,
      );
      walletSyncController.tokens = [t];
      addTearDown(walletSyncController.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: AssetsScreen(args: WalletRouteArgs(senderAddress: 's', receiveAddress: 's', changeAddress: 's', tokens: [t])),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Collectibles'));
      await tester.pump();
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: AssetTile.token(t))),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TokenDetailSheet(
              token: t,
              explorerUrl: 'https://example.org/token',
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(http.clients, 0);
      expect(api.metadataRequests, 0);
    },
  );
}
