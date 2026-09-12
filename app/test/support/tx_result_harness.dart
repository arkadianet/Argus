import 'package:argus_wallet/services/network_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const resultTxId =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

/// Intercepts platform actions; no browser or real clipboard is used.
class TxResultHarness {
  String? copied;
  String? launched;
  Map<dynamic, dynamic>? launchArguments;

  TxResultHarness(WidgetTester tester) {
    final messenger = tester.binding.defaultBinaryMessenger;
    final previousExplorer = networkController.explorer;
    networkController.explorer = 'https://api.sigmaspace.io';
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'launch') {
        launchArguments = call.arguments as Map;
        launched = launchArguments!['url'] as String;
      }
      return true;
    });
    addTearDown(() {
      networkController.explorer = previousExplorer;
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      messenger.setMockMethodCallHandler(channel, null);
    });
  }

  Future<void> verifyReceipt(WidgetTester tester) async {
    expect(
      find.byWidgetPredicate(
        (w) => w is SelectableText && w.data == resultTxId,
      ),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('Copy id'));
    await tester.tap(find.text('Copy id'));
    await tester.pump();
    expect(copied, resultTxId);
    await tester.ensureVisible(find.text('View on explorer'));
    await tester.tap(find.text('View on explorer'));
    await tester.pump();
    expect(launched, 'https://sigmaspace.io/en/transaction/$resultTxId');
    expect(tester.takeException(), isNull);
  }
}
