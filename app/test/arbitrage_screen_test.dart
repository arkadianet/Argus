import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:argus_wallet/services/amm_service.dart';
import 'package:argus_wallet/services/arbitrage_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/ui/arbitrage_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'arbitrage_service_test.dart' show FakeApi, opportunityJson, scanJson, tok;

/// Counts scans; can answer with no opportunities.
class ScreenApi extends FakeApi {
  int scans = 0;
  bool empty = false;

  @override
  Future<String> scan({String? nodeUrl, required String optionsJson}) async {
    scans++;
    lastScanOptions = optionsJson;
    final second = opportunityJson(net: 12000000, trusted: false);
    for (final leg in second['legs'] as List) {
      leg['pool_id'] = (leg['pool_id'] as String).replaceAll('a', 'f').replaceAll('c', '9');
    }
    return jsonEncode(scanJson(opportunities: empty ? [] : [opportunityJson(), second], height: tip));
  }
}

const _names = AmmPoolSet(truncated: false, pools: [], tokens: {tok: AmmTokenMeta(name: 'SPF', decimals: 6)});

const _args = WalletRouteArgs(
  senderAddress: '9fSender',
  receiveAddress: '9fReceive',
  changeAddress: '9fChange',
  spendableNano: 120000000000,
);

final _boundary = GlobalKey();

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> paths) async {
    final loader = FontLoader(name);
    for (final p in paths) {
      loader.addFont(File(p).readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
    }
    await loader.load();
  }

  await family('Karla', ['assets/fonts/Karla-Regular.ttf', 'assets/fonts/Karla-Medium.ttf']);
  await family('Newsreader', ['assets/fonts/Newsreader-Regular.ttf', 'assets/fonts/Newsreader-Semibold.ttf']);
  await family('IBMPlexMono', ['assets/fonts/IBMPlexMono-Regular.ttf']);
  final root = Platform.environment['FLUTTER_ROOT'];
  final icons = File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (root != null && icons.existsSync()) await family('MaterialIcons', [icons.path]);
}

Future<void> _pump(
  WidgetTester tester,
  FakeApi api, {
  double textScale = 1,
  bool dark = true,
  WalletRouteArgs args = _args,
}) async {
  tester.view.physicalSize = const Size(390, 844) * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: argusTheme(watchful: dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: WalletArgsScope(args: args, child: child!),
        ),
        home: ArbitrageScreen(
          service: ArbitrageService(api: api, nodeUrl: () => 'http://node', handle: () => BigInt.one),
          names: _names,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Writes a PNG of the whole app to `<worktree>/ui-renders/` when
/// `ARGUS_RENDER` is set, for looking at; normal runs write nothing.
Future<void> _render(WidgetTester tester, String name) async {
  if (Platform.environment['ARGUS_RENDER'] == null) return;
  await tester.runAsync(() async {
    final boundary = _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('../ui-renders')..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(_loadFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('says up front that bots compete and quotes go stale, then lists routes', (tester) async {
    final api = ScreenApi();
    await _pump(tester, api);
    expect(api.scans, 1, reason: 'one scan when the screen opens');
    expect(find.byKey(const Key('arb-warning')), findsOneWidget);
    expect(find.textContaining('Bots trade these gaps'), findsOneWidget);
    expect(find.textContaining('seconds old'), findsOneWidget);
    expect(find.text('ERG → SPF → ERG'), findsNWidgets(2));
    expect(find.text('+0.025 ERG'), findsOneWidget);
    expect(find.text('Unverified token'), findsOneWidget);
    expect(find.textContaining('1 left out: a pool on the route is already being traded'), findsOneWidget);
    await _render(tester, 'arbitrage_list');
  });

  testWidgets('fits a phone at twice the text size', (tester) async {
    await _pump(tester, ScreenApi(), textScale: 2);
    expect(tester.takeException(), isNull);
    await _render(tester, 'arbitrage_list_2x');
    final card = find.byKey(Key('arb-opp-${'a' * 64}>${'c' * 64}'));
    await tester.scrollUntilVisible(card, 300, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _render(tester, 'arbitrage_card_2x');
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _render(tester, 'arbitrage_review_2x');
  });

  testWidgets('the review shows every leg, every fee and the risk before anything is signed', (tester) async {
    final api = ScreenApi();
    await _pump(tester, api);
    await tester.tap(find.byKey(Key('arb-opp-${'a' * 64}>${'c' * 64}')));
    await tester.pumpAndSettle();
    expect(find.text('Review arbitrage'), findsOneWidget);
    expect(find.text('46.3 ERG → 4,629 SPF'), findsOneWidget);
    expect(find.text('4,629 SPF → 46.3294 ERG'), findsOneWidget);
    expect(find.text('Miner fees (2 legs)'), findsOneWidget);
    expect(find.text('Argus fees (2 legs)'), findsOneWidget);
    expect(find.text('Expected net profit'), findsOneWidget);
    expect(find.text('+0.025 ERG'), findsWidgets);
    expect(find.textContaining('which would cost about 0.28 ERG'), findsOneWidget);
    expect(find.text('Sign & broadcast 2 legs'), findsOneWidget);
    await _render(tester, 'arbitrage_review');
    // Turning the review down forgets the prepared chain.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.discarded, [BigInt.from(42)]);
  });

  testWidgets('a watch-only wallet sees the trade but cannot sign it', (tester) async {
    await _pump(
      tester,
      ScreenApi(),
      args: const WalletRouteArgs(watchOnly: true, senderAddress: 'a', receiveAddress: 'b', changeAddress: 'c'),
    );
    await tester.tap(find.byKey(Key('arb-opp-${'a' * 64}>${'c' * 64}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('arb-sign')), findsNothing);
    expect(find.textContaining('watch-only'), findsOneWidget);
  });

  testWidgets('a stranded chain says what the wallet holds and offers the sale back at a fresh quote', (tester) async {
    final api = ScreenApi()
      ..executeAnswer = jsonEncode({
        'status': 'stranded',
        'tx_ids': ['t1'],
        'wallet_deltas': [-46302200000],
        'failed_leg': 1,
        'error': 'Double spending attempt',
        'holding': {'token_id': tok, 'amount': 4629000000, 'box_id': 'e' * 64, 'after_leg': 1},
      });
    await _pump(tester, api);
    await tester.tap(find.byKey(Key('arb-opp-${'a' * 64}>${'c' * 64}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('arb-sign')));
    await tester.pumpAndSettle();
    expect(find.text('A leg did not land'), findsOneWidget);
    expect(find.textContaining('You now hold 4,629 SPF, bought by leg 1, instead of ERG'), findsOneWidget);
    await _render(tester, 'arbitrage_stranded');
    await tester.tap(find.byKey(const Key('arb-unwind')));
    await tester.pumpAndSettle();
    // The ordinary confirm sheet, with the fresh quote, before any signing.
    expect(find.text('Sell SPF back to ERG'), findsWidgets);
    expect(find.text('You sell'), findsOneWidget);
    expect(find.text('46.01 ERG'), findsOneWidget);
    expect(find.text('Sign & broadcast sale'), findsOneWidget);
    await _render(tester, 'arbitrage_unwind_confirm');
  });

  testWidgets('says plainly when there is no gap', (tester) async {
    await _pump(tester, ScreenApi()..empty = true, dark: false);
    expect(find.text('No gap worth taking'), findsOneWidget);
    await _render(tester, 'arbitrage_empty_light');
  });

  testWidgets('scans stop when the app leaves the foreground and resume with it', (tester) async {
    final api = ScreenApi();
    await _pump(tester, api);
    expect(api.scans, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(minutes: 3));
    expect(api.scans, 1, reason: 'nothing scans in the background');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(api.scans, 2);
    await tester.pump(arbScanInterval);
    expect(api.scans, 2, reason: 'no new block, no new read of every pool');
    api.tip++;
    await tester.pump(arbScanInterval);
    expect(api.scans, 3);
  });

  testWidgets('the minimum profit can be changed and is used by the next scan', (tester) async {
    final api = ScreenApi();
    await _pump(tester, api);
    await tester.tap(find.byKey(const Key('arb-min-profit-row')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('arb-min-profit')), '0.002');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect((jsonDecode(api.lastScanOptions!) as Map)['min_profit_nano'], 2000000);
    expect(find.text('0.002 ERG'), findsOneWidget);
  });
}
