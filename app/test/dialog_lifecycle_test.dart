import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/format.dart';
import 'package:argus_wallet/services/address_label_service.dart';
import 'package:argus_wallet/services/contacts_service.dart';
import 'package:argus_wallet/services/stealth_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/ui/contacts_screen.dart';
import 'package:argus_wallet/ui/receive_screen.dart';
import 'package:argus_wallet/ui/send_screen.dart';
import 'package:argus_wallet/ui/settings/security_settings_page.dart';
import 'package:argus_wallet/ui/settings/settings_shared.dart';
import 'package:argus_wallet/ui/settings/wallet_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/dialog_harness.dart';

// Every dialog outside the home screen that asks for text or a PIN, opened
// from where the app opens it, answered both ways, and pumped through its
// exit animation (see support/dialog_harness.dart). The home screen's own
// are in dialog_lifecycle_home_test.dart.

const _ergo = '9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8';
const _ergoOld = '9hY16vzHmmfyVBwKeFGHvb2bMFsG94A1u7To1QWtUokACyFVENQ';

void main() {
  final api = DialogApi();
  setUpAll(() => RustLib.initMock(api: api));

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'argus_contacts': '[]',
      'argus_address_labels': '[]',
    });
    await contactsService.load();
    await addressLabelService.load();
    stealthService.reset();
    stealthService.scanEnabled = false;
    api.wrappedUnder.clear();
  });

  tearDown(() async {
    stealthService.scanEnabled = true;
    stealthService.reset();
    if (walletService.isUnlocked) await walletService.lock();
  });

  /// The wallet unlocked, as Settings and adding a stealth address need.
  Future<DialogKeystore> unlocked(WidgetTester tester) async {
    final keystore = DialogKeystore()..install(tester);
    await walletService.restoreWallet('', walletId: dialogWallet);
    return keystore;
  }

  group('Security', () {
    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: SecuritySettingsPage(walletId: dialogWallet)),
      );
      await tester.pumpAndSettle();
    }

    Finder biometricSwitch() => find.descendant(
      of: find.widgetWithText(SettingsRow, 'Biometric unlock'),
      matching: find.byType(Switch),
    );

    testWidgets('Confirm PIN is as tall as its field, not the screen', (
      tester,
    ) async {
      tallView(tester, size: const Size(390, 844));
      await unlocked(tester);
      await open(tester);
      await tester.tap(biometricSwitch());
      await tester.pumpAndSettle();

      // The dialog's surface; the Dialog widget itself fills the screen.
      final surface = find
          .descendant(of: find.byType(Dialog), matching: find.byType(Material))
          .first;
      final height = tester.getSize(surface).height;
      expect(
        height,
        lessThan(844 / 2),
        reason: 'one PIN field and two buttons, stretched to $height',
      );
      await answer(tester, 'Cancel');
    });

    testWidgets('Confirm PIN (biometric unlock): Cancel, then Continue', (
      tester,
    ) async {
      tallView(tester);
      final keystore = await unlocked(tester);
      await open(tester);

      await tester.tap(biometricSwitch());
      await tester.pumpAndSettle();
      await tester.enterText(dialogField('PIN'), api.goodPin);
      await answer(tester, 'Cancel');
      expect(keystore.writes, isEmpty);
      expect(tester.widget<Switch>(biometricSwitch()).value, isFalse);

      await tester.tap(biometricSwitch());
      await tester.pumpAndSettle();
      await tester.enterText(dialogField('PIN'), api.goodPin);
      await answer(tester, 'Continue');
      expect(keystore.writes, ['saveWrapKey']);
      expect(tester.widget<Switch>(biometricSwitch()).value, isTrue);
      expect(find.text('Biometric unlock enabled'), findsOneWidget);
    });

    testWidgets('Change PIN: Cancel, then Change', (tester) async {
      tallView(tester);
      final keystore = await unlocked(tester);
      await open(tester);

      Future<void> fill() async {
        await tester.tap(find.widgetWithText(SettingsRow, 'Change PIN'));
        await tester.pumpAndSettle();
        await tester.enterText(dialogField('Current PIN'), api.goodPin);
        await tester.enterText(dialogField('New PIN'), '654321');
        await tester.enterText(dialogField('Confirm PIN'), '654321');
      }

      await fill();
      await answer(tester, 'Cancel');
      expect(api.wrappedUnder, isEmpty);
      expect(keystore.writes, isEmpty);

      await fill();
      await answer(tester, 'Change');
      expect(api.wrappedUnder, ['654321']);
      expect(keystore.writes, ['savePinWrap']);
      expect(find.text('PIN changed'), findsOneWidget);
    });

    testWidgets('Rename stealth address: Cancel, then Save', (tester) async {
      tallView(tester);
      await unlocked(tester);
      await open(tester);
      final row = find.widgetWithIcon(SettingsRow, Icons.alternate_email);

      await tester.tap(row);
      await tester.pumpAndSettle();
      await tester.enterText(dialogField(), 'Tips');
      await answer(tester, 'Cancel');
      expect(stealthService.identities.single.label, '');

      await tester.tap(row);
      await tester.pumpAndSettle();
      await tester.enterText(dialogField(), 'Tips');
      await answer(tester, 'Save');
      expect(stealthService.identities.single.label, 'Tips');
      expect(find.widgetWithText(SettingsRow, 'Tips'), findsOneWidget);
    });
  });

  group('Receive', () {
    Widget receive() => const MaterialApp(
      home: WalletArgsScope(
        args: WalletRouteArgs(
          senderAddress: _ergo,
          receiveAddress: _ergo,
          changeAddress: _ergo,
          historyAddresses: [_ergo, _ergoOld],
        ),
        child: ReceiveScreen(),
      ),
    );

    testWidgets('Address label (a used address): Cancel, then Save', (
      tester,
    ) async {
      tallView(tester);
      await tester.pumpWidget(receive());
      await tester.pumpAndSettle();
      final row = find.text(shorten(_ergoOld, head: 12, tail: 10));

      await tester.longPress(row);
      await tester.pumpAndSettle();
      await tester.enterText(dialogField(), 'Cold storage');
      await answer(tester, 'Cancel');
      expect(addressLabelService.labelFor(_ergoOld), isNull);

      await tester.longPress(row);
      await tester.pumpAndSettle();
      await tester.enterText(dialogField(), 'Cold storage');
      await answer(tester, 'Save');
      expect(addressLabelService.labelFor(_ergoOld), 'Cold storage');
      expect(find.text('Cold storage'), findsOneWidget);
    });

    testWidgets('Add stealth address: Cancel, then Add', (tester) async {
      tallView(tester);
      await unlocked(tester);
      stealthService.address = stealthAddress0;
      await tester.pumpWidget(receive());
      await tester.pumpAndSettle();
      final add = find.byKey(const Key('stealth-identity-add'));
      final field = find.byKey(const Key('stealth-identity-label-field'));

      await tester.tap(add);
      await tester.pumpAndSettle();
      await tester.enterText(field, 'Donations');
      await answer(tester, 'Cancel');
      expect(stealthService.identities, hasLength(1));

      await tester.tap(add);
      await tester.pumpAndSettle();
      await tester.enterText(field, 'Donations');
      await answer(tester, 'Add');
      expect(stealthService.identities.map((i) => i.label), ['', 'Donations']);
      expect(find.text(stealthAddress1), findsOneWidget);
    });
  });

  testWidgets('Save to contacts (Send): Cancel, then Save', (tester) async {
    tallView(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: argusTheme(watchful: false),
        home: const WalletArgsScope(
          args: WalletRouteArgs(
            senderAddress: _ergoOld,
            receiveAddress: _ergoOld,
            changeAddress: _ergoOld,
            spendableNano: 5000000000,
          ),
          child: SendScreen(initialRecipient: _ergo),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final save = find.text('Save to contacts');

    await tester.tap(save);
    await tester.pumpAndSettle();
    await tester.enterText(dialogField(), 'Alice');
    await answer(tester, 'Cancel');
    expect(contactsService.contacts, isEmpty);

    await tester.tap(save);
    await tester.pumpAndSettle();
    await tester.enterText(dialogField(), 'Alice');
    await answer(tester, 'Save');
    expect(contactsService.contacts.single.name, 'Alice');
    expect(contactsService.contacts.single.address, _ergo);
    expect(find.text('Contact saved'), findsOneWidget);
  });

  testWidgets('Pin address index (wallet settings): Cancel, then Pin', (
    tester,
  ) async {
    tallView(tester);
    await unlocked(tester);
    await tester.pumpWidget(
      const MaterialApp(
        home: WalletSettingsPage(walletId: dialogWallet, walletName: 'Daily'),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.widgetWithText(SettingsRow, 'Primary address: index 0');

    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.enterText(dialogField(), '3');
    await answer(tester, 'Cancel');
    expect(await walletService.getPinnedAddressIndex(walletId: dialogWallet), 0);

    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.enterText(dialogField(), '3');
    await answer(tester, 'Pin');
    expect(await walletService.getPinnedAddressIndex(walletId: dialogWallet), 3);
    expect(find.text('Primary address: index #3'), findsOneWidget);
    expect(find.text('Pinned index 3 · addr3'), findsOneWidget);
  });

  testWidgets('Add contact and Edit contact: Cancel, then save each', (
    tester,
  ) async {
    tallView(tester);
    await tester.pumpWidget(const MaterialApp(home: ContactsScreen()));
    await tester.pumpAndSettle();

    Future<void> add() async {
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(dialogField('Name'), 'Bob');
      await tester.enterText(dialogField('Address'), _ergo);
    }

    await add();
    await answer(tester, 'Cancel');
    expect(contactsService.contacts, isEmpty);

    await add();
    await answer(tester, 'Add');
    expect(contactsService.contacts.single.name, 'Bob');

    Future<void> edit() async {
      await tester.tap(find.text(contactsService.contacts.single.name));
      await tester.pumpAndSettle();
      expect(find.text('Edit contact'), findsOneWidget);
      await tester.enterText(dialogField('Name'), 'Robert');
    }

    await edit();
    await answer(tester, 'Cancel');
    expect(contactsService.contacts.single.name, 'Bob');

    await edit();
    await answer(tester, 'Save');
    expect(contactsService.contacts.single.name, 'Robert');
    expect(find.text('Robert'), findsOneWidget);
  });
}
