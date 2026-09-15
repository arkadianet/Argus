import 'package:argus_wallet/services/duckpools_service.dart';
import 'dart:convert';
import 'dart:io';

import 'package:argus_wallet/services/stealth_identities.dart';
import 'package:argus_wallet/services/stealth_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/wallet_sync_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  _paginationTests();
  _displayConsistencyTests();
  _stealthMetadataTests();
  _truncationTests();
  _stealthActivityTests();
  _walletRowTests();
  _identityFrontierTests();
  test('a template scan asks the explorer for nothing but the template list', () async {
    final client = _RecordingHttpClient();
    final service = StealthService(
      wallet: _ScanWallet(),
      fetcher: (_) async => '{"items":[{"boxId":"change","ergoTree":"privateTree"}]}',
    );
    await HttpOverrides.runZoned(() async {
      expect(await service.scan(explorerBase: 'https://explorer'), isNotNull);
    }, createHttpClient: (_) => client);
    expect(client.requests, isEmpty);
  });
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
  test('Duckpools receipt is visible in Assets with no public balance', () {
    const id = 'fc888e0eed50a4042324793a7894134d83c7aaf5c99f4bf643e7e2b4e71e0095';
    final merged = mergeStealthTokens([], [
      TokenBalance(id: id, amount: 482930456, decimals: 9,
          name: 'Lend Token ERG-0e', stealthAmount: 482930456),
    ]);
    expect(merged.single.amount, 482930456);
    expect(merged.single.amount - merged.single.stealthAmount, 0);
    final issue = duckpoolsStealthFundingIssue(merged, id, 482930456, decimals: 9)!;
    expect(issue, contains('0.482930456 of token'));
    expect(issue, contains('Stealth pocket'));
    expect(issue, contains('makes the transferred funds public'));
    expect(issue, isNot(contains('have 0')));
    final both = mergeStealthTokens([TokenBalance(id: id, amount: 482930456)], merged);
    expect(duckpoolsStealthFundingIssue(both, id, 482930456, decimals: 9), isNull);
    expect(duckpoolsStealthFundingIssue([], id, 482930456, decimals: 9), isNull);

  });

  test('Duckpools asks for only the minimum stealth shortfall in pool units', () {
    final holdings = [TokenBalance(id: 'receipt', amount: 11000, stealthAmount: 8000)];
    expect(
      duckpoolsStealthFundingIssue(holdings, 'receipt', 10000, decimals: 2),
      'Assets includes 80 of token receipt in Stealth. '
      'Duckpools protocol funding uses public boxes, which hold 30; '
      'this order needs 100. '
      'In Send, choose the Stealth pocket and transfer at least 70 '
      'of this token (the minimum shortfall) to your '
      'public receive address, then retry after confirmation. '
      'This makes the transferred funds public. Nothing was sent.',
    );
    expect(
      duckpoolsStealthFundingIssue(holdings, 'receipt', 3001, decimals: 2),
      contains('transfer at least 0.01 of this token'),
    );
  });

  test('Duckpools needs no stealth transfer when public holdings exactly cover the order', () {
    final holdings = [TokenBalance(id: 'receipt', amount: 18000, stealthAmount: 8000)];
    expect(
      duckpoolsStealthFundingIssue(holdings, 'receipt', 10000, decimals: 2),
      isNull,
    );
  });

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

// The wallet row must not contradict the portfolio card above it.
// walletRowDisplay is the decision the row makes, so testing it covers the
// row rather than only the controller behind it.
void _walletRowTests() {
  test('the active row shows the same total as the portfolio and names the stealth part', () {
    // The screenshot that prompted this showed 2.012 in the portfolio and
    // 1.01 on the same wallet's row.
    final d = walletRowDisplay(
      isActive: true,
      spendableNano: 1012000000,
      stealthNano: 1000000000,
      cachedNano: 999,
      hidden: false,
    );
    expect(d.balanceNano, 2012000000);
    expect(d.note, 'includes 1 ERG stealth');
  });

  test('no stealth funds means no note', () {
    final d = walletRowDisplay(
      isActive: true, spendableNano: 1012000000, stealthNano: 0, cachedNano: null, hidden: false);
    expect(d.balanceNano, 1012000000);
    expect(d.note, isNull);
  });

  test('hidden balances do not leak the stealth amount in the note', () {
    final d = walletRowDisplay(
      isActive: true, spendableNano: 1, stealthNano: 1000000000, cachedNano: null, hidden: true);
    expect(d.note, isNull);
  });

  test('an inactive row keeps its cached snapshot and gains nothing', () {
    final d = walletRowDisplay(
      isActive: false, spendableNano: 5, stealthNano: 1000000000, cachedNano: 26390000000, hidden: false);
    expect(d.balanceNano, 26390000000);
    expect(d.note, isNull);
  });

  test('an unknown spendable balance stays unknown rather than becoming the stealth total', () {
    final d = walletRowDisplay(
      isActive: true, spendableNano: null, stealthNano: 1000000000, cachedNano: null, hidden: false);
    expect(d.balanceNano, isNull);
  });
}

// The handle must learn every identity before a scan runs, or funds on a
// later identity are reported as missing rather than as somebody else's.
void _identityFrontierTests() {
  StealthService serviceWith(_IdentityWallet wallet) => StealthService(
        wallet: wallet,
        fetcher: (_) async => jsonEncode({'items': const []}),
      );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a scan raises the frontier to cover every stored identity', () async {
    await StealthIdentityStore.add('w1', 'Donations');
    await StealthIdentityStore.add('w1', 'Project B');
    final wallet = _IdentityWallet();
    final service = serviceWith(wallet);

    await service.scan(explorerBase: 'https://explorer');

    // Frontier 3 means identities 0..2, so the handle is told index 2.
    expect(wallet.frontierCalls, [2]);
    expect(service.frontier, 3);
    expect(service.identities.map((i) => i.displayLabel),
        ['Main', 'Donations', 'Project B']);
    // Every string is derived once and cached.
    expect(service.addressOf(0), 'stealth-0');
    expect(service.addressOf(2), 'stealth-2');
    expect(wallet.derived, [0, 1, 2]);
  });

  test('the frontier is pushed before the scan, not after', () async {
    await StealthIdentityStore.add('w1', 'Donations');
    final wallet = _IdentityWallet();
    await serviceWith(wallet).scan(explorerBase: 'https://explorer');
    expect(wallet.order.indexOf('frontier'), lessThan(wallet.order.indexOf('scan')));
  });

  test('a single-identity wallet still scans with identity 0', () async {
    final wallet = _IdentityWallet();
    final service = serviceWith(wallet);
    await service.scan(explorerBase: 'https://explorer');
    expect(wallet.frontierCalls, [0]);
    expect(service.frontier, 1);
    expect(service.hasMultipleIdentities, isFalse);
  });

  test('adding an identity widens the frontier immediately', () async {
    final wallet = _IdentityWallet();
    final service = serviceWith(wallet);
    await service.loadIdentities();
    expect(wallet.frontierCalls, [0]);

    final created = await service.addIdentity('Donations');
    expect(created.index, 1);
    expect(wallet.frontierCalls.last, 1);
    expect(service.addressOf(1), 'stealth-1');
  });

  test('reset forgets the identities of the previous wallet', () async {
    await StealthIdentityStore.add('w1', 'Donations');
    final service = serviceWith(_IdentityWallet());
    await service.loadIdentities();
    expect(service.identities.length, 2);

    service.reset();
    expect(service.identities.map((i) => i.index), [0]);
    expect(service.addressOf(1), isNull);
    expect(service.frontier, 1);
  });

  test('discovery adopts funded identities the device did not know', () async {
    final wallet = _IdentityWallet(funded: const [3]);
    final service = serviceWith(wallet);
    await service.loadIdentities();

    final result =
        await service.discoverIdentities(explorerBase: 'https://explorer');
    expect(result.isComplete, isTrue);
    expect(result.adopted, [3]);
    expect(service.identities.map((i) => i.index), [0, 3]);
    expect(service.frontier, 4);
    expect(wallet.frontierCalls.last, 3);
    // It survives a reload: discovery wrote it down.
    expect((await StealthIdentityStore.load('w1')).map((i) => i.index), [0, 3]);
  });

  test('a complete search that finds nothing is a real answer', () async {
    final service = serviceWith(_IdentityWallet());
    await service.loadIdentities();
    final result = await service.discoverIdentities(explorerBase: 'https://x');
    expect(result.isComplete, isTrue);
    expect(result.adopted, isEmpty);
    expect(result.error, isNull);
  });

  // "Could not look" must not read as "looked and found nothing" — this runs
  // when a user is asking whether a restore recovered their money.
  test('a truncated box list is not evidence an identity is unfunded', () async {
    final wallet = _IdentityWallet(funded: const [3]);
    final service = StealthService(
      wallet: wallet,
      fetcher: (_) async =>
          jsonEncode({'items': const [], 'argus_truncated': true}),
    );
    await service.loadIdentities();

    final result = await service.discoverIdentities(explorerBase: 'https://x');
    expect(result.isComplete, isFalse);
    expect(result.adopted, isEmpty);
    expect(result.error, contains('incomplete'));
    expect(service.identities.map((i) => i.index), [0]);
  });

  test('an unreachable explorer is a failure, not an empty result', () async {
    final service = StealthService(
      wallet: _IdentityWallet(funded: const [3]),
      fetcher: (_) async => throw StateError('explorer down'),
    );
    await service.loadIdentities();

    final result = await service.discoverIdentities(explorerBase: 'https://x');
    expect(result.isComplete, isFalse);
    expect(result.error, contains('Could not reach the explorer'));
  });

  test('an FFI failure is a failure, not an empty result', () async {
    final service = serviceWith(_IdentityWallet(discoveryThrows: true));
    await service.loadIdentities();

    final result = await service.discoverIdentities(explorerBase: 'https://x');
    expect(result.isComplete, isFalse);
    expect(result.error, contains('Could not search'));
  });

  // A frontier push that failed must not be remembered as loaded, or the
  // session scans narrow forever and funds on later identities stay hidden.
  test('a failed frontier push leaves the next scan to retry', () async {
    await StealthIdentityStore.add('w1', 'Donations');
    final wallet = _IdentityWallet(frontierThrowsUntil: 2);
    final service = serviceWith(wallet);

    await service.loadIdentities();
    expect(wallet.frontierCalls, [1]);

    // The retry happens on the next scan rather than waiting for an unlock.
    await service.scan(explorerBase: 'https://x');
    expect(wallet.frontierCalls, [1, 1]);

    // Third attempt succeeds and is not retried after that.
    await service.scan(explorerBase: 'https://x');
    expect(wallet.frontierCalls, [1, 1, 1]);
    await service.scan(explorerBase: 'https://x');
    expect(wallet.frontierCalls, [1, 1, 1]);
  });

  test('a successful frontier push is not repeated on every scan', () async {
    final wallet = _IdentityWallet();
    final service = serviceWith(wallet);
    await service.scan(explorerBase: 'https://x');
    await service.scan(explorerBase: 'https://x');
    expect(wallet.frontierCalls, [0]);
  });
}

class _IdentityWallet extends WalletService {
  _IdentityWallet({
    this.funded = const [],
    this.frontierThrowsUntil = 0,
    this.discoveryThrows = false,
  });

  /// Indices `stealthDiscoverIdentities` should report as holding funds.
  final List<int> funded;

  /// Fail this many `stealthUseIdentity` calls before succeeding.
  final int frontierThrowsUntil;

  final bool discoveryThrows;

  final frontierCalls = <int>[];
  final derived = <int>[];
  final order = <String>[];

  @override
  bool get isUnlocked => true;

  @override
  String? get activeWalletId => 'w1';

  @override
  Future<int> stealthUseIdentity(int index) async {
    frontierCalls.add(index);
    order.add('frontier');
    if (frontierCalls.length <= frontierThrowsUntil) {
      throw StateError('handle busy');
    }
    return index + 1;
  }

  @override
  Future<String> stealthAddressAt(int index) async {
    derived.add(index);
    return 'stealth-$index';
  }

  @override
  Future<Map<String, dynamic>> stealthScan(String boxesJson) async {
    order.add('scan');
    return {'scanned': 0, 'owned_count': 0, 'total_nano_erg': 0};
  }

  @override
  Future<Map<String, dynamic>> stealthDiscoverIdentities(String boxesJson) async {
    if (discoveryThrows) throw StateError('ffi failed');
    return {'span': 32, 'funded': funded, 'frontier': 1};
  }
}

// Change we send ourselves must be findable without the template scan

class _ScanWallet extends WalletService {
  @override
  bool get isUnlocked => true;
  @override
  Future<Map<String, dynamic>> stealthScan(String boxesJson) async => {
    'scanned': 1,
    'owned_count': 1,
    'boxes': [{'box_id': 'change', 'ergo_tree': 'privateTree'}],
  };
}

class _RecordingHttpClient implements HttpClient {
  final requests = <Uri>[];
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    requests.add(url);
    throw StateError('unexpected network request');
  }
  @override
  void close({bool force = false}) {}
  @override
  set autoUncompress(bool value) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
