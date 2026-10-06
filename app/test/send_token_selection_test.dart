import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/token_router.dart';
import 'package:argus_wallet/ui/widgets/asset_picker_sheet.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64;
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/ui/send_screen.dart';
import 'package:argus_wallet/ui/confirm_transaction_sheet.dart';
import 'package:argus_wallet/ui/widgets/held_token_picker.dart';
import 'package:argus_wallet/ui/widgets/amount_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SendApi extends RustLibApi {
  Map<String, Object?>? prepared;
  String? singlePreview;
  String? multiPreview;
  int broadcasts = 0;
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
    if (singlePreview != null) return singlePreview!;
    throw StateError('Captured preparation; no network transaction');
  }

  @override
  Future<String> crateApiPrepareSendMulti({
    required BigInt handleId,
    required String senderAddress,
    required List<String> spendAddresses,
    required String changeAddress,
    required String recipientsJson,
    String? nodeUrl,
    PlatformInt64? feeNano,
    List<String>? inputBoxIds,
    String? stealthBoxesJson,
    String? babelTokenId,
  }) async {
    prepared = {
      'recipients': jsonDecode(recipientsJson),
      'sender': senderAddress,
      'change': changeAddress,
      'spend': spendAddresses,
    };
    if (multiPreview != null) return multiPreview!;
    throw StateError('Captured preparation; no network transaction');
  }

  @override
  Future<String> crateApiSendErg({
    required BigInt handleId,
    required BigInt preparationId,
  }) async {
    broadcasts++;
    throw StateError('Captured broadcast; no network transaction');
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

Future<void> mount(
  WidgetTester tester, {
  List<TokenBalance>? tokens,
  String? recipient,
}) async {
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
        child: SendScreen(initialRecipient: recipient),
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

const _clipboardPrimary = '9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8';
const _clipboardAdditional =
    '9hY16vzHmmfyVBwKeFGHvb2bMFsG94A1u7To1QWtUokACyFVENQ';
const _clipboardOther = '${_clipboardPrimary}b';

Future<void> _reviewWithClipboard(
  WidgetTester tester,
  SendApi api, {
  required String clipboard,
  bool trustedPrimary = false,
  bool additionalRecipient = true,
}) async {
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.getData') return {'text': clipboard};
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  await mount(
    tester,
    tokens: [],
    recipient: trustedPrimary ? _clipboardPrimary : null,
  );
  await walletService.restoreWallet('mock', walletId: 'send-clipboard-test');
  addTearDown(walletService.lock);
  if (!trustedPrimary) {
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Recipient address'),
      '  $_clipboardPrimary  ',
    );
    await tester.pumpAndSettle();
  }
  await tester.enterText(
    find.descendant(
      of: find.byType(AmountEntry).first,
      matching: find.byType(TextFormField),
    ),
    '0.1',
  );
  if (additionalRecipient) {
    await tester.ensureVisible(find.text('Add another recipient'));
    await tester.tap(find.text('Add another recipient'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Recipient 2 address'),
      '  $_clipboardAdditional  ',
    );
    await tester.enterText(
      find.descendant(
        of: find.byType(AmountEntry).last,
        matching: find.byType(TextFormField),
      ),
      '0.1',
    );
  }
  final preview = {
    'preparation_id': 1,
    if (additionalRecipient)
      'recipients': [
        {'address': _clipboardPrimary, 'amount_nano_erg': 100000000},
        {'address': _clipboardAdditional, 'amount_nano_erg': 100000000},
      ]
    else
      'recipient': _clipboardPrimary,
    'amount_nano_erg': additionalRecipient ? 200000000 : 100000000,
    'miner_fee': 1100000,
    'citadel_fee_nano': 1100000,
    'change_nano_erg': additionalRecipient ? 797800000 : 897800000,
    'input_count': 2,
  };
  api.singlePreview = jsonEncode(preview);
  api.multiPreview = jsonEncode(preview);
  final review = find.widgetWithText(FilledButton, 'Review');
  await tester.ensureVisible(review);
  await tester.tap(review);
  // The send remains busy while either the warning or confirmation is open.
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  expect(api.prepared, isNotNull);
  expect(api.broadcasts, 0);
  expect(tester.takeException(), isNull);
}

void main() {
  final api = SendApi();
  setUpAll(() => RustLib.initMock(api: api));
  tearDownAll(RustLib.dispose);
  setUp(() {
    api.prepared = null;
    api.singlePreview = null;
    api.multiPreview = null;
    api.broadcasts = 0;
  });

  for (final clipboard in [_clipboardPrimary, _clipboardAdditional]) {
    testWidgets(
      'multi-recipient clipboard match ${clipboard == _clipboardPrimary ? 'primary' : 'additional'} reaches confirmation',
      (tester) async {
        await _reviewWithClipboard(tester, api, clipboard: '  $clipboard  ');
        expect(find.text('Clipboard holds another address'), findsNothing);
        final confirmation = tester.widget<ConfirmTransactionSheet>(
          find.byType(ConfirmTransactionSheet),
        );
        expect(
          confirmation.recipientAddress,
          '$_clipboardPrimary\n\n$_clipboardAdditional',
        );
        expect((api.prepared!['recipients'] as List).map((r) => r['address']), [
          _clipboardPrimary,
          _clipboardAdditional,
        ]);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(api.broadcasts, 0);
      },
    );
  }

  for (final trustedPrimary in [false, true]) {
    testWidgets(
      'multi-recipient clipboard mismatch warns with ${trustedPrimary ? 'trusted' : 'typed'} primary',
      (tester) async {
        await _reviewWithClipboard(
          tester,
          api,
          clipboard: _clipboardOther,
          trustedPrimary: trustedPrimary,
        );
        expect(find.text('Clipboard holds another address'), findsOneWidget);
        expect(find.byType(ConfirmTransactionSheet), findsNothing);
        await tester.tap(find.text('Go back'));
        await tester.pumpAndSettle();
        expect(find.byType(ConfirmTransactionSheet), findsNothing);
        expect(api.broadcasts, 0);
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Review'))
              .onPressed,
          isNotNull,
        );
      },
    );
  }

  testWidgets(
    'single typed recipient still warns for another clipboard address',
    (tester) async {
      await _reviewWithClipboard(
        tester,
        api,
        clipboard: _clipboardOther,
        additionalRecipient: false,
      );
      expect(find.text('Clipboard holds another address'), findsOneWidget);
      expect(find.byType(ConfirmTransactionSheet), findsNothing);
      await tester.tap(find.text('Go back'));
      await tester.pumpAndSettle();
      expect(api.broadcasts, 0);
    },
  );

  testWidgets('single trusted recipient keeps the clipboard bypass', (
    tester,
  ) async {
    await _reviewWithClipboard(
      tester,
      api,
      clipboard: _clipboardOther,
      trustedPrimary: true,
      additionalRecipient: false,
    );
    expect(find.text('Clipboard holds another address'), findsNothing);
    expect(find.byType(ConfirmTransactionSheet), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.broadcasts, 0);
  });

  testWidgets(
    'backend multi-token preview without single recipient reaches confirmation',
    (tester) async {
      const recipient = '9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8';
      await mount(tester, recipient: recipient);
      await walletService.restoreWallet('mock', walletId: 'send-test');
      addTearDown(walletService.lock);
      api.multiPreview = jsonEncode({
        'preparation_id': 1,
        'recipients': [
          {
            'address': recipient,
            'amount_nano_erg': 2000000,
            'tokens': [
              {'token_id': 'a', 'amount': 25},
              {'token_id': 'nft', 'amount': 1},
            ],
          },
        ],
        'amount_nano_erg': 2000000,
        'miner_fee': 1100000,
        'citadel_fee_nano': 1100000,
        'change_nano_erg': 995800000,
        'input_count': 2,
      });
      await open(tester);
      await toggle(tester, 'a');
      await toggle(tester, 'nft');
      await done(tester);
      await tester.enterText(find.byKey(const ValueKey('amount-a')), '0.25');
      final review = find.widgetWithText(FilledButton, 'Review');
      await tester.ensureVisible(review);
      await tester.tap(review);
      // The send button remains busy while confirmation is open.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final confirmation = tester.widget<ConfirmTransactionSheet>(
        find.byType(ConfirmTransactionSheet),
      );
      expect(confirmation.recipientAddress, recipient);
      expect(confirmation.rows.first.value, '0.002 ERG + 0.25 Alpha + 1 Art');
      expect(
        confirmation.rows.firstWhere((r) => r.label == 'Total sent').value,
        '0.002 ERG',
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('two held tokens reach the multi builder with exact amounts', (
    tester,
  ) async {
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
    await toggle(tester, 'nft');
    await done(tester);
    await tester.enterText(find.byKey(const ValueKey('amount-a')), '0.25');
    final review = find.widgetWithText(FilledButton, 'Review');
    await tester.ensureVisible(review);
    await tester.tap(review);
    await tester.pumpAndSettle();
    expect(api.prepared, {
      'recipients': [
        {
          'address': recipient,
          'amount_nano_erg': 1000000,
          'tokens': [
            {'token_id': 'a', 'amount': 25},
            {'token_id': 'nft', 'amount': 1},
          ],
        },
      ],
      'sender': 'sender',
      'change': 'sender',
      'spend': ['sender'],
    });
  });

  testWidgets(
    'additional NFT recipient needs neither token quantity nor ERG entry',
    (tester) async {
      await mount(tester);
      await walletService.restoreWallet('mock', walletId: 'send-test');
      addTearDown(walletService.lock);
      const recipient = '9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8';
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Recipient address'),
        recipient,
      );
      await tester.pumpAndSettle();
      final mainAmount = find.descendant(
        of: find.byType(AmountEntry).first,
        matching: find.byType(TextFormField),
      );
      await tester.ensureVisible(mainAmount);
      await tester.tap(mainAmount);
      await tester.enterText(mainAmount, '0.1');
      await tester.ensureVisible(find.text('Add another recipient'));
      await tester.tap(find.text('Add another recipient'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Recipient 2 address'),
        recipient,
      );
      final dropdown = find.byType(DropdownButtonFormField<String?>).first;
      await tester.ensureVisible(dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Art').last);
      await tester.pumpAndSettle();
      expect(find.text('Sends 1 Art · Available 1'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Art amount'), findsNothing);
      final review = find.widgetWithText(FilledButton, 'Review');
      await tester.ensureVisible(review);
      await tester.tap(review);
      await tester.pumpAndSettle();
      expect(api.prepared, isNotNull);
      expect((api.prepared!['recipients'] as List).last, {
        'address': recipient,
        'amount_nano_erg': 1000000,
        'tokens': [
          {'token_id': 'nft', 'amount': 1},
        ],
        'token_id': 'nft',
        'token_amount': 1,
      });
    },
  );

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
