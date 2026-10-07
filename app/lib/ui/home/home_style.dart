import 'package:flutter/material.dart';

import '../../theme/argus_theme.dart';
import '../../theme/argus_tones.dart';

/// The home screens' visual language, kept in one place.
///
/// One type scale (three sizes and the hero numeral), spacing in steps of
/// four, one corner radius, one hairline. Everything that sets type or
/// space on these screens reads it from here, which is what lets several
/// lists on one page read as one composed page rather than a stack of
/// blocks.

/// Side margin shared by every row, so every figure on a page ends on the
/// same edge.
const homeGutter = 24.0;

/// The one corner radius: the raised panel, sheets and their ripples.
const homeRadius = buttonRadius;

/// A two-line row (title and detail) and a one-line row (a note).
const homeRowHeight = 56.0;
const homeLineHeight = 48.0;

/// Wallet initials, token letters and activity arrows share one size.
const homeMarkSize = 32.0;

/// Icons inside the content; the app bar and tab bar keep their 24.
const homeIconSize = 20.0;

/// Figures line up digit for digit; Karla and Newsreader both carry
/// tabular figures.
const tabularFigures = [FontFeature.tabularFigures()];

/// Marks what sits on the hero panel, whose surface is the page inverted:
/// everything under it takes its colours from [spec] rather than from the
/// page ([HomeTones]).
class HeroSurface extends InheritedWidget {
  const HeroSurface({super.key, required this.spec, required super.child});

  final HeroSpec spec;

  static HeroSpec? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<HeroSurface>()?.spec;

  @override
  bool updateShouldNotify(HeroSurface old) => old.spec != spec;
}

/// The colours text and marks take where they are set: on the page, or on
/// the hero panel, whose own colours were chosen for its inverted surface.
/// A widget that can sit in either place reads its colours from here, so
/// the same row reads right on both.
class HomeTones {
  const HomeTones._({
    required this.ink,
    required this.muted,
    required this.accent,
    required this.positive,
    required this.negative,
    required this.divider,
    required this.filled,
    required this.onFilled,
    required this.tonal,
    required this.onTonal,
  });

  factory HomeTones.of(BuildContext context) {
    final hero = HeroSurface.maybeOf(context);
    if (hero != null) {
      return HomeTones._(
        ink: hero.ink,
        muted: hero.muted,
        accent: hero.accent,
        positive: hero.positive,
        negative: hero.negative,
        divider: hero.divider,
        filled: hero.filled,
        onFilled: hero.onFilled,
        tonal: hero.tonal,
        onTonal: hero.onTonal,
      );
    }
    final colors = ArgusColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    return HomeTones._(
      ink: scheme.onSurface,
      muted: colors.muted,
      accent: colors.accentText,
      positive: mossFor(context),
      negative: rustFor(context),
      divider: scheme.outline,
      filled: colors.accent,
      onFilled: colors.onAccent,
      tonal: colors.inset,
      onTonal: scheme.onSurface,
    );
  }

  /// Figures and words.
  final Color ink;

  /// Labels and quieter lines.
  final Color muted;

  /// Links and marks in the accent.
  final Color accent;

  /// A rise or something arriving; a fall or something wrong.
  final Color positive;
  final Color negative;

  /// Hairlines.
  final Color divider;

  /// The one filled action and the mark on it.
  final Color filled;
  final Color onFilled;

  /// The other actions' wells and their marks.
  final Color tonal;
  final Color onTonal;
}

/// The type scale. Karla carries 400 and 500 only, so emphasis is 500:
/// a heavier request would be synthesised. The family comes from the
/// theme rather than being named here: a span that names its family drops
/// the fallback fonts it would otherwise inherit, and Karla has no "≈".
class HomeText {
  const HomeText._({
    required this.primary,
    required this.secondary,
    required this.label,
    required this.link,
    required this.ink,
    required this.muted,
  });

  factory HomeText.of(BuildContext context) {
    final tones = HomeTones.of(context);
    final ink = tones.ink;
    final muted = tones.muted;
    return HomeText._(
      ink: ink,
      muted: muted,
      primary: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        height: 1.3,
        color: ink,
        fontFeatures: tabularFigures,
      ),
      secondary: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        height: 1.3,
        color: muted,
        fontFeatures: tabularFigures,
      ),
      label: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        height: 1.3,
        letterSpacing: 1.6,
        color: muted,
      ),
      // A button sets its label's style outright instead of inheriting it,
      // so this one names its family.
      link: TextStyle(fontFamily: 'Karla', fontSize: 13, fontWeight: FontWeight.w500, height: 1.3, color: ink),
    );
  }

  /// Row titles, amounts, links: 15, medium, ink.
  final TextStyle primary;

  /// Details, values, notes: 13, regular, muted.
  final TextStyle secondary;

  /// Section and card labels: 11, medium, tracked capitals.
  final TextStyle label;

  /// Text-button labels ("View all", "Learn more"): 13, medium, ink.
  final TextStyle link;

  final Color ink;
  final Color muted;
}

/// Whether text is large enough that two-column rows stack their figures.
bool homeLargeText(BuildContext context) => MediaQuery.textScalerOf(context).scale(14) / 14 > 1.35;

/// A rule one device pixel thick, in the palette's outline colour (the
/// hero's divider on the hero), inset to the page's gutters or (indents of
/// 0) to the edges of the panel it sits in.
class HomeRule extends StatelessWidget {
  const HomeRule({super.key, this.indent = homeGutter, this.endIndent = homeGutter});

  final double indent;
  final double endIndent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsetsDirectional.only(start: indent, end: endIndent),
      child: SizedBox(
        height: 1 / MediaQuery.devicePixelRatioOf(context),
        width: double.infinity,
        child: ColoredBox(color: HomeTones.of(context).divider),
      ),
    );
  }
}
