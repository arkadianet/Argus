import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/token_descriptor_store.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _node = 'https://node.example';
String _id(String seed) => seed * (64 ~/ seed.length);

class ResolverApi extends RustLibApi {
  final List<String> asked = [];

  /// Thrown instead of a descriptor when set. `unsupported` mimics a node
  /// with no extraIndex; `missing` mimics a token it simply cannot find.
  String? failWith;

  @override
  Future<BigInt> crateApiWalletRestore({
    required String encryptedSeedJson,
    String? wrapKey,
  }) async => BigInt.one;

  @override
  Future<void> crateApiWalletLock({required BigInt handleId}) async {}

  @override
  Future<String> crateApiInspectTokenMetadata({
    required String tokenId,
    required String providerUrl,
    required bool providerIsNode,
  }) async {
    asked.add(tokenId);
    if (failWith == 'unsupported') {
      throw StateError('extraIndex is required for this endpoint');
    }
    if (failWith == 'missing') throw StateError('404 not found');
    return jsonEncode({
      'id': tokenId,
      'name': 'Name ${tokenId.substring(0, 2)}',
      'decimals': 2,
      'emissionAmount': 1000,
      'supplyEvidence': 'originalEmission',
      'decimalsEvidence': 'valid',
      'declaredAssetKind': 'none',
      'metadataState': 'complete',
      'mediaState': 'unknown',
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = ResolverApi();
  setUpAll(() => RustLib.initMock(api: api));
  tearDownAll(RustLib.dispose);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api.asked.clear();
    api.failWith = null;
    networkController.activeUrl = _node;
  });

  tearDown(() => networkController.activeUrl = null);

  Future<WalletService> unlocked(String walletId) async {
    final s = WalletService();
    await s.restoreWallet('mock', walletId: walletId);
    return s;
  }

  test('a resolved descriptor is cached and survives a restart', () async {
    final first = await unlocked('w1');
    await first.prefetchTokenMeta([_id('ab')]);

    expect(api.asked, contains(_id('ab')));
    expect(first.cachedTokenMeta(_id('ab'))?.name, 'Name ab');
    expect(first.cachedTokenMeta(_id('ab'))?.decimals, 2);

    // A fresh service unlocking the same wallet, as a relaunch would.
    // loadWalletTokenMeta refuses to populate a service that is not on that
    // wallet, so go through the real activation path rather than calling it
    // directly.
    final second = WalletService();
    api.asked.clear();
    await second.restoreWallet('mock', walletId: 'w1');
    // The table loads on the first path that needs it, which in production
    // is the sync that would otherwise resolve these ids.
    await second.prefetchTokenMeta([_id('ab')]);

    expect(api.asked, isEmpty,
        reason: 'a cached name must not cost a request after a restart');
    expect(second.cachedTokenMeta(_id('ab'))?.name, 'Name ab',
        reason: 'names must not be re-fetched every launch');
  });

  test('evidence survives the round trip rather than flattening', () async {
    final svc = await unlocked('w2');
    await svc.prefetchTokenMeta([_id('cd')]);

    final reloaded = await TokenDescriptorStore.load('w2');
    final d = reloaded[_id('cd')]!;
    expect(d.supplyEvidence, SupplyEvidence.originalEmission);
    expect(d.decimalsEvidence, DecimalsEvidence.valid);
    expect(d.metadataState, MetadataState.complete);
    expect(d.source, _node,
        reason: 'provenance must not be reattributed to a later node');
  });

  test('a cached descriptor is not re-requested', () async {
    final svc = await unlocked('w3');
    await svc.prefetchTokenMeta([_id('ef')]);
    final before = api.asked.length;
    await svc.prefetchTokenMeta([_id('ef')]);
    expect(api.asked.length, before);
  });

  test('one incapable-node failure stops the rest of the batch', () async {
    final svc = await unlocked('w4');
    api.failWith = 'unsupported';
    await svc.prefetchTokenMeta([_id('ab'), _id('cd'), _id('ef')]);
    expect(api.asked, hasLength(1),
        reason: 'a node without extraIndex must be asked once, not per token');
    expect(svc.metadataLookupUnsupported, isTrue);

    // And nothing further, until the provider changes.
    await svc.prefetchTokenMeta([_id('12')]);
    expect(api.asked, hasLength(1));
  });

  test('a new provider gets a fresh chance', () async {
    final svc = await unlocked('w5');
    api.failWith = 'unsupported';
    await svc.prefetchTokenMeta([_id('ab')]);
    expect(svc.metadataLookupUnsupported, isTrue);

    api.failWith = null;
    networkController.activeUrl = 'https://other.example';
    await svc.prefetchTokenMeta([_id('cd')]);
    expect(svc.metadataLookupUnsupported, isFalse);
    expect(api.asked, contains(_id('cd')));
  });

  test('a token the node cannot find is not retried every sync', () async {
    final svc = await unlocked('w6');
    api.failWith = 'missing';
    await svc.prefetchTokenMeta([_id('ab')]);
    expect(api.asked, hasLength(1));
    await svc.prefetchTokenMeta([_id('ab')]);
    expect(api.asked, hasLength(1),
        reason: 'an unresolvable token must not be asked about forever');
  });

  test('one missing token does not write off the node', () async {
    final svc = await unlocked('w6b');
    api.failWith = 'missing';
    await svc.prefetchTokenMeta([_id('ab')]);
    expect(svc.metadataLookupUnsupported, isFalse,
        reason: '404 also means "this node does not know that token"');

    // The next token still gets asked about, and resolves.
    api.failWith = null;
    await svc.prefetchTokenMeta([_id('cd')]);
    expect(svc.cachedTokenMeta(_id('cd'))?.name, 'Name cd');
  });

  test('a run of not-founds is treated as an incapable node', () async {
    final svc = await unlocked('w6c');
    api.failWith = 'missing';
    final many = [
      for (var i = 0; i < 12; i++)
        i.toRadixString(16).padLeft(2, '0') * 32,
    ];
    await svc.prefetchTokenMeta(many);
    expect(svc.metadataLookupUnsupported, isTrue);
    expect(api.asked, hasLength(WalletService.notFoundRunBeforeUnsupported),
        reason: 'a node that answers nothing must not be asked 194 times');
  });

  test('descriptors do not leak between wallets', () async {
    final svc = await unlocked('w7');
    await svc.prefetchTokenMeta([_id('ab')]);
    expect(svc.cachedTokenMeta(_id('ab'))?.name, 'Name ab');

    // Switching wallets must drop the outgoing table synchronously.
    await svc.restoreWallet('mock', walletId: 'w8');
    expect(svc.cachedTokenMeta(_id('ab')), isNull,
        reason: "one wallet's holdings must not be visible under another");

    final other = await TokenDescriptorStore.load('w8');
    expect(other, isEmpty);
  });

  test('an unparseable table is not a descriptor', () async {
    SharedPreferences.setMockInitialValues({
      'argus_token_descriptors_v1_w9': 'not json',
    });
    expect(await TokenDescriptorStore.load('w9'), isEmpty);
  });

  test('an unknown enum name falls back instead of throwing', () {
    final d = TokenDescriptorStore.decode('tok', {
      'name': 'X',
      'metadataState': 'somethingNewerBuildsWrote',
    });
    expect(d, isNotNull);
    expect(d!.metadataState, MetadataState.partial);
  });
}
