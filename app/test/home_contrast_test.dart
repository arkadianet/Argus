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
/// that carry meaning on their own, and a control's shape, 3:1. Checked
/// from the tokens because sampling the antialiased glyphs of a render
/// under-reads thin text.
void main() {
  for (final palette in allPalettes) {
    test('${palette.name}: the home pages meet WCAG AA', () {
      final colors = ArgusColors.fromSpec(palette);
      final dark = palette.isDark;
      final grounds = {'page': palette.background, 'sheet': palette.surface};
      final text = <String, Color>{
        'ink': palette.ink,
        'muted': colors.muted,
        'a link or Tidy up': colors.accentText,
        'an incoming amount, a rise': dark ? mossBright : moss,
        'a fall, "Fragmented"': dark ? rustBright : rust,
      };
      final short = <String>[
        for (final MapEntry(key: what, value: fg) in text.entries)
          for (final MapEntry(key: where, value: bg) in grounds.entries)
            if (contrast(fg, bg) < 4.5) '$what on the $where (${contrast(fg, bg).toStringAsFixed(2)})',
      ];
      final icons = <String, (Color, Color)>{
        'the selected tab': (colors.accentText, Color.alphaBlend(palette.accent.withValues(alpha: 0.18), palette.background)),
        'the sync dot': (moss, palette.background),
      };
      for (final MapEntry(key: what, value: (fg, bg)) in icons.entries) {
        if (contrast(fg, bg) < 3) short.add('$what (${contrast(fg, bg).toStringAsFixed(2)})');
      }
      expect(short, isEmpty, reason: palette.name);
    });

    {
      final hero = palette.hero;
      test('${palette.name}: the hero meets WCAG AA on its own surface', () {
        final short = <String>[];
        // The panel may shade toward its foot: everything on it holds on both.
        void atLeast(String what, Color fg, Color bg, double ratio) {
          for (final ground in {bg == hero.surface ? hero.surfaceEnd : bg, bg}) {
            final got = contrast(fg, ground);
            if (got < ratio) short.add('$what: ${got.toStringAsFixed(2)} < $ratio');
          }
        }

        // Text, all of it set straight on the panel: the balance and its
        // lines, the actions' names, the price strip.
        atLeast('ink', hero.ink, hero.surface, 4.5);
        atLeast('muted', hero.muted, hero.surface, 4.5);
        atLeast('accent (links, the price chart)', hero.accent, hero.surface, 4.5);
        atLeast('positive (a rise)', hero.positive, hero.surface, 4.5);
        atLeast('negative (a fall, a stale price)', hero.negative, hero.surface, 4.5);
        // The filled action: its shape against the panel, and its mark,
        // held to text's ratio.
        atLeast('the filled action on the panel', hero.filled, hero.surface, 3);
        atLeast('the mark on the filled action', hero.onFilled, hero.filled, 4.5);
        // The other actions: named under the well, so the well itself only
        // has to show; its mark is held to text's ratio.
        atLeast('the mark in a tonal well', hero.onTonal, hero.tonal, 4.5);
        atLeast('the eye and the chevrons', hero.ink, hero.surface, 3);
        expect(short, isEmpty, reason: palette.name);
      });

      test('${palette.name}: the hero stands apart from the page, Send apart on it', () {
        // Apart from the page by its colour alone: no border, no shadow.
        expect(contrast(hero.surface, palette.background), greaterThan(1.2));
        expect(hero.surface, isNot(palette.background));
        // A divider and a well show, quietly. Neither carries meaning
        // alone, so neither is held to a WCAG ratio.
        expect(contrast(hero.divider, hero.surface), greaterThan(1.25));
        expect(contrast(hero.tonal, hero.surface), greaterThan(1.1));
        expect(contrast(hero.tonal, hero.surface), lessThan(contrast(hero.filled, hero.surface)),
            reason: 'Send stays the one filled action');
      });
    }
  }

  test('what reads the theme directly on the hero reads the hero\'s colours', () {
    for (final palette in allPalettes) {
      final hero = RaisedPanel.heroTheme(argusThemeFor(palette), palette.hero);
      expect(hero.colorScheme.onSurface, palette.hero.ink, reason: palette.name);
      expect(hero.brightness, palette.hero.brightness, reason: palette.name);
      expect(hero.extension<ArgusColors>()!.muted, palette.hero.muted, reason: palette.name);
      expect(hero.extension<ArgusColors>()!.accentText, palette.hero.accent, reason: palette.name);
      expect(hero.extension<ArgusColors>()!.accent, palette.hero.filled, reason: palette.name);
    }
  });
}
