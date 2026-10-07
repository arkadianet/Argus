import 'package:flutter/material.dart';

import '../../theme/argus_theme.dart';
import '../../theme/argus_tones.dart';

/// The home screens' visual language, kept in one place.
///
/// One type scale (spaced capitals for a list's name, three sizes, and
/// the serif balance), spacing in steps of four, one hairline. Depth comes
/// from the scene the pages open on and the glass laid over it
/// (home_scene.dart, home_glass.dart). Everything that sets type or space
/// on these screens reads it from here, which is what lets several lists on
/// one page read as one composed page rather than a stack of boxes.

/// Side margin shared by every row, so every figure on a page ends on the
/// same edge.
const homeGutter = 24.0;

/// The one corner radius: the raised panel, sheets and their ripples.
const homeRadius = buttonRadius;

/// The side margin where [context] sits. On the page it is [homeGutter].
/// Inside a [HomeInset] (a section's soft surface, which is itself inset
/// from the screen) it is what is left of the gutter, so the rows' figures
/// still end on the page's one edge.
double homeGutterOf(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<HomeInset>()?.gutter ?? homeGutter;

/// Marks content that sits on a surface already inset from the screen's
/// edge by `homeGutter - gutter`.
class HomeInset extends InheritedWidget {
  const HomeInset({super.key, required this.gutter, required super.child});

  final double gutter;

  @override
  bool updateShouldNotify(HomeInset old) => old.gutter != gutter;
}

/// A two-line row (title and detail) and a one-line row (a note).
const homeRowHeight = 56.0;
const homeLineHeight = 48.0;

/// Wallet initials, token letters and activity arrows share one size.
const homeMarkSize = 40.0;

/// Icons inside the content; the app bar and tab bar keep their 24.
const homeIconSize = 20.0;

/// Figures line up digit for digit; Karla and Newsreader both carry
/// tabular figures.
const tabularFigures = [FontFeature.tabularFigures()];

/// The colours text and marks take on the home pages. The scene and its
/// glass are held to the page's own type, so one set serves everywhere.
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
///
/// Hierarchy comes from size and face as much as from colour: a section
/// opens on a serif title, a row's name is a size above its detail line,
/// and labels are small tracked capitals.
class HomeText {
  const HomeText._({
    required this.title,
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
      // A heading within the page ("Recent Activity"): a size up, plain.
      title: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        height: 1.25,
        letterSpacing: 0.3,
        color: ink,
      ),
      // Names and figures are set in the regular cut: on the dark glass a
      // size and ink above their detail lines carry them.
      primary: TextStyle(
        fontSize: 14.5,
        fontWeight: FontWeight.w400,
        height: 1.3,
        color: ink,
        fontFeatures: tabularFigures,
      ),
      secondary: TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w400,
        height: 1.3,
        color: muted,
        fontFeatures: tabularFigures,
      ),
      label: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        height: 1.3,
        letterSpacing: 2.6,
        color: muted,
      ),
      // A button sets its label's style outright instead of inheriting it,
      // so this one names its family.
      link: TextStyle(fontFamily: 'Karla', fontSize: 13, fontWeight: FontWeight.w500, height: 1.3, color: ink),
    );
  }

  /// A heading within the page: 16, regular, ink.
  final TextStyle title;

  /// Row titles, amounts: 14.5, regular, ink.
  final TextStyle primary;

  /// Details, values, notes: 12.5, regular, muted.
  final TextStyle secondary;

  /// A list's name and the balance's label: 12, widely spaced capitals.
  final TextStyle label;

  /// Text-button labels ("View all", "Learn more"): 13, medium, ink.
  final TextStyle link;

  final Color ink;
  final Color muted;
}

/// Whether text is large enough that two-column rows stack their figures.
bool homeLargeText(BuildContext context) => MediaQuery.textScalerOf(context).scale(14) / 14 > 1.35;

/// A rule one device pixel thick, in the palette's outline colour, inset to the page's gutters or (indents of
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
