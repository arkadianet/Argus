import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'home_harness.dart';

// Opening a dialog from where the app opens it, answering it, and pumping
// until it has finished animating out.
//
// Dialogs that ask for text or a PIN used to take TextEditingControllers
// from their caller, who disposed them as soon as `showDialog` returned. That
// future completes when the dialog is popped, not when it is gone: for the
// length of the exit animation the fields were still on screen, and the
// first rebuild (the field losing focus as its route closes is enough) used
// a disposed controller. In a debug build that is the red
// "'_dependents.isEmpty': is not true" screen; [answer] fails on it.

const dialogWallet = 'dialogs';
const stealthAddress0 =
    'stealth2Zc5nJHNTZmnKSyfnCsQrkVW42s9dhoNUmm5bxLrDBnwuGSaSQ';
const stealthAddress1 =
    'stealth7pKv2xPsEjeNd2v68sbKxjxP2p63A8MwcrXhh6LAq945wfPo5Z';

/// The home stand-in, plus re-wrapping a key under a new PIN and the
/// stealth identity calls.
class DialogApi extends HomeApi {
  /// Every PIN a key was wrapped under.
  final wrappedUnder = <String>[];

  @override
  Future<String> crateApiWrapKeyWithPin({
    required String wrapKeyHex,
    required String pin,
  }) async {
    wrappedUnder.add(pin);
    return '{"pin":"$pin"}';
  }

  @override
  Future<int> crateApiStealthUseIdentity({
    required BigInt handleId,
    required int index,
  }) async => index + 1;

  @override
  Future<String> crateApiStealthAddressAt({
    required BigInt handleId,
    required int index,
  }) async => index == 0 ? stealthAddress0 : stealthAddress1;
}

/// The platform keystore for [dialogWallet], recording what was written.
class DialogKeystore {
  DialogKeystore({this.pin = true, this.wrapKey = false});

  /// A PIN-wrapped key is stored.
  bool pin;

  /// A biometric copy of the key is stored (or, with no [pin], the key a
  /// wallet from before PINs unlocks with).
  bool wrapKey;
  final writes = <String>[];

  void install(WidgetTester tester) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureStorageChannel, (call) async {
      switch (call.method) {
        case 'listWalletIds':
          return [dialogWallet];
        case 'hasEncryptedSeed':
          return true;
        case 'hasPinWrap':
          return pin;
        case 'hasBiometric':
          return true;
        case 'hasWrapKey':
          return wrapKey;
        case 'loadEncryptedSeed':
          return '{"v":2}';
        case 'loadPinWrap':
          return pin ? '{"pin":"wrap"}' : null;
        case 'loadWrapKey':
          return wrapKey ? 'legacy-wrap' : null;
        case 'loadPinGate':
          return {'count': 0, 'until': 0};
        case 'saveWrapKey':
          writes.add(call.method);
          wrapKey = true;
          return null;
        case 'savePinWrap':
          writes.add(call.method);
          pin = true;
          return null;
        case 'deleteWrapKey':
          writes.add(call.method);
          wrapKey = false;
          return null;
        default:
          return null;
      }
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(secureStorageChannel, null),
    );
  }
}

Finder inDialog(Finder finder) =>
    find.descendant(of: find.byType(AlertDialog), matching: finder);

/// The open dialog's text field, or the one labelled [label].
Finder dialogField([String? label]) => inDialog(
  label == null
      ? find.byType(TextField)
      : find.widgetWithText(TextField, label),
);

/// Taps [button] in the open dialog and pumps until the dialog has finished
/// animating out. Anything thrown on the way fails the test here, which is
/// where a field whose controller was already disposed throws.
Future<void> answer(WidgetTester tester, String button) async {
  await tester.tap(inDialog(find.text(button)));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  expect(find.byType(AlertDialog), findsNothing);
}

/// A view tall enough that a settings page needs no scrolling.
void tallView(WidgetTester tester, {Size size = const Size(420, 2400)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}
