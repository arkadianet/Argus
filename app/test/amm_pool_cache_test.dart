import 'dart:convert';

import 'package:argus_wallet/services/amm_service.dart';
import 'package:argus_wallet/services/token_catalog.dart';
import 'package:argus_wallet/services/token_descriptor_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _tok = 'abababababababababababababababababababababababababababababababab';

Map<String, dynamic> _pool(String id, String token) => {
  'pool_id': id,
  'box_id': 'b$id',
  'pool_type': 'N2T',
  'erg_reserves': 1000,
  'token_y': {'token_id': token, 'amount': 5},
};

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    publicTokenCatalog.debugReset();
  });

  test('pool set round-trips through the cache with its age', () async {
    final set = AmmPoolSet(
      truncated: false,
      pools: [_pool('p1', _tok)],
      tokens: const {},
    );
    await AmmPoolCache.save(set, nodeUrl: 'https://n');

    final cached = await AmmPoolCache.load();
    expect(cached, isNotNull);
    expect(cached!.set.pools.single['pool_id'], 'p1');
    expect(cached.nodeUrl, 'https://n');
    expect(cached.age, lessThan(const Duration(seconds: 5)));
  });

  test('names come from the catalog, not from the saved file', () async {
    // What earlier builds saved: the Rust placeholder as if it were a name.
    SharedPreferences.setMockInitialValues({
      'argus_amm_pools_v1': jsonEncode({
        'saved_at': DateTime.now().millisecondsSinceEpoch,
        'node_url': 'https://n',
        'set': {
          'truncated': false,
          'pools': [_pool('p1', _tok)],
          'tokens': {
            _tok: {'name': 'abababab…', 'decimals': 0},
          },
        },
      }),
    });
    final before = await AmmPoolCache.load();
    expect(before!.set.tokens, isEmpty,
        reason: 'a placeholder is not a name, and its zero is not a scale');

    publicTokenCatalog.debugSeed([
      const CachedDescriptor(id: _tok, name: 'Real', decimals: 6),
    ]);
    final after = await AmmPoolCache.load();
    expect(after!.set.tokens[_tok]?.name, 'Real',
        reason: 'a list saved before a token was resolved still names it');
    expect(after.set.tokens[_tok]?.decimals, 6);
  });

  test('a saved pool list carries no token names of its own', () async {
    publicTokenCatalog.debugSeed([
      const CachedDescriptor(id: _tok, name: 'Real', decimals: 6),
    ]);
    await AmmPoolCache.save(
      AmmPoolSet(
        truncated: false,
        pools: [_pool('p1', _tok)],
        tokens: const {_tok: AmmTokenMeta(name: 'Real', decimals: 6)},
      ),
    );
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonDecode(prefs.getString('argus_amm_pools_v1')!) as Map;
    expect((raw['set'] as Map)['tokens'], isEmpty);
  });

  test('corrupt cache is ignored', () async {
    SharedPreferences.setMockInitialValues({'argus_amm_pools_v1': 'nope'});
    expect(await AmmPoolCache.load(), isNull);
  });
}
