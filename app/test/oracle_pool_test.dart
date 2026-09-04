import 'dart:convert';
import 'dart:io';

import 'package:argus_wallet/services/oracle_pool.dart';
import 'package:flutter_test/flutter_test.dart';

List<Map<String, dynamic>> _load(String name) {
  final raw = jsonDecode(File('test/fixtures/$name').readAsStringSync());
  final items = raw is List ? raw : (raw as Map)['items'] as List;
  return items.map((e) => (e as Map).cast<String, dynamic>()).toList();
}

void main() {
  final pool = _load('oracle_pool_box.json').first;
  final oracles = _load('oracle_operator_boxes.json');

  test('aggregates the current epoch from real node boxes', () {
    final snap = aggregateOracle(poolBox: pool, oracleBoxes: oracles)!;
    expect(snap.epoch, 14013);
    expect(snap.poolHeight, 1865320);
    expect(snap.operators, 4);
    expect(snap['ERG_USD'], closeTo(0.265, 0.05));
    expect(snap['BTC_USD'], greaterThan(10000));
    expect(snap['XAU_USD'], greaterThan(1000));
    expect(snap['ETH_USD'], greaterThan(100));
    expect(snap.usd.length, 20);
  });

  test('uses the newest epoch the operators actually published, and says how far back', () {
    // Operators post when they post. Insisting on the pool's exact epoch
    // meant a lag left the wallet with no ERG price at all, and therefore
    // nothing priced anywhere.
    final onlyOld = oracles.where((b) {
      final r5 = (b['additionalRegisters'] as Map)['R5'];
      return r5 == null || r5 == '04be25';
    }).toList();
    final snap = aggregateOracle(poolBox: pool, oracleBoxes: onlyOld)!;
    expect(snap.epoch, 2399, reason: 'the only vector on offer');
    expect(snap.poolEpoch, 14013);
    expect(snap.epochsBehind, 14013 - 2399);
    expect(snap.isStale(null), isTrue, reason: 'used, but flagged');
  });

  test('boxes with no vector, or from a future epoch, are ignored', () {
    final noVector = oracles.where((b) {
      return (b['additionalRegisters'] as Map)['R6'] == null;
    }).toList();
    expect(aggregateOracle(poolBox: pool, oracleBoxes: noVector), isNull);

    final future = Map<String, dynamic>.from(pool);
    future['additionalRegisters'] = {
      ...(pool['additionalRegisters'] as Map).cast<String, dynamic>(),
      'R4': '0402', // epoch 1: every operator box is ahead of it
    };
    expect(aggregateOracle(poolBox: future, oracleBoxes: oracles), isNull);
  });

  test('prefers the pool epoch when operators have reached it', () {
    final bumped = Map<String, dynamic>.from(pool);
    bumped['additionalRegisters'] = {
      ...(pool['additionalRegisters'] as Map).cast<String, dynamic>(),
      'R4': '04fcda01', // epoch 14014
    };
    final snap = aggregateOracle(poolBox: bumped, oracleBoxes: oracles)!;
    expect(snap.epoch, 14013);
  });

  test('median is taken per feed and zero entries are skipped', () {
    Map<String, dynamic> op(String epochHex, List<int> v) => {
          'creationHeight': 10,
          'additionalRegisters': {
            'R5': '04$epochHex',
            'R6': '11${v.length.toRadixString(16).padLeft(2, '0')}${v.map(_zig).join()}',
          },
        };
    final poolBox = {
      'creationHeight': 9,
      'additionalRegisters': {'R4': '0402', 'R6': '0404'}, // epoch 1, 2 feeds
    };
    final snap = aggregateOracle(poolBox: poolBox, oracleBoxes: [
      op('02', [3000000, 0]),
      op('02', [1000000, 5000000]),
      op('02', [2000000, 7000000]),
    ])!;
    expect(snap['ETH_USD'], 2.0);
    expect(snap['BTC_USD'], 6.0);
    expect(snap.usd.containsKey('BNB_USD'), isFalse);
  });

  test('stale when the pool box is far behind the tip', () {
    final snap = aggregateOracle(poolBox: pool, oracleBoxes: oracles)!;
    expect(snap.isStale(1865330), isFalse);
    expect(snap.isStale(1865320 + 61), isTrue);
    expect(snap.isStale(null), isFalse);
  });
}

/// Zigzag VLQ hex for small non-negative values used in fixtures.
String _zig(int n) {
  var v = n << 1;
  final out = StringBuffer();
  while (true) {
    final b = v & 0x7f;
    v >>= 7;
    if (v == 0) {
      out.write(b.toRadixString(16).padLeft(2, '0'));
      return out.toString();
    }
    out.write((b | 0x80).toRadixString(16).padLeft(2, '0'));
  }
}
