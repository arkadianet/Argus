import 'dart:async';
import 'dart:convert';

import 'package:argus_wallet/services/token_catalog.dart';
import 'package:argus_wallet/services/token_descriptor_store.dart';
import 'package:argus_wallet/services/token_evidence.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _node = 'https://pools.example';
String _id(String seed) => seed * (64 ~/ seed.length);

String _descriptor(String id, {String? name, int decimals = 2}) => jsonEncode({
  'id': id,
  'name': name ?? 'Name ${id.substring(0, 2)}',
  'decimals': decimals,
  'decimalsEvidence': 'valid',
  'supplyEvidence': 'originalEmission',
  'emissionAmount': 1000000,
  'declaredAssetKind': 'none',
  'metadataState': 'complete',
  'mediaState': 'unknown',
});

/// Records what the catalog asks, and answers like the node would.
class FakeNode {
  final List<({String id, String provider})> asked = [];
  String? Function(String id)? fail;
  bool yieldJob = false;
  Completer<void>? gate;

  Future<String?> inspect(String id, String provider) async {
    if (yieldJob) return null;
    asked.add((id: id, provider: provider));
    final waiting = gate;
    if (waiting != null) {
      gate = null;
      await waiting.future;
    }
    final err = fail?.call(id);
    if (err != null) throw StateError(err);
    return _descriptor(id);
  }
}

void main() {
  late FakeNode node;
  late PublicTokenCatalog catalog;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    node = FakeNode();
    catalog = PublicTokenCatalog(inspect: node.inspect);
  });

  test('pool tokens are asked of the node that served the list, in order',
      () async {
    await catalog.resolve([_id('ab'), _id('cd')], servedBy: _node);
    expect(node.asked.map((a) => a.id), [_id('ab'), _id('cd')],
        reason: "the list's order, not one a wallet could influence");
    expect(node.asked.every((a) => a.provider == _node), isTrue);
    expect(catalog.lookup(_id('ab'))?.name, 'Name ab');
    expect(catalog.lookup(_id('ab'))?.decimalsEvidence, DecimalsEvidence.valid,
        reason: 'evidence is kept, not flattened to a name');
    expect(catalog.lookup(_id('ab'))?.source, _node);
  });

  test('what was learned survives a restart and is not asked again', () async {
    await catalog.resolve([_id('ab')], servedBy: _node);
    final relaunched = PublicTokenCatalog(inspect: node.inspect);
    await relaunched.ensureLoaded();
    expect(relaunched.lookup(_id('ab'))?.name, 'Name ab');

    node.asked.clear();
    await relaunched.resolve([_id('ab')], servedBy: _node);
    expect(node.asked, isEmpty, reason: 'a known token costs no request');
  });

  test('one pass is bounded; the rest resolve on later passes', () async {
    final ids = [
      for (var i = 0; i < PublicTokenCatalog.maxPerPass + 5; i++)
        i.toRadixString(16).padLeft(64, '0'),
    ];
    await catalog.resolve(ids, servedBy: _node);
    expect(node.asked, hasLength(PublicTokenCatalog.maxPerPass));
    await catalog.resolve(ids, servedBy: _node);
    expect(catalog.length, ids.length);
  });

  test('giving the job back to the wallet ends the pass without a verdict',
      () async {
    node.yieldJob = true;
    await catalog.resolve([_id('ab')], servedBy: _node);
    expect(catalog.lookup(_id('ab')), isNull);

    node.yieldJob = false;
    await catalog.resolve([_id('ab')], servedBy: _node);
    expect(node.asked.map((a) => a.id), [_id('ab')],
        reason: 'a token the wallet pre-empted is not remembered as missing');
  });

  test('a node that cannot serve issuance lookups is not asked again',
      () async {
    node.fail = (_) => 'extraIndex is required for this endpoint';
    await catalog.resolve([_id('ab'), _id('cd')], servedBy: _node);
    expect(node.asked, hasLength(1), reason: 'one capability failure ends it');
    expect(catalog.lookupUnsupported, isTrue);
    await catalog.resolve([_id('cd')], servedBy: _node);
    expect(node.asked, hasLength(1));

    node.fail = null;
    await catalog.resolve([_id('cd')], servedBy: 'https://other.example');
    expect(node.asked.last.provider, 'https://other.example',
        reason: 'a different node gets a fresh chance');
  });

  test('a transient failure is retried on the next pass', () async {
    node.fail = (_) => 'RETRYABLE: Metadata provider returned 503';
    await catalog.resolve([_id('ab')], servedBy: _node);
    node.fail = null;
    await catalog.resolve([_id('ab')], servedBy: _node);
    expect(node.asked, hasLength(2));
    expect(catalog.lookup(_id('ab')), isNotNull);
  });

  test('a clear during a pass discards what it was about to learn', () async {
    final gate = Completer<void>();
    node.gate = gate;
    final pass = catalog.resolve([_id('ab')], servedBy: _node);
    while (node.asked.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    await catalog.clear();
    gate.complete();
    await pass;
    expect(catalog.lookup(_id('ab')), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PublicTokenCatalog.storageKey), isNull,
        reason: 'a write overtaken by a clear must not recreate the table');
  });

  test('ids that are not token ids are never sent', () async {
    await catalog.resolve(['not-an-id', '', _id('ab')], servedBy: _node);
    expect(node.asked.map((a) => a.id), [_id('ab')]);
  });

  test('an oversized issuer label is not stored', () async {
    final huge = 'x' * 20000;
    final big = PublicTokenCatalog(
      inspect: (id, _) async => _descriptor(id, name: huge),
    );
    await big.resolve([_id('ab')], servedBy: _node);
    expect(big.lookup(_id('ab')), isNull);
  });

  group('the old AMM table', () {
    test('real names migrate; placeholders do not', () async {
      final named = _id('ab');
      final placeholder = _id('cd');
      SharedPreferences.setMockInitialValues({
        PublicTokenCatalog.legacyAmmKey: jsonEncode({
          named: {'name': 'Real', 'decimals': 6},
          placeholder: {'name': '${placeholder.substring(0, 8)}…', 'decimals': 0},
          'short': {'name': 'Bad id', 'decimals': 0},
        }),
      });
      final migrated = PublicTokenCatalog(inspect: node.inspect);
      await migrated.ensureLoaded();

      expect(migrated.lookup(named)?.name, 'Real');
      expect(migrated.lookup(named)?.decimals, 6);
      expect(migrated.lookup(placeholder), isNull,
          reason: 'a placeholder is not a name and its zero is not a scale');
      expect(migrated.lookup('short'), isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PublicTokenCatalog.legacyAmmKey), isNull);
      final stored = jsonDecode(
        prefs.getString(PublicTokenCatalog.storageKey)!,
      ) as Map;
      expect(stored.keys, [named]);
    });

    test('a migrated name is shown, then upgraded after unknown tokens',
        () async {
      final named = _id('ab');
      SharedPreferences.setMockInitialValues({
        PublicTokenCatalog.legacyAmmKey: jsonEncode({
          named: {'name': 'Real', 'decimals': 6},
        }),
      });
      final migrated = PublicTokenCatalog(inspect: node.inspect);
      await migrated.resolve([named, _id('cd')], servedBy: _node);
      expect(node.asked.map((a) => a.id), [_id('cd'), named],
          reason: 'what has no name at all comes first');
      expect(migrated.lookup(named)?.metadataState, MetadataState.complete);
    });
  });

  test('a stored table round-trips through the shared descriptor encoding',
      () async {
    SharedPreferences.setMockInitialValues({
      PublicTokenCatalog.storageKey: jsonEncode({
        _id('ab'): TokenDescriptorStore.encode(
          CachedDescriptor(id: _id('ab'), name: 'Stored', decimals: 3),
        ),
      }),
    });
    final loaded = PublicTokenCatalog(inspect: node.inspect);
    await loaded.ensureLoaded();
    expect(loaded.lookup(_id('ab'))?.name, 'Stored');
    expect(loaded.lookup(_id('ab'))?.decimals, 3);
  });
}
