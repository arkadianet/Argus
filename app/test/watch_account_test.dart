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
  test('gap resets for used addresses; totals and deduplication', () async {
    final visited = <int>[];
    final snapshot = await scan({0, 19, 21}, visited);
    expect(visited.last, 41);
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
    expect(visited.last, 50);
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
      expect(watchAccountDisclosure, contains('Cannot spend'));
      expect(watchAccountDisclosure, contains('forever'));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    },
  );
}
