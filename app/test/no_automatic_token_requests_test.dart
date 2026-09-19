import 'dart:io';
import 'package:argus_wallet/services/preview/preview_service.dart';
import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/wallet_sync_controller.dart';
import 'package:argus_wallet/ui/assets_screen.dart';
import 'package:argus_wallet/ui/widgets/asset_tile.dart';
import 'package:argus_wallet/ui/widgets/token_detail_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DenyTokenApi extends RustLibApi {
  @override
  Future<BigInt> crateApiWalletRestore({
    required String encryptedSeedJson,
    String? wrapKey,
  }) async => BigInt.one;

  @override
  Future<void> crateApiWalletLock({required BigInt handleId}) async {}

  int metadataRequests = 0;
  final List<({String tokenId, String provider, bool isNode})> descriptorCalls =
      [];
  @override
  Future<String> crateApiGetTokenInfo({
    required String tokenId,
    String? explorerUrl,
  }) async {
    metadataRequests++;
    throw StateError('Automatic metadata request');
  }

  @override
  Future<String> crateApiInspectTokenMetadata({
    required String tokenId,
    required String providerUrl,
    required bool providerIsNode,
  }) async {
    metadataRequests++;
    descriptorCalls.add((
      tokenId: tokenId,
      provider: providerUrl,
      isNode: providerIsNode,
    ));
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
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api.metadataRequests = 0;
    api.descriptorCalls.clear();
  });
  // The old invariant was "sync makes zero token-specific requests". Ordinary
  // public holdings are now resolved during sync — the node already receives
  // the addresses whose boxes carry those ids. What must still never leave
  // automatically is narrower, and these tests hold that line.
  test('stealth hydration makes no token-specific request', () async {
    final service = WalletService();
    networkController.activeUrl = 'https://node.example';
    addTearDown(() => networkController.activeUrl = null);
    // Default scope, which is what the stealth path uses.
    final tokens = await service.hydrateTokens([
      {'id': 'stealth', 'amount': 5},
    ]);
    expect(tokens.length, 1);
    expect(api.metadataRequests, 0,
        reason: 'a stealth-only id is not derivable from public addresses');
  });

  test('a locked wallet resolves nothing', () async {
    final service = WalletService();
    networkController.activeUrl = 'https://node.example';
    addTearDown(() => networkController.activeUrl = null);
    await service.prefetchTokenMeta([
      '0' * 64,
    ]);
    expect(api.metadataRequests, 0);
  });

  test('resolution never goes to the explorer, and stops on an incapable node',
      () async {
    final service = WalletService();
    await service.restoreWallet('mock', walletId: 'deny-test');
    addTearDown(() => service.lock('deny-test'));
    networkController.activeUrl = 'https://node.example';
    addTearDown(() => networkController.activeUrl = null);
    api.descriptorCalls.clear();

    final ids = {'a' * 64, 'b' * 64, 'c' * 64};
    await service.prefetchTokenMeta(ids);
    // Wallet activation can drive its own sync in the background; judge only
    // the ids this test asked about.
    List<({String tokenId, String provider, bool isNode})> mine() => [
      for (final c in api.descriptorCalls)
        if (ids.contains(c.tokenId)) c,
    ];

    expect(mine(), isNotEmpty);
    expect(api.descriptorCalls.every((c) => c.isNode), isTrue,
        reason: 'automatic resolution must never address the explorer');
    expect(
      api.descriptorCalls.every((c) => c.provider == 'https://node.example'),
      isTrue,
      reason: 'and never a node other than the one serving sync',
    );
    // DenyTokenApi throws StateError('Automatic descriptor request'), which
    // is not a capability failure, so every id is attempted exactly once.
    expect(mine(), hasLength(3));

    // Second pass: ids already attempted are not re-asked.
    await service.prefetchTokenMeta(ids);
    expect(mine(), hasLength(3),
        reason: 'a miss must not be retried on every sync');
  });
  testWidgets(
    'Assets, dashboard row and detail rebuild without HTTP or metadata requests',
    (tester) async {
      await previewSettings.setGateway(
        'https://gateway.example',
        lookup: (_) async => [InternetAddress('8.8.8.8')],
      );
      final http = DenyHttp();
      final previous = HttpOverrides.current;
      HttpOverrides.global = http;
      addTearDown(() => HttpOverrides.global = previous);
      final t = TokenBalance(
        id: 'hostile-token',
        amount: 1,
        name: 'Art\u202e\u0001',
        iconUrl: 'ipfs://QmYwAPJzv5CZsnAzt8auVZRnG6FMmQLGzsh6coP7u8MLhM',
        declaredAssetKind: DeclaredAssetKind.picture,
      );
      walletSyncController.tokens = [t];
      addTearDown(walletSyncController.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: AssetsScreen(
            args: WalletRouteArgs(
              senderAddress: 's',
              receiveAddress: 's',
              changeAddress: 's',
              tokens: [t],
            ),
          ),
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
