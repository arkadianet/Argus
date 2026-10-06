import 'package:argus_wallet/services/amm_service.dart';
import 'package:argus_wallet/services/token_catalog.dart';
import 'package:argus_wallet/services/token_descriptor_store.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/ui/swap_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    publicTokenCatalog.debugReset();
  });

  TokenBalance held(String id, {String? name, int amount = 1, int decimals = 0}) =>
      TokenBalance(id: id, amount: amount, name: name, decimals: decimals);

  /// Pools trading [ids], each named by the public catalog the way a
  /// resolved pool list would be.
  AmmPoolSet poolSet(List<String> ids, {bool truncated = false}) {
    publicTokenCatalog.debugSeed([
      for (final id in ids) CachedDescriptor(id: id, name: 'Pooled $id'),
    ]);
    return AmmPoolSet(
      truncated: truncated,
      pools: [
        for (final id in ids)
          {
            'pool_id': 'pool-$id',
            'pool_type': 'N2T',
            'erg_reserves': 1000,
            'token_y': {'token_id': id, 'amount': 1000},
          },
      ],
      tokens: const {},
    );
  }

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
      // at that same text. The id shares no substring with the name, so the
      // pre-existing id matcher cannot satisfy this on its own — deleting
      // displayName() from matches() fails here.
      final result = await pick(
        tester,
        set: poolSet(const ['traded']),
        complete: true,
        holdings: [held('f00dbeef', name: 'Orphan')],
        tap: 'Orphan',
        query: 'Orph',
      );
      expect(find.text('Orphan'), findsOneWidget,
          reason: 'the row must survive a search for the name it shows');
      expect(result, isNull, reason: 'and still not be selectable');
    });

    testWidgets('a held token is named and scaled as the asset list does', (
      tester,
    ) async {
      // The beta.1 picker read only the pool set's map, where every token
      // was an id placeholder at zero decimals: COMET showed "0cd8c9f4…".
      const comet =
          '0cd8c9f416e5b1ca9f986a7f10a84191dfb85941619e49e53c0dc30ebf83324b';
      final sigUsd = _sigUsd;
      final set = AmmPoolSet(
        truncated: false,
        pools: [
          for (final id in [comet, sigUsd])
            {
              'pool_id': 'pool-$id',
              'pool_type': 'N2T',
              'erg_reserves': 1000,
              'token_y': {'token_id': id, 'amount': 1000},
            },
        ],
        tokens: const {},
      );
      await pick(
        tester,
        set: set,
        complete: true,
        holdings: [
          held(comet, name: 'COMET', amount: 69),
          held(sigUsd, name: 'SigUSD', amount: 150, decimals: 2),
        ],
        tap: 'nothing-to-tap',
      );
      expect(find.text('COMET'), findsOneWidget);
      expect(find.text('69'), findsOneWidget);
      expect(find.text('SigUSD'), findsOneWidget);
      expect(find.text('1.5'), findsOneWidget,
          reason: 'decimals applied, not 150 raw units');
      expect(find.textContaining('…'), findsNothing,
          reason: 'no id placeholders where names are known');
    });

    testWidgets('a token nothing can scale says its amount is raw units', (
      tester,
    ) async {
      final unknown = 'e9' * 32;
      await pick(
        tester,
        set: AmmPoolSet(
          truncated: false,
          pools: [
            {
              'pool_id': 'p',
              'pool_type': 'N2T',
              'erg_reserves': 1000,
              'token_y': {'token_id': unknown, 'amount': 1000},
            },
          ],
          tokens: const {},
        ),
        complete: true,
        holdings: [TokenBalance(id: unknown, amount: 5000)],
        tap: 'nothing-to-tap',
      );
      expect(find.text('e9e9e9e9…'), findsOneWidget,
          reason: 'a short id where no name is known');
      expect(find.text('5,000 raw units'), findsOneWidget);
    });
  });
}

const _sigUsd =
    '03faf2cb329f2e90d6d23b58d91bbb6c046aa143261cc21f52fbe2824bfcbf04';
