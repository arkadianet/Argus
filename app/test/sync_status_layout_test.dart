import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/ui/home/home_models.dart';
import 'package:argus_wallet/ui/home/wallet_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/home_finders.dart';

// The wallet page's status lines on a narrow phone at the largest text the
// app allows: every part is there, nothing overflows, and the line wraps
// rather than cutting the age off.
void main() {
  for (final dark in [true, false]) {
    testWidgets('home status wraps at narrow width and 1.6x ($dark)', (tester) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        theme: argusTheme(watchful: dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: Scaffold(
          body: WalletPageView(
            onStatus: () {},
            onTidyUp: () {},
            data: const WalletPageData(
              wallet: WalletSummary(ref: WalletRef.seed('w'), name: 'Daily', nanoErg: 0),
              currency: FiatCurrency(symbol: r'$', code: 'USD'),
              status: NetworkStatus(
                state: SyncState.stale,
                label: 'Out of sync',
                blockHeight: 1999999,
                age: '10 minutes ago',
              ),
              utxoCount: 12345,
              fragmented: true,
            ),
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
      final status = find.byKey(const Key('wallet-status'));
      final line = find.descendant(of: status, matching: textPlainContaining('Out of sync'));
      expect(plainOf(tester, line), 'Out of sync   ·   Block 1,999,999   ·   10 minutes ago');
      expect(find.descendant(of: find.byKey(const Key('utxo-fragmented')), matching: textPlain('12,345 UTXOs · Fragmented')),
          findsOneWidget);
      // At this size the line takes more than one row of text.
      final lineHeight = tester.getSize(line).height;
      expect(lineHeight, greaterThan(13 * 1.6 * 1.3 * 1.5));
    });
  }
}
