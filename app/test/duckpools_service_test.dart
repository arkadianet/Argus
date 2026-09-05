import 'dart:convert';
import 'dart:io';

import 'package:argus_wallet/services/duckpools_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pool identities as the Rust side reports them, and a state answer built
/// the way the FFI does from the boxes it is handed.
class FakeGateway implements DuckpoolsGateway {
  FakeGateway({this.node});
  final String? node;
  String? lastBoxes;
  String? lastHoldings;
  String? lastInterest;
  int? height;

  /// Outcomes by proxy box id for `orderOutcome`.
  final outcomes = <String, Map<String, dynamic>>{};

  @override
  String? get nodeUrl => node;
  @override
  String get explorerBase => 'https://explorer/';
  /// Mutable, so a test can switch wallets under an in-flight order.
  String? wallet = 'w1';
  @override
  String? get walletId => wallet;
  @override
  bool get isUnlocked => true;
  @override
  int? get chainHeight => height;
  @override
  String quote(String b, String poolKey, String kind, int amount, int slippageBps, int refundHeight) => jsonEncode({
        'kind': kind,
        'pool': poolKey,
        'amount': amount,
        'service_fee': amount ~/ 160,
        'to_pool': amount - amount ~/ 160,
        'lend_tokens_expected': amount ~/ 2,
        'min_lend_tokens': amount ~/ 2 * 99 ~/ 100,
        'lend_tokens': amount,
        'entitled': amount * 2,
        'out': amount * 2 - 1,
        'min_out': amount * 2 - 2,
        'box_value': 3000000,
        'refund_height': refundHeight,
      });
  String? lastLoanBoxes;
  List<String>? lastLoanAddresses;
  String? lastPrepareLoanBoxes;

  @override
  String loans(String loanBoxesJson, List<String> walletAddresses, int height) {
    lastLoanBoxes = loanBoxesJson;
    lastLoanAddresses = walletAddresses;
    final root = (jsonDecode(loanBoxesJson) as Map).cast<String, dynamic>();
    final collateral = (root['collateral'] as List).cast<Map>();
    // As the Rust side does: only the wallet's collateral boxes count,
    // and a pool whose boxes are missing reports why.
    return jsonEncode({
      'positions': [
        for (final c in collateral)
          if (walletAddresses.contains(c['borrower']))
            {
              'pool': 'sigusd', 'ticker': 'SigUSD', 'decimals': 2, 'box_id': c['boxId'],
              'collateral_nano': c['value'], 'loan': 23899, 'owed': 23939, 'collateral_value': 62316,
              'threshold': 1400, 'penalty': 400, 'health_bps': 18594, 'liquidation_value': 33514,
              'liquidatable': false, 'forced_liquidation_height': 1920515,
            },
      ],
      'markets': [
        if ((root['params'] as List).isNotEmpty)
          {'pool': 'sigusd', 'ticker': 'SigUSD', 'decimals': 2, 'threshold': 1400, 'penalty': 400, 'erg_value': 25, 'loans': collateral.length}
        else
          {'pool': 'sigusd', 'ticker': 'SigUSD', 'decimals': 2, 'error': 'the SigUSD parameter box is missing'},
      ],
    });
  }

  @override
  String loanQuote({
    required String poolBoxesJson,
    required String loanBoxesJson,
    required String poolKey,
    required String kind,
    required int amount,
    required int collateralNano,
    required String collateralBoxId,
    required int height,
  }) =>
      jsonEncode(switch (kind) {
        'borrow' => {
            'kind': kind, 'pool': poolKey, 'loan': amount, 'collateral_nano': collateralNano,
            'collateral_value': collateralNano ~/ 40000000, 'max_loan': collateralNano ~/ 56000000,
            'threshold': 1400, 'penalty': 400, 'health_bps': 15000, 'box_value': collateralNano + 2000000,
          },
        'repay' => {
            'kind': kind, 'pool': poolKey, 'collateral_box_id': collateralBoxId, 'owed_now': 23939,
            'repayment': 23941, 'collateral_nano': 2500000000000, 'box_value': 3000000,
          },
        _ => {
            'kind': kind, 'pool': poolKey, 'collateral_box_id': collateralBoxId, 'repayment': amount,
            'final_borrow_tokens': 23899 - amount, 'owed_after': 23939 - amount, 'box_value': 3000000,
          },
      });

  @override
  Future<String> prepareOrder({
    required String poolBoxesJson,
    required String poolKey,
    required String kind,
    required int amount,
    required int slippageBps,
    required int refundAfterBlocks,
    required String userAddress,
    required List<String> spendAddresses,
    required String changeAddress,
    String? loanBoxesJson,
    int? collateralNano,
    String? collateralBoxId,
  }) async {
    lastPrepareLoanBoxes = loanBoxesJson;
    final loanSide = kind == 'borrow' || kind == 'repay' || kind == 'partial_repay';
    return jsonEncode({
      'preparation_id': 9,
      'quote': loanSide
          ? jsonDecode(loanQuote(
              poolBoxesJson: poolBoxesJson, loanBoxesJson: loanBoxesJson ?? '', poolKey: poolKey, kind: kind,
              amount: amount, collateralNano: collateralNano ?? 0, collateralBoxId: collateralBoxId ?? '', height: 1000))
          : jsonDecode(quote(poolBoxesJson, poolKey, kind, amount, slippageBps, 1000 + refundAfterBlocks)),
      'proxy_box_id': 'proxy-$kind',
      'refund_height': 1000 + refundAfterBlocks,
      'height': 1000,
      'miner_fee': 1100000,
      'app_fee_nano': 1100000,
    });
  }
  @override
  Future<String> prepareRefund(String proxyBoxJson, String userAddress) async =>
      jsonEncode({'preparation_id': 10, 'value_nano_erg': 2000000, 'miner_fee': 1000000});
  @override
  String orderOutcome(String kind, String proxyBoxId, String txJson) =>
      jsonEncode(outcomes[proxyBoxId] ?? {'outcome': 'unknown'});

  @override
  String pools() => jsonEncode([
        {
          'key': 'erg', 'ticker': 'ERG', 'decimals': 9,
          'pool_nft': '90290924d95d699f5852d54dd5c20d01a3c729b11e7ccb5444671f62bec3b4bc',
          'lend_token': 'fc888e0eed50a4042324793a7894134d83c7aaf5c99f4bf643e7e2b4e71e0095',
          'borrow_token': 'd90d4000ed4b826856b93fc3d1e2c10ecb8a08dc0172fe72f58c43d28e681b49',
          'currency_id': null, 'ergo_tree': 'aa', 'interest_param_nft': 'ip-erg',
        },
        {
          'key': 'sigusd', 'ticker': 'SigUSD', 'decimals': 2,
          'pool_nft': '6a5506ff2e12fe121686dfb5089b3576d0d921caba2eb68de99f7aa54c18d658',
          'lend_token': '99fd3c29dd4485bcb9cabd3574a66435a8c699bef8783ce71bc3edbb7b39e4cd',
          'borrow_token': '1d7857', 'currency_id': '03faf2', 'ergo_tree': 'bb', 'interest_param_nft': 'ip-sigusd',
          'param_nft': 'param-sigusd', 'child_nft': 'child-sigusd', 'parent_nft': 'parent-sigusd',
          'collateral_ergo_tree': 'cc', 'erg_dex_nft': 'dex-sigusd',
        },
      ]);

  @override
  String state(String poolBoxesJson, String holdingsJson, String interestBoxesJson) {
    lastBoxes = poolBoxesJson;
    lastHoldings = holdingsJson;
    lastInterest = interestBoxesJson;
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
        if (uri.path.contains('byTokenId')) return jsonEncode([]);
        throw StateError('explorer should not be needed');
      },
      post: (uri, body) async {
        requests.add('POST ${uri.path} $body');
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
    expect(requests.where((r) => r.startsWith('GET') && r.contains('api/v1/boxes/unspent/byErgoTree')), isEmpty);
    expect(gw.lastHoldings, contains('482880000'));
  });

  test('falls back to the explorer when the node has no index, and ignores the deployer bag', () async {
    final gw = FakeGateway(node: 'http://node');
    final svc = DuckpoolsService(
      gateway: gw,
      get: (uri) async => jsonEncode({'items': uri.path.contains('/byErgoTree/aa') ? [bag, ergBox] : []}),
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

  test('a pool that cannot be read keeps its last state and is reported, the rest refresh', () async {
    final gw = FakeGateway(node: 'http://node');
    var sigusdDown = false;
    final started = <String>[];
    final svc = DuckpoolsService(
      gateway: gw,
      get: (uri) async => throw StateError('explorer down'),
      post: (uri, body) async {
        started.add(body);
        if (body == '"bb"' && sigusdDown) {
          // Slow and failing: the other pool must not wait for this.
          await Future<void>.delayed(const Duration(milliseconds: 50));
          throw StateError('timeout');
        }
        return jsonEncode(body == '"aa"' ? [ergBox] : []);
      },
    );
    await svc.refresh(const {});
    expect(svc.lastError, isNull);
    expect(svc.states.map((s) => s.pool), ['erg']);

    sigusdDown = true;
    started.clear();
    await svc.refresh(const {});
    expect(started.length, 2, reason: 'both reads started');
    expect(svc.lastError, contains('SigUSD'));
    expect(svc.states.map((s) => s.pool), ['erg'], reason: 'the ERG pool still refreshed');

    // Had the SigUSD pool been read before, its last state would stay.
    // The fake only values the ERG pool, so prove it the other way round.
    sigusdDown = false;
    var ergDown = true;
    final svc2 = DuckpoolsService(
      gateway: gw,
      get: (uri) async => throw StateError('explorer down'),
      post: (uri, body) async {
        if (body == '"aa"' && ergDown) throw StateError('timeout');
        return jsonEncode(body == '"aa"' ? [ergBox] : []);
      },
    );
    ergDown = false;
    await svc2.refresh(const {});
    expect(svc2.states.single.pool, 'erg');
    ergDown = true;
    await svc2.refresh(const {});
    expect(svc2.states.single.pool, 'erg', reason: 'kept from the last read');
    expect(svc2.lastError, contains('ERG'));
  });

  test('typed amounts are parsed exactly and refused beyond the asset\'s decimals', () {
    expect(parseDuckAmount('1.5', 9), 1500000000);
    expect(parseDuckAmount('1,000.25', 2), 100025);
    expect(parseDuckAmount('.5', 2), 50);
    expect(parseDuckAmount('7', 0), 7);
    expect(parseDuckAmount('1.0000000005', 9), isNull, reason: 'ten decimals on a nine-decimal asset');
    expect(parseDuckAmount('1,2', 2), isNull, reason: 'a comma is only a thousands separator');
    expect(parseDuckAmount('1.2,3', 2), isNull);
    expect(parseDuckAmount('1,000,000', 2), 100000000);
    expect(parseDuckAmount('1,0000', 2), isNull);
    expect(parseDuckAmount('0.001', 2), isNull);
    expect(parseDuckAmount('0', 2), isNull);
    expect(parseDuckAmount('abc', 2), isNull);
    expect(parseDuckAmount('', 2), isNull);
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

  test('orders are recorded, tracked to refundable, and read as filled or refunded', () async {
    SharedPreferences.setMockInitialValues({});
    final gw = FakeGateway(node: 'http://node')..height = 1000;
    final boxes = <String, Map<String, dynamic>>{};
    final txs = <String, Map<String, dynamic>>{};
    final svc = DuckpoolsService(
      gateway: gw,
      get: (uri) async {
        final p = uri.path;
        final b = RegExp(r'/blockchain/box/byId/(.+)$').firstMatch(p)?.group(1);
        if (b != null) return jsonEncode(boxes[b] ?? (throw StateError('404')));
        final t = RegExp(r'/blockchain/transaction/byId/(.+)$').firstMatch(p)?.group(1);
        if (t != null) return jsonEncode(txs[t] ?? (throw StateError('404')));
        if (p.contains('byTokenId')) return jsonEncode([]);
        throw StateError('unexpected $uri');
      },
      post: (uri, body) async => jsonEncode([]),
    );
    await svc.load();
    svc.lastPoolBoxesJson = '[]';

    final prepared = await svc.prepareOrder(
      poolKey: 'erg',
      kind: 'lend',
      amount: 1000000000,
      userAddress: '9me',
      spendAddresses: const ['9me'],
      changeAddress: '9me',
      refundAfterBlocks: 100,
    );
    expect(prepared['wallet_id'], 'w1');
    expect(svc.canCommit(prepared), isTrue);
    expect(svc.activeWalletId, 'w1');
    // The wallet switches while the order is in flight: it must not be
    // sent or recorded here.
    gw.wallet = 'w2';
    expect(svc.activeWalletId, 'w2');
    expect(svc.canCommit(prepared), isFalse, reason: 'prepared under w1, w2 active');
    await expectLater(svc.commitOrder(prepared, 'tx-x'), throwsStateError);
    gw.wallet = 'w1';
    expect(svc.canCommit(prepared), isTrue);
    final order = await svc.commitOrder(prepared, 'tx-order');
    expect(order.status, 'pending');
    expect(order.refundHeight, 1100);
    expect(svc.openOrders.length, 1);

    // Unspent, before the refund height: still pending.
    boxes['proxy-lend'] = {'boxId': 'proxy-lend', 'spentTransactionId': null};
    await svc.tickOrders();
    expect(order.status, 'pending');

    // Past the refund height and still unspent: refundable.
    gw.height = 1100;
    await svc.tickOrders();
    expect(order.status, 'refundable');

    // A bot filled it: the spending transaction says so.
    boxes['proxy-lend'] = {'boxId': 'proxy-lend', 'spentTransactionId': 'fill'};
    txs['fill'] = {'id': 'fill', 'outputs': []};
    gw.outcomes['proxy-lend'] = {
      'outcome': 'filled',
      'value': 1000000,
      'assets': [
        {'token_id': 'fc888e0eed50a4042324793a7894134d83c7aaf5c99f4bf643e7e2b4e71e0095', 'amount': '480000000'},
      ],
    };
    await svc.tickOrders();
    expect(order.status, 'filled');
    expect(order.received, 480000000);
    expect(order.outcomeTxId, 'fill');
    expect(svc.openOrders, isEmpty);

    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString('argus_duck_orders_v1_w1')!) as List;
    expect((saved.single as Map)['status'], 'filled');

    // A withdraw order that got refunded by someone else.
    final w = await svc.commitOrder(
      await svc.prepareOrder(poolKey: 'erg', kind: 'withdraw', amount: 5, userAddress: '9me', spendAddresses: const [], changeAddress: '9me'),
      'tx-w',
    );
    boxes['proxy-withdraw'] = {'boxId': 'proxy-withdraw', 'spentTransactionId': 'rf'};
    txs['rf'] = {'id': 'rf', 'outputs': []};
    gw.outcomes['proxy-withdraw'] = {'outcome': 'refunded', 'value': 2000000, 'assets': []};
    await svc.tickOrders();
    expect(w.status, 'refunded');
    await svc.removeOrder(w);
    expect(svc.orders.length, 1);
  });

  test('loans are read from the collateral, interest, price and parameter boxes', () async {
    SharedPreferences.setMockInitialValues({});
    final gw = FakeGateway(node: 'http://node')..height = 1866418;
    final posted = <String>[];
    final myLoan = {'boxId': 'loan-1', 'value': 2500000000000, 'ergoTree': 'cc', 'borrower': '9me'};
    final theirs = {'boxId': 'loan-2', 'value': 1, 'ergoTree': 'cc', 'borrower': '9them'};
    var withParams = true;
    final svc = DuckpoolsService(
      gateway: gw,
      get: (uri) async {
        final p = uri.path;
        if (p.contains('byTokenId/param-sigusd')) return jsonEncode(withParams ? [{'boxId': 'param'}] : []);
        if (p.contains('byTokenId/')) return jsonEncode([{'boxId': p.split('/').last}]);
        throw StateError('unexpected $uri');
      },
      post: (uri, body) async {
        posted.add(body);
        return jsonEncode(body == '"cc"' ? [myLoan, theirs] : []);
      },
    );
    await svc.load();
    await svc.refreshLoans(const ['9me', '9me-2']);
    expect(svc.loansError, isNull);
    expect(posted, contains('"cc"'), reason: 'collateral boxes come from the node by script');
    expect(gw.lastLoanAddresses, ['9me', '9me-2']);
    final sent = (jsonDecode(gw.lastLoanBoxes!) as Map).cast<String, dynamic>();
    expect((sent['collateral'] as List).length, 2, reason: 'Rust picks the wallet\'s among all loans');
    expect((sent['children'] as List).single['boxId'], 'child-sigusd');
    expect(svc.loans.single.boxId, 'loan-1');
    expect(svc.loans.single.owed, 23939);
    expect(svc.loans.single.ratioPercent, closeTo(260.3, 0.1));
    expect(svc.marketFor('sigusd')!.ready, isTrue);
    expect(svc.loanLine((a, d) => (a / 100).toStringAsFixed(2)), 'You owe 239.39 SigUSD');

    // A borrow order records the collateral; a repayment names the loan.
    svc.lastPoolBoxesJson = '[]';
    final borrow = await svc.commitOrder(
      await svc.prepareOrder(
        poolKey: 'sigusd', kind: 'borrow', amount: 1000, collateralNano: 100000000000,
        userAddress: '9me', spendAddresses: const [], changeAddress: '9me',
      ),
      'tx-b',
    );
    expect(gw.lastPrepareLoanBoxes, gw.lastLoanBoxes, reason: 'the loan snapshot rides along');
    expect(borrow.amount, 1000);
    expect(borrow.collateralNano, 100000000000);
    expect(borrow.isLoanSide, isTrue);
    final repay = await svc.commitOrder(
      await svc.prepareOrder(
        poolKey: 'sigusd', kind: 'repay', amount: 0, collateralBoxId: 'loan-1',
        userAddress: '9me', spendAddresses: const [], changeAddress: '9me',
      ),
      'tx-r',
    );
    expect(repay.amount, 23941);
    expect(repay.collateralBoxId, 'loan-1');
    expect(repay.expected, 2500000000000);
    final quote = svc.loanQuote(poolKey: 'sigusd', kind: 'partial_repay', amount: 5000, collateralBoxId: 'loan-1');
    expect(quote['owed_after'], 18939);

    // A pool whose parameter box cannot be read says so and offers no borrowing.
    withParams = false;
    await svc.refreshLoans(const ['9me']);
    expect(svc.loansError, isNull);
    expect(svc.marketFor('sigusd')!.ready, isFalse);
    expect(svc.marketFor('sigusd')!.error, contains('parameter box'));
    expect(svc.loans.single.boxId, 'loan-1', reason: 'positions still read from the collateral boxes');
  });

  test('a refund is prepared only for an unspent order box', () async {
    SharedPreferences.setMockInitialValues({});
    final gw = FakeGateway(node: 'http://node');
    final spent = <String, dynamic>{'boxId': 'p1', 'spentTransactionId': 'x'};
    final svc = DuckpoolsService(
      gateway: gw,
      get: (uri) async => uri.path.endsWith('/p1') ? jsonEncode(spent) : (throw StateError('404')),
      post: (_, __) async => '[]',
    );
    await svc.load();
    final o = DuckOrder(
      kind: 'lend', pool: 'erg', ticker: 'ERG', decimals: 9, proxyBoxId: 'p1', txId: 't',
      amount: 1, expected: 1, minOut: 1, refundHeight: 1, createdAt: DateTime.now(), status: 'refundable',
    );
    await expectLater(svc.prepareRefund(o, userAddress: '9me'), throwsStateError);
    spent['spentTransactionId'] = null;
    final prepared = await svc.prepareRefund(o, userAddress: '9me');
    expect(prepared['preparation_id'], 10);
    await svc.markRefundSent(o, 'rtx');
    expect(o.status, 'refund_sent');
  });
}
