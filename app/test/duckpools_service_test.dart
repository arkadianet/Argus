import 'dart:convert';
import 'dart:io';

import 'package:argus_wallet/services/duckpools_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pool identities as the Rust side reports them, and a state answer built
/// the way the FFI does from the boxes it is handed.
class FakeGateway implements DuckpoolsGateway {
  FakeGateway({this.node});
  final String? node;
  String? lastBoxes;
  String? lastHoldings;

  @override
  String? get nodeUrl => node;
  @override
  String get explorerBase => 'https://explorer/';

  @override
  String pools() => jsonEncode([
        {
          'key': 'erg', 'ticker': 'ERG', 'decimals': 9,
          'pool_nft': '90290924d95d699f5852d54dd5c20d01a3c729b11e7ccb5444671f62bec3b4bc',
          'lend_token': 'fc888e0eed50a4042324793a7894134d83c7aaf5c99f4bf643e7e2b4e71e0095',
          'borrow_token': 'd90d4000ed4b826856b93fc3d1e2c10ecb8a08dc0172fe72f58c43d28e681b49',
          'currency_id': null, 'ergo_tree': 'aa',
        },
        {
          'key': 'sigusd', 'ticker': 'SigUSD', 'decimals': 2,
          'pool_nft': '6a5506ff2e12fe121686dfb5089b3576d0d921caba2eb68de99f7aa54c18d658',
          'lend_token': '99fd3c29dd4485bcb9cabd3574a66435a8c699bef8783ce71bc3edbb7b39e4cd',
          'borrow_token': '1d7857', 'currency_id': '03faf2', 'ergo_tree': 'bb',
        },
      ]);

  @override
  String state(String poolBoxesJson, String holdingsJson) {
    lastBoxes = poolBoxesJson;
    lastHoldings = holdingsJson;
    final boxes = jsonDecode(poolBoxesJson) as List;
    final holdings = (jsonDecode(holdingsJson) as Map).cast<String, dynamic>();
    // Only the ERG pool is valued here; enough to prove the plumbing.
    return jsonEncode([
      for (final b in boxes.cast<Map>())
        // As the Rust side does: the pool box carries the NFT exactly once.
        if ((b['assets'] as List).any((a) => a['tokenId'] == '90290924d95d699f5852d54dd5c20d01a3c729b11e7ccb5444671f62bec3b4bc' && a['amount'] == 1))
          {
            'pool': 'erg', 'ticker': 'ERG', 'decimals': 9,
            'pool_nft': '90290924d95d699f5852d54dd5c20d01a3c729b11e7ccb5444671f62bec3b4bc',
            'lend_token': 'fc888e0eed50a4042324793a7894134d83c7aaf5c99f4bf643e7e2b4e71e0095',
            'box_id': b['boxId'], 'creation_height': 1,
            'pooled': b['value'], 'borrowed': 0, 'lend_circulating': 7270560727953,
            'utilisation_bps': 0, 'lend_token_price': 2.0707,
            'wallet_lend_tokens': holdings['fc888e0eed50a4042324793a7894134d83c7aaf5c99f4bf643e7e2b4e71e0095'] ?? 0,
            'wallet_value': ((holdings['fc888e0eed50a4042324793a7894134d83c7aaf5c99f4bf643e7e2b4e71e0095'] ?? 0) * 2.0707).round(),
          },
    ]);
  }
}

void main() {
  final ergBox = jsonDecode(File('test/fixtures/duckpools_pool_erg.json').readAsStringSync()) as Map;
  final bag = {
    'boxId': 'bag', 'value': 519000, 'ergoTree': 'aa',
    'assets': [
      {'tokenId': '90290924d95d699f5852d54dd5c20d01a3c729b11e7ccb5444671f62bec3b4bc', 'amount': 3},
    ],
  };

  test('reads the pool box by script from the node, picks the box with the NFT, values holdings', () async {
    final requests = <String>[];
    final gw = FakeGateway(node: 'http://node');
    final svc = DuckpoolsService(
      gateway: gw,
      get: (uri) async {
        requests.add('GET $uri');
        throw StateError('explorer should not be needed');
      },
      post: (uri, body) async {
        requests.add('POST ${uri.path} $body');
        // A look-alike bag with the NFT sits first under the same script.
        if (body == '"aa"') return jsonEncode([ergBox]);
        return jsonEncode([]);
      },
    );
    await svc.refresh({'fc888e0eed50a4042324793a7894134d83c7aaf5c99f4bf643e7e2b4e71e0095': 482880000});
    expect(svc.lastError, isNull);
    expect(svc.states.length, 1);
    final s = svc.states.single;
    expect(s.pooled, 15055088456407);
    expect(s.hasPosition, isTrue);
    expect(s.walletValue, closeTo(1000000000, 2000000), reason: 'about 1 ERG');
    expect(svc.positionLine((a, d) => (a / 1000000000).toStringAsFixed(3)), 'You lend 1.000 ERG');
    expect(requests.where((r) => r.startsWith('GET')), isEmpty);
    expect(gw.lastHoldings, contains('482880000'));
  });

  test('falls back to the explorer when the node has no index, and ignores the deployer bag', () async {
    final gw = FakeGateway(node: 'http://node');
    final svc = DuckpoolsService(
      gateway: gw,
      get: (uri) async => jsonEncode({'items': uri.path.contains('/aa') ? [bag, ergBox] : []}),
      post: (uri, body) async => throw StateError('404'),
    );
    await svc.refresh(const {});
    expect(svc.lastError, isNull);
    final sent = jsonDecode(gw.lastBoxes!) as List;
    expect(sent.length, 2, reason: 'everything under the script goes to Rust, which picks');
    expect(svc.states.single.boxId, ergBox['boxId'], reason: 'the bag with 3 NFT units is not the pool');
    expect(svc.positions, isEmpty);
    expect(svc.positionLine((a, d) => '$a'), isNull);
  });

  test('an unreachable chain leaves the last state and reports the error', () async {
    final svc = DuckpoolsService(
      gateway: FakeGateway(),
      get: (_) async => throw StateError('offline'),
      post: (_, __) async => throw StateError('offline'),
    );
    await svc.refresh(const {});
    expect(svc.lastError, contains('offline'));
    expect(svc.states, isEmpty);
  });
}
