import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Screenshots of real screens for a person to look at, written to
/// `<repo>/ui-renders/` (never committed). Off unless ARGUS_RENDER is set,
/// so an ordinary test run writes nothing.
final renderEnabled = Platform.environment['ARGUS_RENDER'] != null;

const renderBoundaryKey = ValueKey('render-boundary');

bool _fontsLoaded = false;

/// The app's own fonts, plus the Material icon font, so renders show text
/// and icons as the phone does rather than test boxes.
Future<void> loadAppFonts() async {
  if (_fontsLoaded) return;
  _fontsLoaded = true;
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      loader.addFont(
        Future.value(ByteData.sublistView(File(f).readAsBytesSync())),
      );
    }
    await loader.load();
  }

  await family('Newsreader', [
    'assets/fonts/Newsreader-Regular.ttf',
    'assets/fonts/Newsreader-Semibold.ttf',
  ]);
  await family('Karla', [
    'assets/fonts/Karla-Regular.ttf',
    'assets/fonts/Karla-Medium.ttf',
  ]);
  await family('IBMPlexMono', ['assets/fonts/IBMPlexMono-Regular.ttf']);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ??
      // flutter_tester sits in <root>/bin/cache/artifacts/engine/<platform>/.
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
  final icons = File('$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    await family('MaterialIcons', [icons.path]);
  }
}

/// Writes what [renderBoundaryKey] shows to `ui-renders/<name>.png`.
Future<void> renderPng(WidgetTester tester, String name) async {
  if (!renderEnabled) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(renderBoundaryKey),
  );
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  });
  final dir = Directory('../ui-renders')..createSync(recursive: true);
  File('${dir.path}/$name.png').writeAsBytesSync(bytes!);
}
