import 'package:flutter/material.dart';

import '../../theme/argus_theme.dart';

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

/// Where a row's text starts, for hairlines that begin under it.
const homeTextStart = homeGutter + homeMarkSize + 12;

/// Figures line up digit for digit; Karla and Newsreader both carry
/// tabular figures.
const tabularFigures = [FontFeature.tabularFigures()];

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
    final ink = Theme.of(context).colorScheme.onSurface;
    final muted = ArgusColors.of(context).muted;
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

/// A rule one device pixel thick, inset to the gutters (or to a row's text
/// start), in the palette's outline colour.
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
        child: ColoredBox(color: Theme.of(context).colorScheme.outline),
      ),
    );
  }
}
