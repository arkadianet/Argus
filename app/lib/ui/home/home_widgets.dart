import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'home_glass.dart';
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
    this.button,
  });

  final String label;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? hint;
  final Widget child;

  /// Announce a button even while [onTap] is null: a disabled action is
  /// still an action. Defaults to whether there is a tap.
  final bool? button;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: button ?? onTap != null,
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

/// A list's name in widely spaced capitals, its count in a small round
/// badge, and at the far edge either a link ("View all ›") in the accent or
/// a control of its own, such as the round "+" that adds to the list.
class HomeSectionHeader extends StatelessWidget {
  const HomeSectionHeader({
    super.key,
    required this.title,
    this.count,
    this.action,
    this.onAction,
    this.actionKey,
    this.trailing,
  });

  final String title;
  final String? count;
  final String? action;
  final VoidCallback? onAction;
  final Key? actionKey;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    final gutter = homeGutterOf(context);
    return Padding(
      padding: EdgeInsetsDirectional.only(start: gutter, end: gutter - (trailing == null ? 6 : 10)),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: action == null && trailing == null ? 40 : homeLineHeight),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                label: count == null ? title : '$title, $count',
                excludeSemantics: true,
                child: Row(
                  children: [
                    Flexible(child: Text(title.toUpperCase(), style: t.label)),
                    if (count != null) ...[const SizedBox(width: 10), CountBadge(count: count!)],
                  ],
                ),
              ),
            ),
            if (trailing != null)
              trailing!
            else if (action != null)
              HomeLink(text: action!, onPressed: onAction, linkKey: actionKey),
          ],
        ),
      ),
    );
  }
}

/// A heading inside the page ("Recent Activity"), in plain type, with a
/// "View all ›" link at the far edge.
class HomeHeading extends StatelessWidget {
  const HomeHeading({super.key, required this.title, this.action, this.onAction, this.actionKey});

  final String title;
  final String? action;
  final VoidCallback? onAction;
  final Key? actionKey;

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    final gutter = homeGutterOf(context);
    return Padding(
      padding: EdgeInsetsDirectional.only(start: gutter, end: gutter - 6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: homeLineHeight),
        child: Row(
          children: [
            Expanded(child: Semantics(header: true, child: Text(title, style: t.title))),
            if (action != null) HomeLink(text: action!, onPressed: onAction, linkKey: actionKey, quiet: true),
          ],
        ),
      ),
    );
  }
}

/// The chevron at the end of a row that opens something.
Widget homeChevron(BuildContext context) => Padding(
      padding: const EdgeInsetsDirectional.only(start: 10),
      child: Icon(Icons.chevron_right, size: 20, color: HomeText.of(context).muted),
    );

/// "View all ›": a text link, a full touch target tall. In the accent, or
/// [quiet] in the page's muted type where the accent would crowd.
class HomeLink extends StatelessWidget {
  const HomeLink({super.key, required this.text, required this.onPressed, this.linkKey, this.quiet = false});

  final String text;
  final VoidCallback? onPressed;
  final Key? linkKey;
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    final colour = quiet ? t.ink : HomeTones.of(context).accent;
    return TextButton(
      key: linkKey,
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: colour,
        minimumSize: const Size(48, 48),
        padding: const EdgeInsetsDirectional.only(start: 10, end: 2),
        textStyle: t.link.copyWith(fontWeight: FontWeight.w400, fontSize: 14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [Text(text), const SizedBox(width: 4), Icon(Icons.chevron_right, size: 18, color: colour)],
      ),
    );
  }
}

/// Whether motion should be left out: the system's "remove animations"
/// setting. Every animation on the home screens asks this first and, when
/// it is on, shows the end state at once.
bool homeReducedMotion(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

/// How the home screens move. Short and eased out, so nothing waits on an
/// animation.
abstract final class HomeMotion {
  /// A part of the page settling in when the page opens.
  static const entrance = Duration(milliseconds: 420);

  /// The gap between one part's entrance and the next's.
  static const stagger = Duration(milliseconds: 70);

  /// A balance counting to its new figure.
  static const count = Duration(milliseconds: 700);

  /// A round button giving under a finger.
  static const press = Duration(milliseconds: 110);

  static const curve = Curves.easeOutCubic;
}

/// A part of the page that eases in when the page first opens: it rises
/// 12 points as it fades up, [order] steps after the first part. It plays
/// once, not on every rebuild. With reduced motion it is simply there.
///
/// While it fades, what it holds is still read out and still takes taps.
class HomeEntrance extends StatefulWidget {
  const HomeEntrance({super.key, required this.child, this.order = 0});

  final Widget child;
  final int order;

  @override
  State<HomeEntrance> createState() => _HomeEntranceState();
}

class _HomeEntranceState extends State<HomeEntrance> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: HomeMotion.entrance + HomeMotion.stagger * widget.order,
  );
  late final Animation<double> _shown = CurvedAnimation(
    parent: _controller,
    curve: Interval(
      (HomeMotion.stagger * widget.order).inMicroseconds / _controller.duration!.inMicroseconds,
      1,
      curve: HomeMotion.curve,
    ),
  );
  late final Animation<Offset> _rise = Tween(begin: const Offset(0, 12), end: Offset.zero).animate(_shown);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (homeReducedMotion(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _shown,
      alwaysIncludeSemantics: true,
      child: AnimatedBuilder(
        animation: _rise,
        builder: (context, child) => Transform.translate(offset: _rise.value, child: child),
        child: widget.child,
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

  /// The disc every wallet's mark sits on: a deep, cool shade a step off
  /// the page, the same for every wallet so the names, not the colours,
  /// tell them apart.
  static Color discOf(BuildContext context) {
    final page = Theme.of(context).scaffoldBackgroundColor;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return dark ? Color.lerp(page, const Color(0xFF3C6B5E), 0.28)! : Color.lerp(page, const Color(0xFF3C6B5E), 0.12)!;
  }

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    final trimmed = name.trim();
    return ExcludeSemantics(
      child: HomeDisc(
        fill: discOf(context),
        child: kind == WalletKind.seed
            ? Text(
                trimmed.isEmpty ? '?' : String.fromCharCode(trimmed.runes.first).toUpperCase(),
                textScaler: TextScaler.noScaling,
                style: TextStyle(fontFamily: 'Newsreader', fontSize: 20, fontWeight: FontWeight.w500, height: 1, color: t.ink),
              )
            : Icon(Icons.visibility_outlined, size: 20, color: t.ink),
      ),
    );
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
        // Set apart by its fill alone, as every mark is.
        color: fill ?? Theme.of(context).colorScheme.surfaceContainerHighest,
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
    this.subtitleLines = 1,
  });

  final Widget leading;
  final Widget title;
  final InlineSpan? subtitle;

  /// Lines the detail may take at normal text sizes: one in a list of
  /// figures, more where the detail is a sentence. Large text allows three
  /// more.
  final int subtitleLines;
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
        if (subtitle != null) ...[
          const SizedBox(height: 1),
          Text.rich(subtitle!, style: t.secondary, maxLines: subtitleLines + (large ? 2 : 0), overflow: TextOverflow.ellipsis),
        ],
        if (large && figures != null) ...[const SizedBox(height: 4), figures],
      ],
    );
    final row = Container(
      constraints: const BoxConstraints(minHeight: homeRowHeight),
      alignment: AlignmentDirectional.centerStart,
      padding: EdgeInsets.symmetric(horizontal: homeGutterOf(context), vertical: 8),
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
