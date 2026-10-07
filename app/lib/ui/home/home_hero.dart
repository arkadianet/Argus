import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../format.dart';
import '../../theme/argus_theme.dart';
import 'home_format.dart';
import 'home_models.dart';
import 'home_style.dart';
import 'home_widgets.dart';

/// The balance on its raised panel, set as type rather than boxed: a label,
/// the numeral, its value and what the value leaves out, then a line for
/// what is pending and one for what is not on public addresses.
class HomeBalance extends StatelessWidget {
  const HomeBalance({
    super.key,
    required this.label,
    required this.nanoErg,
    this.currency,
    this.labelExtra,
    this.loading = false,
    this.fiatValue,
    this.unpricedCount = 0,
    this.pricesNote,
    this.notLoaded = 0,
    this.asOf,
    this.pending,
    this.pockets = const [],
    this.pocketsAsOf,
    this.hidden = false,
    this.figureKey,
    this.pendingKey,
  });

  /// Room kept clear at the end of the label line for the hide-balances
  /// eye the panel pins in its corner.
  static const _cornerReserve = 40.0;

  /// "Total balance" or "Balance".
  final String label;

  /// Read after the label in the same capitals, e.g. "Watched account".
  final String? labelExtra;

  /// Null while unknown: drawn as a placeholder while [loading], else as a
  /// dash, never as zero.
  final int? nanoErg;
  final bool loading;

  /// What [fiatValue] is in; without one no value is shown.
  final FiatCurrency? currency;
  final double? fiatValue;
  final int unpricedCount;

  /// Why the fiat value may not be current ("prices 3 h old").
  final String? pricesNote;

  /// Wallets the figure leaves out because their balance is unknown.
  final int notLoaded;

  /// Age of a snapshot figure ("3h ago").
  final String? asOf;
  final PendingBalance? pending;
  final List<PocketBalance> pockets;
  final String? pocketsAsOf;
  final bool hidden;

  /// Keys for the numeral and the pending line, so a figure can be found
  /// without knowing how it is set.
  final Key? figureKey;
  final Key? pendingKey;

  /// The value, when there is one and something to say it in.
  ({double value, FiatCurrency currency})? get _fiat => switch ((fiatValue, currency)) {
        (final double value, final FiatCurrency currency) => (value: value, currency: currency),
        _ => null,
      };

  /// How old the figures are and what they leave out besides tokens:
  /// "prices 3 h old", "1 wallet not loaded", "as of 3h ago". None of it
  /// gives an amount away.
  List<String> _notes() => [
        if (_fiat != null && pricesNote != null) pricesNote!,
        if (notLoaded > 0) '${countLabel(notLoaded, 'wallet')} not loaded',
        if (asOf != null) 'as of $asOf',
      ];

  /// Tokens the fiat value leaves out. Hidden: a count of holdings tells
  /// an onlooker as much as an amount.
  bool get _showUnpriced => _fiat != null && unpricedCount > 0 && !hidden;

  String _spoken() {
    final nano = nanoErg;
    if (nano == null) return '$label ${loading ? 'loading' : 'unavailable'}';
    final pendingLine = pendingText(pending, hidden: hidden);
    // Hidden, the screen's dots would be read out one by one; the word is
    // what they stand for.
    if (hidden) return spoken(['$label hidden', ..._notes(), if (pendingLine != null) 'something pending'].join(', '));
    final fiat = _fiat;
    return spoken([
      '$label ${summaryErg(nano)} ERG',
      if (fiat != null) 'about ${fiatFigure(fiat.value, fiat.currency, approximate: false)} ${fiat.currency.code}',
      if (_showUnpriced) '$unpricedCount tokens unpriced',
      ..._notes(),
      ?pendingLine,
      ?pocketsLine(pockets, hidden: false, asOf: pocketsAsOf),
    ].join(', '));
  }

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(end: _cornerReserve),
          child: Text.rich(
            TextSpan(
              text: label.toUpperCase(),
              children: [if (labelExtra != null) TextSpan(text: '   ·   ${labelExtra!.toUpperCase()}')],
            ),
            style: t.label,
          ),
        ),
        const SizedBox(height: 6),
        // The figures are read as one sentence: amount, value, what the
        // value leaves out, and what is on its way.
        Semantics(
          container: true,
          label: _spoken(),
          excludeSemantics: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _numeral(context),
              const SizedBox(height: 2),
              ..._lines(context),
            ],
          ),
        ),
      ],
    );
  }

  Widget _numeral(BuildContext context) {
    final t = HomeText.of(context);
    final nano = nanoErg;
    // Newsreader's regular cut at display size, tracked in: the hero is
    // the one serif figure on the page, so it can afford to be quiet.
    final style = TextStyle(
      fontFamily: 'Newsreader',
      fontWeight: FontWeight.w400,
      fontSize: 46,
      height: 1.1,
      letterSpacing: -1.4,
      color: t.ink,
      fontFeatures: const [FontFeature.liningFigures()],
    );
    if (nano == null && loading) {
      return Container(
        width: 168,
        height: 34,
        margin: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(color: t.muted.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(6)),
      );
    }
    if (nano == null || hidden) return _figure(context, style, nano);
    // A new balance counts to its figure from the last one, so a change is
    // seen as a change; the first figure is simply shown, as is every
    // figure with reduced motion. Only the drawing counts: what is read
    // out is the balance itself.
    return TweenAnimationBuilder<double>(
      tween: Tween(end: nano.toDouble()),
      duration: homeReducedMotion(context) ? Duration.zero : HomeMotion.count,
      curve: HomeMotion.curve,
      builder: (context, shown, _) => _figure(context, style, shown.round()),
    );
  }

  Widget _figure(BuildContext context, TextStyle style, int? nano) {
    final t = HomeText.of(context);
    final (whole, fraction) = nano == null
        ? ('—', '')
        : hidden
            ? ('••••••', '')
            : splitFraction(summaryErg(nano));
    // One line at any text size: a balance broken over two lines reads as
    // two numbers, so it shrinks to fit instead.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerStart,
      child: Text.rich(
        TextSpan(
          children: [
            // Masked, the dots are set smaller than digits (at full size
            // they read as a password field) in a line of the same height,
            // so hiding balances moves nothing.
            if (hidden && nano != null)
              TextSpan(text: whole, style: TextStyle(fontSize: 28, height: 46 * 1.1 / 28, letterSpacing: 3, color: t.muted))
            else
              TextSpan(text: whole, style: nano == null ? TextStyle(color: t.muted) : null),
            // The fraction is set smaller and quieter, so the magnitude
            // reads first.
            if (fraction.isNotEmpty)
              TextSpan(text: fraction, style: TextStyle(fontSize: 30, letterSpacing: -0.6, color: t.muted)),
            TextSpan(
              text: '${nbsp}ERG',
              style: t.label.copyWith(fontSize: 13, letterSpacing: 1.4, fontFeatures: const []),
            ),
          ],
        ),
        key: figureKey,
        maxLines: 1,
        softWrap: false,
        style: style,
      ),
    );
  }

  List<Widget> _lines(BuildContext context) {
    final t = HomeText.of(context);
    final lines = <Widget>[];
    final caveats = [if (_showUnpriced) '$unpricedCount${nbsp}unpriced', ..._notes()];
    final fiat = _fiat;
    if (fiat != null || caveats.isNotEmpty) {
      lines.add(Text.rich(
        TextSpan(
          children: [
            if (fiat != null)
              TextSpan(
                text: hidden ? '≈$nbsp${fiat.currency.symbol}$maskedFigure' : fiatFigure(fiat.value, fiat.currency),
                style: t.primary,
              ),
            // Honest about what the value leaves out, and how old it is.
            for (final (i, c) in caveats.indexed) TextSpan(text: i == 0 && fiat == null ? c : '   ·   $c'),
          ],
        ),
        style: t.secondary,
      ));
    }
    if (pendingText(pending, hidden: hidden) != null) {
      lines.add(Padding(
        padding: const EdgeInsets.only(top: 2),
        child: HomePendingLine(key: pendingKey, pending: pending, hidden: hidden),
      ));
    }
    if (pocketsLine(pockets, hidden: hidden, asOf: pocketsAsOf) case final note?) {
      lines.add(Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(note, style: t.secondary),
      ));
    }
    return lines;
  }
}

/// "+2.5 ERG pending · 105.21 confirmed" under a balance, in ink with a
/// clock, or nothing while nothing touching the balance is in the mempool.
/// Emphasised by weight, not colour: the accent is kept for the one thing
/// on a screen to act on.
class HomePendingLine extends StatelessWidget {
  const HomePendingLine({super.key, required this.pending, required this.hidden});

  final PendingBalance? pending;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    final text = pendingText(pending, hidden: hidden);
    if (text == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(Icons.schedule, size: 14, color: t.ink),
        ),
        const SizedBox(width: 4),
        Flexible(child: Text(text, style: t.secondary.copyWith(color: t.ink, fontWeight: FontWeight.w500))),
      ],
    );
  }
}

/// The address a wallet is shown as, with its pinned index when it has one:
/// "📌 #275  9evoke9R…KmPoW".
class HomeIdentityLine extends StatelessWidget {
  const HomeIdentityLine({super.key, required this.address, this.pinnedIndex});

  final String address;
  final int? pinnedIndex;

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    final pinned = pinnedIndex != null && pinnedIndex! > 0;
    // A node of its own: merged into its neighbours it read as part of
    // the panel's label.
    return Semantics(
      container: true,
      label: spoken('${pinned ? 'Pinned address #$pinnedIndex, ' : 'Address '}${shorten(address, head: 8, tail: 6)}'),
      excludeSemantics: true,
      child: Row(
        children: [
          if (pinned) ...[
            Icon(Icons.push_pin_outlined, size: 13, color: t.muted),
            const SizedBox(width: 3),
            Text('#$pinnedIndex', style: t.secondary),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              shorten(address, head: 8, tail: 6),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(context, size: 12).copyWith(color: t.muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// The word for a status, its dot, and whether it is a problem.
(String, Color, bool) syncLook(BuildContext context, NetworkStatus status) {
  final (word, dot) = switch (status.state) {
    SyncState.synced => ('Synced', moss),
    SyncState.syncing => ('Syncing…', ArgusColors.of(context).accent),
    SyncState.partial => ('Not synced', ArgusColors.of(context).accent),
    SyncState.stale => ('Out of sync', rustFor(context)),
    SyncState.offline => ('Offline', rustFor(context)),
  };
  final problem = status.state == SyncState.stale || status.state == SyncState.offline;
  return (status.label ?? word, dot, problem);
}

/// A one-line row for a note about the balance: an icon in the mark
/// column, a sentence, and, when it leads somewhere, a quiet link.
class HomeLineRow extends StatelessWidget {
  const HomeLineRow({
    super.key,
    required this.leading,
    required this.text,
    required this.semanticLabel,
    this.action,
    this.onTap,
    this.inkKey,
    this.hint,
    this.trailing,
    this.padding,
  });

  final Widget leading;
  final InlineSpan text;
  final String semanticLabel;

  /// The link's words, in the accent: the one thing on the page to do.
  final String? action;
  final VoidCallback? onTap;
  final Key? inkKey;
  final String? hint;

  /// A control of its own at the end of the line, e.g. a dismiss button.
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    final accent = HomeTones.of(context).accent;
    final row = Container(
      constraints: const BoxConstraints(minHeight: homeLineHeight),
      alignment: AlignmentDirectional.centerStart,
      padding: padding ?? EdgeInsets.symmetric(horizontal: homeGutterOf(context)),
      child: Row(
        children: [
          SizedBox(width: homeMarkSize, child: Center(child: leading)),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text.rich(text, style: t.secondary),
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: 12),
            Text(action!, style: t.secondary.copyWith(color: accent, fontWeight: FontWeight.w500)),
          ],
          if (onTap != null && trailing == null)
            Icon(Icons.chevron_right, size: 18, color: action != null ? accent : t.muted),
        ],
      ),
    );
    final tappable = TappableNode(
      label: semanticLabel,
      hint: hint,
      onTap: onTap,
      child: InkWell(key: inkKey, onTap: onTap, child: row),
    );
    if (trailing == null) return tappable;
    return Row(children: [Expanded(child: tappable), trailing!]);
  }
}

/// The overview's ERG price: the price of one ERG from the source picked in
/// Display settings, its change over the window and a sparkline of it.
///
/// It names ERG and its source, so it can't be mistaken for the balance's
/// own history. Without history it is the price and a caption saying why;
/// without a price it says that; a price that is not current says how old
/// it is. The sparkline sits beside the figures, or under them when large
/// text leaves no room.
class ErgPriceStrip extends StatelessWidget {
  const ErgPriceStrip({super.key, required this.price, required this.currency});

  final ErgPriceView price;
  final FiatCurrency currency;

  static const _sparkWidth = 96.0;
  static const _sparkHeight = 32.0;
  static const _gap = 16.0;

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    final tones = HomeTones.of(context);
    final rate = price.fiatPerErg;
    final change = price.changePercent;
    final trend = price.hasTrend && rate != null;
    final rising = (change ?? 0) >= 0;
    final window = price.trendSource == null ? price.window : '${price.window} via ${price.trendSource}';
    final caption = [
      price.source,
      if (trend) window else if (price.historyUnavailable != null) price.historyUnavailable!,
      ?price.staleNote,
    ].join('   ·   ');
    final InlineSpan figures = rate == null
        ? TextSpan(text: 'ERG price unavailable', style: t.primary)
        : TextSpan(
            children: [
              TextSpan(text: '1${nbsp}ERG   ', style: t.secondary),
              TextSpan(text: '≈$nbsp${ergPriceFigure(rate, currency)}', style: t.primary),
              if (trend)
                TextSpan(
                  text: '   ${percentChange(change!)}',
                  style: t.secondary.copyWith(
                    color: rising ? tones.positive : tones.negative,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(figures),
        Text(caption, style: t.secondary),
      ],
    );
    final spokenLabel = rate == null
        ? ['ERG price unavailable', price.source, ?price.historyUnavailable].join(', ')
        : [
            'ERG price ${fiatFigure(rate, currency, approximate: false)} ${currency.code}',
            if (trend) '${rising ? 'up' : 'down'} ${change!.abs().toStringAsFixed(1)}% over $window',
            price.source,
            if (!trend && price.historyUnavailable != null) price.historyUnavailable!,
            ?price.staleNote,
          ].join(', ');
    Widget spark({double? width}) => SizedBox(
          key: const Key('home-price-sparkline'),
          width: width ?? _sparkWidth,
          height: _sparkHeight,
          child: CustomPaint(painter: SparklinePainter(points: price.points, color: tones.accent)),
        );
    return Semantics(
      container: true,
      label: spoken(spokenLabel),
      excludeSemantics: true,
      child: !trend
          ? SizedBox(width: double.infinity, child: text)
          : LayoutBuilder(
              builder: (context, constraints) {
                final needed = math.max(measureSpan(context, figures), measureText(context, caption, t.secondary));
                if (needed + _gap + _sparkWidth <= constraints.maxWidth) {
                  return Row(children: [Expanded(child: text), const SizedBox(width: _gap), spark()]);
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [text, const SizedBox(height: 8), spark(width: double.infinity)],
                );
              },
            ),
    );
  }
}

/// A price line over a gradient fill, strengthening toward the latest
/// point, which carries a dot in a soft halo.
class SparklinePainter extends CustomPainter {
  SparklinePainter({required this.points, required this.color});

  final List<double> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final lo = points.reduce(math.min);
    final hi = points.reduce(math.max);
    final span = hi - lo == 0 ? 1.0 : hi - lo;
    const inset = 3.0;
    Offset at(int i) => Offset(
          i / (points.length - 1) * (size.width - inset),
          inset + (1 - (points[i] - lo) / span) * (size.height - 2 * inset),
        );
    final line = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < points.length; i++) {
      line.lineTo(at(i).dx, at(i).dy);
    }
    final last = at(points.length - 1);
    final fill = Path.from(line)
      ..lineTo(last.dx, size.height)
      ..lineTo(0, size.height)
      ..close();
    final area = Offset.zero & size;
    // The area under the line is filled from the line's colour down to
    // nothing, so the shape of the day reads at a glance.
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.26), color.withValues(alpha: 0.02)],
        ).createShader(area),
    );
    // The line strengthens toward now: the latest prices carry the most.
    canvas.drawPath(
      line,
      Paint()
        ..shader = LinearGradient(
          colors: [color.withValues(alpha: 0.45), color],
          stops: const [0, 0.7],
        ).createShader(area)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.75
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    // The latest point, with a soft halo.
    canvas.drawCircle(last, 5, Paint()..color = color.withValues(alpha: 0.22));
    canvas.drawCircle(last, 2.6, Paint()..color = color);
  }

  @override
  bool shouldRepaint(SparklinePainter old) => old.color != color || !identical(old.points, points);
}

/// The hero: the one surface on the page that is not the page.
///
/// It is coloured ([HeroSpec]): the palette's accent, so the balance and
/// the wallet's actions read before anything else without the jolt of a
/// paper card on a dark page. It has depth without an outline: a sheen
/// across it, a light along its top edge, a soft low shadow, and on a
/// dark page a faint glow of its colour.
///
/// Everything inside takes the hero's colours: its own tones through
/// [HeroSurface], and a theme turned to match for what reads the theme
/// directly (ink ripples, icon buttons, the default text colour).
///
/// Its edges sit 12 in from the screen and its content 12 in again, so the
/// figures on it start on the same gutter as every row below.
class RaisedPanel extends StatelessWidget {
  const RaisedPanel({super.key, required this.child, this.corner});

  final Widget child;

  /// A control pinned to the top corner, e.g. the hide-balances eye.
  final Widget? corner;

  /// The page's theme turned for the hero's surface.
  static ThemeData heroTheme(ThemeData page, HeroSpec hero) {
    final colors = page.extension<ArgusColors>() ?? (page.brightness == Brightness.dark ? ArgusColors.dark : ArgusColors.light);
    return page.copyWith(
      colorScheme: page.colorScheme.copyWith(
        brightness: hero.brightness,
        primary: hero.filled,
        onPrimary: hero.onFilled,
        surface: hero.surface,
        onSurface: hero.ink,
        onSurfaceVariant: hero.muted,
        outline: hero.divider,
      ),
      splashColor: hero.ink.withValues(alpha: 0.12),
      highlightColor: hero.ink.withValues(alpha: 0.06),
      hoverColor: hero.ink.withValues(alpha: 0.04),
      focusColor: hero.ink.withValues(alpha: 0.12),
      iconTheme: page.iconTheme.copyWith(color: hero.ink),
      progressIndicatorTheme: page.progressIndicatorTheme.copyWith(color: hero.accent),
      extensions: [
        colors.copyWith(
          muted: hero.muted,
          cardBorder: hero.divider,
          inset: hero.tonal,
          accent: hero.filled,
          onAccent: hero.onFilled,
          accentText: hero.accent,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final page = Theme.of(context);
    final hero = ArgusColors.of(context).hero;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: homeGutter - 12),
      child: Theme(
        data: heroTheme(page, hero),
        child: HeroSurface(
          spec: hero,
          child: DefaultTextStyle.merge(
            style: TextStyle(color: hero.ink),
            child: DecoratedBox(
              key: const Key('home-hero'),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(homeRadius),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [hero.surface, hero.surfaceEnd],
                ),
                boxShadow: [
                  // A haze of the accent, faint and cast downward, as if the
                  // panel lit the page under it. Kept from rising above the
                  // panel, where the app bar would cut it off in a line.
                  if (hero.glow case final glow?)
                    BoxShadow(color: glow, blurRadius: 40, spreadRadius: -10, offset: const Offset(0, 20)),
                  // The panel's own shadow: soft, low and drawn in under its
                  // foot, so it lifts without an outline.
                  BoxShadow(color: hero.shadow, blurRadius: 28, spreadRadius: -12, offset: const Offset(0, 16)),
                ],
              ),
              child: Material(
                type: MaterialType.transparency,
                borderRadius: BorderRadius.circular(homeRadius),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  children: [
                    // Light along the top edge, brightest at its middle: the
                    // surface reads as a sheet with a face, not a flat fill.
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: 1,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.white.withValues(alpha: 0),
                              Colors.white.withValues(alpha: 0.45),
                              Colors.white.withValues(alpha: 0),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Padding(padding: const EdgeInsets.fromLTRB(12, 16, 12, 12), child: child),
                    if (corner != null) PositionedDirectional(top: 4, end: 4, child: corner!),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The hide-balances eye the panel pins in its corner, beside the figure
/// it hides.
class HideBalancesButton extends StatelessWidget {
  const HideBalancesButton({super.key, required this.hidden, required this.onPressed});

  final bool hidden;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const Key('home-hide-balances'),
      onPressed: onPressed,
      tooltip: hidden ? 'Show balances' : 'Hide balances',
      color: HomeTones.of(context).ink,
      icon: Icon(hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined),
    );
  }
}

/// A short line saying whether a node answers and how far the chain has
/// got: the overview's only status line. It opens the network settings, or
/// with no node looks again.
HomeLineRow homeNetworkRow(
  BuildContext context,
  NetworkStatus network, {
  VoidCallback? onTap,
  String? action,
  String? hint,
}) {
  final t = HomeText.of(context);
  final (word, dot, problem) = syncLook(context, network);
  final parts = [
    if (network.blockHeight != null) 'Block$nbsp${formatWithCommas(network.blockHeight!)}',
    if (network.age != null) network.age!,
  ];
  return HomeLineRow(
    inkKey: const Key('home-network'),
    onTap: onTap,
    action: action,
    hint: hint ?? (onTap == null ? null : 'Network settings'),
    semanticLabel: spoken([word, ...parts, ?action].join(', ')),
    leading: Container(width: 7, height: 7, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
    text: TextSpan(
      children: [
        TextSpan(text: word, style: TextStyle(color: problem ? rustFor(context) : t.ink, fontWeight: FontWeight.w500)),
        for (final p in parts) TextSpan(text: '   ·   $p'),
      ],
    ),
  );
}
