import 'dart:math' as math;

import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/theme/argus_tones.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG contrast ratio between two opaque colours.
double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Every text and icon colour the home screens set, against every ground
/// it is set on, in every palette a user can pick. Text needs 4.5:1; icons
/// that carry meaning on their own, and a control's shape, 3:1. Checked
/// from the tokens because sampling the antialiased glyphs of a render
/// under-reads thin text.
void main() {
  for (final palette in allPalettes) {
    final colors = ArgusColors.fromSpec(palette);
    final dark = palette.isDark;
    final scene = palette.scene;
    final text = <String, Color>{
      'ink': palette.ink,
      'muted': colors.muted,
      'a link or Tidy up': colors.accentText,
      'an incoming amount, a rise': dark ? mossBright : moss,
      'a fall, "Fragmented"': dark ? rustBright : rust,
    };

    test('${palette.name}: the home pages meet WCAG AA', () {
      final grounds = {
        'page': palette.background,
        'sheet': palette.surface,
        // A glass card or pill on the page.
        'glass on the page': Color.alphaBlend(scene.glassFill, palette.background),
        'the glass sheen': Color.alphaBlend(scene.glassSheen, Color.alphaBlend(scene.glassFill, palette.background)),
      };
      final short = <String>[
        for (final MapEntry(key: what, value: fg) in text.entries)
          for (final MapEntry(key: where, value: bg) in grounds.entries)
            if (contrast(fg, bg) < 4.5) '$what on the $where (${contrast(fg, bg).toStringAsFixed(2)})',
      ];
      final icons = <String, (Color, Color)>{
        'the selected tab': (colors.accentText, Color.alphaBlend(palette.accent.withValues(alpha: 0.22), palette.background)),
        'the sync dot': (moss, palette.background),
      };
      for (final MapEntry(key: what, value: (fg, bg)) in icons.entries) {
        if (contrast(fg, bg) < 3) short.add('$what (${contrast(fg, bg).toStringAsFixed(2)})');
      }
      expect(short, isEmpty, reason: palette.name);
    });

    test('${palette.name}: the balance reads on every part of the scene it can fall on', () {
      // The sky, its middle as it settles into the page, the haze round the
      // light at its strongest, and each ridge at its top; and a pill of
      // glass on the brightest of them. The eclipse's rim and the light on
      // the ridges are thin lines no text sits on.
      final skyMid = Color.lerp(scene.sky, palette.background, 0.55)!;
      final grounds = <String, Color>{
        'the sky': scene.sky,
        'the sky settling': skyMid,
        'the haze': Color.alphaBlend(scene.haze, scene.sky),
        'a lit slope': Color.alphaBlend(scene.lit, Color.alphaBlend(scene.haze, scene.ridges[1])),
        for (final (i, ridge) in scene.ridges.indexed) ...{
          'ridge ${i + 1}': ridge,
          'ridge ${i + 1} in the haze': Color.alphaBlend(scene.haze, ridge),
        },
      };
      grounds['glass on the haze'] = Color.alphaBlend(scene.glassFill, grounds['the haze']!);
      grounds['glass on the far ridge'] = Color.alphaBlend(scene.glassFill, scene.ridges.first);
      final short = <String>[
        for (final MapEntry(key: what, value: fg) in text.entries)
          for (final MapEntry(key: where, value: bg) in grounds.entries)
            if (contrast(fg, bg) < 4.5) '$what on $where (${contrast(fg, bg).toStringAsFixed(2)})',
      ];
      expect(short, isEmpty, reason: palette.name);
    });

    test('${palette.name}: the actions and the glass hold their shape', () {
      final behind = Color.alphaBlend(scene.haze, scene.ridges.first);
      // Send's mark on both ends of its gradient, as an icon that carries
      // the action alone.
      for (final ground in [scene.sendTop, scene.sendBottom]) {
        expect(contrast(scene.onSend, ground), greaterThanOrEqualTo(3), reason: '${palette.name}: the mark on Send');
      }
      // Send stands off the scene.
      expect(contrast(scene.sendBottom, behind), greaterThanOrEqualTo(1.6), reason: '${palette.name}: Send on the scene');
      // A ring, and the edge of a pane of glass, show: quietly, since a
      // name under each action and the words on each pane carry them.
      expect(contrast(Color.alphaBlend(scene.ring, behind), behind), greaterThan(1.3), reason: '${palette.name}: a ring');
      expect(
        contrast(Color.alphaBlend(scene.glassBorder, palette.background), palette.background),
        greaterThan(1.12),
        reason: '${palette.name}: a pane\'s edge',
      );
      // The light is the scene's brightest part, apart from the page.
      expect(contrast(scene.glow, palette.background), greaterThan(2), reason: '${palette.name}: the glow');
    });
  }
}
