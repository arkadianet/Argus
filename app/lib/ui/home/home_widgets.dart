import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/token_evidence.dart';
import '../../theme/argus_theme.dart';
import 'home_models.dart';

/// Pieces shared by the overview, the wallet page and the More sheet.

/// Figures in lists line up digit for digit; Karla and Newsreader both
/// carry tabular figures.
const tabularFigures = [FontFeature.tabularFigures()];

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

/// Serif section title with an optional count and a "View all"-style link.
class HomeSectionHeader extends StatelessWidget {
  const HomeSectionHeader({super.key, required this.title, this.count, this.action, this.onAction, this.actionKey});

  final String title;

  /// Shown quietly after the title, so the link needn't repeat it.
  final String? count;
  final String? action;
  final VoidCallback? onAction;
  final Key? actionKey;

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Semantics(
            header: true,
            label: count == null ? title : '$title, $count',
            excludeSemantics: true,
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: title),
                  if (count != null)
                    TextSpan(
                      text: '  $count',
                      style: TextStyle(
                        fontFamily: 'Karla',
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: colors.muted,
                        fontFeatures: tabularFigures,
                      ),
                    ),
                ],
              ),
              // Two lines before an ellipsis: "Recent act…" says less
              // than a title that wraps at large text sizes.
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontFamily: 'Newsreader', fontWeight: FontWeight.w600, fontSize: 20, height: 1.15),
            ),
          ),
        ),
        if (action != null)
          // The link keeps a full-size touch target while reading as text.
          TextButton(
            key: actionKey,
            onPressed: onAction,
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              padding: const EdgeInsets.only(left: 10, right: 2),
              textStyle: const TextStyle(fontFamily: 'Karla', fontSize: 14, fontWeight: FontWeight.w500),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(action!),
                const SizedBox(width: 2),
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
          ),
      ],
    );
  }
}

/// Small rounded tag: "+2.5 ERG pending", "Fragmented", "Watch-only".
class HomeChip extends StatelessWidget {
  const HomeChip({super.key, required this.label, this.icon, this.tone = HomeChipTone.accent, this.dense = false});

  final String label;
  final IconData? icon;
  final HomeChipTone tone;
  final bool dense;

  /// The chip's fill, exposed for the contrast test.
  static Color fillFor(HomeChipTone tone, ArgusColors colors, ColorScheme scheme) => switch (tone) {
        HomeChipTone.accent => Color.alphaBlend(
            colors.accent.withValues(alpha: scheme.brightness == Brightness.dark ? 0.16 : 0.2),
            scheme.surface,
          ),
        // Lighter on paper: brand rust needs a near-white ground for 4.5:1.
        HomeChipTone.warn => Color.alphaBlend(
            rust.withValues(alpha: scheme.brightness == Brightness.dark ? 0.18 : 0.07),
            scheme.surface,
          ),
        HomeChipTone.quiet => colors.inset,
      };

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final fg = switch (tone) {
      HomeChipTone.accent => colors.accentText,
      HomeChipTone.warn => rustFor(context),
      HomeChipTone.quiet => colors.muted,
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 7 : 10, vertical: dense ? 2 : 4),
      decoration: BoxDecoration(color: fillFor(tone, colors, scheme), borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: dense ? 12 : 14, color: fg),
            SizedBox(width: dense ? 4 : 6),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: dense ? 11.5 : 13,
                height: 1.25,
                fontWeight: FontWeight.w500,
                color: fg,
                fontFeatures: tabularFigures,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum HomeChipTone { accent, warn, quiet }

/// The recessed square behind a mark: the same well for a wallet and for a
/// token, so the two lists read as one system.
BoxDecoration _wellDecoration(ArgusColors colors, double size, {bool round = false}) => BoxDecoration(
      color: colors.inset,
      shape: round ? BoxShape.circle : BoxShape.rectangle,
      borderRadius: round ? null : BorderRadius.circular(size * 0.3),
      border: Border.all(color: colors.cardBorder),
    );

/// A wallet's mark: its initial set in the serif, or an eye for a wallet
/// watched without keys, so the two kinds differ at a glance.
class WalletMark extends StatelessWidget {
  const WalletMark({super.key, required this.name, required this.kind, this.size = 40});

  final String name;
  final WalletKind kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    final trimmed = name.trim();
    final initial = trimmed.isEmpty ? '?' : String.fromCharCode(trimmed.runes.first).toUpperCase();
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: _wellDecoration(colors, size),
        child: kind == WalletKind.watchOnly
            ? Icon(Icons.visibility_outlined, size: size * 0.48, color: colors.muted)
            : Text(
                initial,
                // The mark is decoration: it must not grow with the text
                // and push the wallet's name out of its row.
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  fontFamily: 'Newsreader',
                  fontWeight: FontWeight.w600,
                  fontSize: size * 0.48,
                  height: 1,
                  color: colors.accentText,
                ),
              ),
      ),
    );
  }
}

/// A token's mark in a round well. Like the app's TokenAvatar it shows a
/// letter of the token *id*, never of the issuer's name, so no token can
/// dress up as another; ERG alone gets its sigma on a gold disc. Unlike
/// TokenAvatar the well stays visible on a card, whose surface is the same
/// colour as that avatar's fill in the dark palettes.
class HomeTokenMark extends StatelessWidget {
  const HomeTokenMark({super.key, required this.tokenId, this.isErg = false, this.size = 36});

  /// Null draws a neutral "?" (hidden balances).
  final String? tokenId;
  final bool isErg;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final text = issuerText(tokenId);
    final letter = isErg ? 'Σ' : (text.isEmpty ? '?' : String.fromCharCode(text.runes.first).toUpperCase());
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: isErg
            ? BoxDecoration(color: colors.accent.withValues(alpha: dark ? 0.25 : 0.2), shape: BoxShape.circle)
            : _wellDecoration(colors, size, round: true),
        child: Text(
          letter,
          textScaler: TextScaler.noScaling,
          style: TextStyle(
            fontFamily: 'Newsreader',
            fontWeight: FontWeight.w600,
            fontSize: size * 0.42,
            height: 1,
            color: isErg ? Theme.of(context).colorScheme.onSurface : colors.muted,
          ),
        ),
      ),
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

/// Lays [children] out in [columns] equal columns, rows top to bottom,
/// each row as tall as its tallest tile.
class EqualColumns extends StatelessWidget {
  const EqualColumns({super.key, required this.columns, required this.gap, required this.children});

  final int columns;
  final double gap;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <List<Widget>>[];
    for (var i = 0; i < children.length; i += columns) {
      rows.add(children.sublist(i, math.min(i + columns, children.length)));
    }
    return Column(
      children: [
        for (var r = 0; r < rows.length; r++) ...[
          if (r > 0) SizedBox(height: gap),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < columns; i++) ...[
                  if (i > 0) SizedBox(width: gap),
                  Expanded(child: i < rows[r].length ? rows[r][i] : const SizedBox.shrink()),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// The bordered tile behind each action and each add-a-wallet choice.
class HomeTile extends StatelessWidget {
  const HomeTile({super.key, required this.child, required this.onTap, required this.semanticLabel, this.padding});

  final Widget child;
  final VoidCallback? onTap;
  final String semanticLabel;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    return TappableNode(
      label: semanticLabel,
      onTap: onTap,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(buttonRadius + 2),
          side: BorderSide(color: colors.cardBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: padding ?? const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// Rows separated by a hairline that starts where the text does, inside a
/// card whose own fill would otherwise hide each row's ripple.
class HomeList extends StatelessWidget {
  const HomeList({super.key, required this.children, this.indent = 64});

  final List<Widget> children;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(cardRadius),
        border: Border.all(color: colors.cardBorder),
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(cardRadius),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(height: 1, indent: indent),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}
