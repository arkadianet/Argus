import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Renders whole screens with the app's real fonts and saves them as PNGs.
///
/// PNGs are written only when ARGUS_UI_RENDERS is set: `1` writes to
/// `<repo>/ui-renders/`, any other value is taken as the directory. The
/// directory gets a `.gitignore` of `*` so renders never get committed.

/// The phone the renders are drawn for, in logical pixels.
const renderSize = Size(390, 844);
const renderPixelRatio = 2.0;

/// A status bar's worth of inset, as on a real phone.
const _statusBar = 24.0;

final _boundary = GlobalKey();

/// Loads the fonts the app bundles (Newsreader, Karla, IBM Plex Mono and
/// the Material icons) and Roboto from the Flutter SDK, which stands in
/// for the phone's system fallback: the brand fonts have no ≈ or Σ.
/// Without this the test font draws every glyph as a box.
Future<void> loadRenderFonts() async {
  final manifest = json.decode(await rootBundle.loadString('FontManifest.json')) as List<dynamic>;
  for (final entry in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(entry['family'] as String);
    for (final font in (entry['fonts'] as List<dynamic>).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
  final roboto = FontLoader('Roboto');
  var any = false;
  for (final name in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf']) {
    final file = _sdkFont(name);
    if (file == null) continue;
    roboto.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    any = true;
  }
  if (any) await roboto.load();
}

File? _sdkFont(String name) {
  final starts = <Directory>[
    if (Platform.environment['FLUTTER_ROOT'] case final root?) Directory('$root/bin/cache'),
    File(Platform.resolvedExecutable).parent,
  ];
  for (final start in starts) {
    for (Directory? dir = start; dir != null; dir = dir.parent.path == dir.path ? null : dir.parent) {
      final candidate = File('${dir.path}/artifacts/material_fonts/$name');
      if (candidate.existsSync()) return candidate;
    }
  }
  return null;
}

/// The app's theme for [palette], with Roboto behind the brand fonts for
/// the glyphs they lack, as the phone's own fallback would be.
ThemeData renderTheme(PaletteSpec palette) {
  final theme = argusThemeFor(palette);
  return theme.copyWith(textTheme: theme.textTheme.apply(fontFamilyFallback: const ['Roboto']));
}

/// Pumps [screen] as the whole app on a [renderSize] phone, or [height]
/// tall, with text at [textScale].
Future<void> pumpRender(
  WidgetTester tester,
  Widget screen, {
  required PaletteSpec palette,
  double textScale = 1,
  double? height,
}) async {
  tester.view.physicalSize = Size(renderSize.width, height ?? renderSize.height) * renderPixelRatio;
  tester.view.devicePixelRatio = renderPixelRatio;
  tester.view.padding = const FakeViewPadding(top: _statusBar * renderPixelRatio);
  tester.view.viewPadding = const FakeViewPadding(top: _statusBar * renderPixelRatio);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: renderTheme(palette),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: screen,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Re-pumps [screen] tall enough that the scrolling list under [listKey]
/// shows everything, for a render of the whole page.
Future<void> pumpFullLength(
  WidgetTester tester,
  Widget screen, {
  required Key listKey,
  required PaletteSpec palette,
  double textScale = 1,
}) async {
  final scrollable = find.descendant(of: find.byKey(listKey), matching: find.byType(Scrollable)).first;
  final position = tester.state<ScrollableState>(scrollable).position;
  // A lazy list only estimates the extent of rows it hasn't built; walk to
  // the end until the figure stops moving.
  var extra = -1.0;
  while (extra != position.maxScrollExtent) {
    extra = position.maxScrollExtent;
    position.jumpTo(extra);
    await tester.pump();
  }
  position.jumpTo(0);
  await tester.pump();
  await pumpRender(tester, screen, palette: palette, textScale: textScale, height: renderSize.height + extra);
}

/// Where renders go, or null when they weren't asked for.
Directory? renderDirectory() {
  final setting = Platform.environment['ARGUS_UI_RENDERS'];
  if (setting == null || setting.isEmpty || setting == '0') return null;
  final dir = Directory(setting == '1' || setting == 'true' ? '${Directory.current.parent.path}/ui-renders' : setting);
  dir.createSync(recursive: true);
  final ignore = File('${dir.path}/.gitignore');
  if (!ignore.existsSync()) ignore.writeAsStringSync('# Renders from test/home_design_render_test.dart\n*\n');
  return dir;
}

/// Saves the current frame, modal sheets included, as [name].png.
Future<void> saveRender(WidgetTester tester, String name) async {
  final dir = renderDirectory();
  if (dir == null) return;
  final boundary = _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: renderPixelRatio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await File('${dir.path}/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
  });
}
