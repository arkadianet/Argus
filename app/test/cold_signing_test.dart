import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:argus_wallet/services/cold_signing_service.dart';
import 'package:argus_wallet/ui/cold_signing_screen.dart';

final reviewFixture = <String, dynamic>{
  'network': 'Mainnet',
  'fee_nano': '1100000',
  'outputs': [
    {
      'address': 'FULL_RECIPIENT_ADDRESS',
      'owned': false,
      'is_fee': false,
      'nano_erg': '2000000000',
      'tokens': [
        {'id': 'FULL_TOKEN_ID', 'amount': '42'},
      ],
    },
    {
      'address': null,
      'owned': false,
      'is_fee': true,
      'nano_erg': '1100000',
      'tokens': [],
    },
  ],
  'burns': [],
  'mints': [],
};

// UI contract fake. Real wire parsing, resource bounds, duplicate conflicts and
// cryptographic verification are separately exercised in the Rust tests.
class Backend extends ColdBackend {
  final parts = <int, String>{};
  bool conflict = false;
  bool rejectVerification = false;
  bool verified = false;
  int broadcasts = 0;
  int signatures = 0;
  @override
  Future<Map<String, dynamic>> add(String session, String page) async {
    if (conflict) throw StateError('Conflicting QR pages; reset required');
    final raw = jsonDecode(page) as Map<String, dynamic>;
    final p = raw['p'] as int;
    final data = (raw['CSR'] ?? raw['CSTX']) as String;
    if (parts.containsKey(p) && parts[p] != data) {
      conflict = true;
      throw StateError('Conflicting QR pages; reset required');
    }
    parts[p] = data;
    return {
      'received': parts.length,
      'total': 3,
      'missing': [
        for (var i = 1; i <= 3; i++)
          if (!parts.containsKey(i)) i,
      ],
    };
  }

  @override
  Future<void> reset(String session) async {
    parts.clear();
    conflict = false;
    verified = false;
  }

  @override
  Future<Map<String, dynamic>> review(String session, BigInt handle) async =>
      reviewData;
  Map<String, dynamic> get reviewData => reviewFixture;
  @override
  Future<void> sign(String session, BigInt handle) async {
    signatures++;
  }

  @override
  Future<List<String>> pages(String session) async => [
    '{"CSR":"a"}',
    '{"CSR":"b"}',
    '{"CSR":"c"}',
  ];
  @override
  Future<String> verify(String session) async {
    if (rejectVerification)
      throw StateError(
        'Returned transaction does not match the prepared transaction',
      );
    verified = true;
    return 'VERIFIED_ID';
  }

  @override
  Future<String> broadcast(String session) async {
    // Count the attempt before refusing. A node cannot know whether we
    // verified, so a fake that refuses first would pass these tests with the
    // service's own guard deleted — it would be testing this class, not the
    // controller.
    broadcasts++;
    if (!verified) throw StateError('Refusing broadcast: no verified response');
    return 'VERIFIED_ID';
  }

  @override
  Future<void> discard(String session) async {}
}

String page(bool hot, int p, [String? value]) =>
    jsonEncode({hot ? 'CSTX' : 'CSR': value ?? 'part$p', 'p': p, 'n': 3});
Future<void> show(WidgetTester tester, ColdSigningController c) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ColdSigningScreen(
        controller: c,
        onDiscard: () {},
        handle: () => BigInt.one,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> press(WidgetTester tester, String text) async {
  if (find.text(text).evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      find.text(text),
      300,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await Scrollable.ensureVisible(
    tester.element(find.text(text)),
    alignment: 0.5,
  );
  await tester.pumpAndSettle();
  await Scrollable.ensureVisible(
    tester.element(find.text(text)),
    alignment: 0.5,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

void main() {
  for (final hot in [false, true]) {
    final role = hot ? 'hot response' : 'cold request';
    testWidgets(
      '$role progress, missing page, out-of-order duplicate and resume',
      (tester) async {
        final c = ColdSigningController(
          session: 's',
          hot: hot,
          backend: Backend(),
        );
        if (hot) c.scanResponse();
        await show(tester, c);
        await c.addPage(page(hot, 3));
        await c.addPage(page(hot, 1));
        await c.addPage(page(hot, 3));
        await tester.pumpAndSettle();
        expect(find.text('2 of 3 scanned'), findsOneWidget);
        expect(find.text('Missing pages: 2'), findsOneWidget);
        final label = hot ? 'Verify signed transaction' : 'Review transaction';
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, label))
              .onPressed,
          isNull,
        );
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        await show(tester, c); // returning from interrupted navigation
        expect(find.text('2 of 3 scanned'), findsOneWidget);
        await c.addPage(page(hot, 2));
        await tester.pumpAndSettle();
        expect(find.text('3 of 3 scanned'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, label))
              .onPressed,
          isNotNull,
        );
      },
    );
    testWidgets('$role conflicting page latches refusal until reset', (
      tester,
    ) async {
      final c = ColdSigningController(
        session: 's',
        hot: hot,
        backend: Backend(),
      );
      if (hot) c.scanResponse();
      await show(tester, c);
      await c.addPage(page(hot, 1));
      await c.addPage(page(hot, 1, 'other payment'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Conflicting QR pages'), findsOneWidget);
      expect(c.refused, isTrue);
      await c.addPage(page(hot, 2));
      expect(c.received, 1);
      await press(tester, 'Reset collected pages');
      expect(find.text('0 of ? scanned'), findsOneWidget);
      await c.addPage(page(hot, 2));
      expect(c.received, 1);
    });
    testWidgets('$role hostile payload offers reset and cannot finish', (
      tester,
    ) async {
      final backend = Backend();
      final c = ColdSigningController(session: 's', hot: hot, backend: backend);
      if (hot) c.scanResponse();
      await show(tester, c);
      await c.addPage('{"CSR":');
      await tester.pumpAndSettle();
      expect(find.textContaining('Refused:'), findsOneWidget);
      expect(c.complete, isFalse);
      await c.finish(BigInt.one);
      await c.broadcast();
      expect(backend.broadcasts, 0);
      expect(backend.signatures, 0);
    });
  }
  testWidgets('verification failure never offers or invokes broadcast', (
    tester,
  ) async {
    final backend = Backend()..rejectVerification = true;
    final c = ColdSigningController(session: 's', hot: true, backend: backend)
      ..scanResponse();
    await show(tester, c);
    for (var i = 1; i <= 3; i++) {
      await c.addPage(page(true, i));
    }
    await tester.pumpAndSettle();
    await press(tester, 'Verify signed transaction');
    expect(find.textContaining('does not match'), findsOneWidget);
    expect(find.text('Broadcast verified transaction'), findsNothing);
    await c.broadcast();
    expect(backend.broadcasts, 0);
    expect(c.transactionId, isNull);
  });
  testWidgets(
    'cold review discloses outputs, token units and fee before explicit signing',
    (tester) async {
      final backend = Backend();
      final c = ColdSigningController(
        session: 's',
        hot: false,
        backend: backend,
      );
      await show(tester, c);
      for (var i = 1; i <= 3; i++) {
        await c.addPage(page(false, i));
      }
      await c.finish(BigInt.one);
      await tester.pumpAndSettle();
      expect(find.text('FULL_RECIPIENT_ADDRESS'), findsOneWidget);
      expect(find.text('Token ID: FULL_TOKEN_ID'), findsOneWidget);
      expect(find.text('Quantity: 42 base units'), findsOneWidget);
      expect(find.text('Miner fee: 0.001100000 ERG'), findsOneWidget);
      expect(backend.signatures, 0);
      await tester.scrollUntilVisible(
        find.text('Confirm and sign offline'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Confirm and sign offline'),
            )
            .onPressed,
        isNull,
      );
      await press(
        tester,
        'I checked every output, token and fee on this device',
      );
      await press(tester, 'Confirm and sign offline');
      expect(backend.signatures, 1);
      expect(c.stage, ColdStage.responseQr);
    },
  );
  testWidgets('hot sequence returns only verified transaction to broadcast', (
    tester,
  ) async {
    final backend = Backend();
    final c = ColdSigningController(
      session: 's',
      hot: true,
      backend: backend,
      reviewData: reviewFixture,
    );
    await show(tester, c);
    expect(find.text('Code 1 of 3'), findsOneWidget);
    await press(tester, 'Next');
    expect(find.text('Code 2 of 3'), findsOneWidget);
    await press(tester, 'Scan signed response');
    for (var i = 1; i <= 3; i++) {
      await c.addPage(page(true, i));
    }
    await tester.pumpAndSettle();
    await press(tester, 'Verify signed transaction');
    await press(tester, 'Broadcast verified transaction');
    expect(backend.broadcasts, 1);
    expect(c.stage, ColdStage.broadcast);
  });
  testWidgets('QR sequence can pause and repeat in either direction', (
    tester,
  ) async {
    for (final key in ['CSR', 'CSTX']) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ColdQrSequence(
              key: ValueKey(key),
              pages: ['{"$key":"a"}', '{"$key":"b"}'],
            ),
          ),
        ),
      );
      expect(find.text('Code 1 of 2'), findsOneWidget);
      await tester.tap(find.text('Previous'));
      await tester.pump();
      expect(find.text('Code 2 of 2'), findsOneWidget);
      await tester.tap(find.text('Auto-repeat'));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Code 1 of 2'), findsOneWidget);
      await tester.tap(find.text('Pause'));
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('Code 1 of 2'), findsOneWidget);
    }
  });
}
