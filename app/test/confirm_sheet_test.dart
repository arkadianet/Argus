import 'package:argus_wallet/ui/confirm_transaction_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Future<ConfirmChoice> Function(BuildContext) open, void Function(ConfirmChoice) onResult) {
  return MaterialApp(
    home: Builder(
      builder: (ctx) => TextButton(
        onPressed: () async => onResult(await open(ctx)),
        child: const Text('open'),
      ),
    ),
  );
}

void main() {
  testWidgets('sign-only action resolves to ConfirmChoice.signOnly', (tester) async {
    ConfirmChoice? result;
    await tester.pumpWidget(_host(
      (ctx) => showConfirmTransactionChoice(
        ctx,
        title: 'Confirm send',
        rows: const [ConfirmTxRow('Amount', '1 ERG')],
        recipientAddress: '9abc',
        allowSignOnly: true,
      ),
      (r) => result = r,
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('9abc'), findsOneWidget);
    await tester.tap(find.text('Sign only'));
    await tester.pumpAndSettle();

    expect(result, ConfirmChoice.signOnly);
  });

  testWidgets('dismissing the sheet resolves to cancel', (tester) async {
    ConfirmChoice? result;
    await tester.pumpWidget(_host(
      (ctx) => showConfirmTransactionChoice(
        ctx,
        title: 'Confirm send',
        rows: const [],
      ),
      (r) => result = r,
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Sign only'), findsNothing);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(result, ConfirmChoice.cancel);
  });

  testWidgets('an expandable detail section is collapsed until tapped', (tester) async {
    await tester.pumpWidget(_host(
      (ctx) => showConfirmTransactionChoice(
        ctx,
        title: 'Confirm send',
        rows: const [],
        expandableTitle: 'Show UTXOs',
        expandable: const Text('box-1'),
      ),
      (_) {},
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('box-1'), findsNothing);
    await tester.tap(find.text('Show UTXOs'));
    await tester.pumpAndSettle();
    expect(find.text('box-1'), findsOneWidget);
  });
}
