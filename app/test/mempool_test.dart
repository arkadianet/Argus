import 'package:flutter_test/flutter_test.dart';

import 'package:argus_wallet/services/wallet_service.dart';

void main() {
  group('mergePending', () {
    test('a transaction seen on two addresses appears once', () {
      // Spending from address A with change to address B returns the same
      // transaction from both mempool queries.
      final pending = [
        {'tx_id': 'tx1', 'confirmed': false},
        {'tx_id': 'tx1', 'confirmed': false},
      ];

      final merged = mergePending(pending, []);

      expect(merged, hasLength(1));
      expect(merged.single['tx_id'], 'tx1');
    });

    test('pending entries sort above confirmed ones', () {
      final merged = mergePending(
        [
          {'tx_id': 'tx1', 'confirmed': false},
        ],
        [
          {'tx_id': 'tx0', 'height': 100, 'timestamp': 1},
        ],
      );

      expect(merged.map((e) => e['tx_id']), ['tx1', 'tx0']);
    });

    test('a transaction that has confirmed is not also shown as pending', () {
      final merged = mergePending(
        [
          {'tx_id': 'tx1', 'confirmed': false},
        ],
        [
          {'tx_id': 'tx1', 'height': 100, 'timestamp': 1},
        ],
      );

      expect(merged, hasLength(1));
      expect((merged.single['height'] as num).toInt(), greaterThan(0));
    });
  });
}
