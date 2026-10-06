import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/ui/send_screen.dart';
import 'package:argus_wallet/ui/widgets/amount_entry.dart';
import 'package:argus_wallet/ui/widgets/rent_hint.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const recipient = '9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8';
const second = '9hY16vzHmmfyVBwKeFGHvb2bMFsG94A1u7To1QWtUokACyFVENQ';

/// The wallet core's answers for a P2PK box with one token at 1.25 mERG per
/// byte (`wallet_core::rent` tests): 110 bytes below 2^21 nanoERG, 111 at
/// the suggested 0.14 ERG, so 0.1375 or 0.13875 ERG of rent.
class RentSendApi extends RustLibApi {
  final estimates = <Map<String, Object?>>[];
  Map<String, Object?>? prepared;

  @override
  Future<BigInt> crateApiWalletRestore({
    required String encryptedSeedJson,
    String? wrapKey,
  }) async => BigInt.one;
  @override
  Future<void> crateApiWalletLock({required BigInt handleId}) async {}

  @override
  Future<String> crateApiStorageRentRentParameters({String? nodeUrl}) async =>
      jsonEncode({
        'height': 1600000,
        'storage_fee_factor': 1250000,
        'factor_from_node': true,
      });

  @override
  String crateApiStorageRentOutputRentEstimate({
    required String address,
    required PlatformInt64 valueNano,
    required String tokensJson,
    required int height,
    required int storageFeeFactor,
  }) {
    estimates.add({
      'address': address,
      'value': valueNano,
      'tokens': jsonDecode(tokensJson),
    });
    final size = valueNano >= 2097152 ? 111 : 110;
    final fee = size * storageFeeFactor;
    return jsonEncode({
      'value_nano_erg': valueNano,
      'due_height': height + 1051200,
      'suggested_nano_erg': 140000000,
      'boxes': [
        {
          'value_nano': valueNano,
          'token_count': 1,
          'size_bytes': size,
          'fee_nano': fee,
          'charge': valueNano > fee ? 'fee' : 'whole_box',
        },
      ],
    });
  }

  @override
  Future<String> crateApiPrepareSend({
    required BigInt handleId,
    required String senderAddress,
    required List<String> spendAddresses,
    required String changeAddress,
    required String recipientAddress,
    required PlatformInt64 amountNanoErg,
    String? tokenId,
    BigInt? tokenAmount,
    String? nodeUrl,
    PlatformInt64? feeNano,
    List<String>? inputBoxIds,
    String? stealthBoxesJson,
    String? babelTokenId,
  }) async {
    prepared = {'nano': amountNanoErg, 'token': tokenId};
    throw StateError('Captured preparation; no network transaction');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final holdings = [
  TokenBalance(id: 'a' * 64, name: 'Alpha', amount: 1000, decimals: 2),
  TokenBalance(id: 'f' * 64, name: 'Art', amount: 1, decimals: 0),
];

void main() {
  final api = RentSendApi();
  setUpAll(() => RustLib.initMock(api: api));
  tearDownAll(RustLib.dispose);
  setUp(() {
    api.estimates.clear();
    api.prepared = null;
  });

  Future<void> mount(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: argusTheme(watchful: false),
        home: WalletArgsScope(
          args: WalletRouteArgs(
            senderAddress: second,
            receiveAddress: second,
            changeAddress: second,
            spendableNano: 5000000000,
            tokens: holdings,
          ),
          child: const SendScreen(initialRecipient: recipient),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pick(WidgetTester tester, String id) async {
    final button = find.widgetWithIcon(FilledButton, Icons.checklist);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(ValueKey('pick-$id')),
        matching: find.byType(Checkbox),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
  }

  TextEditingController ergField(WidgetTester tester, {int index = 0}) => tester
      .widget<TextField>(
        find.descendant(
          of: find.byType(AmountEntry).at(index),
          matching: find.byType(TextField),
        ),
      )
      .controller!;

  testWidgets('an NFT send suggests ERG that covers the rent, one tap', (
    tester,
  ) async {
    await mount(tester);
    expect(find.byType(RentHint), findsNothing, reason: 'no tokens yet');
    await pick(tester, 'f' * 64);
    expect(find.byType(RentHint), findsOneWidget);
    expect(api.estimates.last, {
      'address': recipient,
      'value': 1000000,
      'tokens': [
        {'token_id': 'f' * 64, 'amount': 1},
      ],
    });
    expect(
      find.textContaining('about 0.1375 ERG for this 110-byte box.'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'A box holding less can be collected whole, tokens included.',
      ),
      findsOneWidget,
    );
    expect(find.text('Suggested 0.14 ERG'), findsOneWidget);

    await tester.ensureVisible(find.text('Use suggested'));
    await tester.tap(find.text('Use suggested'));
    await tester.pumpAndSettle();
    expect(ergField(tester).text, '0.14');
    expect(find.textContaining('This amount covers it.'), findsOneWidget);
    expect(find.text('Use suggested'), findsNothing);
  });

  testWidgets('a lower amount stays the user\'s choice', (tester) async {
    await mount(tester);
    await walletService.restoreWallet('mock', walletId: 'rent-hint-test');
    addTearDown(walletService.lock);
    await pick(tester, 'f' * 64);
    await tester.enterText(
      find.descendant(
        of: find.byType(AmountEntry).first,
        matching: find.byType(TextFormField),
      ),
      '0.001',
    );
    await tester.pumpAndSettle();
    expect(find.text('Use suggested'), findsOneWidget);
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': recipient};
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final review = find.widgetWithText(FilledButton, 'Review');
    await tester.ensureVisible(review);
    await tester.tap(review);
    await tester.pumpAndSettle();
    expect(api.prepared, {'nano': 1000000, 'token': 'f' * 64});
  });

  testWidgets('every token-carrying recipient gets its own hint', (
    tester,
  ) async {
    await mount(tester);
    await tester.ensureVisible(find.text('Add another recipient'));
    await tester.tap(find.text('Add another recipient'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Recipient 2 address'),
      second,
    );
    expect(find.byType(RentHint), findsNothing);
    final dropdown = find.byType(DropdownButtonFormField<String?>).first;
    await tester.ensureVisible(dropdown);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alpha').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Alpha amount'),
      '2.5',
    );
    await tester.pumpAndSettle();
    expect(find.byType(RentHint), findsOneWidget);
    expect(api.estimates.last['address'], second);
    expect(api.estimates.last['tokens'], [
      {'token_id': 'a' * 64, 'amount': 250},
    ]);
    await tester.ensureVisible(find.text('Use suggested'));
    await tester.tap(find.text('Use suggested'));
    await tester.pumpAndSettle();
    expect(ergField(tester, index: 1).text, '0.14');
    expect(ergField(tester).text, isEmpty, reason: 'main recipient untouched');
  });
}
