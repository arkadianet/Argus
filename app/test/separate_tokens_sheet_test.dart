import 'package:argus_wallet/services/utxo_plans.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/ui/separate_tokens_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

InputBoxInput box(
  String id,
  int nano, {
  String address = 'own',
  int height = 10,
  List<InputAsset> assets = const [],
}) => InputBoxInput(
  boxId: id,
  address: address,
  valueNanoErg: BigInt.from(nano),
  creationHeight: height,
  assets: assets,
);

void main() {
  final tokens = [
    InputAsset(tokenId: 'A' * 64, amount: BigInt.one),
    InputAsset(tokenId: 'B' * 64, amount: BigInt.from(123)),
  ];

  testWidgets(
    'insufficient source ERG disables review until explicit funding is selected',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SeparateTokensSheet(
              boxes: [
                box('source', 1000000, assets: tokens),
                box('funding', 5000000),
                box('foreign', 5000000, address: 'other'),
                box('token-funding', 5000000, assets: [tokens.first]),
              ],
            ),
          ),
        ),
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Review separation'),
            )
            .onPressed,
        isNull,
      );
      expect(find.byType(CheckboxListTile), findsOneWidget);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Review separation'),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        find.text('2 input boxes → 2 token boxes + ERG change'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'configuration returns an allocation for review without signing',
    (tester) async {
      SeparateTokensPlan? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showModalBottomSheet<SeparateTokensPlan>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => SeparateTokensSheet(
                      boxes: [box('source', 1000000000, assets: tokens)],
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Review separation'));
      await tester.tap(find.text('Review separation'));
      await tester.pumpAndSettle();
      expect(result?.inputBoxIds, ['source']);
      expect(result?.outputs.length, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'fits a small phone with full token IDs and maximum token amounts',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SeparateTokensSheet(
              boxes: [
                box(
                  'source',
                  1000000000,
                  assets: [
                    tokens.first,
                    InputAsset(
                      tokenId: 'C' * 64,
                      amount: BigInt.parse('9223372036854775807'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.text('Review separation'));
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Review separation'),
            )
            .onPressed,
        isNotNull,
      );
    },
  );
}
