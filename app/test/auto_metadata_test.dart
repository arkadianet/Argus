import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/metadata_consent.dart';
import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _pinned = 'https://mine.example';
const _other = 'https://pool.example';

/// Records every metadata request that actually leaves the app, so a test
/// can assert that none did. The previous tests only asserted that a call
/// completed, which the sweep's own error handling made vacuous.
class MetadataApi extends RustLibApi {
  final List<({String tokenId, String provider, bool isNode})> requests = [];

  /// Set to make the resolver fail, as a node with no such token would.
  bool fail = false;

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
    requests.add((
      tokenId: tokenId,
      provider: providerUrl,
      isNode: providerIsNode,
    ));
    if (fail) throw StateError('no such token');
    return jsonEncode({
      'id': tokenId,
      'name': 'Token $tokenId',
      'decimals': 0,
      'supplyEvidence': 'unknown',
      'decimalsEvidence': 'unknown',
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
  final api = MetadataApi();
  setUpAll(() => RustLib.initMock(api: api));
  tearDownAll(RustLib.dispose);

  late WalletService svc;

  /// An unlocked service on a pinned, granted node — every condition for
  /// automatic resolution satisfied, so a test can remove exactly one.
  Future<WalletService> eligible() async {
    final s = WalletService();
    await s.restoreWallet('mock', walletId: 'auto-metadata-test');
    networkController.preferredUrl = _pinned;
    networkController.activeUrl = _pinned;
    await metadataConsent.grant(_pinned);
    return s;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await metadataConsent.load();
    api.requests.clear();
    api.fail = false;
    svc = WalletService();
  });

  tearDown(() async {
    svc.cancelAutoResolve();
    networkController.preferredUrl = null;
    networkController.activeUrl = null;
  });

  List<TokenBalance> holdings(List<String> ids) =>
      [for (final id in ids) TokenBalance(id: id, amount: 1)];

  group('what actually goes out', () {
    test('a granted pinned node is asked, once per token', () async {
      svc = await eligible();
      await svc.autoResolveMetadata(holdings(['a', 'b']));
      expect(api.requests.map((r) => r.tokenId), ['a', 'b']);
      expect(api.requests.every((r) => r.provider == _pinned), isTrue);
      expect(api.requests.every((r) => r.isNode), isTrue);
    });

    test('nothing is sent without a grant', () async {
      svc = await eligible();
      await metadataConsent.revoke(_pinned);
      await svc.autoResolveMetadata(holdings(['a']));
      expect(api.requests, isEmpty);
    });

    test('a grant does not transfer to another node', () async {
      svc = await eligible();
      // The user pins a different node. Permission was given to the first.
      networkController.preferredUrl = _other;
      networkController.activeUrl = _other;
      await svc.autoResolveMetadata(holdings(['a']));
      expect(api.requests, isEmpty);
    });

    test('nothing is sent while failover moved off the pinned node', () async {
      svc = await eligible();
      networkController.activeUrl = _other;
      await svc.autoResolveMetadata(holdings(['a']));
      expect(api.requests, isEmpty);
    });

    test('stealth holdings are never resolved automatically', () async {
      svc = await eligible();
      await svc.autoResolveMetadata([
        TokenBalance(id: 'plain', amount: 1),
        TokenBalance(id: 'private', amount: 1, stealthAmount: 1),
      ]);
      expect(api.requests.map((r) => r.tokenId), ['plain']);
    });

    test('nothing is sent while the wallet is locked', () async {
      networkController.preferredUrl = _pinned;
      networkController.activeUrl = _pinned;
      await metadataConsent.grant(_pinned);
      await svc.autoResolveMetadata(holdings(['a']));
      expect(api.requests, isEmpty);
    });

    test('backgrounding stops the sweep and blocks a restart', () async {
      svc = await eligible();
      svc.didChangeAppLifecycleState(AppLifecycleState.paused);
      await svc.autoResolveMetadata(holdings(['a', 'b']));
      expect(api.requests, isEmpty,
          reason: 'a poll tick after backgrounding must not refetch');

      svc.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await svc.autoResolveMetadata(holdings(['a']));
      expect(api.requests, hasLength(1));
    });

    test('a failed token is not retried on the next sweep', () async {
      svc = await eligible();
      api.fail = true;
      await svc.autoResolveMetadata(holdings(['a']));
      expect(api.requests, hasLength(1));
      await svc.autoResolveMetadata(holdings(['a']));
      expect(api.requests, hasLength(1),
          reason: 'repeated failures must not become unbounded work');
    });

    test('an explicit hold blocks automatic requests, then resumes', () async {
      svc = await eligible();
      await svc.beginManualMetadata();
      await svc.autoResolveMetadata(holdings(['a']));
      expect(api.requests, isEmpty);

      svc.endManualMetadata();
      await Future<void>.delayed(Duration.zero);
      expect(api.requests.map((r) => r.tokenId), ['a'],
          reason: 'work displaced by a hold must not be stranded');
    });
  });

  group('metadataEndpoint', () {
    test('keeps scheme and port apart', () {
      expect(metadataEndpoint('https://h.example'), 'https://h.example:443');
      expect(metadataEndpoint('http://h.example'), 'http://h.example:80');
      expect(
        metadataEndpoint('https://h.example:9053'),
        'https://h.example:9053',
      );
      expect(
        metadataEndpoint('https://h.example') ==
            metadataEndpoint('http://h.example'),
        isFalse,
      );
    });

    test('rejects what cannot be a provider', () {
      expect(metadataEndpoint(null), isNull);
      expect(metadataEndpoint(''), isNull);
      expect(metadataEndpoint('ftp://h.example'), isNull);
      expect(metadataEndpoint('not a url'), isNull);
      expect(metadataEndpoint('https://ünïcode.example'), isNull);
    });
  });

  group('MetadataConsent', () {
    test('grants nothing by default', () async {
      final c = MetadataConsent();
      await c.load();
      expect(c.allows(_pinned), isFalse);
    });

    test('a grant survives a restart', () async {
      final first = MetadataConsent();
      await first.grant(_pinned);
      final second = MetadataConsent();
      await second.load();
      expect(second.allows(_pinned), isTrue);
    });

    test('the pre-consent switch is never read as consent', () async {
      // Someone who enabled the old global boolean agreed to different
      // terms, which said the node learned nothing new.
      SharedPreferences.setMockInitialValues({'argus_auto_metadata_v1': true});
      final c = MetadataConsent();
      await c.load();
      expect(c.allows(_pinned), isFalse);
      expect(c.granted, isEmpty);
    });

    test('a corrupt grant list is not a grant', () async {
      SharedPreferences.setMockInitialValues({
        'argus_metadata_consent_v1': 'not json',
      });
      final c = MetadataConsent();
      await c.load();
      expect(c.granted, isEmpty);
    });

    test('revoking removes only that endpoint', () async {
      final c = MetadataConsent();
      await c.grant(_pinned);
      await c.grant(_other);
      await c.revoke(_pinned);
      expect(c.allows(_pinned), isFalse);
      expect(c.allows(_other), isTrue);
    });
  });
}
