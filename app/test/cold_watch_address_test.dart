import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/cold_signing_service.dart';
import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/ui/cold_signing_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class AddressApi extends RustLibApi {
  String? preparedAddress;
  BigInt? preparedTokenAmount;
  @override
  Future<void> crateApiInitApp() async {}
  @override
  Future<String> crateApiColdPrepareAddress({
    required String address,
    required String recipient,
    required int amountNano,
    String? tokenId,
    BigInt? tokenAmount,
    required String nodeUrl,
  }) async {
    preparedAddress = address;
    preparedTokenAmount = tokenAmount;
    return jsonEncode({
      'session': 'address-session',
      'review': {
        'network': 'Mainnet',
        'fee_nano': '1100000',
        'outputs': [],
        'burns': [],
        'mints': [],
      },
    });
  }

  @override
  Future<List<String>> crateApiColdQrPages({
    required String session,
    required bool lowDensity,
  }) async => ['request'];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final api = AddressApi();
  setUpAll(() => RustLib.initMock(api: api));
  for (final withToken in [false, true]) {
    testWidgets(
      'single address prepares ${withToken ? 'token' : 'ERG'} send without account or seed',
      (tester) async {
        final oldNode = networkController.activeUrl;
        networkController.activeUrl = 'node';
        addTearDown(() {
          networkController.activeUrl = oldNode;
          pendingColdSends.clear();
        });
        await tester.pumpWidget(
          const MaterialApp(
            home: ColdWatchSendScreen.address(address: 'watched'),
          ),
        );
        expect(
          find.textContaining(
            'Change, including remaining tokens, returns to this same watched address',
          ),
          findsOneWidget,
        );
        await tester.enterText(find.byType(TextField).at(0), 'recipient');
        await tester.enterText(find.byType(TextField).at(1), '2000000');
        if (withToken) {
          await tester.enterText(find.byType(TextField).at(2), 'ab' * 32);
          await tester.enterText(find.byType(TextField).at(3), '12');
        }
        await tester.ensureVisible(find.text('Prepare cold request'));
        await tester.tap(find.text('Prepare cold request'));
        await tester.pumpAndSettle();
        expect(api.preparedAddress, 'watched');
        expect(api.preparedTokenAmount, withToken ? BigInt.from(12) : null);
        expect(find.byType(ColdSigningScreen), findsOneWidget);
        expect(pendingColdSends['address:watched']!.stage, ColdStage.requestQr);
        expect(find.text('Broadcast verified transaction'), findsNothing);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('Resume cold send'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
