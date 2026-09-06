import 'dart:convert';

import 'package:argus_wallet/services/sigmafi_service.dart';
import 'package:flutter_test/flutter_test.dart';

const erg = 'ERG';
const sigusd = '03faf2cb329f2e90d6d23b58d91bbb6c046aa143261cc21f52fbe2824bfcbf04';

/// The Rust side as the FFI answers: contracts by asset, and a market
/// built from the boxes it is handed (one order or bond per box, by a
/// `kind` field the fake reads).
class FakeGateway implements SigmaFiGateway {
  FakeGateway({this.node, this.height});
  final String? node;
  int? height;
  String? lastBoxes;
  int? lastHeight;
  final calls = <String>[];
  String? wallet = 'w1';

  @override
  String? get nodeUrl => node;
  @override
  String get explorerBase => 'https://explorer/';
  @override
  String? get walletId => wallet;
  @override
  int? get chainHeight => height;
  @override
  String contracts() => jsonEncode([
        {'id': erg, 'name': 'ERG', 'decimals': 9, 'order_tree': 'oo-erg', 'bond_tree': 'bb-erg'},
        {'id': sigusd, 'name': 'SigUSD', 'decimals': 2, 'order_tree': 'oo-su', 'bond_tree': 'bb-su'},
      ]);

  @override
  String market(String boxesJson, int h) {
    lastBoxes = boxesJson;
    lastHeight = h;
    final orders = <Map<String, dynamic>>[];
    final bonds = <Map<String, dynamic>>[];
    for (final b in jsonDecode(boxesJson) as List) {
      final m = (b as Map).cast<String, dynamic>();
      if (m['kind'] == 'order') {
        orders.add({
          'box_id': m['boxId'],
          'loan_asset': m['asset'],
          'on_close': m['on_close'] ?? true,
          'borrower_address': m['borrower'],
          'principal': 1000,
          'repayment': 1050,
          'term_blocks': 720,
          'collateral_erg': 5000000000,
          'collateral_tokens': [
            ['aa', 3]
          ],
          'interest_percent': 5.0,
          'apr_percent': m['apr'] ?? 1825.0,
          'dev_fee': 5,
          'ui_fee': 4,
          'box': {'boxId': m['boxId']},
        });
      } else if (m['kind'] == 'bond') {
        bonds.add({
          'box_id': m['boxId'],
          'loan_asset': m['asset'],
          'order_box_id': 'o1',
          'borrower_address': m['borrower'],
          'lender_address': m['lender'],
          'repayment': 1050,
          'maturity_height': m['maturity'],
          'collateral_erg': 5000000000,
          'collateral_tokens': [],
          'blocks_remaining': (m['maturity'] as int) - h,
          'box': {'boxId': m['boxId']},
        });
      }
    }
    return jsonEncode({'orders': orders, 'bonds': bonds, 'skipped': ['box zz: register R5 is missing']});
  }

  @override
  Future<String> prepareOpen({
    required String loanAsset,
    required int principal,
    required int repayment,
    required int termBlocks,
    required int collateralErg,
    required String collateralTokensJson,
    required String userAddress,
    required List<String> spendAddresses,
    required String changeAddress,
  }) async {
    calls.add('open $loanAsset $principal $repayment $termBlocks $collateralErg $collateralTokensJson');
    return jsonEncode({'preparation_id': 7, 'miner_fee': 1100000});
  }

  @override
  Future<String> prepareSpend({
    required String action,
    required String boxJson,
    required String userAddress,
    required List<String> spendAddresses,
  }) async {
    calls.add('$action ${(jsonDecode(boxJson) as Map)['boxId']} $userAddress');
    return jsonEncode({'preparation_id': 8, 'action': action});
  }
}

Map<String, dynamic> order(String id, String asset, String borrower, {double? apr}) =>
    {'kind': 'order', 'boxId': id, 'asset': asset, 'borrower': borrower, if (apr != null) 'apr': apr};
Map<String, dynamic> bond(String id, String asset, String borrower, String lender, int maturity) =>
    {'kind': 'bond', 'boxId': id, 'asset': asset, 'borrower': borrower, 'lender': lender, 'maturity': maturity};

void main() {
  test('refresh reads every script from the node, marks what is ours, sorts', () async {
    final gw = FakeGateway(node: 'http://node', height: 1000);
    final posted = <String>[];
    final byTree = {
      'oo-erg': [order('o1', erg, 'mine', apr: 10), order('o2', erg, 'them', apr: 50)],
      'bb-erg': [bond('b1', erg, 'mine', 'them', 1100), bond('b2', erg, 'them', 'mine', 900)],
      'oo-su': [order('o3', sigusd, 'them', apr: 30)],
      'bb-su': <Map<String, dynamic>>[],
    };
    final svc = SigmaFiService(
      gateway: gw,
      get: (u) async => throw StateError('explorer not expected: $u'),
      post: (u, body) async {
        posted.add(u.toString());
        return jsonEncode(byTree[jsonDecode(body)]!);
      },
    );
    await svc.refresh({'mine'});
    expect(svc.lastError, isNull);
    expect(posted.length, 4);
    expect(posted.first, contains('/blockchain/box/unspent/byErgoTree?offset=0&limit=100'));
    expect(gw.lastHeight, 1000);
    expect(svc.orders.map((o) => o.boxId), ['o2', 'o3', 'o1']);
    expect(svc.myOrders.map((o) => o.boxId), ['o1']);
    expect(svc.openOrders.map((o) => o.boxId), ['o2', 'o3']);
    expect(svc.myBorrows.single.boxId, 'b1');
    expect(svc.myBorrows.single.repayable, isTrue);
    expect(svc.myLends.single.boxId, 'b2');
    expect(svc.myLends.single.liquidatable, isTrue);
    expect(svc.bonds.first.boxId, 'b2'); // matured first
    expect(svc.skipped, ['box zz: register R5 is missing']);
    expect(svc.positionLine(), '1 open request, 1 borrowed, 1 lent');
    expect(svc.orders.first.collateralTokens.single, (id: 'aa', amount: 3));
  });

  test('without a node the explorer is paged until the total', () async {
    final gw = FakeGateway(height: 5);
    final gets = <String>[];
    final svc = SigmaFiService(
      gateway: gw,
      get: (u) async {
        gets.add(u.toString());
        final tree = u.pathSegments.last;
        final offset = int.parse(u.queryParameters['offset']!);
        if (tree == 'oo-erg') {
          final items = [for (var i = 0; i < 100; i++) order('o$offset-$i', erg, 'x')];
          return jsonEncode({'items': offset == 0 ? items : items.take(5).toList(), 'total': 105});
        }
        return jsonEncode({'items': [], 'total': 0});
      },
      post: (u, b) async => throw StateError('no node'),
    );
    await svc.refresh({});
    expect(svc.lastError, isNull);
    expect(svc.orders.length, 105);
    expect(gets.where((g) => g.contains('/oo-erg?')).length, 2);
    expect(gets.where((g) => g.contains('/bb-su?')).length, 1);
  });

  test('a script that cannot be read is reported and the rest still shows', () async {
    final gw = FakeGateway(node: 'http://node', height: 1);
    final svc = SigmaFiService(
      gateway: gw,
      get: (u) async => throw StateError('down'),
      post: (u, body) async {
        if (jsonDecode(body) == 'bb-su') throw StateError('timeout');
        return jsonEncode([order('o1', erg, 'x')]);
      },
    );
    await svc.refresh({});
    expect(svc.orders.length, 3);
    expect(svc.lastError, contains('SigUSD bonds'));
  });

  test('a wallet switch during the read drops the answer', () async {
    final gw = FakeGateway(node: 'http://node', height: 1);
    final svc = SigmaFiService(
      gateway: gw,
      get: (u) async => throw StateError('down'),
      post: (u, body) async {
        gw.wallet = 'w2';
        return jsonEncode([order('o1', erg, 'x')]);
      },
    );
    await svc.refresh({});
    expect(svc.orders, isEmpty);
    expect(svc.lastRefreshedAt, isNull);
  });

  test('the height comes from the explorer when the network has none', () async {
    final gw = FakeGateway(node: 'http://node');
    final svc = SigmaFiService(
      gateway: gw,
      get: (u) async {
        expect(u.path, endsWith('/api/v1/networkState'));
        return jsonEncode({'height': 4242});
      },
      post: (u, body) async => '[]',
    );
    await svc.refresh({});
    expect(svc.lastError, isNull);
    expect(gw.lastHeight, 4242);
  });

  test('prepared transactions are bound to the wallet they were built for', () async {
    final gw = FakeGateway(node: 'http://node', height: 1);
    final svc = SigmaFiService(gateway: gw, get: (u) async => '', post: (u, b) async => '[]');
    final p = await svc.prepareOpen(
      loanAsset: erg,
      principal: 100,
      repayment: 105,
      termBlocks: 720,
      collateralErg: 200,
      collateralTokens: const [(id: 'aa', amount: 2)],
      userAddress: 'me',
      spendAddresses: const ['me'],
      changeAddress: 'me',
    );
    expect(gw.calls.single, 'open ERG 100 105 720 200 [{"token_id":"aa","amount":2}]');
    expect(svc.canCommit(p), isTrue);
    final s = await svc.prepareSpend(action: 'close', box: {'boxId': 'o9'}, userAddress: 'me', spendAddresses: const []);
    expect(gw.calls.last, 'close o9 me');
    gw.wallet = 'w2';
    expect(svc.canCommit(p), isFalse);
    expect(svc.canCommit(s), isFalse);
    svc.clearIfForeign();
  });
}
