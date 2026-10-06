import 'dart:convert';
import 'dart:io';

import 'package:argus_wallet/services/erg_price_history.dart';
import 'package:argus_wallet/services/oracle_pool.dart';
import 'package:argus_wallet/services/sigmausd_service.dart';
import 'package:flutter_test/flutter_test.dart';

List<Map<String, dynamic>> _load(String name) {
  final raw = jsonDecode(File('test/fixtures/$name').readAsStringSync());
  final items = raw is List ? raw : (raw as Map)['items'] as List;
  return items.map((e) => (e as Map).cast<String, dynamic>()).toList();
}

/// A synthetic pool box at [height] pricing ERG at [usd].
Map<String, dynamic> poolBox(int height, double usd, {int id = 0}) {
  const erg = 100000 * 1000000000;
  return {
    'boxId': 'box-$height-$id',
    'value': erg,
    'inclusionHeight': height,
    'assets': [
      {'tokenId': ergSigUsdPoolNft, 'amount': 1},
      {'tokenId': 'lp', 'amount': 9},
      {'tokenId': SigmaUsdTokens.sigUsd, 'amount': (usd * 100000 * 100).round()},
    ],
  };
}

void main() {
  final now = DateTime.utc(2026, 10, 6, 12);

  test('real ERG/SigUSD pool boxes become a price series, oldest first', () {
    final history = poolHistoryFromBoxes(_load('erg_sigusd_pool_history.json'), sigUsdId: SigmaUsdTokens.sigUsd);
    expect(history, hasLength(12));
    expect(history.first.$1, 1888470);
    expect(history.last.$1, 1888486);
    // 34,216.49 SigUSD against 114,319.79 ERG.
    expect(history.last.$2, closeTo(0.29931, 0.00001));
    for (var i = 1; i < history.length; i++) {
      expect(history[i].$1, greaterThanOrEqualTo(history[i - 1].$1));
    }
  });

  test('boxes of another pool layout or token are not read as prices', () {
    final odd = poolBox(10, 0.3);
    (odd['assets'] as List)[2] = {'tokenId': 'not-sigusd', 'amount': 5};
    expect(poolHistoryFromBoxes([odd, {'value': 1, 'assets': []}], sigUsdId: SigmaUsdTokens.sigUsd), isEmpty);
  });

  test('oracle history is the per-epoch median the live price uses', () {
    final boxes = _load('oracle_operator_boxes.json');
    final pool = _load('oracle_pool_box.json').first;
    final live = aggregateOracle(poolBox: pool, oracleBoxes: boxes)!;
    final history = oracleHistoryFromBoxes(boxes);
    expect(history, isNotEmpty);
    expect(history.last.$2, live['ERG_USD'], reason: 'newest epoch, same median');
    for (var i = 1; i < history.length; i++) {
      expect(history[i].$1, greaterThanOrEqualTo(history[i - 1].$1));
    }
  });

  test('heights become times at two minutes a block', () {
    final points = pointsFromHeights([(970, 0.3), (1000, 0.4)], tip: 1000, now: now, scale: 2);
    expect(points.first.at, now.subtract(const Duration(minutes: 60)));
    expect(points.first.price, 0.6);
    expect(points.last.at, now);
  });

  test('24h change runs from the price in force a day ago to the newest', () {
    final points = [
      PricePoint(now.subtract(const Duration(hours: 30)), 0.20),
      PricePoint(now.subtract(const Duration(hours: 10)), 0.30),
      PricePoint(now.subtract(const Duration(hours: 1)), 0.25),
    ];
    expect(changeOver(points, const Duration(hours: 24), now), closeTo(25, 1e-9));
    expect(changeOver(points.sublist(1), const Duration(hours: 24), now), isNull,
        reason: 'history that does not reach back a day has no 24h change');
  });

  test('a window starts with the price in force at its left edge', () {
    final points = [
      PricePoint(now.subtract(const Duration(days: 3)), 0.2),
      PricePoint(now.subtract(const Duration(hours: 2)), 0.3),
    ];
    final clipped = clipToWindow(points, const Duration(hours: 24), now);
    expect(clipped, hasLength(2));
    expect(clipped.first.at, now.subtract(const Duration(hours: 24)));
    expect(clipped.first.price, 0.2);
    expect(clipped.last.price, 0.3);
  });

  test('CoinGecko market chart points parse and sort', () {
    final points = coingeckoChartPoints({
      'prices': [
        [1700000060000, 0.31],
        [1700000000000, 0.30],
        ['bad', 1],
      ],
    });
    expect(points.map((p) => p.price), [0.30, 0.31]);
    expect(points.first.at.isUtc, isTrue);
  });

  group('sampleHistory', () {
    /// [count] boxes newest first, [perBlock] per block, ending at [tip].
    List<Map<String, dynamic>> chain(int count, {required int tip, required double perBlock}) => [
          for (var i = 0; i < count; i++) poolBox(tip - (i / perBlock).floor(), 0.3, id: i),
        ];

    test('a quiet pool needs one request', () async {
      final boxes = chain(100, tip: 10000, perBlock: 0.01); // a box every 100 blocks
      var calls = 0;
      final got = await sampleHistory(
        page: (node, token, offset, limit) async {
          calls++;
          return boxes.skip(offset).take(limit).toList();
        },
        node: 'n',
        tokenId: 't',
        tip: 10000,
        windowBlocks: 720,
      );
      expect(calls, 1);
      expect(got, hasLength(100));
    });

    test('a busy feed is sampled across the window in bounded requests, reaching past its start', () async {
      final boxes = chain(40000, tip: 100000, perBlock: 2); // two boxes a block
      final offsets = <int>[];
      final got = await sampleHistory(
        page: (node, token, offset, limit) async {
          offsets.add(offset);
          return boxes.skip(offset).take(limit).toList();
        },
        node: 'n',
        tokenId: 't',
        tip: 100000,
        windowBlocks: 5040, // a week
      );
      expect(offsets.length, lessThanOrEqualTo(14));
      final heights = got.map((b) => b['inclusionHeight'] as int).toList();
      expect(heights.reduce((a, b) => a < b ? a : b), lessThanOrEqualTo(100000 - 5040),
          reason: 'the price in force at the window start is known');
      expect(got.map((b) => b['boxId']).toSet().length, got.length, reason: 'no box twice');
      for (var i = 1; i < offsets.length; i++) {
        expect(offsets[i], greaterThan(offsets[i - 1]));
      }
    });

    test('short history stops at its end', () async {
      final boxes = chain(130, tip: 1000, perBlock: 1);
      var calls = 0;
      final got = await sampleHistory(
        page: (node, token, offset, limit) async {
          calls++;
          return boxes.skip(offset).take(limit).toList();
        },
        node: 'n',
        tokenId: 't',
        tip: 1000,
        windowBlocks: 21600,
      );
      expect(got, hasLength(lessThanOrEqualTo(130)));
      expect(calls, lessThanOrEqualTo(14));
    });
  });
}
