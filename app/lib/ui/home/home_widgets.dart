import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/argus_theme.dart';
import '../token_avatar.dart';
import 'home_models.dart';
import 'home_style.dart';

/// Pieces shared by the overview, the wallet page and their sheets.

/// One node for a screen reader: [label] read as a whole, with the tap
/// (and long press) on the node itself.
///
/// Rows set their own label so a row reads as one sentence instead of a
/// list of fragments. Excluding the children's semantics would also drop
/// the ink well's tap, so the tap is given to the node directly.
class TappableNode extends StatelessWidget {
  const TappableNode({
    super.key,
    required this.label,
    required this.onTap,
    required this.child,
    this.onLongPress,
    this.hint,
  });

  final String label;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? hint;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: onTap != null,
      enabled: onTap != null,
      label: label,
      hint: hint,
      onTap: onTap,
      onLongPress: onLongPress,
      excludeSemantics: true,
      child: child,
    );
  }
}

/// A section's label in tracked capitals, with an optional count and a
/// quiet "View all" link at the far edge.
class HomeSectionHeader extends StatelessWidget {
  const HomeSectionHeader({super.key, required this.title, this.count, this.action, this.onAction, this.actionKey});

  final String title;
  final String? count;
  final String? action;
  final VoidCallback? onAction;
  final Key? actionKey;

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: homeGutter, end: homeGutter - 6),
      // A header with a link is a full touch target tall; one without
      // sits closer to its list.
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: action == null ? 40 : homeLineHeight),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                label: count == null ? title : '$title, $count',
                excludeSemantics: true,
                child: Text.rich(
                  TextSpan(
                    text: title.toUpperCase(),
                    children: [if (count != null) TextSpan(text: '   $count')],
                  ),
                  style: t.label,
                ),
              ),
            ),
            if (action != null)
              TextButton(
                key: actionKey,
                onPressed: onAction,
                style: TextButton.styleFrom(
                  foregroundColor: t.ink,
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsetsDirectional.only(start: 10, end: 2),
                  textStyle: t.link,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(action!),
                    Icon(Icons.chevron_right, size: 18, color: t.muted),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A wallet's mark: its initial on the same disc a token gets, or an eye
/// for a wallet watched without keys, so a page of marks reads as one set.
class WalletMark extends StatelessWidget {
  const WalletMark({super.key, required this.name, required this.kind});

  final String name;
  final WalletKind kind;

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    if (kind == WalletKind.seed) {
      return ExcludeSemantics(child: TokenAvatar(label: name.trim(), radius: homeMarkSize / 2));
    }
    return ExcludeSemantics(child: HomeDisc(child: Icon(Icons.visibility_outlined, size: 16, color: colors.muted)));
  }
}

/// The mark disc, for marks that are icons rather than letters.
class HomeDisc extends StatelessWidget {
  const HomeDisc({super.key, required this.child, this.fill});

  final Widget child;
  final Color? fill;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: homeMarkSize,
      height: homeMarkSize,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: fill ?? Theme.of(context).colorScheme.surfaceContainerHighest,
        border: fill == null ? Border.all(color: ArgusColors.of(context).cardBorder) : null,
      ),
      child: child,
    );
  }
}

/// The one row every list on the home screens is made of: a mark, a title
/// over a detail line, and figures over a value on the right, ending on
/// the gutter like every other figure on the page. A footnote can run
/// under the text. At large text sizes the figures move under the title.
class HomeRow extends StatelessWidget {
  const HomeRow({
    super.key,
    required this.leading,
    required this.title,
    required this.semanticLabel,
    this.subtitle,
    this.figure,
    this.subfigure,
    this.footnote,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.inkKey,
    this.hint,
  });

  final Widget leading;
  final Widget title;
  final InlineSpan? subtitle;
  final InlineSpan? figure;
  final InlineSpan? subfigure;
  final Widget? footnote;

  /// A chevron or similar after the figures (sheets only; lists don't
  /// draw one, so the figures keep a single right edge).
  final Widget? trailing;
  final String semanticLabel;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Key? inkKey;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    final large = homeLargeText(context);
    final align = large ? TextAlign.start : TextAlign.end;
    final figures = figure == null && subfigure == null
        ? null
        : Column(
            crossAxisAlignment: large ? CrossAxisAlignment.start : CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (figure != null)
                Text.rich(figure!, style: t.primary, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: align),
              if (subfigure != null)
                Text.rich(subfigure!, style: t.secondary, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: align),
            ],
          );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        title,
        if (subtitle != null)
          Text.rich(subtitle!, style: t.secondary, maxLines: large ? 3 : 1, overflow: TextOverflow.ellipsis),
        if (large && figures != null) ...[const SizedBox(height: 4), figures],
      ],
    );
    final row = Container(
      constraints: const BoxConstraints(minHeight: homeRowHeight),
      alignment: AlignmentDirectional.centerStart,
      padding: const EdgeInsets.symmetric(horizontal: homeGutter, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: large ? CrossAxisAlignment.start : CrossAxisAlignment.center,
            children: [
              leading,
              const SizedBox(width: 12),
              Expanded(child: text),
              if (!large && figures != null) ...[
                const SizedBox(width: 12),
                // Up to just under half the line: a long figure ellipsizes
                // before it pushes the name out.
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.45),
                  child: figures,
                ),
              ],
              ?trailing,
            ],
          ),
          if (footnote != null)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: homeMarkSize + 12, top: 2),
              child: footnote,
            ),
        ],
      ),
    );
    return TappableNode(
      label: semanticLabel,
      hint: hint,
      onTap: onTap,
      onLongPress: onLongPress,
      child: InkWell(key: inkKey, onTap: onTap, onLongPress: onLongPress, child: row),
    );
  }
}

/// How many equal columns a row of tiles can use so that every tile fits
/// its content at the current text size: all of them on one line when
/// they fit, then the widest even split (four become two by two), then
/// one per line. Never squeezes a label, and never leaves a tile alone
/// beside a hole.
int fittingColumns({required double maxWidth, required double gap, required List<double> needs}) {
  final n = needs.length;
  if (n == 0) return 1;
  final widest = needs.reduce(math.max);
  for (final columns in [n, for (var c = n - 1; c > 1; c--) if (n % c == 0) c, 1]) {
    final width = (maxWidth - gap * (columns - 1)) / columns;
    if (width >= widest) return columns;
  }
  return 1;
}

/// Width [span] needs on one line at the current text scale.
double measureSpan(BuildContext context, InlineSpan span) {
  final painter = TextPainter(
    text: TextSpan(style: DefaultTextStyle.of(context).style, children: [span]),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// Width [text] needs on one line at the current text scale, in [style].
double measureText(BuildContext context, String text, TextStyle style) =>
    measureSpan(context, TextSpan(text: text, style: style));

/// [label] as it should be set in [maxWidth]: unchanged when it fits on a
/// line, else broken at the space nearest its middle, so "Send with
/// offline signer" becomes two even lines rather than a long one and an
/// orphan.
String balancedLabel(BuildContext context, String label, TextStyle style, double maxWidth) {
  if (!label.contains(' ') || measureText(context, label, style) <= maxWidth) return label;
  final middle = label.length / 2;
  var best = -1;
  for (var i = 0; i < label.length; i++) {
    if (label[i] == ' ' && (best == -1 || (i - middle).abs() < (best - middle).abs())) best = i;
  }
  return '${label.substring(0, best)}\n${label.substring(best + 1)}';
}
