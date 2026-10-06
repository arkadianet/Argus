import 'dart:async';
import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/amm_service.dart';
import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/sigmausd_service.dart';
import 'package:argus_wallet/services/token_catalog.dart';
import 'package:argus_wallet/services/token_descriptor_store.dart';
import 'package:argus_wallet/services/token_metadata.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _node = 'https://node.example';
String _id(String seed) => seed * (64 ~/ seed.length);

/// A held token, a deep pool's token and a shallow pool's token.
final _held = _id('ab');
final _deep = _id('d1');
final _shallow = _id('5a');

class LookupApi extends RustLibApi {
  final List<({String id, String provider, bool node})> asked = [];

  /// The request numbered [gateOnCall] (1-based) waits for this.
  Completer<void>? gate;
  int gateOnCall = 1;

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
  Future<String> crateApiInspectTokenMetadata({
    required String tokenId,
    required String providerUrl,
    required bool providerIsNode,
  }) async {
    asked.add((id: tokenId, provider: providerUrl, node: providerIsNode));
    final waiting = asked.length == gateOnCall ? gate : null;
    if (waiting != null) {
      gate = null;
      await waiting.future;
    }
    return jsonEncode({
      'id': tokenId,
      'name': 'Name ${tokenId.substring(0, 2)}',
      'decimals': 2,
      'decimalsEvidence': 'valid',
      'supplyEvidence': 'originalEmission',
      'emissionAmount': 1000,
      'declaredAssetKind': 'none',
      'metadataState': 'complete',
      'mediaState': 'unknown',
    });
  }

  @override
  Future<String> crateApiAmmPools({
    String? nodeUrl,
    required bool forceRefresh,
    String? knownTokensJson,
  }) async => jsonEncode({
    'truncated': false,
    'pools': [
      {
        'pool_id': 'shallow',
        'pool_type': 'N2T',
        'erg_reserves': 10,
        'token_y': {'token_id': _shallow, 'amount': 5},
      },
      {
        'pool_id': 'deep',
        'pool_type': 'N2T',
        'erg_reserves': 1000000,
        'token_y': {'token_id': _deep, 'amount': 5},
      },
    ],
    // What Rust pads an unseeded set with.
    'tokens': {
      _deep: {'name': '${_deep.substring(0, 8)}…', 'decimals': 0},
      _shallow: {'name': '${_shallow.substring(0, 8)}…', 'decimals': 0},
    },
  });

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 1000 && !done(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(done(), isTrue, reason: 'condition never became true');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = LookupApi();
  setUpAll(() {
    RustLib.initMock(api: api);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.argus.wallet/secure_storage'),
          (call) async => null,
        );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    publicTokenCatalog.debugReset();
    api.asked.clear();
    api.gate = null;
    api.gateOnCall = 1;
    networkController.activeUrl = _node;
  });

  tearDown(() async {
    networkController.activeUrl = null;
    if (walletService.isUnlocked) await walletService.lock();
  });

  Future<void> resolveForWallet(WalletService svc, String walletId) =>
      svc.prefetchTokenMeta(
        [_held],
        walletId: walletId,
        servedBy: _node,
        stillCurrent: () => true,
      );

  test('one lookup, best layer first', () async {
    final sigUsd = SigmaUsdTokens.sigUsd;
    final legacyOnly = _id('1e');
    SharedPreferences.setMockInitialValues({
      'argus_token_meta_v2': jsonEncode({
        sigUsd: {'name': 'Old SigUSD', 'decimals': 0},
        legacyOnly: {'name': 'Legacy', 'decimals': 1},
      }),
    });
    final svc = WalletService();
    await svc.loadTokenMeta();
    await svc.restoreWallet('mock', walletId: 'layers');
    await resolveForWallet(svc, 'layers');
    publicTokenCatalog.debugSeed([
      CachedDescriptor(id: _held, name: 'Catalog name', decimals: 9),
      CachedDescriptor(id: _deep, name: 'Pooled', decimals: 4),
    ]);

    expect(svc.cachedTokenMeta(_held)?.name, 'Name ab',
        reason: "the wallet's own descriptor comes first");
    expect(svc.cachedTokenMeta(_deep)?.name, 'Pooled');
    expect(svc.cachedTokenMeta(sigUsd)?.name, 'SigUSD',
        reason: 'the curated registry outranks a table with no provenance');
    expect(svc.cachedTokenMeta(sigUsd)?.decimals, 2);
    expect(svc.cachedTokenMeta(legacyOnly)?.name, 'Legacy');
    expect(svc.cachedTokenMeta(_id('99')), isNull);
    await svc.lock('layers');
  });

  test('the first balance after an unlock already carries learned names',
      () async {
    final first = WalletService();
    await first.restoreWallet('mock', walletId: 'relaunch');
    await resolveForWallet(first, 'relaunch');
    await first.lock('relaunch');
    api.asked.clear();

    // A relaunch: nothing in memory, and no name pass has run.
    final second = WalletService();
    await second.restoreWallet('mock', walletId: 'relaunch');
    final holdings = await second.hydrateTokens([
      {'id': _held, 'amount': 500},
    ]);
    expect(holdings.single.name, 'Name ab',
        reason: 'names must not wait for a sync to come back');
    expect(holdings.single.decimals, 2);
    expect(holdings.single.amount, 500);
    expect(api.asked, isEmpty, reason: 'and cost no request');
    await second.lock('relaunch');
  });

  test('a holding published without a record is filled from the lookup',
      () async {
    publicTokenCatalog.debugSeed([
      CachedDescriptor(id: _deep, name: 'Pooled', decimals: 4),
    ]);
    final shown = walletService.displayMetadata(
      TokenBalance(id: _deep, amount: 12345, stealthAmount: 5),
    );
    expect(shown.name, 'Pooled');
    expect(shown.decimals, 4);
    expect(shown.amount, 12345);
    expect(shown.stealthAmount, 5);

    // Restored from a snapshot: a name, but none of the evidence behind it.
    final restored = TokenBalance(id: _deep, amount: 1, name: 'Snapshot');
    expect(walletService.displayMetadata(restored).name, 'Pooled',
        reason: 'what is known now is the one source');

    final unknown = TokenBalance(id: _id('77'), amount: 1, name: 'Published');
    expect(walletService.displayMetadata(unknown).name, 'Published',
        reason: 'with nothing known, a holding keeps its published name');
  });

  test("a wallet's own names never reach the public catalog or a pool set",
      () async {
    await walletService.restoreWallet('mock', walletId: 'private');
    await resolveForWallet(walletService, 'private');
    expect(walletService.cachedTokenMeta(_held)?.name, 'Name ab',
        reason: 'control: the wallet knows it');

    expect(publicTokenCatalog.lookup(_held), isNull);
    final pool = {
      'pool_id': 'p',
      'pool_type': 'N2T',
      'erg_reserves': 1,
      'token_y': {'token_id': _held, 'amount': 1},
    };
    expect(publicPoolTokenMeta([pool]), isEmpty,
        reason: 'a pool set is cached and shared; it must not carry this');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PublicTokenCatalog.storageKey), isNull);
  });

  test('pool tokens are named only from the node that served the pools',
      () async {
    await walletService.restoreWallet('mock', walletId: 'pools');
    final set = await ammService.pools();
    expect(set.tokens, isEmpty,
        reason: 'the placeholders Rust pads the set with are not names');
    expect(set.tokenIds, {_deep, _shallow});

    await _until(() => publicTokenCatalog.lookup(_shallow) != null);
    expect(api.asked.map((a) => a.id), [_deep, _shallow],
        reason: 'deepest pool first, and nothing but pool tokens');
    expect(api.asked.every((a) => a.provider == _node && a.node), isTrue,
        reason: 'the node that served the list, never the explorer');

    final again = await ammService.pools();
    expect(again.tokens[_deep]?.name, 'Name d1');
    expect(again.tokens[_deep]?.decimals, 2);
    expect(tokenLabel(_shallow), 'Name 5a');
  });

  test('with no node configured nothing is resolved', () async {
    await walletService.restoreWallet('mock', walletId: 'nonode');
    networkController.activeUrl = null;
    await ammService.pools();
    await Future<void>.delayed(Duration.zero);
    expect(api.asked, isEmpty,
        reason: 'Rust would pick its own node, and Argus cannot tell which');
  });

  test('a locked wallet makes no catalog requests', () async {
    await publicTokenCatalog.resolve([_deep], servedBy: _node);
    expect(api.asked, isEmpty);
  });

  test("a wallet pass waits out a catalog lookup and the catalog stops",
      () async {
    await walletService.restoreWallet('mock', walletId: 'shared');
    final gate = Completer<void>();
    api.gate = gate;
    final catalogPass = publicTokenCatalog.resolve(
      [_deep, _shallow],
      servedBy: _node,
    );
    await _until(() => api.asked.isNotEmpty);

    final walletPass = resolveForWallet(walletService, 'shared');
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    await walletPass;
    await catalogPass;

    expect(api.asked.map((a) => a.id), [_deep, _held],
        reason: 'the wallet is served next, and the catalog gives way');
    expect(walletService.cachedTokenMeta(_held)?.name, 'Name ab',
        reason: 'the pass must not end early because the catalog was busy');
  });

  test('an explicit request waits out a catalog lookup', () async {
    await walletService.restoreWallet('mock', walletId: 'explicit');
    final gate = Completer<void>();
    api.gate = gate;
    final catalogPass = publicTokenCatalog.resolve([_deep], servedBy: _node);
    await _until(() => api.asked.isNotEmpty);

    final load = walletService.loadMetadata(
      TokenBalance(id: _held, amount: 1),
      provider: _node,
      providerIsNode: true,
    );
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    final loaded = await load;
    await catalogPass;
    expect(loaded.name, 'Name ab',
        reason: 'a background lookup must not make a tap fail as busy');
  });

  group('display helpers', () {
    test('an amount nothing can scale is said to be raw units', () {
      expect(
        tokenAmountText(BigInt.from(349670571986), _id('6d')),
        '349,670,571,986 raw units of 6d6d6d6d…',
      );
      expect(tokenDecimals(_id('6d')), isNull);
    });

    test('a known scale is applied', () {
      publicTokenCatalog.debugSeed([
        CachedDescriptor(id: _deep, name: 'Pooled', decimals: 4),
      ]);
      expect(tokenAmountText(BigInt.from(12345678), _deep), '1,234.5678 Pooled');
      expect(tokenDecimals(_deep), 4);
    });

    test('a token issued with no decimals has a known zero', () {
      publicTokenCatalog.debugSeed([
        CachedDescriptor(
          id: _deep,
          name: 'Whole',
          decimalsEvidence: DecimalsEvidence.valid,
        ),
      ]);
      expect(tokenAmountText(BigInt.from(69), _deep), '69 Whole');
    });

    test('a malformed decimals declaration is not trusted', () {
      publicTokenCatalog.debugSeed([
        CachedDescriptor(
          id: _deep,
          name: 'Odd',
          decimalsEvidence: DecimalsEvidence.invalid,
        ),
      ]);
      expect(tokenAmountText(BigInt.from(69), _deep), '69 raw units of Odd');
    });

    test('a holding keeps its published name once caches are cleared', () {
      final held = TokenBalance(
        id: _id('77'),
        amount: 150,
        name: 'Kept',
        decimals: 2,
      );
      expect(tokenAmountText(BigInt.from(150), held.id, held: held), '1.5 Kept');
    });

    test('issuer text is sanitised before it is shown', () {
      publicTokenCatalog.debugSeed([
        CachedDescriptor(id: _deep, name: 'Ev\u202eil\u0001', decimals: 0),
      ]);
      expect(tokenLabel(_deep), 'Evil');
    });

    test('exact at any size', () {
      expect(
        formatUnits(BigInt.parse('123456789012345678901234567890'), 9),
        '123,456,789,012,345,678,901.23456789',
      );
    });
  });
}
