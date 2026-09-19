import 'dart:async';
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

  /// Per-call hook: return an error string to throw, or null to succeed.
  String? Function(String tokenId)? onAsk;

  /// When set, the next request suspends until this completes, so a test can
  /// run another pass while one is genuinely in flight.
  Completer<String?>? gate;

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
    final waiting = gate;
    if (waiting != null) {
      gate = null;
      final err = await waiting.future;
      if (err != null) throw StateError(err);
    }
    final hook = onAsk?.call(tokenId);
    if (hook != null) throw StateError(hook);
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

  late String _wallet;
  Future<WalletService> unlocked(String walletId) async {
    _wallet = walletId;
    final s = WalletService();
    await s.restoreWallet('mock', walletId: walletId);
    return s;
  }

  test('a resolved descriptor is cached and survives a restart', () async {
    final first = await unlocked('w1');
    await first.prefetchTokenMeta([_id('ab')], walletId: _wallet, servedBy: networkController.activeUrl!, stillCurrent: () => true);

    expect(api.asked, contains(_id('ab')));
    expect(first.cachedTokenMeta(_id('ab'))?.name, 'Name ab');
    expect(first.cachedTokenMeta(_id('ab'))?.decimals, 2);

    // A fresh service unlocking the same wallet, as a relaunch would.
    // loadWalletTokenMeta refuses to populate a service that is not on that
    // wallet, so go through the real activation path rather than calling it
    // directly.
    final second = WalletService();
    api.asked.clear();
    _wallet = 'w1';
    await second.restoreWallet('mock', walletId: 'w1');
    // The table loads on the first path that needs it, which in production
    // is the sync that would otherwise resolve these ids.
    await second.prefetchTokenMeta([_id('ab')], walletId: _wallet, servedBy: networkController.activeUrl!, stillCurrent: () => true);

    expect(api.asked, isEmpty,
        reason: 'a cached name must not cost a request after a restart');
    expect(second.cachedTokenMeta(_id('ab'))?.name, 'Name ab',
        reason: 'names must not be re-fetched every launch');
  });

  test('evidence survives the round trip rather than flattening', () async {
    final svc = await unlocked('w2');
    await svc.prefetchTokenMeta([_id('cd')], walletId: _wallet, servedBy: networkController.activeUrl!, stillCurrent: () => true);

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
    await svc.prefetchTokenMeta([_id('ef')], walletId: _wallet, servedBy: networkController.activeUrl!, stillCurrent: () => true);
    final before = api.asked.length;
    await svc.prefetchTokenMeta([_id('ef')], walletId: _wallet, servedBy: networkController.activeUrl!, stillCurrent: () => true);
    expect(api.asked.length, before);
  });

  test('one incapable-node failure stops the rest of the batch', () async {
    final svc = await unlocked('w4');
    api.failWith = 'unsupported';
    await svc.prefetchTokenMeta([_id('ab'), _id('cd'), _id('ef')], walletId: _wallet, servedBy: networkController.activeUrl!, stillCurrent: () => true);
    expect(api.asked, hasLength(1),
        reason: 'a node without extraIndex must be asked once, not per token');
    expect(svc.metadataLookupUnsupported, isTrue);

    // And nothing further, until the provider changes.
    await svc.prefetchTokenMeta([_id('12')], walletId: _wallet, servedBy: networkController.activeUrl!, stillCurrent: () => true);
    expect(api.asked, hasLength(1));
  });

  test('a new provider retries the token the old one failed', () async {
    // The same token, deliberately: asking about a different one would pass
    // even if misses were never scoped to the provider that produced them.
    final svc = await unlocked('w5');
    api.failWith = 'missing';
    await svc.prefetchTokenMeta(
      [_id('ab')],
      walletId: _wallet,
      servedBy: 'https://a.example',
      stillCurrent: () => true,
    );
    expect(api.asked, [_id('ab')]);

    api.failWith = null;
    await svc.prefetchTokenMeta(
      [_id('ab')],
      walletId: _wallet,
      servedBy: 'https://b.example',
      stillCurrent: () => true,
    );
    expect(api.asked, [_id('ab'), _id('ab')],
        reason: 'a miss belongs to the provider that produced it');
    expect(svc.cachedTokenMeta(_id('ab'))?.name, 'Name ab');
  });

  test('an early capability exit still persists earlier successes', () async {
    final svc = await unlocked('w5b');
    // One success, then a run of not-founds long enough to write the node
    // off. The success must survive a restart.
    final ids = [
      _id('ab'),
      for (var i = 0; i < WalletService.notFoundRunBeforeUnsupported; i++)
        i.toRadixString(16).padLeft(2, '0') * 32,
    ];
    var first = true;
    api.onAsk = (_) {
      if (first) {
        first = false;
        return null;
      }
      return '404 not found';
    };
    await svc.prefetchTokenMeta(
      ids,
      walletId: _wallet,
      servedBy: networkController.activeUrl!,
      stillCurrent: () => true,
    );
    api.onAsk = null;
    expect(svc.metadataLookupUnsupported, isTrue);

    final onDisk = await TokenDescriptorStore.load('w5b');
    expect(onDisk[_id('ab')]?.name, 'Name ab',
        reason: 'returning early must not discard what was already resolved');
  });

  test('a failure arriving after a wallet switch does not disable the new '
      'wallet', () async {
    final svc = await unlocked('w5c');
    api.failWith = 'unsupported';
    // The pass no longer owns the wallet by the time the error lands.
    await svc.prefetchTokenMeta(
      [_id('ab')],
      walletId: 'a-wallet-that-is-no-longer-active',
      servedBy: networkController.activeUrl!,
      stillCurrent: () => true,
    );
    expect(svc.metadataLookupUnsupported, isFalse,
        reason: "wallet A's failure must not disable wallet B");
    expect(api.asked, isEmpty);
  });

  test('a failure that lands after ownership is lost changes nothing',
      () async {
    // The pass starts owned and loses ownership while the request is in
    // flight, then that request fails with a capability error. Without the
    // ownership check on the error path, this would disable resolution for
    // whatever wallet is current by the time it lands.
    final svc = await unlocked('w5e');
    var current = true;
    api.onAsk = (_) {
      current = false;
      return 'extraIndex is required for this endpoint';
    };
    await svc.prefetchTokenMeta(
      [_id('ab')],
      walletId: _wallet,
      servedBy: networkController.activeUrl!,
      stillCurrent: () => current,
    );
    api.onAsk = null;
    expect(api.asked, hasLength(1), reason: 'the request did go out');
    expect(svc.metadataLookupUnsupported, isFalse,
        reason: 'a verdict from a pass that no longer owns the session must '
            'not be applied to the one that does');
  });

  test('a discarded session is not written back', () async {
    final svc = await unlocked('w5d');
    // clearSessionMetadata bumps the descriptor epoch mid-pass.
    api.onAsk = (_) {
      svc.clearSessionMetadata();
      return null;
    };
    await svc.prefetchTokenMeta(
      [_id('ab'), _id('cd')],
      walletId: _wallet,
      servedBy: networkController.activeUrl!,
      stillCurrent: () => true,
    );
    api.onAsk = null;
    expect(api.asked, hasLength(1),
        reason: 'the pass stops once its session is discarded');
    expect(await TokenDescriptorStore.load('w5d'), isEmpty,
        reason: 'and writes nothing back');
  });

  test('a token the node cannot find is not retried every sync', () async {
    final svc = await unlocked('w6');
    api.failWith = 'missing';
    await svc.prefetchTokenMeta([_id('ab')], walletId: _wallet, servedBy: networkController.activeUrl!, stillCurrent: () => true);
    expect(api.asked, hasLength(1));
    await svc.prefetchTokenMeta([_id('ab')], walletId: _wallet, servedBy: networkController.activeUrl!, stillCurrent: () => true);
    expect(api.asked, hasLength(1),
        reason: 'an unresolvable token must not be asked about forever');
  });

  test('one missing token does not write off the node', () async {
    final svc = await unlocked('w6b');
    api.failWith = 'missing';
    await svc.prefetchTokenMeta([_id('ab')], walletId: _wallet, servedBy: networkController.activeUrl!, stillCurrent: () => true);
    expect(svc.metadataLookupUnsupported, isFalse,
        reason: '404 also means "this node does not know that token"');

    // The next token still gets asked about, and resolves.
    api.failWith = null;
    await svc.prefetchTokenMeta([_id('cd')], walletId: _wallet, servedBy: networkController.activeUrl!, stillCurrent: () => true);
    expect(svc.cachedTokenMeta(_id('cd'))?.name, 'Name cd');
  });

  test('a run of not-founds is treated as an incapable node', () async {
    final svc = await unlocked('w6c');
    api.failWith = 'missing';
    final many = [
      for (var i = 0; i < 12; i++)
        i.toRadixString(16).padLeft(2, '0') * 32,
    ];
    await svc.prefetchTokenMeta(many, walletId: _wallet, servedBy: networkController.activeUrl!, stillCurrent: () => true);
    expect(svc.metadataLookupUnsupported, isTrue);
    expect(api.asked, hasLength(WalletService.notFoundRunBeforeUnsupported),
        reason: 'a node that answers nothing must not be asked 194 times');
  });

  test('descriptors do not leak between wallets', () async {
    final svc = await unlocked('w7');
    await svc.prefetchTokenMeta([_id('ab')], walletId: _wallet, servedBy: networkController.activeUrl!, stillCurrent: () => true);
    expect(svc.cachedTokenMeta(_id('ab'))?.name, 'Name ab');

    // Switching wallets must drop the outgoing table synchronously.
    _wallet = 'w8';
    await svc.restoreWallet('mock', walletId: 'w8');
    expect(svc.cachedTokenMeta(_id('ab')), isNull,
        reason: "one wallet's holdings must not be visible under another");

    final other = await TokenDescriptorStore.load('w8');
    expect(other, isEmpty);
  });

  test('an unfinished lookup is not suppressed on the next refresh',
      () async {
    // Ownership is lost while the request is in flight. The id must not be
    // remembered as a miss: nothing was learned about it.
    final svc = await unlocked('w10');
    var current = true;
    api.onAsk = (_) {
      current = false;
      return null;
    };
    await svc.prefetchTokenMeta(
      [_id('ab')],
      walletId: _wallet,
      servedBy: networkController.activeUrl!,
      stillCurrent: () => current,
    );
    api.onAsk = null;
    api.asked.clear();

    await svc.prefetchTokenMeta(
      [_id('ab')],
      walletId: _wallet,
      servedBy: networkController.activeUrl!,
      stillCurrent: () => true,
    );
    expect(api.asked, [_id('ab')],
        reason: 'an interrupted pass must not permanently skip the token');
    expect(svc.cachedTokenMeta(_id('ab'))?.name, 'Name ab');
  });

  test('cached descriptors are returned, not just freshly fetched ones',
      () async {
    final svc = await unlocked('w11');
    await svc.prefetchTokenMeta(
      [_id('ab')],
      walletId: _wallet,
      servedBy: networkController.activeUrl!,
      stillCurrent: () => true,
    );
    api.asked.clear();

    // Second pass: nothing to fetch, but the caller still needs the name to
    // apply to holdings that published before the table was read.
    final out = await svc.prefetchTokenMeta(
      [_id('ab')],
      walletId: _wallet,
      servedBy: networkController.activeUrl!,
      stillCurrent: () => true,
    );
    expect(api.asked, isEmpty);
    expect(out[_id('ab')]?.name, 'Name ab',
        reason: 'otherwise a restart shows raw ids until a later hydration');
  });

  test('results from a discarded session are dropped, not returned',
      () async {
    final svc = await unlocked('w12');
    var asks = 0;
    api.onAsk = (_) {
      // Discard the session while the SECOND request is in flight, so the
      // first has already accumulated a result.
      if (++asks == 2) svc.clearSessionMetadata();
      return null;
    };
    final out = await svc.prefetchTokenMeta(
      [_id('ab'), _id('cd')],
      walletId: _wallet,
      servedBy: networkController.activeUrl!,
      stillCurrent: () => true,
    );
    api.onAsk = null;
    expect(out, isEmpty,
        reason: 'a result accumulated before the clear must not survive it');
  });

  test('a pass cannot record a verdict about a provider it does not own',
      () async {
    final svc = await unlocked('w13');
    // A's request is genuinely in flight and holds the metadata job.
    final gate = Completer<String?>();
    api.gate = gate;
    final passA = svc.prefetchTokenMeta(
      [_id('ab')],
      walletId: _wallet,
      servedBy: 'https://a.example',
      stillCurrent: () => true,
    );
    await Future<void>.delayed(Duration.zero);

    // B takes over the provider slot, then exits because the job is held.
    await svc.prefetchTokenMeta(
      [_id('cd')],
      walletId: _wallet,
      servedBy: 'https://b.example',
      stillCurrent: () => true,
    );

    // Now A's request fails with a capability error, after B owns the slot.
    gate.complete('extraIndex is required for this endpoint');
    await passA;

    expect(svc.metadataLookupUnsupported, isFalse,
        reason: "a verdict about A must not be applied to B");
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
