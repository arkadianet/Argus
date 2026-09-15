import 'dart:async';
import 'dart:convert';
import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/ui/widgets/token_detail_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MetadataApi extends RustLibApi {
  int emission = 1;
  int calls = 0;
  int cancels = 0;
  String? provider;
  bool? node;
  Completer<String>? gate;
  String descriptor(String id) => jsonEncode({
    'id': id,
    'name': 'Art',
    'emissionAmount': emission,
    'decimals': 0,
    'supplyEvidence': 'originalEmission',
    'decimalsEvidence': 'valid',
    'declaredAssetKind': 'picture',
    'metadataState': 'complete',
    'mediaState': 'notLoaded',
  });
  @override
  Future<BigInt> crateApiWalletRestore({
    required String encryptedSeedJson,
    String? wrapKey,
  }) async => BigInt.one;
  @override
  Future<void> crateApiWalletLock({required BigInt handleId}) async {}
  @override
  void crateApiCancelTokenMetadata() {
    cancels++;
  }

  @override
  Future<String> crateApiInspectTokenMetadata({
    required String tokenId,
    required String providerUrl,
    required bool providerIsNode,
  }) async {
    calls++;
    provider = providerUrl;
    node = providerIsNode;
    return gate == null ? descriptor(tokenId) : gate!.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final api = MetadataApi();
  final holding = TokenBalance(id: 'a' * 64, amount: 1, stealthAmount: 1);
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    api.emission = 1;
    api.calls = 0;
    api.cancels = 0;
    api.gate = null;
    networkController.activeUrl = 'https://node.example';
    networkController.explorer = 'https://explorer.example';
    await walletService.restoreWallet('mock', walletId: 'metadata-wallet');
  });
  tearDown(() async {
    await walletService.lock();
  });
  testWidgets('stealth disclosure precedes the named-provider request', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TokenDetailSheet(
            token: holding,
            explorerUrl: 'https://explorer.example/token',
          ),
        ),
      ),
    );
    final action = find.text('Load metadata from node.example (node)');
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(api.calls, 0);
    expect(
      find.textContaining('Loading may link this private holding'),
      findsOneWidget,
    );
    await tester.tap(find.text('Load metadata'));
    await tester.pumpAndSettle();
    expect(api.calls, 1);
    expect(api.provider, 'https://node.example');
    expect(api.node, isTrue);
    expect(walletService.displayMetadata(holding).isCollectible, isTrue);
    expect(
      (await SharedPreferences.getInstance()).getString('argus_token_meta_v2'),
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
  });
  test(
    'cancel discards stale results and prevents concurrent metadata jobs',
    () async {
      api.gate = Completer<String>();
      final pending = walletService.loadMetadata(
        holding,
        provider: networkController.explorer,
      );
      final assertion = expectLater(pending, throwsStateError);
      await expectLater(
        walletService.loadMetadata(
          holding,
          provider: networkController.explorer,
        ),
        throwsStateError,
      );
      walletService.clearSessionMetadata();
      api.gate!.complete(api.descriptor(holding.id));
      await assertion;
      expect(api.cancels, 1);
      expect(walletService.displayMetadata(holding).isCollectible, isFalse);
    },
  );
  test(
    'provider changes and wallet switches do not reuse a descriptor',
    () async {
      await walletService.loadMetadata(
        holding,
        provider: networkController.explorer,
      );
      expect(walletService.displayMetadata(holding).isCollectible, isTrue);
      networkController.explorer = 'https://different.example';
      expect(walletService.displayMetadata(holding).isCollectible, isFalse);
      networkController.explorer = 'https://explorer.example';
      await walletService.restoreWallet('mock', walletId: 'second-wallet');
      expect(walletService.displayMetadata(holding).isCollectible, isFalse);
    },
  );
  test('contradictory refresh is a conflict without changing the holding', () async {
    await walletService.loadMetadata(holding, provider: networkController.explorer);
    api.emission = 20;
    final changed = await walletService.loadMetadata(holding, provider: networkController.explorer);
    expect(changed.metadataState, MetadataState.conflict);
    expect(changed.isCollectible, isFalse);
    expect(changed.id, holding.id);
    expect(changed.amount, holding.amount);
  });

}
