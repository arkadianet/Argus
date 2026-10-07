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
ThemeData renderTheme(PaletteSpec palette) => withRenderFallback(argusThemeFor(palette));

/// [theme] with Roboto behind its fonts, for a render of a screen that
/// takes its theme from elsewhere.
ThemeData withRenderFallback(ThemeData theme) =>
    theme.copyWith(textTheme: theme.textTheme.apply(fontFamilyFallback: const ['Roboto']));

/// Pumps [screen] as the whole app on a [renderSize] phone, or [height]
/// tall, with text at [textScale]. Settles every animation unless
/// [settle] is false, for a render of the motion itself; with
/// [reduceMotion], as with the system setting to remove animations.
Future<void> pumpRender(
  WidgetTester tester,
  Widget screen, {
  required PaletteSpec palette,
  double textScale = 1,
  double? height,
  bool settle = true,
  bool reduceMotion = false,
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
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale), disableAnimations: reduceMotion),
          child: child!,
        ),
        home: screen,
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
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
  if (boundary is! RenderRepaintBoundary || renderDirectory() == null) return;
  // Tests draw shadows as hard solid shapes, so a render would show a
  // ledge under every soft shadow. A render is for a person, so for the
  // one frame it saves, shadows are drawn as the phone draws them. The flag
  // is back before the test ends, as the test binding requires.
  debugDisableShadows = false;
  try {
    _repaintAll(boundary);
    await tester.pump();
    await _writePng(tester, boundary, name, renderPixelRatio);
  } finally {
    debugDisableShadows = true;
    _repaintAll(boundary);
    await tester.pump();
  }
}

void _repaintAll(RenderObject node) {
  node.markNeedsPaint();
  node.visitChildren(_repaintAll);
}

/// The frame on screen now, shadows drawn as on the phone, at [pixelRatio].
Future<ui.Image?> _grab(WidgetTester tester, double pixelRatio) async {
  final boundary = _boundary.currentContext?.findRenderObject();
  if (boundary is! RenderRepaintBoundary) return null;
  debugDisableShadows = false;
  try {
    _repaintAll(boundary);
    await tester.pump();
    return await tester.runAsync(() => boundary.toImage(pixelRatio: pixelRatio));
  } finally {
    debugDisableShadows = true;
    _repaintAll(boundary);
    await tester.pump();
  }
}

/// A strip of frames of a motion, side by side and captioned with their
/// times, saved as [name].png: one frame at each of [at] (times from now,
/// in order), after [start] sets the motion going. Frames are drawn at
/// half the render's scale, so a strip of six stays a sensible width.
/// Does nothing unless renders were asked for.
Future<void> saveFrameStrip(
  WidgetTester tester,
  String name, {
  required List<Duration> at,
  required Color background,
  required Color caption,
  Future<void> Function()? start,
  Rect? crop,
}) async {
  final dir = renderDirectory();
  if (dir == null) return;
  await start?.call();
  const scale = 1.0;
  final frames = <(Duration, ui.Image)>[];
  var now = Duration.zero;
  for (final time in at) {
    await tester.pump(time - now);
    now = time;
    final image = await _grab(tester, scale);
    if (image != null) frames.add((time, image));
  }
  if (frames.isEmpty) return;
  final source = crop ?? Offset.zero & Size(frames.first.$2.width / scale, frames.first.$2.height / scale);
  const gap = 12.0, label = 28.0;
  final width = frames.length * source.width + (frames.length + 1) * gap;
  final height = source.height + label + gap;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Rect.fromLTWH(0, 0, width, height), Paint()..color = background);
  for (final (i, (time, image)) in frames.indexed) {
    final x = gap + i * (source.width + gap);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(source.left * scale, source.top * scale, source.width * scale, source.height * scale),
      Rect.fromLTWH(x, gap, source.width, source.height),
      Paint()..filterQuality = FilterQuality.high,
    );
    final text = TextPainter(
      text: TextSpan(text: '${time.inMilliseconds} ms', style: TextStyle(fontFamily: 'Karla', fontSize: 14, color: caption)),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, Offset(x + (source.width - text.width) / 2, gap + source.height + 6));
    text.dispose();
  }
  final picture = recorder.endRecording();
  await tester.runAsync(() async {
    final strip = await picture.toImage(width.ceil(), height.ceil());
    final bytes = await strip.toByteData(format: ui.ImageByteFormat.png);
    strip.dispose();
    for (final (_, image) in frames) {
      image.dispose();
    }
    final file = File('${dir.path}/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
  });
  picture.dispose();
}

/// Writes what [renderBoundaryKey] shows to `ui-renders/<name>.png`.
Future<void> renderPng(WidgetTester tester, String name) async {
  if (!renderEnabled) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(renderBoundaryKey));
  await _writePng(tester, boundary, name, 2);
}
