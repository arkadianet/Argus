import 'dart:convert';

import 'package:argus_wallet/services/stealth_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/wallet_sync_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  _paginationTests();
  _displayConsistencyTests();
  _stealthMetadataTests();
  _truncationTests();
  _stealthActivityTests();
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

// A capped scan must not read as a complete, smaller balance
void _truncationTests() {
  Map<String, dynamic> box(int i) => {
        'boxId': 'box$i',
        'transactionId': '0',
        'index': 0,
        'value': 1000000,
        'creationHeight': 1,
        'ergoTree': 'tree$i',
        'assets': const [],
      };

  test('hitting the cap marks the body truncated', () async {
    Future<String> page(String base, int offset) async => jsonEncode({
          'items': [for (var i = offset; i < offset + boxPageLimit; i++) box(i)],
        });
    final body = await fetchAllStealthBoxes('https://x', page: page);
    expect(isTruncatedScan(body), isTrue);
    expect((jsonDecode(body)['items'] as List).length, boxScanCap);
  });

  test('a complete scan is not marked truncated', () async {
    Future<String> page(String base, int offset) async =>
        jsonEncode({'items': [box(1), box(2)], 'total': 2});
    final body = await fetchAllStealthBoxes('https://x', page: page);
    expect(isTruncatedScan(body), isFalse);
  });

  // scan() and prepareSweep() both consult this before using a body; the
  // wallet-state half of those paths needs an unlocked wallet, so the guard
  // itself is what is pinned here.
  test('the truncation guard reads the marker, not the box count', () {
    expect(isTruncatedScan(jsonEncode({'items': const [], 'argus_truncated': true})), isTrue);
    expect(isTruncatedScan(jsonEncode({'items': [box(1)]})), isFalse);
    expect(isTruncatedScan('not json'), isFalse);
  });
}

// Stealth receipts in the activity list
void _stealthActivityTests() {
  StealthOwnedBox b(String tx, int nano, int height, {List<StealthToken> tokens = const []}) =>
      StealthOwnedBox(
        boxId: '$tx-$nano',
        transactionId: tx,
        valueNanoErg: nano,
        creationHeight: height,
        tokens: tokens,
      );

  test('boxes from one transaction become one receipt', () {
    final rows = stealthActivityRows([
      b('tx1', 1000000000, 100),
      b('tx1', 500000000, 100, tokens: [StealthToken(id: 'sig', amount: BigInt.from(250))]),
    ]);
    expect(rows.length, 1, reason: 'the user saw one payment');
    expect(rows.single['value_nano_erg'], 1500000000);
    expect(rows.single['stealth'], isTrue);
    expect((rows.single['tokens_received'] as List).single['amount'], '250');
  });

  test('receipts are newest first', () {
    final rows = stealthActivityRows([b('old', 1, 10), b('new', 1, 900)]);
    expect(rows.map((r) => r['tx_id']), ['new', 'old']);
  });

  test('a box with no creating transaction is skipped rather than shown blank', () {
    expect(stealthActivityRows([b('', 1, 10)]), isEmpty);
  });

  test('merging keeps address history and adds only unseen stealth receipts', () {
    final history = [
      {'tx_id': 'shared', 'height': 500, 'value_nano_erg': 1},
      {'tx_id': 'plain', 'height': 300, 'value_nano_erg': 1},
    ];
    final merged = mergeStealthActivity(history, [
      {'tx_id': 'shared', 'height': 500, 'value_nano_erg': 9, 'stealth': true},
      {'tx_id': 'stealthy', 'height': 400, 'value_nano_erg': 1, 'stealth': true},
    ]);
    expect(merged.map((t) => t['tx_id']), ['shared', 'stealthy', 'plain']);
    expect(merged.first['value_nano_erg'], 1, reason: 'the sweep tx keeps its real history row');
  });

  test('no stealth rows leaves history untouched', () {
    final history = [
      {'tx_id': 'a', 'height': 1},
    ];
    expect(identical(mergeStealthActivity(history, const []), history), isTrue);
  });
}
