import 'package:argus_wallet/services/token_catalog.dart';
import 'package:argus_wallet/services/token_descriptor_store.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/ui/transaction_detail_screen.dart';
import 'package:argus_wallet/ui/widgets/activity_tile.dart';
import 'package:argus_wallet/ui/widgets/tx_details.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _comet =
    '0cd8c9f416e5b1ca9f986a7f10a84191dfb85941619e49e53c0dc30ebf83324b';
final _pooled = 'aa' * 32;
final _unknown = 'e91cbc48${'b' * 56}';
const _contract =
    '5vSUZRZbdVbnk4sJWjg2uhL94VZWRg4iatK9VgMChufzUgdihgvhR8yWSUEJKszzV7Vmi6K8hCyKTNhUaiP8p5ko6YEU9yfHpjVuXdQ4i5p1YMhmvBBUbEEWqgrx1Ah5R9mdS4B7ENzfGjWn9hzpDdZDp6nffA6fkT6zfSpRaeBTaM7KH6Hjfq5rrFbz8x2bmfVPPYmRvvSsmhzETb7c9zVnC4jH2Mx4YbKDX8MTYAUVbmhX5ARDTr4FXJ3Fv9SsK1ohnVfUxQspkjP2oMPU5ZoXWKBv6q9Ek4EKM4Xu1Cph3E2rbTG7HFaPEYRp4pVHY3xFsSkBapAa9EuZHdGjcKKGVJjB4dKvjdYNPpHdZS5rZ7dxgFsXLEgHAkAqJ';

Map<String, dynamic> _sent(List<Map<String, Object>> tokens) => {
  'tx_id': 'tx1',
  'height': 100,
  'timestamp': 0,
  'value_nano_erg': -1816200000,
  'counterparty': _contract,
  'tokens_sent': tokens,
};

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    publicTokenCatalog.debugReset();
  });

  Future<void> row(WidgetTester tester, Map<String, dynamic> tx) =>
      tester.pumpWidget(
        MaterialApp(
          theme: argusTheme(watchful: false),
          home: Scaffold(body: ActivityTile(tx: tx, onTap: () {})),
        ),
      );

  testWidgets('the row names the token it sent, with its scale', (
    tester,
  ) async {
    await row(tester, _sent([
      {'token_id': _comet, 'amount': 69},
    ]));
    expect(find.text('Sent'), findsOneWidget);
    expect(find.textContaining('69 COMET + 1.8162 ERG'), findsOneWidget);
    expect(find.textContaining('2 tokens'), findsNothing);
  });

  testWidgets('more than two tokens: two by name, then how many more', (
    tester,
  ) async {
    publicTokenCatalog.debugSeed([
      CachedDescriptor(id: _pooled, name: 'Pooled', decimals: 2),
    ]);
    await row(tester, _sent([
      {'token_id': _unknown, 'amount': 5},
      {'token_id': _comet, 'amount': 69},
      {'token_id': _pooled, 'amount': 150},
    ]));
    expect(
      find.textContaining('69 COMET + 1.5 Pooled + 1 more token + 1.8162 ERG'),
      findsOneWidget,
    );
  });

  testWidgets('a name learned later repaints the row', (tester) async {
    await row(tester, _sent([
      {'token_id': _pooled, 'amount': 150},
    ]));
    expect(find.textContaining('150 raw units of aaaaaaaa…'), findsOneWidget);
    publicTokenCatalog.debugSeed([
      CachedDescriptor(id: _pooled, name: 'Pooled', decimals: 2),
    ]);
    await tester.pump();
    expect(find.textContaining('1.5 Pooled + 1.8162 ERG'), findsOneWidget);
  });

  testWidgets('hidden balances hide the names as well', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ActivityTile(
            tx: _sent([
              {'token_id': _comet, 'amount': 69},
            ]),
            hidden: true,
          ),
        ),
      ),
    );
    expect(find.textContaining('COMET'), findsNothing);
  });

  testWidgets('confirm-sheet details name and scale the tokens moved', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: argusTheme(watchful: false),
        home: Scaffold(
          body: SingleChildScrollView(
            child: TxDetailsView(
              details: {
                'inputs': const [],
                'outputs': [
                  {
                    'kind': 'recipient',
                    'address': _contract,
                    'value_nano_erg': 1000000,
                    'tokens': [
                      {'id': _comet, 'amount': 69},
                      {'id': _unknown, 'amount': 5000},
                    ],
                  },
                ],
                'fee_nano_erg': 1100000,
              },
            ),
          ),
        ),
      ),
    );
    expect(
      find.textContaining('69 COMET, 5,000 raw units of e91cbc48…'),
      findsOneWidget,
    );
  });

  testWidgets('the transaction screen names and scales its tokens', (
    tester,
  ) async {
    final tx = {
      ..._sent([
        {'token_id': _comet, 'amount': 69},
        {'token_id': _unknown, 'amount': 5000},
      ]),
    };
    await tester.pumpWidget(
      MaterialApp(
        home: WalletArgsScope(
          args: const WalletRouteArgs(
            senderAddress: 'a',
            receiveAddress: 'a',
            changeAddress: 'a',
          ),
          child: Builder(
            builder: (context) => Navigator(
              onGenerateRoute: (_) => MaterialPageRoute(
                settings: RouteSettings(
                  arguments: WalletRouteArgs(
                    senderAddress: 'a',
                    receiveAddress: 'a',
                    changeAddress: 'a',
                    transaction: tx,
                  ),
                ),
                builder: (_) => const TransactionDetailScreen(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('69 COMET'), findsOneWidget);
    expect(find.text('5,000 raw units of e91cbc48…'), findsOneWidget);
  });
}
