import 'package:argus_wallet/services/amm_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('pool set round-trips through the cache with its age', () async {
    final set = AmmPoolSet(
      truncated: false,
      pools: [
        {'pool_id': 'p1', 'box_id': 'b1'},
      ],
      tokens: {'tok': const AmmTokenMeta(name: 'Tok', decimals: 2)},
    );
    await AmmPoolCache.save(set, nodeUrl: 'https://n');

    final cached = await AmmPoolCache.load();
    expect(cached, isNotNull);
    expect(cached!.set.pools.single['pool_id'], 'p1');
    expect(cached.set.tokens['tok']?.decimals, 2);
    expect(cached.nodeUrl, 'https://n');
    expect(cached.age, lessThan(const Duration(seconds: 5)));
  });

  test('known token metadata is remembered across launches', () async {
    await AmmPoolCache.rememberTokens({'a': const AmmTokenMeta(name: 'A', decimals: 1)});
    await AmmPoolCache.rememberTokens({'b': const AmmTokenMeta(name: 'B', decimals: 0)});
    final json = await AmmPoolCache.knownTokensJson();
    expect(json, contains('"a"'));
    expect(json, contains('"b"'));
  });

  test('corrupt cache is ignored', () async {
    SharedPreferences.setMockInitialValues({'argus_amm_pools_v1': 'nope'});
    expect(await AmmPoolCache.load(), isNull);
  });
}
