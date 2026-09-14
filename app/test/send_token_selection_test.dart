import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/token_router.dart';
import 'package:argus_wallet/ui/widgets/asset_picker_sheet.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64;
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/ui/send_screen.dart';
import 'package:argus_wallet/ui/widgets/held_token_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SendApi extends RustLibApi {
  Map<String, Object?>? prepared;
  @override
  Future<BigInt> crateApiWalletRestore({
    required String encryptedSeedJson,
    String? wrapKey,
  }) async => BigInt.one;
  @override
  Future<void> crateApiWalletLock({required BigInt handleId}) async {}
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
    prepared = {
      'recipient': recipientAddress,
      'nano': amountNanoErg,
      'token': tokenId,
      'amount': tokenAmount,
      'sender': senderAddress,
      'change': changeAddress,
      'spend': spendAddresses,
    };
    throw StateError('Captured preparation; no network transaction');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final holdings = [
  TokenBalance(id: 'a', name: 'Alpha', amount: 100, decimals: 2),
  TokenBalance(id: 'b', name: 'Beta', amount: 100, decimals: 0),
  TokenBalance(id: 'c', name: 'Gamma', amount: 100, decimals: 0),
  TokenBalance(id: 'nft', name: 'Art', amount: 1, decimals: 0),
];

Future<void> mount(WidgetTester tester, {List<TokenBalance>? tokens}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1000, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: argusTheme(watchful: false),
      home: WalletArgsScope(
        args: WalletRouteArgs(
          senderAddress: 'sender',
          receiveAddress: 'sender',
          changeAddress: 'sender',
          spendableNano: 1000000000,
          tokens: tokens ?? holdings,
        ),
        child: const SendScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> open(WidgetTester tester) async {
  final button = find.widgetWithIcon(FilledButton, Icons.checklist);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> toggle(WidgetTester tester, String id) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(ValueKey('pick-$id')),
      matching: find.byType(Checkbox),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> done(WidgetTester tester) async {
  await tester.tap(find.text('Done'));
  await tester.pumpAndSettle();
}

String amount(WidgetTester tester, String id) => tester
    .widget<TextFormField>(find.byKey(ValueKey('amount-$id')))
    .controller!
    .text;

void main() {
  final api = SendApi();
  setUpAll(() => RustLib.initMock(api: api));
  tearDownAll(RustLib.dispose);

  testWidgets(
    'single held token reaches the unchanged single-send builder in base units',
    (tester) async {
      await mount(tester);
      await walletService.restoreWallet('mock', walletId: 'send-test');
      addTearDown(walletService.lock);
      const recipient = '9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8';
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Recipient address'),
        recipient,
      );
      await open(tester);
      await toggle(tester, 'a');
      await done(tester);
      await tester.enterText(find.byKey(const ValueKey('amount-a')), '0.25');
      final review = find.widgetWithText(FilledButton, 'Review');
      await tester.ensureVisible(review);
      await tester.tap(review);
      await tester.pumpAndSettle();
      expect(api.prepared, {
        'recipient': recipient,
        'nano': 1000000,
        'token': 'a',
        'amount': BigInt.from(25),
        'sender': 'sender',
        'change': 'sender',
        'spend': ['sender'],
      });
    },
  );

  testWidgets(
    'several selections survive name and ID searches and cannot duplicate',
    (tester) async {
      await mount(tester);
      await open(tester);
      await toggle(tester, 'a');
      await toggle(tester, 'b');
      final search = find.descendant(
        of: find.byType(HeldTokenPicker),
        matching: find.byType(TextField),
      );
      await tester.enterText(search, 'Gamma');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pick-a')), findsNothing);
      expect(find.text('2 selected'), findsOneWidget);
      await toggle(tester, 'c');
      await tester.enterText(search, 'nft');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pick-nft')), findsOneWidget);
      expect(find.text('3 selected'), findsOneWidget);
      await tester.enterText(search, 'a');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(
                of: find.byKey(const ValueKey('pick-a')),
                matching: find.byType(Checkbox),
              ),
            )
            .value,
        isTrue,
      );
      await toggle(tester, 'a');
      await toggle(tester, 'a');
      expect(find.text('3 selected'), findsOneWidget);
      await done(tester);
      for (final id in ['a', 'b', 'c']) {
        expect(find.byKey(ValueKey('amount-$id')), findsOneWidget);
      }
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    },
  );

  testWidgets('reopen, remove primary, retain quantities, MAX and fixed NFT', (
    tester,
  ) async {
    await mount(tester);
    await open(tester);
    await toggle(tester, 'a');
    await toggle(tester, 'b');
    await done(tester);
    await tester.enterText(find.byKey(const ValueKey('amount-a')), '0.25');
    await tester.enterText(find.byKey(const ValueKey('amount-b')), '12');
    await open(tester);
    await toggle(tester, 'c');
    await done(tester);
    expect(amount(tester, 'a'), '0.25');
    expect(amount(tester, 'b'), '12');
    await open(tester);
    await toggle(tester, 'a');
    await toggle(tester, 'nft');
    await done(tester);
    expect(amount(tester, 'b'), '12');
    expect(find.byKey(const ValueKey('amount-a')), findsNothing);
    expect(find.byKey(const ValueKey('amount-nft')), findsNothing);
    expect(find.text('Sends 1 Art · Available 1'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('amount-row-b')),
        matching: find.text('MAX'),
      ),
    );
    await tester.pumpAndSettle();
    expect(amount(tester, 'b'), '100');
    await tester.tap(find.byTooltip('Remove Art'));
    await tester.pumpAndSettle();
    expect(find.text('Sends 1 Art · Available 1'), findsNothing);
    expect(amount(tester, 'b'), '100');
    await open(tester);
    await toggle(tester, 'b');
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(amount(tester, 'b'), '100');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'large selection pages quantities without losing offscreen amounts',
    (tester) async {
      await mount(
        tester,
        tokens: List.generate(
          100,
          (i) => TokenBalance(
            id: 't$i',
            name: 'Token $i',
            amount: 100,
            decimals: 0,
          ),
        ),
      );
      await open(tester);
      expect(find.byType(Checkbox).evaluate().length, lessThan(100));
      // Commit the same set returned by the picker without 100 scrolling taps.
      final context = tester.element(find.byType(HeldTokenPicker));
      Navigator.pop(context, {for (var i = 0; i < 100; i++) 't$i'});
      await tester.pumpAndSettle();
      expect(find.text('100 tokens selected · Page 1 of 10'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('amount-t0')), '7');
      await tester.tap(find.byTooltip('Next tokens'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('amount-t0')), findsNothing);
      await tester.tap(find.byTooltip('Previous tokens'));
      await tester.pumpAndSettle();
      expect(amount(tester, 't0'), '7');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'buyable holdings are ordinary sends in the held picker; buying is separate',
    (tester) async {
      final buy = (await buyableTokens()).first;
      await mount(
        tester,
        tokens: [
          TokenBalance(
            id: buy.id,
            name: buy.name,
            amount: 100,
            decimals: buy.decimals,
          ),
        ],
      );
      await open(tester);
      await toggle(tester, buy.id);
      await done(tester);
      expect(find.byKey(ValueKey('amount-${buy.id}')), findsOneWidget);
      expect(find.text(buyAmountLabel(buy)), findsNothing);
      await tester.tap(find.byTooltip('Remove ${buy.name}'));
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .ancestor(
              of: find.text('ERG or buy and send'),
              matching: find.byType(InkWell),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<AssetPickerSheet>(find.byType(AssetPickerSheet)).held,
        isEmpty,
      );
      await tester.tap(find.text(buy.name).last);
      await tester.pumpAndSettle();
      expect(find.text(buyAmountLabel(buy)), findsOneWidget);
      expect(find.widgetWithIcon(FilledButton, Icons.checklist), findsNothing);
      expect(find.text('Add another recipient'), findsNothing);
    },
  );

  testWidgets('main selection edits preserve additional recipient state', (
    tester,
  ) async {
    await mount(tester);
    await tester.ensureVisible(find.text('Add another recipient'));
    await tester.tap(find.text('Add another recipient'));
    await tester.pumpAndSettle();
    final address = find.widgetWithText(TextFormField, 'Recipient 2 address');
    await tester.enterText(address, 'second recipient');
    final dropdown = find.byType(DropdownButtonFormField<String?>).first;
    await tester.ensureVisible(dropdown);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beta').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Beta amount'),
      '9',
    );
    await open(tester);
    await toggle(tester, 'a');
    await done(tester);
    expect(
      tester.widget<TextFormField>(address).controller!.text,
      'second recipient',
    );
    expect(
      tester
          .widget<TextFormField>(
            find.widgetWithText(TextFormField, 'Beta amount'),
          )
          .controller!
          .text,
      '9',
    );
    expect(amount(tester, 'a'), '');
    expect(tester.takeException(), isNull);
  });
}
