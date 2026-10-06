import 'dart:math' as math;

import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/theme/argus_tones.dart';
import 'package:argus_wallet/ui/home/home_hero.dart';
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
/// that carry meaning on their own, 3:1. Checked from the tokens because
/// sampling the antialiased glyphs of a render under-reads thin text.
void main() {
  for (final palette in allPalettes) {
    test('${palette.name}: the home screens meet WCAG AA', () {
      final colors = ArgusColors.fromSpec(palette);
      final theme = argusThemeFor(palette);
      final dark = palette.isDark;
      final page = palette.background;
      final surface = palette.surface;
      // The raised panel shades from its surface to its foot.
      final grounds = {
        'page': page,
        'sheet and panel top': surface,
        'panel foot': raisedPanelFoot(theme),
      };
      final incoming = dark ? mossBright : moss;
      final warn = dark ? rustBright : rust;
      final text = <String, Color>{
        'ink': palette.ink,
        'muted': colors.muted,
        'a link or Tidy up': colors.accentText,
        'an incoming amount, a rise': incoming,
        'a fall, "Fragmented"': warn,
      };
      final short = <String>[
        for (final MapEntry(key: what, value: fg) in text.entries)
          for (final MapEntry(key: where, value: bg) in grounds.entries)
            if (contrast(fg, bg) < 4.5) '$what on the $where (${contrast(fg, bg).toStringAsFixed(2)})',
      ];
      final icons = <String, (Color, Color)>{
        'the selected tab': (colors.accentText, Color.alphaBlend(palette.accent.withValues(alpha: 0.18), page)),
        'the main action': (colors.onAccent, palette.accent),
        'the other actions': (palette.ink, colors.inset),
        'the sync dot': (moss, page),
      };
      for (final MapEntry(key: what, value: (fg, bg)) in icons.entries) {
        if (contrast(fg, bg) < 3) short.add('$what (${contrast(fg, bg).toStringAsFixed(2)})');
      }
      expect(short, isEmpty, reason: palette.name);
    });
  }
}
