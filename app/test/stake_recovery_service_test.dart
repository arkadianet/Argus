import 'dart:async';
import 'dart:convert';

import 'package:argus_wallet/services/stake_recovery_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

final keyA = 'aa' * 32;
final keyB = 'bb' * 32;
Map<String, dynamic> box(String id, String key) => {'boxId': id, 'key': key};

class Gateway implements StakeRecoveryGateway {
  @override
  String? walletId = 'alice';
  @override
  String network = 'mainnet';
  @override
  String? nodeUrl = 'https://node.test';
  @override
  String explorerBase = 'https://explorer.test';
  @override
  String contracts() => jsonEncode([
    for (final id in ['ergopad', 'paideia', 'egio'])
      {
        'id': id,
        'name': id == 'ergopad' ? 'Ergopad' : 'Paideia',
        'active': id != 'egio',
        'stake_tree': '$id-full-tree',
        'stake_address': '$id-address',
        'state_nft': '$id-nft',
        'reward_decimals': 2,
      },
  ]);
  @override
  String state(String pool, String box) => '{"checkpoint":1}';
  @override
  String positions(String pool, String boxes, String keys, String stateBox) {
    final candidates = (jsonDecode(keys) as List).toSet();
    final items = jsonDecode(boxes) as List;
    return jsonEncode({
      'positions': [
        for (final b in items)
          if (candidates.contains(b['key']) && b['invalid'] != true)
            {
              'key_id': b['key'],
              'box_id': b['boxId'],
              'reward_amount': '12345',
              'eligible': stateBox.isNotEmpty ? true : null,
            },
      ],
      'rejected': [
        for (final b in items)
          if (b['invalid'] == true) 'invalid box',
      ],
      'ambiguous_keys': [],
    });
  }
}

http.Response ok(Object body) => http.Response(jsonEncode(body), 200);
http.Response? common(http.Request r, {int lag = 0}) {
  if (r.url.path == '/info')
    return ok({
      'network': 'mainnet',
      'fullHeight': 100,
      'headersHeight': 100,
      'maxPeerHeight': 100,
    });
  if (r.url.path == '/blockchain/indexedHeight')
    return ok({'indexedHeight': 100 - lag, 'fullHeight': 100});
  if (r.url.path.contains('byTokenId')) {
    expect(r.url.queryParameters, {'offset': '0', 'limit': '2'});
    return ok([
      {'boxId': 'state'},
    ]);
  }
  return null;
}

String cache(String pool, String key, {String network = 'mainnet'}) =>
    'stake_recovery.v1.$network.$pool.$key';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'one full-tree POST scan per pool for every unresolved key; EGIO makes zero requests',
    () async {
      final requests = <http.Request>[];
      final svc = StakeRecoveryService(
        gateway: Gateway(),
        client: MockClient((r) async {
          requests.add(r);
          final shared = common(r);
          if (shared != null) return shared;
          expect(r.method, 'POST');
          expect(r.headers['Content-Type'], 'application/json');
          expect(r.url.path, '/blockchain/box/unspent/byErgoTree');
          expect(jsonDecode(r.body), endsWith('-full-tree'));
          return ok([box('one', keyA), box('two', keyB)]);
        }),
      );
      await svc.refresh({keyA, keyB});
      expect(
        svc.results.map((r) => r.status),
        everyElement(StakeScanStatus.complete),
      );
      expect(svc.results.map((r) => r.positions.length), [2, 2]);
      expect(requests.where((r) => r.method == 'POST').length, 2);
      expect(requests.any((r) => '${r.url}${r.body}'.contains('egio')), false);
      svc.dispose();
    },
  );

  for (final lag in [1, 100]) {
    test('index lag $lag falls back without querying the node index', () async {
      final svc = StakeRecoveryService(
        gateway: Gateway(),
        client: MockClient((r) async {
          final shared = common(r, lag: lag);
          if (shared != null) return shared;
          expect(r.url.host, 'explorer.test');
          expect(r.url.path, contains('/byAddress/'));
          return ok({'items': [], 'total': 0});
        }),
      );
      await svc.refresh({keyA});
      expect(
        svc.results.map((r) => r.status),
        everyElement(StakeScanStatus.complete),
      );
      svc.dispose();
    });
  }

  test(
    'absent index and explorer failure preserve Paideia results with exact wording',
    () async {
      final svc = StakeRecoveryService(
        gateway: Gateway(),
        client: MockClient((r) async {
          if (r.url.path == '/blockchain/indexedHeight')
            return http.Response('', 404);
          final shared = common(r);
          if (shared != null) return shared;
          if (r.url.path.contains('ergopad-address'))
            return http.Response('', 503);
          return ok({
            'items': [box('paideia-box', keyA)],
            'total': 1,
          });
        }),
      );
      await svc.refresh({keyA});
      expect(svc.results.first.status, StakeScanStatus.unavailable);
      expect(
        svc.results.first.message,
        StakeRecoveryService.ergopadExplorerFailure,
      );
      expect(svc.results.last.status, StakeScanStatus.complete);
      expect(svc.results.last.positions.single.keyId, keyA);
      svc.dispose();
    },
  );

  test('page cap is incomplete even when no matching key was found', () async {
    final gw = Gateway()..nodeUrl = null;
    final svc = StakeRecoveryService(
      gateway: gw,
      pageSize: 1,
      maxPages: 2,
      client: MockClient((r) async {
        final shared = common(r);
        if (shared != null) return shared;
        return ok({
          'items': [box('box-${r.url.queryParameters['offset']}', keyB)],
          'total': 3,
        });
      }),
    );
    await svc.refresh({keyA});
    expect(
      svc.results.map((r) => r.status),
      everyElement(StakeScanStatus.incomplete),
    );
    expect(svc.results.map((r) => r.scanned), [2, 2]);
    expect(svc.results.every((r) => r.positions.isEmpty), true);
    svc.dispose();
  });

  test(
    'interrupted paging retains positions without claiming absence',
    () async {
      final gw = Gateway()..nodeUrl = null;
      final svc = StakeRecoveryService(
        gateway: gw,
        pageSize: 1,
        client: MockClient((r) async {
          final shared = common(r);
          if (shared != null) return shared;
          if (r.url.queryParameters['offset'] == '0')
            return ok({
              'items': [box('position', keyA)],
              'total': 2,
            });
          throw TimeoutException('offline');
        }),
      );
      await svc.refresh({keyA, keyB});
      expect(
        svc.results.map((r) => r.status),
        everyElement(StakeScanStatus.incomplete),
      );
      expect(svc.results.map((r) => r.positions.length), [1, 1]);
      svc.dispose();
    },
  );

  test(
    'cache survives restart; one unspent lookup per cached key and no paging',
    () async {
      SharedPreferences.setMockInitialValues({
        cache('ergopad', keyA): 'cached-e',
        cache('paideia', keyA): 'cached-p',
      });
      var lookups = 0;
      final svc = StakeRecoveryService(
        gateway: Gateway(),
        client: MockClient((r) async {
          final shared = common(r);
          if (shared != null) return shared;
          expect(r.url.path, startsWith('/utxo/byId/'));
          lookups++;
          return ok(box(r.url.pathSegments.last, keyA));
        }),
      );
      await svc.refresh({keyA});
      expect(lookups, 2);
      expect(
        svc.results.map((r) => r.status),
        everyElement(StakeScanStatus.complete),
      );
      svc.dispose();
    },
  );

  for (final failure in ['spent', 'wrong-key', 'invalid', '503', 'timeout']) {
    test(
      'cached $failure distinguishes rediscovery from uncertainty',
      () async {
        SharedPreferences.setMockInitialValues({
          cache('ergopad', keyA): 'cached',
        });
        var scans = 0;
        var lookups = 0;
        final svc = StakeRecoveryService(
          gateway: Gateway(),
          client: MockClient((r) async {
            final shared = common(r);
            if (shared != null) return shared;
            if (r.url.path.contains('/utxo/')) {
              lookups++;
              return switch (failure) {
                'spent' => http.Response('', 404),
                '503' => http.Response('', 503),
                'timeout' => throw TimeoutException('timeout'),
                'invalid' => ok({...box('cached', keyA), 'invalid': true}),
                _ => ok(box('cached', keyB)),
              };
            }
            if (r.body.contains('ergopad')) scans++;
            return ok([box('new', keyA)]);
          }),
        );
        await svc.refresh({keyA});
        expect(lookups, 1);
        final uncertain = failure == '503' || failure == 'timeout';
        expect(scans, uncertain ? 0 : 1);
        expect(
          svc.results.first.status,
          uncertain ? StakeScanStatus.unavailable : StakeScanStatus.complete,
        );
        expect(
          (await SharedPreferences.getInstance()).getString(
            cache('ergopad', keyA),
          ),
          uncertain ? 'cached' : 'new',
        );
        svc.dispose();
      },
    );
  }

  test('ambiguous keys across pages are excluded and never cached', () async {
    final gw = Gateway()..nodeUrl = null;
    final svc = StakeRecoveryService(
      gateway: gw,
      pageSize: 1,
      client: MockClient((r) async {
        final shared = common(r);
        if (shared != null) return shared;
        final offset = int.parse(r.url.queryParameters['offset']!);
        return ok({
          'items': offset < 2 ? [box('box-$offset', keyA)] : [],
          'total': 2,
        });
      }),
    );
    await svc.refresh({keyA});
    expect(
      svc.results.map((r) => r.status),
      everyElement(StakeScanStatus.incomplete),
    );
    expect(svc.results.every((r) => r.positions.isEmpty), true);
    expect(
      (await SharedPreferences.getInstance()).getString(cache('ergopad', keyA)),
      isNull,
    );
    svc.dispose();
  });

  test(
    'state failure does not hide positions and marks eligibility unknown',
    () async {
      final svc = StakeRecoveryService(
        gateway: Gateway(),
        client: MockClient((r) async {
          if (r.url.path.contains('byTokenId')) return http.Response('', 503);
          return common(r) ?? ok([box('one', keyA)]);
        }),
      );
      await svc.refresh({keyA});
      expect(
        svc.results.every(
          (r) => r.stateError != null && r.positions.single.eligible == null,
        ),
        true,
      );
      svc.dispose();
    },
  );

  test('wallet switch hides old results and discards late answers', () async {
    final gate = Completer<void>();
    final gw = Gateway();
    final svc = StakeRecoveryService(
      gateway: gw,
      client: MockClient((r) async {
        final shared = common(r);
        if (shared != null) return shared;
        await gate.future;
        return ok([box('old-wallet', keyA)]);
      }),
    );
    final pending = svc.refresh({keyA});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    gw.walletId = 'bob';
    expect(svc.results, isEmpty);
    gate.complete();
    await pending;
    expect(svc.results, isEmpty);
    await svc.refresh({keyB});
    expect(svc.results.every((r) => r.positions.isEmpty), true);
    expect(
      (await SharedPreferences.getInstance()).getString(cache('ergopad', keyA)),
      isNull,
    );
    gw.network = 'testnet';
    expect(svc.results, isEmpty);
    svc.dispose();
  });
  test(
    'partial wallet balances cannot establish absence even with no candidates',
    () async {
      final service = StakeRecoveryService(
        gateway: Gateway(),
        client: MockClient((r) async => common(r) ?? ok([])),
      );
      await service.refresh({}, walletTokensComplete: false);
      expect(
        service.results.map((r) => r.status),
        everyElement(StakeScanStatus.incomplete),
      );
      expect(
        service.results.every(
          (r) => r.message!.contains('Wallet token balances'),
        ),
        true,
      );
      service.dispose();
    },
  );

  test(
    'interrupted node scan remains incomplete after fallback and retains findings',
    () async {
      final service = StakeRecoveryService(
        gateway: Gateway(),
        pageSize: 1,
        client: MockClient((r) async {
          final shared = common(r);
          if (shared != null) return shared;
          if (r.url.host == 'explorer.test')
            return ok({'items': [], 'total': 0});
          if (r.url.queryParameters['offset'] == '0')
            return ok([box('first', keyA)]);
          throw TimeoutException('interrupted');
        }),
      );
      await service.refresh({keyA, keyB});
      expect(
        service.results.map((r) => r.status),
        everyElement(StakeScanStatus.incomplete),
      );
      expect(service.results.map((r) => r.positions.length), [1, 1]);
      service.dispose();
    },
  );

  for (final mode in ['repeated', 'truncated', 'malformed', 'invalid']) {
    test('$mode pages never become authoritative absence', () async {
      final gateway = Gateway()..nodeUrl = null;
      final service = StakeRecoveryService(
        gateway: gateway,
        pageSize: 1,
        maxPages: 3,
        client: MockClient((r) async {
          final shared = common(r);
          if (shared != null) return shared;
          return switch (mode) {
            'repeated' => ok({
              'items': [box('repeated', keyB)],
              'total': 3,
            }),
            'truncated' => ok({'items': [], 'total': 3}),
            'malformed' => ok({'error': 'no index'}),
            _ => ok({
              'items': [
                {...box('bad', keyA), 'invalid': true},
              ],
              'total': 3,
            }),
          };
        }),
      );
      await service.refresh({keyA});
      expect(
        service.results.every((r) => r.status != StakeScanStatus.complete),
        true,
      );
      service.dispose();
    });
  }
}
