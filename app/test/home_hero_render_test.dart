// The home pages (the coloured hero heading the overview and every
// wallet's page, and the lists under it) in every palette, from figures
// like the ones on the user's own phone, checked for layout errors, 48 dp
// targets, labelled controls, screen-reader sentences and hidden balances;
// and their motion, with and without the system's reduce-motion setting.
// Colours are checked against WCAG AA from the tokens in
// home_contrast_test.dart. To also save PNGs, and strips of the motion's
// frames, under <repo>/ui-renders/rich/:
//
//   ARGUS_UI_RENDERS=1 flutter test test/home_hero_render_test.dart

import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/ui/home/home_format.dart';
import 'package:argus_wallet/ui/home/home_models.dart';
import 'package:argus_wallet/ui/home/home_widgets.dart';
import 'package:argus_wallet/ui/home/overview_screen.dart';
import 'package:argus_wallet/ui/home/unlock_gate.dart';
import 'package:argus_wallet/ui/home/wallet_nav_bar.dart';
import 'package:argus_wallet/ui/home/wallet_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/render_harness.dart';

const _aud = FiatCurrency(symbol: r'A$', code: 'AUD');

int _nano(num erg) => (erg * 1e9).round();
BigInt _units(num whole, int decimals) => BigInt.from((whole * BigInt.from(10).pow(decimals).toDouble()).round());

/// Shown as "9iArkadi…WspUZA".
const _pinned = '9iArkadiXq3Nb7Kx2Ty5Vm8Gc1Rz4Fd6Ls9Pw0Ja3Ue7MWspUZA';
const _cold = '9fColdStoragePq3Nb7Kx2Ty5Vm8Gc1Rz4Fd6Ls9Pw0Ja7Lk2';

/// A$ per ERG on the user's screen: 203.16 ERG ≈ A$90.54.
const _rate = 0.44566;

const _price = ErgPriceView(
  fiatPerErg: _rate,
  source: 'SigmaUSD oracle',
  points: [
    0.4352, 0.4361, 0.4349, 0.4370, 0.4382, 0.4377, 0.4391, 0.4386, 0.4398, 0.4411, 0.4405, 0.4419, 0.4426, //
    0.4415, 0.4422, 0.4437, 0.4431, 0.4440, 0.4452, 0.4447, 0.4439, 0.4448, 0.4461, 0.4458, 0.4457,
  ],
  changePercent: 2.4,
);

final _main = _mainWallet();

/// The main wallet holding [erg]; 203.16 is what the user's phone shows.
WalletSummary _mainWallet({num erg = 203.16}) => WalletSummary(
  ref: const WalletRef.seed('main'),
  name: 'Main Wallet',
  nanoErg: _nano(erg),
  fiatValue: (erg * _rate * 100).round() / 100,
  tokenCount: 12,
  pockets: [PocketBalance(pocket: Pocket.stealth, nanoErg: _nano(0.001))],
  otherAddresses: FundsElsewhere(nanoErg: _nano(2.7), tokenCount: 6, addressCount: 1),
  unlocked: true,
  address: _pinned,
  pinnedIndex: 275,
);

final _savings = WalletSummary(
  ref: const WalletRef.seed('savings'),
  name: 'Savings',
  nanoErg: _nano(51.3),
  fiatValue: 51.3 * _rate,
  tokenCount: 2,
  publicTokensOnly: true,
  asOf: '3h ago',
);

final _coldStorage = WalletSummary(
  ref: const WalletRef.watchedAddress(_cold),
  name: 'Cold storage',
  nanoErg: _nano(1250),
  fiatValue: 1250 * _rate,
  tokenCount: 0,
  address: _cold,
);

OverviewData _overviewData({bool hidden = false}) => OverviewData(
      wallets: [_main, _savings],
      watched: [_coldStorage],
      currency: _aud,
      network: const NetworkStatus(state: SyncState.synced, blockHeight: 1889161, label: 'Connected'),
      totalNano: _nano(203.16 + 51.3 + 1250),
      totalFiat: 90.54 + (51.3 + 1250) * _rate,
      unpricedCount: 6,
      price: _price,
      hidden: hidden,
    );

final _assets = [
  AssetRowData(
    id: 'ERG',
    ticker: 'ERG',
    name: 'Ergo',
    amount: BigInt.from(_nano(203.16)),
    decimals: 9,
    fiatValue: 90.54,
    unitFiat: _rate,
    changePercent: 2.4,
    kind: AssetKind.erg,
  ),
  AssetRowData(
    id: '03faf2cb329f2e90d6d23b58d91bbb6c046aa143261cc21f52fbe2824bfcbf04',
    ticker: 'SigUSD',
    amount: _units(1.75, 2),
    decimals: 2,
    fiatValue: 1.75 * 1.52,
    verified: true,
  ),
  AssetRowData(
    id: '0cd8c9f416e5b1ca9f986a7f10a84191dfb85941619e49e53c0dc30ebf83324b',
    ticker: 'COMET',
    amount: BigInt.from(4200),
    fiatValue: 0.38,
    verified: true,
  ),
  AssetRowData(
    id: 'e023c5f382b6e96fbd878f6811aac73345489032157ad5affb84aefd4956c297',
    ticker: 'rsADA',
    name: 'Rosen-bridged ADA',
    amount: _units(12.5, 6),
    decimals: 6,
    fiatValue: 12.5 * 0.97,
    verified: true,
  ),
  AssetRowData(
    id: 'b4f5a8c2e96d1f0374a2c6e8d9b0517f3e2a4c6d8f0b1e3a5c7d9f1b3e5a7c9d',
    ticker: 'ERG_SigUSD_LP',
    name: 'ERG / SigUSD pool share',
    amount: BigInt.from(1830),
    fiatValue: 3.12,
    kind: AssetKind.lpShare,
  ),
  AssetRowData(
    id: '1fd6e032e8476c4aa54c18c1a308dce83940e8f4a28f576440513ed7326ad489',
    ticker: 'Paideia',
    name: 'Paideia DAO token',
    amount: _units(240, 4),
    decimals: 4,
    verified: true,
  ),
];

final _activity = [
  ActivityRowData(
    id: 'r1',
    kind: ActivityKind.received,
    time: '9:12 am',
    counterparty: 'from 9gF3uX…Wq7z',
    legs: [AmountLeg(amount: BigInt.from(_nano(12.5)), decimals: 9, unit: 'ERG')],
  ),
  ActivityRowData(
    id: 's1',
    kind: ActivityKind.sent,
    time: 'Yesterday',
    counterparty: 'to 9hP2kd…Lx8v',
    legs: [AmountLeg(amount: BigInt.from(-_nano(3.25)), decimals: 9, unit: 'ERG')],
  ),
  ActivityRowData(
    id: 'w1',
    kind: ActivityKind.swap,
    time: 'Oct 2',
    legs: [
      AmountLeg(amount: _units(1.75, 2), decimals: 2, unit: 'SigUSD'),
      AmountLeg(amount: BigInt.from(-_nano(3.9)), decimals: 9, unit: 'ERG'),
    ],
  ),
];

WalletPageData _mainPage({bool hidden = false, num erg = 203.16}) => WalletPageData(
      wallet: _mainWallet(erg: erg),
      currency: _aud,
      status: const NetworkStatus(state: SyncState.synced, blockHeight: 1889161, label: 'Synced'),
      assets: _assets,
      assetCount: 13,
      activity: _activity,
      utxoCount: 19,
      unpricedCount: 6,
      hidden: hidden,
    );

WalletPageData _watchedPage() => WalletPageData(
      wallet: _coldStorage,
      currency: _aud,
      assets: [
        AssetRowData(
          id: 'ERG',
          ticker: 'ERG',
          name: 'Ergo',
          amount: BigInt.from(_nano(1250)),
          decimals: 9,
          fiatValue: 1250 * _rate,
          unitFiat: _rate,
          changePercent: 2.4,
          kind: AssetKind.erg,
        ),
      ],
      assetCount: 1,
      activity: [
        ActivityRowData(
          id: 'c1',
          kind: ActivityKind.received,
          time: 'Sep 18',
          counterparty: 'from 9iArka…pUZA',
          legs: [AmountLeg(amount: BigInt.from(_nano(250)), decimals: 9, unit: 'ERG')],
        ),
      ],
      watched: const WatchedDetails(
        status: ['Watch-only · cannot sign here', 'Updated just now'],
        notes: [
          'Cannot sign locally. Send with an offline signer; change returns to this same address. '
              'A watched account tracks more addresses.',
        ],
      ),
    );

void _noop([Object? _]) {}

Widget _page(WalletPageData data) => WalletPageScreen(
      title: data.wallet.name,
      onBack: _noop,
      actions: [
        if (!data.wallet.watchOnly)
          IconButton(
            key: const Key('wallet-scan'),
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: 'Scan a QR code',
            onPressed: _noop,
          ),
      ],
      body: WalletPageView(
        data: data,
        onToggleHidden: _noop,
        onAction: _noop,
        onTool: _noop,
        onAsset: _noop,
        onAllAssets: _noop,
        onActivity: _noop,
        onAllActivity: _noop,
        onStatus: _noop,
        onTidyUp: _noop,
        onOtherAddresses: _noop,
        onCopyAddress: _noop,
      ),
      navBar: WalletNavBar(current: WalletTab.wallet, onSelect: _noop, watchOnly: data.wallet.watchOnly),
    );

Widget _overview(OverviewData data) => OverviewScreen(
      data: data,
      onOpenWallet: _noop,
      onReorder: (_, _) {},
      onAdd: _noop,
      onSettings: _noop,
      onToggleHidden: _noop,
      onNetwork: _noop,
      onLearnMore: _noop,
    );

Widget _locked() => WalletPageScreen(
      title: 'Main Wallet',
      onBack: _noop,
      body: UnlockGate(
        name: 'Main Wallet',
        method: UnlockMethod.biometric,
        pinController: TextEditingController(),
        busy: false,
        usePin: false,
        onUnlock: _noop,
        onUsePin: _noop,
        onUnlockWithPin: _noop,
        onUnlockLegacy: _noop,
        address: _pinned,
        pinnedIndex: 275,
        lastKnownNano: _nano(203.16),
        lastKnownAge: const Duration(hours: 3),
        status: 'Biometric unlock cancelled. Tap Unlock to try again, or use your PIN.',
      ),
    );

String _id(PaletteSpec p) => p.id;

Future<void> _accessible(WidgetTester tester) async {
  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
}


/// The hero's colours as drawn, top and foot, for checking they are the
/// ones the palette names.
List<Color> _heroColors(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(find.byKey(const Key('home-hero')));
  return ((box.decoration as BoxDecoration).gradient! as LinearGradient).colors;
}

void main() {
  setUpAll(loadRenderFonts);
  String file(String screen, PaletteSpec palette, [String suffix = '']) =>
      'rich/$screen-${_id(palette)}-1x$suffix';
  HeroSpec spec(PaletteSpec p) => p.hero;


  for (final palette in allPalettes) {
    testWidgets('wallet page, ${palette.name}', (tester) async {
      await pumpRender(tester, _page(_mainPage()), palette: palette);
      expect(tester.takeException(), isNull);
      if ([harborPalette, watchfulPalette, ledgerPalette].contains(palette)) {
        await saveRender(tester, file('wallet', palette));
      }
      expect(_heroColors(tester), [spec(palette).surface, spec(palette).surfaceEnd]);
      expect(
        find.bySemanticsLabel(RegExp(r'^Balance 203\.16 ERG, about A\$90\.54 AUD, 6 tokens unpriced, '
            r'incl\. 0\.001 ERG stealth$')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Pinned address #275, 9iArkadi…WspUZA'), findsOneWidget);
      expect(find.bySemanticsLabel('incl. 2.7 ERG · 6 tokens on 1 other address'), findsOneWidget);
      await _accessible(tester);
    });
  }

  for (final palette in [harborPalette, watchfulPalette, ledgerPalette]) {
    testWidgets('overview, ${palette.name}', (tester) async {
      await pumpRender(tester, _overview(_overviewData()), palette: palette);
      expect(tester.takeException(), isNull);
      await saveRender(tester, file('overview', palette));
      expect(_heroColors(tester).first, spec(palette).surface);
      expect(find.bySemanticsLabel('ERG price A\$0.45 AUD, up 2.4% over 24h, SigmaUSD oracle'), findsOneWidget);
      expect(find.byKey(const Key('home-price-sparkline')), findsOneWidget);
      await _accessible(tester);
    });

    testWidgets('locked page, ${palette.name}', (tester) async {
      await pumpRender(tester, _locked(), palette: palette);
      expect(tester.takeException(), isNull);
      await saveRender(tester, file('locked', palette));
      expect(_heroColors(tester).first, spec(palette).surface);
      expect(find.bySemanticsLabel(RegExp(r'^Balance 203\.16 ERG, as of 3h ago$')), findsOneWidget);
      await _accessible(tester);
    });
  }

  testWidgets('watched page, Harbor', (tester) async {
    await pumpRender(tester, _page(_watchedPage()), palette: harborPalette);
    expect(tester.takeException(), isNull);
    await saveRender(tester, file('watched', harborPalette));
    expect(find.byKey(const Key('watch-action-send')), findsOneWidget);
    await _accessible(tester);
  });

  for (final screen in ['wallet', 'overview']) {
    testWidgets('$screen at 2x text, Harbor', (tester) async {
      final widget = screen == 'wallet' ? _page(_mainPage()) : _overview(_overviewData());
      await pumpRender(tester, widget, palette: harborPalette, textScale: 2);
      expect(tester.takeException(), isNull);
      await saveRender(tester, 'rich/$screen-harbor-2x');
      await _accessible(tester);
    });
  }

  testWidgets('hidden balances, Harbor', (tester) async {
    await pumpRender(tester, _page(_mainPage(hidden: true)), palette: harborPalette);
    expect(tester.takeException(), isNull);
    await saveRender(tester, file('wallet', harborPalette, '-hidden'));
    expect(find.bySemanticsLabel(RegExp(r'^Balance hidden')), findsOneWidget);
    final shown = tester.widgetList<RichText>(find.byType(RichText)).map((t) => t.text.toPlainText()).join('\n');
    for (final figure in ['203.16', '90.54', '0.001', '2.7', '6 tokens']) {
      expect(shown.contains(figure), isFalse, reason: '"$figure" is on screen with balances hidden');
    }
    await _accessible(tester);
  });

  group('motion', () {
    /// How much of each part of the page has faded in.
    List<double> shown(WidgetTester tester) => [
          for (final fade in tester.widgetList<FadeTransition>(
            find.descendant(of: find.byType(HomeEntrance), matching: find.byType(FadeTransition)),
          ))
            fade.opacity.value,
        ];

    String figure(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const Key('wallet-balance'))).textSpan!.toPlainText();

    Finder sendCircle() => find.descendant(of: find.byKey(const Key('wallet-action-send')), matching: find.byType(AnimatedScale));

    testWidgets('the page eases in from the top, once', (tester) async {
      await pumpRender(tester, _page(_mainPage()), palette: harborPalette, settle: false);
      final first = shown(tester);
      // The parts the list has built: the panel, its lines, the first list.
      expect(first.length, greaterThanOrEqualTo(3));
      expect(first.every((o) => o < 1), isTrue, reason: 'each part starts on its way in');
      await tester.pump(const Duration(milliseconds: 200));
      final mid = shown(tester);
      expect(mid.first, greaterThan(mid.last), reason: 'the panel leads, the last list follows');
      // While it fades in, the page is still read out whole.
      expect(find.bySemanticsLabel(RegExp(r'^Balance 203\.16 ERG')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(shown(tester).every((o) => o == 1), isTrue);
      // A rebuild with new figures does not play it again.
      await pumpRender(tester, _page(_mainPage(erg: 215.4)), palette: harborPalette, settle: false);
      expect(shown(tester).every((o) => o == 1), isTrue);
      await tester.pumpAndSettle();
    });

    testWidgets('a new balance counts to its figure; the screen reader hears the figure', (tester) async {
      await pumpRender(tester, _page(_mainPage()), palette: harborPalette);
      expect(figure(tester), '203.16${nbsp}ERG');
      await pumpRender(tester, _page(_mainPage(erg: 215.4)), palette: harborPalette, settle: false);
      await tester.pump(const Duration(milliseconds: 150));
      final between = figure(tester);
      expect(between, isNot('203.16${nbsp}ERG'));
      expect(between, isNot('215.4${nbsp}ERG'));
      expect(find.bySemanticsLabel(RegExp(r'^Balance 215\.4 ERG')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(figure(tester), '215.4${nbsp}ERG');
    });

    testWidgets('a round button gives under a finger and springs back', (tester) async {
      await pumpRender(tester, _page(_mainPage()), palette: harborPalette);
      final press = await tester.startGesture(tester.getCenter(find.byKey(const Key('wallet-action-send'))));
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.widget<AnimatedScale>(sendCircle()).scale, lessThan(1));
      await press.up();
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedScale>(sendCircle()).scale, 1);
    });

    testWidgets('with animations removed, nothing moves', (tester) async {
      await pumpRender(tester, _page(_mainPage()), palette: harborPalette, settle: false, reduceMotion: true);
      expect(shown(tester).every((o) => o == 1), isTrue, reason: 'the page is simply there');
      await pumpRender(tester, _page(_mainPage(erg: 215.4)), palette: harborPalette, settle: false, reduceMotion: true);
      await tester.pump();
      expect(figure(tester), '215.4${nbsp}ERG', reason: 'the new figure, at once');
      final press = await tester.startGesture(tester.getCenter(find.byKey(const Key('wallet-action-send'))));
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.widget<AnimatedScale>(sendCircle()).scale, 1);
      await press.up();
      await tester.pumpAndSettle();
    });

    testWidgets('frame strips, Harbor', (tester) async {
      if (renderDirectory() == null) return;
      final background = harborPalette.surfaceHigh;
      final caption = harborPalette.muted;
      // The page opening.
      await pumpRender(tester, _page(_mainPage()), palette: harborPalette, settle: false);
      await saveFrameStrip(
        tester,
        'rich/motion/entrance-harbor',
        at: [for (final ms in [0, 90, 180, 270, 380, 560]) Duration(milliseconds: ms)],
        background: background,
        caption: caption,
      );
      await tester.pumpAndSettle();
      // A balance arriving: 203.16 to 215.4, the hero only.
      await saveFrameStrip(
        tester,
        'rich/motion/count-harbor',
        start: () => pumpRender(tester, _page(_mainPage(erg: 215.4)), palette: harborPalette, settle: false),
        at: [for (final ms in [0, 100, 200, 320, 480, 700]) Duration(milliseconds: ms)],
        crop: const Rect.fromLTWH(0, 76, 390, 120),
        background: background,
        caption: caption,
      );
      await tester.pumpAndSettle();
      // Send pressed and let go.
      final send = tester.getCenter(find.byKey(const Key('wallet-action-send')));
      final rect = Rect.fromCenter(center: send, width: 120, height: 110);
      final press = await tester.startGesture(send);
      await saveFrameStrip(
        tester,
        'rich/motion/press-harbor',
        at: [for (final ms in [0, 140, 200, 280]) Duration(milliseconds: ms)],
        crop: rect,
        background: background,
        caption: caption,
      );
      await press.up();
      await saveFrameStrip(
        tester,
        'rich/motion/release-harbor',
        at: [for (final ms in [0, 50, 110, 200]) Duration(milliseconds: ms)],
        crop: rect,
        background: background,
        caption: caption,
      );
      await tester.pumpAndSettle();
    });
  });
}
