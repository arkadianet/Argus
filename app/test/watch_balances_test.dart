import 'package:argus_wallet/services/watch_only_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('failed watched balances are unknown and retain the failure reason', () async {
    final result = await readWatchBalances(['a', 'b'], (address) async {
      if (address == 'b') throw StateError('node timed out');
      return 5000000000;
    });
    expect(result.balances, {'a': 5000000000, 'b': null});
    expect(result.error, contains('node timed out'));
    expect(result.error, contains('b'));
    final retry = await readWatchBalances(['a', 'b'], (_) async => 0);
    expect(retry.balances.values, everyElement(0));
    expect(retry.error, isNull);
  });
}
