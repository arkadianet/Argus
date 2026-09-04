import 'dart:convert';

import 'package:argus_wallet/services/stealth_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/wallet_sync_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  _paginationTests();
  _displayConsistencyTests();
  _stealthMetadataTests();
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

// The dashboard's display model must include stealth everywhere at once
void _displayConsistencyTests() {
  test('display totals include stealth ERG and tokens', () {
    final c = WalletSyncController(_DisplayGateway());
    c.balanceNano = 4000000000;
    c.stealthNano = 1000000000;
    c.tokens = [TokenBalance(id: 'a', amount: 5, decimals: 0)];
    c.stealthTokens = [TokenBalance(id: 'a', amount: 3, decimals: 0, stealthAmount: 3)];

    expect(c.totalNanoWithStealth, 5000000000);
    expect(c.balanceNano, 4000000000, reason: 'spendable is untouched');
    final merged = c.displayTokens.firstWhere((t) => t.id == 'a');
    expect(merged.amount, 8);
    expect(merged.stealthAmount, 3);
  });

  test('an unknown stealth balance is reportable only while scanning is on', () {
    final on = WalletSyncController(_DisplayGateway(scanOn: true));
    expect(on.stealthScanning && on.stealthBalanceUnknown, isTrue);
    final off = WalletSyncController(_DisplayGateway(scanOn: false));
    expect(off.stealthScanning, isFalse);
  });
}

class _DisplayGateway implements WalletSyncGateway {
  _DisplayGateway({this.scanOn = true});
  final bool scanOn;
  @override
  bool get stealthScanEnabled => scanOn;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

// Metadata for tokens seen only in stealth boxes (CodeRabbit, PR #58)
void _stealthMetadataTests() {
  test('a stealth-only token keeps its name and decimals', () {
    final merged = mergeStealthTokens(
      const [],
      [TokenBalance(id: 'sig', amount: 1234, name: 'SigUSD', decimals: 2, stealthAmount: 1234)],
    );
    expect(merged.single.decimals, 2, reason: 'otherwise 12.34 renders as 1234');
    expect(merged.single.name, 'SigUSD');
    expect(merged.single.stealthAmount, 1234);
  });

  test('metadata from the spendable side is preserved when both sides hold it', () {
    final merged = mergeStealthTokens(
      [TokenBalance(id: 'sig', amount: 100, name: 'SigUSD', decimals: 2)],
      [TokenBalance(id: 'sig', amount: 50, decimals: 2, stealthAmount: 50)],
    );
    expect(merged.single.amount, 150);
    expect(merged.single.decimals, 2);
    expect(merged.single.stealthAmount, 50);
  });
}
