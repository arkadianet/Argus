import 'dart:convert';

import 'package:argus_wallet/services/stealth_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  _paginationTests();
}

// Pagination and wallet-switch guards (CodeRabbit review on PR #58)
void _paginationTests() {
  Map<String, dynamic> box(int i) => {
        'boxId': 'box$i',
        'value': '1000000',
        'ergoTree': 'tree$i',
        'assets': const [],
      };

  test('walks every page and de-duplicates by box id', () async {
    final requested = <int>[];
    Future<String> page(String base, int offset) async {
      requested.add(offset);
      final start = offset;
      final items = [
        for (var i = start; i < start + boxPageLimit && i < 1200; i++) box(i),
      ];
      return jsonEncode({'items': items, 'total': 1200});
    }

    final body = jsonDecode(await fetchAllStealthBoxes('https://x', page: page));
    expect(requested, [0, boxPageLimit, boxPageLimit * 2]);
    expect((body['items'] as List).length, 1200);
  });

  test('stops on a short page without asking for another', () async {
    var calls = 0;
    Future<String> page(String base, int offset) async {
      calls++;
      return jsonEncode({'items': [box(1), box(2)], 'total': 2});
    }

    final body = jsonDecode(await fetchAllStealthBoxes('https://x', page: page));
    expect(calls, 1);
    expect((body['items'] as List).length, 2);
  });

  test('a repeated box id is counted once', () async {
    var calls = 0;
    Future<String> page(String base, int offset) async {
      calls++;
      final items = [for (var i = 0; i < boxPageLimit; i++) box(calls == 1 ? i : 0)];
      return jsonEncode({'items': items});
    }

    final body = jsonDecode(await fetchAllStealthBoxes('https://x', page: page));
    expect((body['items'] as List).length, boxPageLimit);
  });
}
