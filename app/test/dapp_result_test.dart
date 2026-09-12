import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/dapp_connector.dart';
import 'package:argus_wallet/ui/dapp_browser_screen.dart';
import 'package:argus_wallet/ui/widgets/tx_result_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class SubmitApi extends RustLibApi {
  int calls = 0;
  bool fail = false;
  @override
  Future<String> crateApiSubmitSignedTransaction({
    required String txJson,
    String? nodeUrl,
  }) async {
    calls++;
    if (fail) throw StateError('node unavailable');
    return calls.toRadixString(16).padLeft(64, '0');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'browser submit returns each ID before dismissal and serializes successes and failures',
    (tester) async {
      final api = SubmitApi();
      RustLib.initMock(api: api);
      addTearDown(RustLib.dispose);
      await tester.pumpWidget(const MaterialApp(home: DappBrowserScreen()));
      final host = tester.state(find.byType(DappBrowserScreen)) as DappHost;
      final ids = await Future.wait(List.generate(3, (_) => host.submit('{}')));
      expect(api.calls, 3);
      expect(ids.toSet(), hasLength(3));
      api.fail = true;
      await expectLater(host.submit('{}'), throwsStateError);
      await tester.pumpAndSettle();
      for (final id in ids) {
        expect(find.byType(TxResultView, skipOffstage: false), findsOneWidget);
        expect(find.text(id), findsOneWidget);
        expect(find.text('Broadcast may have failed'), findsNothing);
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
      }
      expect(find.byType(TxResultView), findsNothing);
      expect(find.text('Broadcast may have failed'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('SigmaFi'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
