import 'package:flutter/material.dart';

import '../../theme/argus_theme.dart';
import 'home_style.dart';
import 'home_widgets.dart';

/// Glass: the material the home pages' cards and pills are made of. A
/// translucent fill over whatever is behind it, a hairline of light at its
/// edge and a sheen across its top, so it reads as a pane laid on the
/// scene rather than a box drawn round its contents.

/// Corner radius of a glass card.
const glassRadius = 18.0;

/// Inside a glass card, rows keep this much in from its edge.
const glassGutter = 16.0;

/// How far a glass card sits in from the screen's edge.
const glassInset = 16.0;

BoxDecoration _glass(SceneSpec spec) => BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color.alphaBlend(spec.glassSheen, spec.glassFill), spec.glassFill],
        stops: const [0, 0.5],
      ),
    );

/// A rounded pane of glass holding [children], each row ink-tappable to
/// its edges. With [dividers], a hairline between rows, inset to the text.
class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.children, this.dividers = false, this.dividerIndent = glassGutter + 52});

  final List<Widget> children;
  final bool dividers;
  final double dividerIndent;

  @override
  Widget build(BuildContext context) {
    final spec = ArgusColors.sceneOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: glassInset),
      child: Material(
        type: MaterialType.transparency,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(glassRadius),
          side: BorderSide(color: spec.glassBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: _glass(spec),
          child: HomeInset(
            gutter: glassGutter,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (i, child) in children.indexed) ...[
                  if (dividers && i > 0) HomeRule(indent: dividerIndent, endIndent: glassGutter),
                  child,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A full-width pill of glass: a line that says something and, when it
/// leads somewhere, a chevron. At least a touch target tall.
class GlassPill extends StatelessWidget {
  const GlassPill({
    super.key,
    required this.child,
    required this.semanticLabel,
    this.leading,
    this.trailing,
    this.onTap,
    this.hint,
    this.inkKey,
  });

  final Widget child;
  final Widget? leading;

  /// A control of its own at the end, e.g. a copy button; without one a
  /// tappable pill shows a chevron.
  final Widget? trailing;
  final String semanticLabel;
  final VoidCallback? onTap;
  final String? hint;
  final Key? inkKey;

  @override
  Widget build(BuildContext context) {
    final spec = ArgusColors.sceneOf(context);
    final t = HomeText.of(context);
    final body = Padding(
      padding: EdgeInsetsDirectional.only(start: 18, end: trailing == null ? 14 : 0),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 14)],
          Expanded(child: DefaultTextStyle.merge(style: t.secondary.copyWith(color: t.ink), child: child)),
          if (trailing == null && onTap != null) Icon(Icons.chevron_right, size: 20, color: t.muted),
        ],
      ),
    );
    // The line is one node; a trailing control keeps its own beside it.
    final line = TappableNode(
      label: semanticLabel,
      hint: hint,
      onTap: onTap,
      child: InkWell(
        key: inkKey,
        onTap: onTap,
        child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 48), child: Center(child: body)),
      ),
    );
    return Material(
      type: MaterialType.transparency,
      shape: StadiumBorder(side: BorderSide(color: spec.glassBorder)),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: _glass(spec),
        child: trailing == null
            ? line
            : Row(children: [Expanded(child: line), trailing!, const SizedBox(width: 4)]),
      ),
    );
  }
}

/// A small rounded pill with an outline and no fill: "83 unpriced tokens ›".
/// Drawn 34 tall, tappable across a full touch target when it leads
/// somewhere.
class OutlinePill extends StatelessWidget {
  const OutlinePill({super.key, required this.text, required this.semanticLabel, this.onTap, this.inkKey});

  final String text;
  final String semanticLabel;
  final VoidCallback? onTap;
  final Key? inkKey;

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    final pill = Container(
      height: 30,
      padding: EdgeInsetsDirectional.only(start: 13, end: onTap == null ? 13 : 7),
      decoration: ShapeDecoration(shape: StadiumBorder(side: BorderSide(color: t.muted.withValues(alpha: 0.45)))),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, style: t.secondary.copyWith(color: t.ink, fontSize: 12.5)),
          if (onTap != null) Icon(Icons.chevron_right, size: 18, color: t.muted),
        ],
      ),
    );
    return TappableNode(
      label: semanticLabel,
      onTap: onTap,
      child: InkWell(
        key: inkKey,
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: onTap == null ? 30 : 48),
          child: Align(alignment: AlignmentDirectional.centerStart, widthFactor: 1, child: pill),
        ),
      ),
    );
  }
}

/// A count in a small round badge, beside a section's name.
class CountBadge extends StatelessWidget {
  const CountBadge({super.key, required this.count});

  final String count;

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
      padding: const EdgeInsets.symmetric(horizontal: 7),
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: t.ink.withValues(alpha: 0.08),
        shape: const StadiumBorder(),
      ),
      child: Text(count, style: t.secondary.copyWith(color: t.ink, fontSize: 12.5)),
    );
  }
}

/// A round button with a thin ring, e.g. the "+" beside a list's name.
class RingButton extends StatelessWidget {
  const RingButton({super.key, required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final spec = ArgusColors.sceneOf(context);
    final t = HomeText.of(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(shape: BoxShape.circle, color: spec.ringFill, border: Border.all(color: spec.ring)),
        child: Icon(icon, size: 22, color: t.ink),
      ),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
    );
  }
}
