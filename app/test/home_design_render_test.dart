// The home screens, rendered from sample data on a 390x844 phone in the
// dark (Watchful), light (Ledger) and teal (Harbor) palettes at normal
// text and in the dark one at 2x, and checked for layout errors, 48 dp
// touch targets, labelled controls, screen-reader sentences and hidden
// balances. Text contrast is checked from the palette tokens in
// home_contrast_test.dart. To also save PNGs under <repo>/ui-renders/v3/:
//
//   ARGUS_UI_RENDERS=1 flutter test test/home_design_render_test.dart
//
// 2x is beyond what ships (the app clamps text at 1.6x) and is here as a
// stress test.

import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/ui/home/home_models.dart';
import 'package:argus_wallet/ui/home/overview_screen.dart';
import 'package:argus_wallet/ui/home/wallet_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/home_samples.dart';
import 'support/render_harness.dart';

/// The palettes rendered: the defaults, and Harbor for a teal accent.
const _looks = [
  (watchfulPalette, 1.0),
  (ledgerPalette, 1.0),
  (harborPalette, 1.0),
  (watchfulPalette, 2.0),
];

String _tag(PaletteSpec p, double scale) =>
    '${p == harborPalette ? 'teal' : p.isDark ? 'dark' : 'light'}-${scale.toStringAsFixed(0)}x';

String _file(String screen, PaletteSpec p, [double scale = 1, String suffix = '']) =>
    'v3/$screen-${_tag(p, scale)}$suffix';

void _noop([Object? _]) {}

/// The overview as the app would host it: every control wired, so links
/// draw enabled.
OverviewScreen _overview(OverviewData data) => OverviewScreen(
      data: data,
      onOpenWallet: _noop,
      onWalletOptions: _noop,
      onCreate: _noop,
      onRestore: _noop,
      onWatch: _noop,
      onSettings: _noop,
      onToggleHidden: _noop,
      onNetwork: _noop,
      onLearnMore: _noop,
    );

WalletPageScreen _walletPage(WalletPageData data, {ValueChanged<WalletTool>? onTool}) => WalletPageScreen(
      data: data,
      onTab: _noop,
      onBack: _noop,
      onScan: _noop,
      onToggleHidden: _noop,
      onAction: _noop,
      onTool: onTool ?? _noop,
      onAsset: _noop,
      onAllAssets: _noop,
      onActivity: _noop,
      onAllActivity: _noop,
      onTidyUp: _noop,
      onOtherAddresses: _noop,
    );

/// Scrolls [finder] into full view, building it first if the list hasn't,
/// and scrolling no further than that so a render keeps its context.
/// (scrollUntilVisible would also pin the target to the top.)
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 50 && finder.evaluate().isEmpty; i++) {
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -120));
    await tester.pump();
  }
  await Scrollable.ensureVisible(
    tester.element(finder),
    alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
  );
  await tester.pumpAndSettle();
}

Future<void> _accessible(WidgetTester tester) async {
  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
}

/// Nothing the samples hold may be readable, on screen or to a screen
/// reader, while balances are hidden.
void _expectNoFigures(WidgetTester tester) {
  final shown = tester.widgetList<RichText>(find.byType(RichText)).map((t) => t.text.toPlainText()).join('\n');
  for (final figure in hiddenModeFigures) {
    // On screen a figure is joined to its unit by a no-break space.
    final pattern = RegExp(RegExp.escape(figure).replaceAll(' ', '[  ]'));
    expect(pattern.hasMatch(shown), isFalse, reason: '"$figure" is on screen with balances hidden');
    expect(find.bySemanticsLabel(pattern), findsNothing, reason: '"$figure" is read out with balances hidden');
  }
}

/// Holdings whose rows sit wholly above the tab bar.
int _assetsAboveFold(WidgetTester tester) {
  final fold = tester.getTopLeft(find.byType(NavigationBar)).dy;
  var shown = 0;
  for (final element in find.byWidgetPredicate((w) => w.key is Key && '${w.key}'.contains('home-asset-')).evaluate()) {
    final box = element.renderObject! as RenderBox;
    if (box.localToGlobal(Offset(0, box.size.height)).dy <= fold) shown++;
  }
  return shown;
}

void main() {
  setUpAll(loadRenderFonts);

  for (final (palette, scale) in _looks) {
    testWidgets('overview ${_tag(palette, scale)}', (tester) async {
      await pumpRender(tester, _overview(sampleOverview()), palette: palette, textScale: scale);
      expect(tester.takeException(), isNull);
      await saveRender(tester, _file('overview', palette, scale));
      expect(
        find.bySemanticsLabel(
            RegExp(r'^Total balance 25,529\.34 ERG, about A\$11,951\.52 AUD, 46 tokens unpriced, \+2\.5 ERG pending$')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('ERG price A\$0.47 AUD, up 2.4% over 24h, Oracle pool'), findsOneWidget);
      expect(find.bySemanticsLabel('Synced, Block 1,888,681'), findsOneWidget);
      await _accessible(tester);
      if (scale == 1) {
        // At 2x the list builds rows only as they near the screen.
        expect(
          find.bySemanticsLabel(RegExp(r'^Main Wallet, unlocked, 107\.71 ERG, about A\$50\.43 AUD, 50 tokens, '
              r'\+2\.5 ERG pending, incl\. 3\.2 ERG · 4 tokens on another address$')),
          findsOneWidget,
        );
        expect(find.bySemanticsLabel(RegExp(r'^9evoke9, 0 ERG, empty$')), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp(r'^Watched, watch-only, 25,421\.62 ERG')), findsOneWidget);
        // Every wallet and the way to add one, with room to spare.
        final fold = tester.view.physicalSize.height / tester.view.devicePixelRatio;
        expect(tester.getBottomLeft(find.byKey(const Key('overview-add-wallet'))).dy, lessThan(fold - 48));
      }
    });

    testWidgets('wallet ${_tag(palette, scale)}', (tester) async {
      final screen = _walletPage(sampleMainPage());
      await pumpRender(tester, screen, palette: palette, textScale: scale);
      expect(tester.takeException(), isNull);
      await saveRender(tester, _file('wallet', palette, scale));
      expect(
        find.bySemanticsLabel(RegExp(r'^Balance 107\.71 ERG, about A\$50\.43 AUD, 46 tokens unpriced, '
            r'\+2\.5 ERG pending, incl\. 0\.001 ERG stealth$')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('incl. 3.2 ERG · 4 tokens on 1 other address'), findsOneWidget);
      expect(find.bySemanticsLabel('165 UTXOs, fragmented. Tidy up'), findsOneWidget);
      expect(find.byKey(const Key('home-price-sparkline')), findsNothing, reason: 'the price strip is overview-only');
      expect(find.byTooltip('All wallets'), findsOneWidget);
      expect(find.byKey(const Key('wallet-tab-discover')), findsOneWidget);
      if (scale == 1) {
        expect(_assetsAboveFold(tester), greaterThanOrEqualTo(5), reason: 'balance, actions and the holdings fit');
      }
      await _accessible(tester);

      await pumpFullLength(tester, screen, listKey: const Key('wallet-list'), palette: palette, textScale: scale);
      expect(tester.takeException(), isNull);
      if (scale == 1 && palette != harborPalette) {
        await saveRender(tester, _file('wallet', palette, scale, '-full'));
      }
      for (final action in ['send', 'receive', 'swap', 'more']) {
        expect(find.byKey(Key('wallet-action-$action')), findsOneWidget);
      }
      expect(find.bySemanticsLabel(RegExp(r'^ERG, price A\$0\.47, up 2\.4% over 24h, 107\.71, about A\$50\.43 AUD$')),
          findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^COMET, verified, Comet, 69, about A\$0\.21 AUD$')), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp(r'^Ergo_6de6f46e_LP, liquidity pool share, Spectrum pool share, '
            r'18,252,893,012, about A\$0\.87 AUD$')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel(RegExp(r'^Sent, −1\.81 ERG, −69 COMET \+ 1 more, contract 5vSUZR…SCqM, 10:08 pm$')),
          findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Received, pending, \+2\.5 ERG, from 9gF3uX…Wq7z, Just now$')),
          findsOneWidget);
      await _accessible(tester);
    });
  }

  for (final palette in [watchfulPalette, ledgerPalette]) {
    testWidgets('More ${_tag(palette, 1)}', (tester) async {
      WalletTool? picked;
      await pumpRender(tester, _walletPage(sampleMainPage(), onTool: (t) => picked = t), palette: palette);
      await _reveal(tester, find.byKey(const Key('wallet-action-more')));
      await tester.tap(find.byKey(const Key('wallet-action-more')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await saveRender(tester, _file('more', palette));
      for (final tool in WalletTool.values) {
        expect(find.byKey(Key('wallet-tool-${tool.name}')), findsOneWidget);
      }
      expect(find.bySemanticsLabel(RegExp(r'^UTXO management, Fragmented, ')), findsOneWidget);
      await _accessible(tester);
      await tester.tap(find.byKey(const Key('wallet-tool-utxos')));
      await tester.pumpAndSettle();
      expect(picked, WalletTool.utxos);
    });

    testWidgets('watched ${_tag(palette, 1)}', (tester) async {
      await pumpRender(tester, _walletPage(sampleWatchedPage()), palette: palette);
      expect(tester.takeException(), isNull);
      await saveRender(tester, _file('watched', palette));
      expect(find.bySemanticsLabel('Send with offline signer'), findsOneWidget);
      expect(find.bySemanticsLabel('Receive'), findsOneWidget);
      for (final keyed in ['send', 'swap', 'more']) {
        expect(find.byKey(Key('wallet-action-$keyed')), findsNothing, reason: '$keyed needs keys on this phone');
      }
      expect(find.byKey(const Key('wallet-scan')), findsNothing);
      expect(find.byKey(const Key('wallet-tab-discover')), findsNothing);
      expect(find.textContaining('WATCH-ONLY'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^ERG, price A\$0\.47, 25,421\.62')), findsOneWidget,
          reason: 'no 24h change without price history');
      await _accessible(tester);
    });
  }

  testWidgets('watched dark-2x', (tester) async {
    await pumpRender(tester, _walletPage(sampleWatchedPage()), palette: watchfulPalette, textScale: 2);
    expect(tester.takeException(), isNull);
    await saveRender(tester, _file('watched', watchfulPalette, 2));
    await _accessible(tester);
  });

  testWidgets('overview hides every amount', (tester) async {
    await pumpRender(tester, _overview(sampleOverview(hidden: true)), palette: watchfulPalette);
    expect(tester.takeException(), isNull);
    await saveRender(tester, _file('overview', watchfulPalette, 1, '-hidden'));
    expect(find.bySemanticsLabel('Total balance hidden'), findsOneWidget);
    expect(find.byTooltip('Show balances'), findsOneWidget);
    _expectNoFigures(tester);
  });

  testWidgets('wallet hides every amount', (tester) async {
    final screen = _walletPage(sampleMainPage(hidden: true));
    await pumpRender(tester, screen, palette: watchfulPalette);
    expect(tester.takeException(), isNull);
    await saveRender(tester, _file('wallet', watchfulPalette, 1, '-hidden'));
    expect(find.bySemanticsLabel('Balance hidden'), findsOneWidget);
    await pumpFullLength(tester, screen, listKey: const Key('wallet-list'), palette: watchfulPalette);
    _expectNoFigures(tester);
  });

  testWidgets('add a wallet', (tester) async {
    final taps = <String>[];
    await pumpRender(
      tester,
      OverviewScreen(
        data: sampleOverview(),
        onCreate: () => taps.add('create'),
        onRestore: () => taps.add('restore'),
        onWatch: () => taps.add('watch'),
      ),
      palette: watchfulPalette,
    );
    for (final choice in ['create', 'restore', 'watch']) {
      await _reveal(tester, find.byKey(const Key('overview-add-wallet')));
      await tester.tap(find.byKey(const Key('overview-add-wallet')));
      await tester.pumpAndSettle();
      if (choice == 'create') {
        expect(tester.takeException(), isNull);
        await saveRender(tester, _file('add-wallet', watchfulPalette));
        await _accessible(tester);
      }
      await tester.tap(find.byKey(Key('overview-add-$choice')));
      await tester.pumpAndSettle();
    }
    expect(taps, ['create', 'restore', 'watch']);
  });

  testWidgets('first launch', (tester) async {
    await pumpRender(tester, _overview(sampleOverview(wallets: const [])), palette: watchfulPalette);
    expect(tester.takeException(), isNull);
    await saveRender(tester, _file('overview', watchfulPalette, 1, '-empty'));
    expect(find.text('Create a wallet'), findsOneWidget);
    expect(find.text('Restore from recovery phrase'), findsOneWidget);
    expect(find.text('Watch an address'), findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget, reason: 'a node can be set before the first restore');
    await _accessible(tester);
  });

  testWidgets('overview reports what was tapped', (tester) async {
    final taps = <String>[];
    await pumpRender(
      tester,
      OverviewScreen(
        data: sampleOverview(),
        onOpenWallet: (id) => taps.add('open $id'),
        onWalletOptions: (id) => taps.add('options $id'),
        onSettings: () => taps.add('settings'),
        onToggleHidden: () => taps.add('hide'),
        onNetwork: () => taps.add('network'),
      ),
      palette: ledgerPalette,
    );
    for (final key in ['overview-wallet-main', 'overview-settings', 'home-hide-balances', 'home-network']) {
      await _reveal(tester, find.byKey(Key(key)));
      await tester.tap(find.byKey(Key(key)));
    }
    await tester.longPress(find.byKey(const Key('overview-wallet-9evoke9')));
    expect(taps, ['open main', 'settings', 'hide', 'network', 'options 9evoke9']);
  });

  testWidgets('wallet reports what was tapped', (tester) async {
    final taps = <String>[];
    await pumpRender(
      tester,
      WalletPageScreen(
        data: sampleMainPage(),
        onBack: () => taps.add('back'),
        onScan: () => taps.add('scan'),
        onToggleHidden: () => taps.add('hide'),
        onAction: (a) => taps.add(a.name),
        onTidyUp: () => taps.add('tidy'),
        onOtherAddresses: () => taps.add('addresses'),
        onTab: (t) => taps.add('tab ${t.name}'),
        onAsset: (id) => taps.add('asset $id'),
        onAllAssets: () => taps.add('all assets'),
        onActivity: (id) => taps.add('tx $id'),
        onAllActivity: () => taps.add('all activity'),
      ),
      palette: ledgerPalette,
    );
    await tester.tap(find.byKey(const Key('wallet-back')));
    await tester.tap(find.byKey(const Key('wallet-scan')));
    await tester.tap(find.byKey(const Key('home-hide-balances')));
    await tester.tap(find.byKey(const Key('wallet-tab-activity')));
    for (final key in [
      'wallet-action-send',
      'wallet-action-receive',
      'wallet-action-swap',
      'wallet-other-addresses',
      'home-tidy-up',
      'home-asset-ERG',
      'wallet-all-assets',
      'home-activity-a2',
      'wallet-all-activity',
    ]) {
      await _reveal(tester, find.byKey(Key(key)));
      await tester.tap(find.byKey(Key(key)));
      await tester.pump();
    }
    expect(taps, [
      'back',
      'scan',
      'hide',
      'tab activity',
      'send',
      'receive',
      'swap',
      'addresses',
      'tidy',
      'asset ERG',
      'all assets',
      'tx a2',
      'all activity',
    ]);
  });

  testWidgets('a screen reader can press what a finger can', (tester) async {
    final taps = <String>[];
    await pumpRender(
      tester,
      WalletPageScreen(
        data: sampleMainPage(),
        onAction: (a) => taps.add(a.name),
        onTidyUp: () => taps.add('tidy'),
        onAsset: (id) => taps.add('asset $id'),
      ),
      palette: watchfulPalette,
    );
    for (final label in ['Send', '165 UTXOs, fragmented. Tidy up', RegExp(r'^ERG, price')]) {
      tester.semantics.tap(find.semantics.byLabel(label));
    }
    await tester.pump();
    expect(taps, ['send', 'tidy', 'asset ERG']);
  });

  testWidgets('the overview price strip reads complete without history', (tester) async {
    await pumpRender(
      tester,
      _overview(OverviewData(
        wallets: sampleOverview().wallets,
        currency: aud,
        network: syncedAtTip,
        totalNano: sampleOverview().totalNano,
        price: ergPriceWithoutHistory,
      )),
      palette: watchfulPalette,
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('home-price-sparkline')), findsNothing);
    expect(find.bySemanticsLabel('ERG price A\$0.47 AUD, Oracle pool, No price history on this node'), findsOneWidget);
  });

  testWidgets('a wallet still syncing shows a placeholder, not zero', (tester) async {
    await pumpRender(
      tester,
      _overview(const OverviewData(
        wallets: [WalletSummary(id: 'new', name: 'Fresh restore')],
        currency: aud,
        network: NetworkStatus(state: SyncState.syncing, blockHeight: 1888681),
        price: ErgPriceView(fiatPerErg: null, source: 'CoinGecko'),
      )),
      palette: ledgerPalette,
    );
    expect(tester.takeException(), isNull);
    expect(find.bySemanticsLabel('Total balance loading'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Fresh restore, balance unavailable')), findsOneWidget);
    expect(find.bySemanticsLabel('Syncing, Block 1,888,681'), findsOneWidget);
    expect(find.bySemanticsLabel('ERG price unavailable, CoinGecko'), findsOneWidget);
  });

  testWidgets('a wallet with no activity offers its address', (tester) async {
    final taps = <String>[];
    await pumpRender(
      tester,
      WalletPageScreen(data: sampleMainPage(activity: const []), onAction: (a) => taps.add(a.name)),
      palette: watchfulPalette,
    );
    await _reveal(tester, find.byKey(const Key('wallet-no-activity')));
    await tester.tap(find.byKey(const Key('wallet-no-activity')));
    expect(taps, ['receive']);
  });
}
