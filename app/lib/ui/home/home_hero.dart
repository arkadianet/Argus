import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../format.dart';
import '../../theme/argus_theme.dart';
import '../../theme/argus_tones.dart';
import 'home_format.dart';
import 'home_models.dart';
import 'home_style.dart';
import 'home_widgets.dart';

/// The balance on its raised panel, set as type rather than boxed: a label,
/// the numeral, its value, and one line for what is pending and what is
/// stealth.
class HomeBalance extends StatelessWidget {
  const HomeBalance({
    super.key,
    required this.label,
    required this.nanoErg,
    required this.currency,
    this.labelExtra,
    this.status,
    this.fiatValue,
    this.unpricedCount = 0,
    this.pending,
    this.stealthNano = 0,
    this.hidden = false,
  });

  /// Room kept clear at the end of the label line for the hide-balances
  /// eye the panel pins in its corner.
  static const _cornerReserve = 40.0;

  /// "Total balance" or "Balance".
  final String label;

  /// Read after the label in the same capitals, e.g. "Watch-only".
  final String? labelExtra;

  /// The wallet's sync state, at the far end of the label line.
  final NetworkStatus? status;

  /// Null while unknown: drawn as a placeholder, never as zero.
  final int? nanoErg;
  final FiatCurrency currency;
  final double? fiatValue;
  final int unpricedCount;
  final PendingFunds? pending;
  final int stealthNano;
  final bool hidden;

  bool get _showPending => pending != null && !pending!.isEmpty;

  String _spoken() {
    final nano = nanoErg;
    if (nano == null) return '$label loading';
    if (hidden) return '$label hidden';
    return spoken([
      '$label ${summaryErg(nano)} ERG',
      if (fiatValue != null) 'about ${fiatFigure(fiatValue!, currency, approximate: false)} ${currency.code}',
      if (fiatValue != null && unpricedCount > 0) '$unpricedCount tokens unpriced',
      if (_showPending) pendingLine(pending!, hidden: false),
      if (stealthNano > 0) 'incl. ${summaryErg(stealthNano)} ERG stealth',
    ].join(', '));
  }

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    final tag = status;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(end: _cornerReserve),
          child: Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    text: label.toUpperCase(),
                    children: [if (labelExtra != null) TextSpan(text: '   ·   ${labelExtra!.toUpperCase()}')],
                  ),
                  style: t.label,
                ),
              ),
              if (tag != null) HomeSyncTag(status: tag),
            ],
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
    if (nano == null) {
      return Container(
        width: 168,
        height: 34,
        margin: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(color: t.muted.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(6)),
      );
    }
    final (whole, fraction) = hidden ? ('••••••', '') : splitFraction(summaryErg(nano));
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
            if (hidden)
              TextSpan(text: whole, style: TextStyle(fontSize: 28, height: 46 * 1.1 / 28, letterSpacing: 3, color: t.muted))
            else
              TextSpan(text: whole),
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
        maxLines: 1,
        softWrap: false,
        style: style,
      ),
    );
  }

  List<Widget> _lines(BuildContext context) {
    final t = HomeText.of(context);
    final lines = <Widget>[];
    if (fiatValue != null) {
      lines.add(Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: hidden ? '≈$nbsp${currency.symbol}$maskedFigure' : fiatFigure(fiatValue!, currency),
              style: t.primary,
            ),
            // Honest about what the value leaves out.
            if (unpricedCount > 0 && !hidden) TextSpan(text: '   ·   $unpricedCount${nbsp}unpriced'),
          ],
        ),
        style: t.secondary,
      ));
    }
    final meta = <InlineSpan>[
      if (_showPending) ...[
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(end: 4),
            child: Icon(Icons.schedule, size: 14, color: t.ink),
          ),
        ),
        TextSpan(text: pendingLine(pending!, hidden: hidden), style: TextStyle(color: t.ink, fontWeight: FontWeight.w500)),
      ],
      if (stealthNano > 0) ...[
        if (_showPending) const TextSpan(text: '   ·   '),
        TextSpan(text: 'incl.$nbsp${hidden ? maskedFigure : summaryErg(stealthNano)}${nbsp}ERG stealth'),
      ],
    ];
    if (meta.isNotEmpty) {
      lines.add(Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text.rich(TextSpan(children: meta), style: t.secondary),
      ));
    }
    return lines;
  }
}

/// "● Synced", or what is wrong instead, in a word or two.
class HomeSyncTag extends StatelessWidget {
  const HomeSyncTag({super.key, required this.status});

  final NetworkStatus status;

  static (String, Color) look(BuildContext context, NetworkStatus status) => switch (status.state) {
        SyncState.synced => ('Synced', moss),
        SyncState.syncing => ('Syncing', ArgusColors.of(context).accent),
        SyncState.stale => ('Out of date', rustFor(context)),
        SyncState.offline => ('Offline', rustFor(context)),
      };

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    final (word, dot) = look(context, status);
    final problem = status.state == SyncState.stale || status.state == SyncState.offline;
    final text = [word, if (status.age != null) status.age!].join(' · ');
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(text, style: t.secondary.copyWith(color: problem ? rustFor(context) : t.muted)),
        ],
      ),
    );
  }
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
    this.padding = const EdgeInsets.symmetric(horizontal: homeGutter),
  });

  final Widget leading;
  final InlineSpan text;
  final String semanticLabel;

  /// The link's words, in the accent: the one thing on the page to do.
  final String? action;
  final VoidCallback? onTap;
  final Key? inkKey;
  final String? hint;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    final colors = ArgusColors.of(context);
    final row = Container(
      constraints: const BoxConstraints(minHeight: homeLineHeight),
      alignment: AlignmentDirectional.centerStart,
      padding: padding,
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
            Text(action!, style: t.secondary.copyWith(color: colors.accentText, fontWeight: FontWeight.w500)),
          ],
          if (onTap != null)
            Icon(Icons.chevron_right, size: 18, color: action != null ? colors.accentText : t.muted),
        ],
      ),
    );
    return TappableNode(
      label: semanticLabel,
      hint: hint,
      onTap: onTap,
      child: InkWell(key: inkKey, onTap: onTap, child: row),
    );
  }
}

/// The overview's ERG price: the price of one ERG from the source picked in
/// Display settings, its change over the window and a sparkline of it.
///
/// It names ERG and its source, so it can't be mistaken for the balance's
/// own history. Without history it is the price and a caption saying why;
/// without a price it says that. The sparkline sits beside the figures,
/// or under them when large text leaves no room.
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
    final colors = ArgusColors.of(context);
    final rate = price.fiatPerErg;
    final change = price.changePercent;
    final trend = price.hasTrend && rate != null;
    final rising = (change ?? 0) >= 0;
    final caption = [
      price.source,
      if (trend) price.window else if (rate != null && price.historyUnavailable != null) price.historyUnavailable!,
      if (price.stale) 'stale',
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
                    color: rising ? mossFor(context) : rustFor(context),
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
        ? 'ERG price unavailable, ${price.source}'
        : [
            'ERG price ${fiatFigure(rate, currency, approximate: false)} ${currency.code}',
            if (trend) '${rising ? 'up' : 'down'} ${change!.abs().toStringAsFixed(1)}% over ${price.window}',
            price.source,
            if (!trend && price.historyUnavailable != null) price.historyUnavailable!,
            if (price.stale) 'stale',
          ].join(', ');
    Widget spark({double? width}) => SizedBox(
          key: const Key('home-price-sparkline'),
          width: width ?? _sparkWidth,
          height: _sparkHeight,
          child: CustomPaint(painter: SparklinePainter(points: price.points, color: colors.accent)),
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

/// A price line with a soft fill below it and a dot on the latest point.
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
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.2), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(last, 2.6, Paint()..color = color);
  }

  @override
  bool shouldRepaint(SparklinePainter old) => old.color != color || !identical(old.points, points);
}

/// The page's one elevated surface: the balance's plinth.
///
/// Its edges sit 12 in from the screen and its content 12 in again, so the
/// figures on it start on the same gutter as every row below. Depth comes
/// from a long soft shadow and a fill that settles a shade toward the page
/// at its foot, as if lit from above, not from a border. Shading down
/// rather than lifting up keeps every text colour on it at its contrast.
class RaisedPanel extends StatelessWidget {
  const RaisedPanel({super.key, required this.child, this.corner});

  final Widget child;

  /// A control pinned to the top corner, e.g. the hide-balances eye.
  final Widget? corner;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: homeGutter - 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(homeRadius),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [scheme.surface, raisedPanelFoot(Theme.of(context))],
          ),
          boxShadow: [
            // On paper a long shadow showed as a ledge; there the panel
            // floats on a short, even one.
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.45 : 0.05),
              blurRadius: dark ? 32 : 18,
              spreadRadius: dark ? -8 : -2,
              offset: Offset(0, dark ? 14 : 6),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.3 : 0.05),
              blurRadius: 2,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(homeRadius),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Padding(padding: const EdgeInsets.fromLTRB(12, 16, 12, 12), child: child),
              if (corner != null) PositionedDirectional(top: 4, end: 4, child: corner!),
            ],
          ),
        ),
      ),
    );
  }
}

/// The panel's foot: its surface settled a shade toward the page.
Color raisedPanelFoot(ThemeData theme) => Color.alphaBlend(
      theme.scaffoldBackgroundColor.withValues(alpha: theme.brightness == Brightness.dark ? 0.45 : 0.35),
      theme.colorScheme.surface,
    );

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
      icon: Icon(hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined),
    );
  }
}

/// A short line saying the network is current, which opens the network
/// settings: the overview's only status line.
HomeLineRow homeNetworkRow(BuildContext context, NetworkStatus network, {VoidCallback? onTap}) {
  final t = HomeText.of(context);
  final (word, dot) = HomeSyncTag.look(context, network);
  final parts = [
    if (network.blockHeight != null) 'Block$nbsp${formatWithCommas(network.blockHeight!)}',
    if (network.age != null) network.age!,
  ];
  return HomeLineRow(
    inkKey: const Key('home-network'),
    onTap: onTap,
    hint: onTap == null ? null : 'Network settings',
    semanticLabel: spoken([word, ...parts].join(', ')),
    leading: Container(width: 7, height: 7, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
    text: TextSpan(
      children: [
        TextSpan(text: word, style: TextStyle(color: t.ink, fontWeight: FontWeight.w500)),
        for (final p in parts) TextSpan(text: '   ·   $p'),
      ],
    ),
  );
}
