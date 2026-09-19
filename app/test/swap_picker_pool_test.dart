import 'package:argus_wallet/services/amm_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/ui/swap_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TokenBalance held(String id, {String? name}) =>
      TokenBalance(id: id, amount: 1, name: name);

  AmmPoolSet poolSet(List<String> ids, {bool truncated = false}) => AmmPoolSet(
    truncated: truncated,
    pools: const [],
    tokens: {
      for (final id in ids)
        id: AmmTokenMeta(name: 'Pooled $id', decimals: 0),
    },
  );

  group('heldByTradability', () {
    test('tradable holdings come first, untradable ones are kept', () {
      final rows = heldByTradability(
        [held('nopool'), held('traded'), held('alsonopool')],
        {'traded'},
      );
      expect(rows.map((t) => t.id), ['traded', 'nopool', 'alsonopool']);
    });

    test('order within each group is preserved', () {
      final rows = heldByTradability(
        [held('p1'), held('x1'), held('p2'), held('x2')],
        {'p1', 'p2'},
      );
      expect(rows.map((t) => t.id), ['p1', 'p2', 'x1', 'x2']);
    });
  });

  group('the picker itself', () {
    /// Mounts the sheet and returns whatever it pops.
    Future<(String?,)?> pick(
      WidgetTester tester, {
      required AmmPoolSet set,
      required bool complete,
      required List<TokenBalance> holdings,
      required String tap,
      String query = '',
    }) async {
      (String?,)? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showModalBottomSheet<(String?,)>(
                    context: context,
                    builder: (_) => SwapAssetPickerSheet(
                      title: 'Pay with',
                      set: set,
                      poolsComplete: complete,
                      heldTokens: holdings,
                      spendableNano: 1000000000,
                      exclude: null,
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      if (query.isNotEmpty) {
        await tester.enterText(find.byType(TextField), query);
        await tester.pumpAndSettle();
      }
      final target = find.text(tap);
      if (target.evaluate().isEmpty) return null;
      await tester.tap(target);
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('a holding with no pool cannot be selected', (tester) async {
      final result = await pick(
        tester,
        set: poolSet(const ['traded']),
        complete: true,
        holdings: [held('orphan', name: 'Orphan')],
        tap: 'Orphan',
      );
      expect(result, isNull, reason: 'the row must not return a selection');
      expect(find.text('No Spectrum pool'), findsOneWidget);
    });

    testWidgets('a holding with a pool can be selected', (tester) async {
      final result = await pick(
        tester,
        set: poolSet(const ['traded']),
        complete: true,
        holdings: [held('traded')],
        tap: 'Pooled traded',
      );
      expect(result, ('traded',));
    });

    testWidgets('an incomplete pool list makes no claim', (tester) async {
      // Cached or truncated discovery: absence is not evidence, so the
      // holding stays selectable and is not labelled.
      final result = await pick(
        tester,
        set: poolSet(const [], truncated: true),
        complete: false,
        holdings: [held('maybe', name: 'Maybe')],
        tap: 'Maybe',
      );
      expect(result, ('maybe',));
      expect(find.text('No Spectrum pool'), findsNothing);
    });

    testWidgets('a holding is findable by the name it displays', (
      tester,
    ) async {
      // The row falls back to the holding's own label, so search has to look
      // at that same text or the token vanishes when its name is typed.
      final result = await pick(
        tester,
        set: poolSet(const ['traded']),
        complete: true,
        holdings: [held('orphan', name: 'Orphan')],
        tap: 'Orphan',
        query: 'Orph',
      );
      expect(result, isNull);
      expect(find.text('Nothing matches "Orph".'), findsNothing);
    });
  });
}
