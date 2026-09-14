import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/ui/send_screen.dart';
import 'package:argus_wallet/ui/widgets/asset_picker_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'token rows exclude primary and other selections but retain their own',
    (tester) async {
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
              tokens: [
                TokenBalance(id: 'a', name: 'Alpha', amount: 100, decimals: 0),
                TokenBalance(id: 'b', name: 'Beta', amount: 100, decimals: 0),
                TokenBalance(id: 'c', name: 'Gamma', amount: 100, decimals: 0),
              ],
            ),
            child: const SendScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .ancestor(of: find.text('Asset'), matching: find.byType(InkWell))
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alpha').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Add another token'));
      await tester.tap(find.text('Add another token'));
      await tester.pumpAndSettle();
      final rows = find.byType(DropdownButtonFormField<String>);
      List<String?> options(int index) => tester
          .widget<DropdownButton<String>>(
            find.descendant(
              of: rows.at(index),
              matching: find.byType(DropdownButton<String>),
            ),
          )
          .items!
          .map((i) => i.value)
          .toList();
      expect(options(0), ['b', 'c']);
      expect(
        find.text('Add another token'),
        findsNothing,
        reason: 'finish the empty row before adding another',
      );
      await tester.tap(rows.first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Beta').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Add another token'));
      await tester.tap(find.text('Add another token'));
      await tester.pumpAndSettle();
      expect(options(0), ['b', 'c']);
      expect(options(1), ['c']);
      await tester.tap(rows.at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gamma').last);
      await tester.pumpAndSettle();
      expect(options(0), ['b']);
      expect(options(1), ['c']);
      expect(find.text('Add another token'), findsNothing);
      // Removing a row frees its token without resetting the surviving row.
      await tester.tap(find.byTooltip('Remove').first);
      await tester.pumpAndSettle();
      expect(options(0), ['b', 'c']);
      expect(
        tester.widget<DropdownButtonFormField<String>>(rows.first).initialValue,
        'c',
      );
      expect(find.text('Add another token'), findsOneWidget);
      await tester.ensureVisible(find.text('Asset'));
      await tester.tap(
        find
            .ancestor(of: find.text('Asset'), matching: find.byType(InkWell))
            .first,
      );
      await tester.pumpAndSettle();
      final picker = tester.widget<AssetPickerSheet>(
        find.byType(AssetPickerSheet),
      );
      expect(
        picker.held.map((t) => t.id),
        ['a', 'b'],
        reason: 'the primary picker cannot duplicate Gamma',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
