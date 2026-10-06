import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Screenshots of real screens for a person to look at, written under
/// `<repo>/ui-renders/` (never committed: the folder ignores itself). Off
/// unless ARGUS_RENDER or ARGUS_UI_RENDERS is set, so an ordinary test run
/// writes nothing. ARGUS_UI_RENDERS may also name another directory.
final renderEnabled =
    Platform.environment['ARGUS_RENDER'] != null || (Platform.environment['ARGUS_UI_RENDERS'] ?? '').isNotEmpty;

const renderBoundaryKey = ValueKey('render-boundary');

/// The phone the renders are drawn for, in logical pixels.
const renderSize = Size(390, 844);
const renderPixelRatio = 2.0;

/// A status bar's worth of inset, as on a real phone.
const _statusBar = 24.0;

final _boundary = GlobalKey();

bool _fontsLoaded = false;

/// The app's own fonts, plus the Material icon font, so renders show text
/// and icons as the phone does rather than test boxes. Also loads Roboto
/// from the Flutter SDK to stand in for the phone's system fallback: the
/// brand fonts have no ≈ or Σ.
Future<void> loadAppFonts() async {
  if (_fontsLoaded) return;
  _fontsLoaded = true;
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

/// The home screens' render tests call it by this name.
Future<void> loadRenderFonts() => loadAppFonts();

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
  if (!renderEnabled) return null;
  final setting = Platform.environment['ARGUS_UI_RENDERS'] ?? '';
  final custom = setting.isNotEmpty && setting != '1' && setting != 'true' && setting != '0';
  final dir = Directory(custom ? setting : '${Directory.current.parent.path}/ui-renders');
  dir.createSync(recursive: true);
  final ignore = File('${dir.path}/.gitignore');
  if (!ignore.existsSync()) ignore.writeAsStringSync('# Screenshots from the render tests\n*\n');
  return dir;
}

Future<void> _writePng(WidgetTester tester, RenderRepaintBoundary boundary, String name, double pixelRatio) async {
  final dir = renderDirectory();
  if (dir == null) return;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final file = File('${dir.path}/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
  });
}

/// Saves the frame [pumpRender] drew, modal sheets included, as
/// [name].png; a name with slashes lands in subfolders.
Future<void> saveRender(WidgetTester tester, String name) async {
  final boundary = _boundary.currentContext?.findRenderObject();
  if (boundary is! RenderRepaintBoundary) return;
  await _writePng(tester, boundary, name, renderPixelRatio);
}

/// Writes what [renderBoundaryKey] shows to `ui-renders/<name>.png`.
Future<void> renderPng(WidgetTester tester, String name) async {
  if (!renderEnabled) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(renderBoundaryKey));
  await _writePng(tester, boundary, name, 2);
}
