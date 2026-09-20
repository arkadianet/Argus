import 'dart:io';
import 'package:argus_wallet/services/preview/preview_service.dart';
import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/stealth_service.dart';
import 'wallet_sync_controller_test.dart' show FakeGateway;
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

// Exercise the real controller-to-service boundary, including candidate
// selection, instead of duplicating its privacy logic in the test.
class ResolvingGateway extends FakeGateway {
  ResolvingGateway(this.service);
  final WalletService service;
  @override
  String? get activeWalletId => service.activeWalletId;
  @override
  Future<Map<String, TokenBalance>> resolveTokenNames(
    Iterable<String> ids, {
    required String walletId,
    required String servedBy,
    required bool Function() stillCurrent,
  }) => service.prefetchTokenMeta(
    ids,
    walletId: walletId,
    servedBy: servedBy,
    stillCurrent: stillCurrent,
  );
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
  // The old invariant was "sync makes zero token-specific requests".
  // Ordinary public holdings are now resolved after sync publishes, from the
  // node that served the balances. What must still never leave automatically
  // is narrower, and these hold that line. Ids are valid 64-char hex on an
  // unlocked wallet, so no unrelated guard can make them pass vacuously.
  const ordinary =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const stealthOnly =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const both =
      'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

  test('an ordinary holding is resolved from the node that served it',
      () async {
    // Positive control: without this, every assertion below could pass
    // because the request path is broken rather than because it is guarded.
    final service = WalletService();
    await service.restoreWallet('mock', walletId: 'auto-ok');
    addTearDown(() => service.lock('auto-ok'));
    await service.prefetchTokenMeta(
      [ordinary],
      walletId: 'auto-ok',
      servedBy: 'https://served.example',
      stillCurrent: () => true,
    );
    expect(api.descriptorCalls.map((c) => c.tokenId), [ordinary]);
    expect(api.descriptorCalls.single.provider, 'https://served.example',
        reason: 'the endpoint that answered, not the configured one');
    expect(api.descriptorCalls.single.isNode, isTrue,
        reason: 'never the explorer');
  });

  test('a stealth-only holding is never handed to resolution', () async {
    final service = WalletService();
    await service.restoreWallet('mock', walletId: 'stealth-w');
    addTearDown(() => service.lock('stealth-w'));

    final gateway = ResolvingGateway(service)
      ..balances = {
        'addr0': {
          'balance_nano_erg': 100,
          'tokens': [
            {'id': ordinary, 'amount': 5},
            {'id': both, 'amount': 5},
          ],
        },
      }
      ..stealthResult = StealthScanResult(
        scanned: 2,
        ownedCount: 2,
        totalNanoErg: 10,
        tokens: [
          StealthToken(id: stealthOnly, amount: BigInt.from(3)),
          StealthToken(id: both, amount: BigInt.from(2)),
        ],
        boxIds: const ['private-box'],
      );
    final controller = WalletSyncController(gateway);
    addTearDown(controller.dispose);
    await controller.hydrateAfterUnlock();
    await controller.refresh(discover: false);
    await controller.pendingNameResolution;
    expect(controller.stealthTokens.map((t) => t.id), contains(stealthOnly));
    expect(
      api.descriptorCalls.every(
        (c) => c.isNode && c.provider == 'https://served.example',
      ),
      isTrue,
    );

    final asked = api.descriptorCalls.map((c) => c.tokenId).toSet();
    expect(asked, contains(ordinary), reason: 'positive control');
    expect(
      asked,
      isNot(contains(stealthOnly)),
      reason: 'a stealth-only id is not derivable from public addresses',
    );
    expect(
      asked,
      contains(both),
      reason: 'held in ordinary boxes too, so the node already has this id',
    );
  });

  test('a stale wallet generation resolves nothing', () async {
    final service = WalletService();
    await service.restoreWallet('mock', walletId: 'stale-w');
    addTearDown(() => service.lock('stale-w'));
    await service.prefetchTokenMeta(
      [ordinary],
      walletId: 'stale-w',
      servedBy: 'https://served.example',
      stillCurrent: () => false,
    );
    expect(api.descriptorCalls, isEmpty);
  });

  test('resolution for another wallet is refused', () async {
    final service = WalletService();
    await service.restoreWallet('mock', walletId: 'wallet-a');
    addTearDown(() => service.lock('wallet-a'));
    await service.prefetchTokenMeta(
      [ordinary],
      walletId: 'wallet-b',
      servedBy: 'https://served.example',
      stillCurrent: () => true,
    );
    expect(api.descriptorCalls, isEmpty,
        reason: "a response must never be written under a wallet that did "
            'not ask for it');
  });

  test('a locked wallet resolves nothing', () async {
    final service = WalletService();
    await service.prefetchTokenMeta(
      [ordinary],
      walletId: 'locked-w',
      servedBy: 'https://served.example',
      stillCurrent: () => true,
    );
    expect(api.descriptorCalls, isEmpty);
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
