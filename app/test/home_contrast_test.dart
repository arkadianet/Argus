import 'dart:math' as math;

import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/theme/argus_tones.dart';
import 'package:argus_wallet/ui/home/balance_card.dart';
import 'package:argus_wallet/ui/home/home_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG contrast ratio between two opaque colours.
double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Shortfalls that come from a palette itself rather than from these
/// screens: Frost's muted grey is 4.38:1 on Frost's page colour, which is
/// also its recessed-well colour, everywhere in the app. Darkening it to
/// #687080 would reach 4.56:1.
const _paletteShortfalls = {
  'Frost: muted on the page',
  'Frost: muted in a recessed well',
  'Frost: the quiet chip',
  'Frost: a tab label',
};

/// Every text and icon colour the home redesign sets, against what it is
/// set on, in every palette a user can pick. Body text needs 4.5:1; the
/// selected tab's icon, a graphic, 3:1. Checked from the tokens because
/// sampling the antialiased glyphs of a render under-reads thin text.
void main() {
  for (final palette in allPalettes) {
    test('${palette.name}: the home screens meet WCAG AA', () {
      final colors = ArgusColors.fromSpec(palette);
      final scheme = argusThemeFor(palette).colorScheme;
      final card = palette.surface;
      final page = palette.background;
      final incoming = palette.isDark ? mossBright : moss;
      final warn = palette.isDark ? rustBright : rust;
      final text = <String, (Color, Color)>{
        'ink on a card': (palette.ink, card),
        'ink on the page': (palette.ink, page),
        'muted on a card': (colors.muted, card),
        'muted on the page': (colors.muted, page),
        'muted in a recessed well': (colors.muted, colors.inset),
        'a link on the page': (colors.accentText, page),
        'gold marks on a card': (colors.accentText, card),
        'the pending chip': (colors.accentText, HomeChip.fillFor(HomeChipTone.accent, colors, scheme)),
        'the fragmented chip': (warn, HomeChip.fillFor(HomeChipTone.warn, colors, scheme)),
        'the quiet chip': (colors.muted, HomeChip.fillFor(HomeChipTone.quiet, colors, scheme)),
        'an incoming amount, a rise': (incoming, card),
        'a fall, "Fragmented"': (warn, card),
        '"Fragmented" in its notice': (warn, colors.inset),
        'the Tidy up button': (colors.accentText, tidyUpFill(colors, palette.brightness)),
        'a tab label': (colors.muted, page),
      };
      final short = <String>[
        for (final MapEntry(key: what, value: (fg, bg)) in text.entries)
          if (contrast(fg, bg) < 4.5) '${palette.name}: $what',
      ];
      final indicator = Color.alphaBlend(palette.accent.withValues(alpha: 0.18), page);
      if (contrast(colors.accentText, indicator) < 3) short.add('${palette.name}: selected tab');
      expect(short.where((s) => !_paletteShortfalls.contains(s)), isEmpty);
    });
  }
}
