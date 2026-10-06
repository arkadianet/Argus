import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/ui/utxo_management_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const tip = 1900000;
const fee = 137500000;

String id(String c) => c * 64;

/// Wallet core stand-in. The box listing is the mempool-aware one
/// (`list_spendable_boxes`), which already leaves out boxes a pending
/// transaction spends; rent rows and estimates use the figures
/// `wallet_core::rent` produces for 110-byte boxes at 1.25 mERG per byte.
class CleanupApi extends RustLibApi {
  bool failReport = false;
  Map<String, Object?>? consolidated;
  int submissions = 0;

  /// The wallet's boxes per address, in the listing's own form.
  List<Map<String, Object?>> Function(String address) listing = (_) => [];
  int listings = 0;

  /// Rent rows the report answers with, whatever it was given: the screen
  /// must count and propose only boxes the listing holds.
  List<Map<String, Object?>> rows = [];

  /// The boxes the last report was asked to judge.
  List<dynamic>? judged;

  @override
  Future<BigInt> crateApiWalletRestore({
    required String encryptedSeedJson,
    String? wrapKey,
  }) async => BigInt.one;
  @override
  Future<void> crateApiWalletLock({required BigInt handleId}) async {}

  @override
  Future<String> crateApiMempoolListSpendableBoxes({
    required BigInt handleId,
    required List<String> addresses,
    String? nodeUrl,
    required bool confirmedOnly,
  }) async {
    listings++;
    return jsonEncode([
      for (final address in addresses)
        for (final b in listing(address))
          {...b, 'address': address},
    ]);
  }

  @override
  Future<String> crateApiStorageRentBoxRentReport({
    required String boxesJson,
    String? nodeUrl,
  }) async {
    judged = jsonDecode(boxesJson) as List;
    if (failReport) throw '{"code":"NODE_ERROR","message":"offline"}';
    return jsonEncode({
      'height': tip,
      'storage_fee_factor': 1250000,
      'factor_from_node': true,
      'storage_period': 1051200,
      'boxes': rows,
    });
  }

  @override
  String crateApiStorageRentOutputRentEstimate({
    required String address,
    required PlatformInt64 valueNano,
    required String tokensJson,
    required int height,
    required int storageFeeFactor,
  }) => jsonEncode({
    'value_nano_erg': valueNano,
    'due_height': height + 1051200,
    'suggested_nano_erg': 140000000,
    'boxes': [
      {
        'value_nano': valueNano,
        'token_count': (jsonDecode(tokensJson) as List).length,
        'size_bytes': 111,
        'fee_nano': 138750000,
        'charge': valueNano > 138750000 ? 'fee' : 'whole_box',
      },
    ],
  });

  @override
  Future<String> crateApiPrepareConsolidate({
    required BigInt handleId,
    required List<String> spendAddresses,
    required List<String> selectedBoxIds,
    required String changeAddress,
    String? nodeUrl,
    PlatformInt64? feeNano,
  }) async {
    consolidated = {
      'spend': spendAddresses,
      'ids': selectedBoxIds,
      'change': changeAddress,
    };
    return jsonEncode({
      'preparation_id': 7,
      'input_count': selectedBoxIds.length,
      'total_erg_in': 0,
      'change_nano_erg': 0,
      'token_count': 1,
      'miner_fee': 1100000,
    });
  }

  @override
  Future<String> crateApiSendErg({
    required BigInt handleId,
    required BigInt preparationId,
  }) async {
    submissions++;
    return jsonEncode({'tx_id': 'ab' * 32});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, Object?> rentRow(
  String boxId, {
  required int value,
  required int creation,
}) {
  final due = creation + 1051200;
  final whole = value <= fee;
  return {
    'box_id': boxId,
    'value_nano_erg': value,
    'creation_height': creation,
    'size_bytes': 110,
    'fee_nano': fee,
    'charge': whole ? 'whole_box' : 'fee',
    'charge_nano': whole ? value : fee,
    'due_height': due,
    'blocks_until_due': due - tip,
    'collectable_now': tip + 1 >= due,
  };
}

/// One box as `list_spendable_boxes` lists it.
Map<String, Object?> listed(
  String boxId, {
  required int value,
  required int creation,
  List<String> tokens = const [],
  bool confirmed = true,
}) => {
  'box_id': boxId,
  'value_nano_erg': '$value',
  'creation_height': creation,
  'assets': [
    for (final t in tokens) {'token_id': t, 'amount': '1'},
  ],
  'confirmed': confirmed,
  'size_bytes': 110,
};

/// One wallet address holding an NFT box that cannot pay its rent, an ERG
/// box due within the month, and a large ERG box to fund the move.
final walletBoxes = [
  listed(id('a'), value: 1000000, creation: 1500000, tokens: [id('7')]),
  listed(id('b'), value: 2000000000, creation: tip - 1051200 + 3000),
  listed(id('c'), value: 40000000000, creation: 1800000),
];

List<Map<String, Object?>> rowsFor(List<Map<String, Object?>> boxes) => [
  for (final b in boxes)
    rentRow(
      b['box_id'] as String,
      value: int.parse(b['value_nano_erg'] as String),
      creation: b['creation_height'] as int,
    ),
];

void main() {
  late CleanupApi api;
  String? previousNode;
  int? previousHeight;
  setUpAll(() {
    api = CleanupApi();
    RustLib.initMock(api: api);
  });
  tearDownAll(RustLib.dispose);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    api
      ..failReport = false
      ..consolidated = null
      ..submissions = 0
      ..listings = 0
      ..judged = null
      ..listing = ((_) => walletBoxes)
      ..rows = rowsFor(walletBoxes);
    previousNode = networkController.activeUrl;
    previousHeight = networkController.height;
    networkController.activeUrl = 'https://node.invalid';
    networkController.height = tip;
    await walletService.restoreWallet('mock', walletId: 'utxo-cleanup-test');
  });
  tearDown(() async {
    networkController.activeUrl = previousNode;
    networkController.height = previousHeight;
    await walletService.lock();
  });

  Future<void> open(
    WidgetTester tester, {
    bool openCleanup = false,
    List<String> addresses = const ['wallet'],
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: argusTheme(watchful: true),
        home: WalletArgsScope(
          args: WalletRouteArgs(
            senderAddress: 'wallet',
            receiveAddress: 'wallet',
            changeAddress: 'wallet',
            historyAddresses: addresses,
          ),
          child: UtxoManagementScreen(openCleanup: openCleanup),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('each box shows when rent falls due and what it costs', (
    tester,
  ) async {
    await open(tester);
    expect(
      find.textContaining(
        'Storage rent: 1 box at risk of collection · 1 due within 30 days.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('0.00125 ERG per byte'), findsOneWidget);
    // At risk: 0.001 ERG cannot pay 0.1375 ERG; due at 1,500,000 + 1,051,200.
    await tester.scrollUntilVisible(
      find.textContaining('At risk: it holds no more than its 0.1375 ERG rent'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('From block 2,551,200'), findsOneWidget);
    expect(
      find.textContaining('it can be collected whole, tokens included'),
      findsOneWidget,
    );
    // Due soon: 3,000 blocks of 2 minutes, rounded up to whole days.
    expect(
      find.text('Storage rent of 0.1375 ERG due in ~5 days (block 1,903,000).'),
      findsOneWidget,
    );
    await tester.ensureVisible(find.textContaining('Rent (2)'));
    await tester.tap(find.textContaining('Rent (2)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('due ~'), findsNothing);
  });

  testWidgets('rent is judged from the listing, without reading boxes again', (
    tester,
  ) async {
    await open(tester);
    expect(api.listings, 1);
    // The report gets the listed boxes with the sizes the listing
    // measured, and nothing else to read.
    expect(api.judged, [
      for (final b in walletBoxes)
        {
          'box_id': b['box_id'],
          'value_nano_erg': b['value_nano_erg'],
          'creation_height': b['creation_height'],
          'size_bytes': 110,
        },
    ]);
  });

  testWidgets('the suggested cleanup shows fee and boxes before signing', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Suggested cleanup'), findsOneWidget);
    expect(
      find.textContaining('Merge 3 boxes at wallet into one.'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        "1 box can't cover its storage rent and 1 falls due within 30 days.",
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Review cleanup'));
    await tester.pumpAndSettle();
    expect(api.consolidated, isNull, reason: 'nothing prepared yet');
    for (final (label, value) in [
      ('Boxes merged', '3'),
      ('Resulting boxes', '1'),
      ('Rent clocks restarted', '1 at risk · 1 due within 30 days'),
      ('Token types carried', '1'),
      ('Miner fee', '0.0011 ERG'),
      ('Argus fee', '0.0011 ERG'),
      ('Total value in', '42.001 ERG'),
      ('Value after fees', '41.9988 ERG'),
      ('New box rent', '0.13875 ERG, due ~Oct 2030'),
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
      expect(find.text(value), findsWidgets, reason: label);
    }
    await tester.ensureVisible(find.text('Sign & broadcast'));
    await tester.tap(find.text('Sign & broadcast'));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(api.consolidated, {
      'spend': ['wallet'],
      // Flagged boxes oldest first, then the address's largest ERG box.
      'ids': [id('b'), id('a'), id('c')],
      'change': 'wallet',
    });
    expect(api.submissions, 1);
    await tester.pump(const Duration(minutes: 2));
    expect(find.text('Cleanup submitted'), findsOneWidget);
  });

  testWidgets('a box a pending transaction spends is never proposed', (
    tester,
  ) async {
    // The listing leaves out box d, which a pending send already spends,
    // though rent figures for it still arrive (as a second node read would
    // have reported it). It must be neither counted nor proposed.
    final spent = listed(id('d'), value: 1000000, creation: 1400000);
    api.rows = [...rowsFor(walletBoxes), ...rowsFor([spent])];
    await open(tester);
    expect(
      find.textContaining(
        'Storage rent: 1 box at risk of collection · 1 due within 30 days.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('ERG-only box'), findsNothing);
    await tester.tap(find.text('Review cleanup'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Sign & broadcast'));
    await tester.tap(find.text('Sign & broadcast'));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(api.consolidated!['ids'], [id('b'), id('a'), id('c')]);
    await tester.pump(const Duration(minutes: 2));
  });

  testWidgets('a box still confirming is never part of a suggested cleanup', (
    tester,
  ) async {
    // With unconfirmed spending allowed the listing offers an incoming
    // payment still in the mempool. It is the largest ERG-only box, yet the
    // cleanup is funded by the largest confirmed one.
    final arriving = listed(
      id('e'),
      value: 90000000000,
      creation: tip,
      confirmed: false,
    );
    api.listing = (_) => [...walletBoxes, arriving];
    api.rows = rowsFor([...walletBoxes, arriving]);
    await open(tester, openCleanup: true);
    expect(find.text('Boxes merged'), findsOneWidget);
    await tester.ensureVisible(find.text('Sign & broadcast'));
    await tester.tap(find.text('Sign & broadcast'));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(api.consolidated!['ids'], [id('b'), id('a'), id('c')]);
    expect(api.consolidated!['ids'], isNot(contains(id('e'))));
    await tester.pump(const Duration(minutes: 2));
  });

  testWidgets('ERG-only dust rent would take whole is said quietly', (
    tester,
  ) async {
    final dust = listed(id('d'), value: 50000000, creation: 1500000);
    api.listing = (_) => [...walletBoxes, dust];
    api.rows = rowsFor([...walletBoxes, dust]);
    await open(tester);
    // Only the token box is "at risk"; the dust is counted on its own.
    expect(
      find.textContaining(
        'Storage rent: 1 box at risk of collection · 1 due within 30 days. '
        '1 ERG-only box is worth no more than its rent, which would take it '
        'whole.',
      ),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.textContaining('Rent would take this whole box (0.05 ERG)'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.textContaining(
        'Rent would take this whole box (0.05 ERG), from block 2,551,200 (~',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('At risk'), findsOneWidget, reason: 'box a');
  });

  testWidgets('a wallet of ERG-only dust is not alarming', (tester) async {
    final dust = [
      for (final c in ['1', '2', '3'])
        listed(id(c), value: 50000000, creation: 1500000),
    ];
    api.listing = (_) => [
      ...dust,
      listed(id('c'), value: 40000000000, creation: 1800000),
    ];
    api.rows = rowsFor(api.listing('wallet'));
    await open(tester);
    expect(
      find.textContaining(
        'Storage rent: no box with tokens is at risk, and nothing else is '
        'due within 30 days. 3 ERG-only boxes are worth no more than their '
        'rent, which would take them whole.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('at risk of collection'), findsNothing);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    final summary = tester.widget<Text>(
      find.textContaining('no box with tokens is at risk'),
    );
    expect(
      summary.textSpan!.toPlainText(),
      startsWith('Storage rent: no box'),
    );
    expect(
      (summary.textSpan! as TextSpan).children!.first.style?.color,
      isNot(rustFor(tester.element(find.byType(UtxoManagementScreen)))),
      reason: 'the warning colour is for tokens at risk',
    );
  });

  testWidgets('the cleanup route opens straight into the review', (
    tester,
  ) async {
    await open(tester, openCleanup: true);
    expect(find.text('Resulting boxes'), findsOneWidget);
    expect(find.text('Sign & broadcast'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.consolidated, isNull);
    expect(find.text('Review cleanup'), findsOneWidget);
  });

  testWidgets('the cleanup route says so when there is nothing to do', (
    tester,
  ) async {
    api.rows = [];
    api.listing = (_) => walletBoxes.skip(1).toList();
    await open(tester, openCleanup: true);
    expect(find.text('Nothing to clean up right now'), findsOneWidget);
    expect(find.text('Suggested cleanup'), findsNothing);
  });

  testWidgets('a wallet fragmented across addresses is told why', (
    tester,
  ) async {
    api.rows = [];
    // One box at each of 81 addresses: fragmented, but nothing to merge
    // without linking addresses.
    api.listing = (address) => [
      listed(address.padLeft(64, '0'), value: 1000000000, creation: 1800000),
    ];
    await open(
      tester,
      openCleanup: true,
      addresses: [for (var i = 0; i < 81; i++) 'addr$i'],
    );
    expect(find.textContaining('spread over many addresses'), findsOneWidget);
    expect(find.text('Suggested cleanup'), findsNothing);
  });

  testWidgets('no cleanup is offered that would leave the tokens at risk', (
    tester,
  ) async {
    // Four NFT boxes of 0.001 ERG and nothing to fund them: the merged box
    // would hold 0.0018 ERG, still taken whole once due.
    final nfts = [
      for (final c in ['1', '2', '3', '4'])
        listed(
          id(c),
          value: 1000000,
          creation: 1500000,
          tokens: ['f$c'.padRight(64, '0')],
        ),
    ];
    api.listing = (_) => nfts;
    api.rows = rowsFor(nfts);
    await open(tester, openCleanup: true);
    expect(find.text('Suggested cleanup'), findsNothing);
    expect(find.text('Nothing to clean up right now'), findsOneWidget);
    expect(
      find.textContaining('Storage rent: 4 boxes at risk of collection.'),
      findsOneWidget,
    );
  });

  testWidgets('an unreadable node leaves the boxes usable', (tester) async {
    api.failReport = true;
    await open(tester);
    expect(find.textContaining('Storage rent unavailable'), findsOneWidget);
    expect(find.textContaining('At risk'), findsNothing);
    expect(find.text('Suggested cleanup'), findsNothing);
    expect(find.text('Consolidate'), findsOneWidget);
  });
}
