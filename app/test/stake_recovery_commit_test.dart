import 'dart:convert';

import 'package:argus_wallet/services/stake_recovery_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'stake_recovery_service_test.dart' as discovery;

class Gateway extends discovery.Gateway {
  @override
  String state(String pool, String box) =>
      jsonEncode({'checkpoint': 1, 'box_id': 'state'});
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final scenario in [
    'success',
    'moved before prepare',
    'moved after confirm',
    'wallet during prepare',
    'wallet before commit',
    'network before commit',
    'http failure',
  ]) {
    test('Direct commit: $scenario', () async {
      final gw = Gateway();
      var moved = false;
      var unavailable = false;
      var preparedCalls = 0;
      final svc = StakeRecoveryService(
        gateway: gw,
        client: MockClient((r) async {
          final shared = discovery.common(r);
          if (shared != null) return shared;
          if (r.url.path.contains('/utxo/byId/')) {
            if (unavailable) return http.Response('unavailable', 503);
            final id = r.url.pathSegments.last;
            if (id == 'position' && moved) return http.Response('', 404);
            return discovery.ok(
              id == 'position'
                  ? discovery.box(id, discovery.keyA)
                  : {'boxId': id},
            );
          }
          return discovery.ok([discovery.box('position', discovery.keyA)]);
        }),
      );
      addTearDown(svc.dispose);
      await svc.refresh({discovery.keyA});
      final result = svc.results.first;
      if (scenario == 'moved before prepare') moved = true;
      if (scenario == 'http failure') unavailable = true;
      final future = svc.prepareDirect(
        result: result,
        position: result.positions.single,
        userAddress: 'wallet',
        spendAddresses: ['wallet'],
        prepare: (state, stake, key) async {
          preparedCalls++;
          if (scenario == 'wallet during prepare') gw.walletId = 'bob';
          return jsonEncode({
            'preparation_id': 1,
            'rows': [],
            'unsigned_tx': {
              'inputs': [
                {'boxId': 'state'},
                {'boxId': 'position'},
                {'boxId': 'key'},
              ],
            },
          });
        },
      );
      if ([
        'moved before prepare',
        'wallet during prepare',
        'http failure',
      ].contains(scenario)) {
        await expectLater(future, throwsStateError);
        expect(preparedCalls, scenario == 'wallet during prepare' ? 1 : 0);
        return;
      }
      final prepared = await future;
      expect(svc.canCommit(prepared), isTrue);
      if (scenario == 'wallet before commit') gw.walletId = 'bob';
      if (scenario == 'network before commit') gw.network = 'testnet';
      if (scenario == 'moved after confirm') moved = true;
      if (scenario == 'success') {
        await svc.revalidateCommit(prepared);
      } else {
        await expectLater(svc.revalidateCommit(prepared), throwsStateError);
      }
    });
  }

  // An unsynced wallet, a capped scan or an unreachable pool all mean other
  // positions may be missing. None of them makes a position that WAS found
  // any less real, so recovery must stay available for it.
  test('an incomplete scan still recovers the position it did find', () async {
    final gw = Gateway();
    final svc = StakeRecoveryService(
      gateway: gw,
      client: MockClient((r) async {
        final shared = discovery.common(r);
        if (shared != null) return shared;
        if (r.url.path.contains('/utxo/byId/')) {
          final id = r.url.pathSegments.last;
          return discovery.ok(
            id == 'position'
                ? discovery.box(id, discovery.keyA)
                : {'boxId': id},
          );
        }
        return discovery.ok([discovery.box('position', discovery.keyA)]);
      }),
    );
    addTearDown(svc.dispose);
    await svc.refresh({discovery.keyA}, walletTokensComplete: false);
    final result = svc.results.first;
    expect(result.status, StakeScanStatus.incomplete);
    expect(result.positions.single.eligible, isTrue);
    final prepared = await svc.prepareDirect(
      result: result,
      position: result.positions.single,
      userAddress: 'wallet',
      spendAddresses: ['wallet'],
      prepare: (state, stake, key) async => jsonEncode({
        'preparation_id': 1,
        'rows': [],
        'unsigned_tx': {
          'inputs': [
            {'boxId': 'state'},
            {'boxId': 'position'},
            {'boxId': 'key'},
          ],
        },
      }),
    );
    expect(svc.canCommit(prepared), isTrue);
    await svc.revalidateCommit(prepared);
  });
}
