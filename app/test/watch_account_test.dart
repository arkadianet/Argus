import 'dart:async';
import 'package:argus_wallet/services/watch_account_service.dart';
import 'package:argus_wallet/ui/widgets/watch_account_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<WatchAccountSnapshot> scan(
    Set<int> used,
    List<int> visited, {
    int highest = -1,
    int max = 100,
    int? failAt,
  }) => scanWatchAccount(
    derive: (start, count) async => List.generate(count, (i) => '${start + i}'),
    history: (a) async {
      final i = int.parse(a);
      visited.add(i);
      if (i == failAt) throw StateError('offline');
      return used.contains(i)
          ? [
              {'tx_id': 'shared', 'timestamp': 1},
            ]
          : [];
    },
    balance: (a) async => {
      'balance_nano_erg': used.contains(int.parse(a)) ? 10 : 0,
      'tokens': used.contains(int.parse(a))
          ? [
              {'id': 'token', 'amount': 2},
            ]
          : [],
    },
    highestUsed: highest,
    maxAddresses: max,
  );
  test(
    'out-of-order reads preserve frontier, totals and address order',
    () async {
      final histories = List.generate(8, (_) => Completer<List<dynamic>>());
      final balances = List.generate(
        8,
        (_) => Completer<Map<String, dynamic>>(),
      );
      final started = <String>[];
      final scan = scanWatchAccount(
        gap: 4,
        derive: (start, count) async =>
            List.generate(count, (i) => '${start + i}'),
        history: (a) {
          started.add('h$a');
          return histories[int.parse(a)].future;
        },
        balance: (a) {
          started.add('b$a');
          return balances[int.parse(a)].future;
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        started.length,
        8,
      ); // Four addresses, both requests already running.
      for (final i in [3, 2, 1, 0]) {
        histories[i].complete(
          i == 1
              ? [
                  {'tx_id': 'used'},
                ]
              : [],
        );
        balances[i].complete({
          'balance_nano_erg': i == 1 ? 7 : 0,
          'tokens': [],
        });
      }
      await Future<void>.delayed(Duration.zero);
      expect(started.length, 16);
      for (final i in [7, 6, 5, 4]) {
        histories[i].complete([]);
        balances[i].complete({'balance_nano_erg': 0, 'tokens': []});
      }
      final result = await scan;
      expect(result.addresses, ['0', '1', '2', '3', '4', '5']);
      expect(result.highestUsed, 1);
      expect(result.receiveAddress, '2');
      expect(result.balance, 7);
    },
  );

  test('account refresh scheduling is bounded', () async {
    final gates = List.generate(5, (_) => Completer<void>());
    final started = <int>[];
    final work = watchMapOrdered(List.generate(5, (i) => i), (i) {
      started.add(i);
      return gates[i].future;
    }, concurrency: watchAccountConcurrency);
    expect(started, [0, 1]);
    gates[1].complete();
    await Future<void>.delayed(Duration.zero);
    expect(started, [0, 1]);
    gates[0].complete();
    await Future<void>.delayed(Duration.zero);
    expect(started, [0, 1, 2, 3]);
    gates[2].complete();
    gates[3].complete();
    await Future<void>.delayed(Duration.zero);
    gates[4].complete();
    await work;
  });

  test('gap resets for used addresses; totals and deduplication', () async {
    final visited = <int>[];
    final snapshot = await scan({0, 19, 21}, visited);
    expect(snapshot.addresses.last, '41');
    expect(snapshot.receiveAddress, '22');
    expect(snapshot.balance, 30);
    expect(snapshot.tokens, {'token': 6});
    expect(snapshot.history.length, 1);
  });
  test('empty chain derives 20 and receives at zero', () async {
    final visited = <int>[];
    final result = await scan({}, visited);
    expect(visited.length, 20);
    expect(result.receiveAddress, '0');
  });
  test('persisted used frontier prevents premature stopping', () async {
    final visited = <int>[];
    final result = await scan({}, visited, highest: 30);
    expect(result.addresses.last, '50');
    expect(result.receiveAddress, '31');
  });
  test('failed query and safety cap fail the scan', () async {
    await expectLater(scan({}, [], failAt: 3), throwsStateError);
    await expectLater(scan({0}, [], max: 20), throwsStateError);
  });
  test('spent history still resets gap', () async {
    final result = await scanWatchAccount(
      derive: (start, count) async =>
          List.generate(count, (i) => '${start + i}'),
      history: (a) async => a == '19'
          ? [
              {'tx_id': 'spent'},
            ]
          : [],
      balance: (_) async => {'balance_nano_erg': 0, 'tokens': []},
    );
    expect(result.addresses.length, 40);
    expect(result.receiveAddress, '20');
  });
  testWidgets(
    'import discloses stealth exclusion, spending and permanent linkage',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: WatchAccountList())),
      );
      await tester.tap(find.text('Watch an extended public key'));
      await tester.pumpAndSettle();
      expect(find.text(watchAccountDisclosure), findsOneWidget);
      expect(watchAccountDisclosure, contains('Cannot see stealth identities'));
      expect(watchAccountDisclosure, contains('Cannot sign locally'));
      expect(watchAccountDisclosure, contains('forever'));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    },
  );
}
