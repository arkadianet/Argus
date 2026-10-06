import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../format.dart';
import '../../theme/argus_theme.dart';
import '../../theme/argus_tones.dart';
import 'home_format.dart';
import 'home_models.dart';
import 'home_widgets.dart';

/// A quiet line under the balance saying where part of it sits.
class BalanceNote {
  const BalanceNote({required this.icon, required this.text, this.onTap, this.key});

  final IconData icon;
  final String text;

  /// Makes the line a link, drawn with a chevron and a full touch target.
  final VoidCallback? onTap;
  final Key? key;
}

/// The one card at the top of both home screens.
///
/// Top half: the balance in ERG, its value, and what is still pending,
/// with the hide-balances eye beside the figure it hides. Below the
/// hairline: the ERG price with its 24-hour trend, then one line saying
/// how current everything above is. Lines that have nothing to say are
/// left out, so the card is complete with or without any of them.
class BalanceCard extends StatelessWidget {
  const BalanceCard({
    super.key,
    required this.label,
    required this.nanoErg,
    required this.currency,
    required this.network,
    this.tag,
    this.fiatValue,
    this.unpricedCount = 0,
    this.pending,
    this.hidden = false,
    this.onToggleHidden,
    this.notes = const [],
    this.price,
    this.onNetwork,
    this.notice,
  });

  /// "Total" on the overview, "Balance" on a wallet.
  final String label;

  /// Beside the label, e.g. a Watch-only chip.
  final Widget? tag;

  /// Null while unknown: drawn as a placeholder, never as zero.
  final int? nanoErg;
  final FiatCurrency currency;
  final NetworkStatus network;
  final double? fiatValue;
  final int unpricedCount;
  final PendingFunds? pending;
  final bool hidden;
  final VoidCallback? onToggleHidden;
  final List<BalanceNote> notes;

  /// The ERG price strip; the card reads complete without it.
  final ErgPriceView? price;

  final VoidCallback? onNetwork;

  /// Something to act on, shown last inside the card (fragmentation).
  final Widget? notice;

  bool get _showPending => pending != null && !pending!.isEmpty;

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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The eye's well sits clear of the card's rounded corner.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 10, 0),
              child: _labelRow(context),
            ),
            // The figures are read as one sentence: amount, value, what
            // the value leaves out, and what is on its way.
            Semantics(
              container: true,
              label: _spokenFigures(),
              excludeSemantics: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: _hero(context)),
                  _valueLine(context),
                ],
              ),
            ),
            if (notes.isNotEmpty) const SizedBox(height: 6),
            for (final note in notes) _note(context, note),
            SizedBox(height: notes.any((n) => n.onTap != null) ? 6 : 16),
            const Divider(height: 1, indent: 20, endIndent: 20),
            if (price != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 2),
                child: ErgPriceStrip(price: price!, currency: currency),
              ),
            _statusLine(context),
            if (notice != null)
              Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), child: notice)
            else
              const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  String _spokenFigures() {
    final nano = nanoErg;
    if (nano == null) return '$label loading';
    if (hidden) return '$label hidden';
    return spoken([
      '$label ${summaryErg(nano)} ERG',
      if (fiatValue != null) 'about ${fiatFigure(fiatValue!, currency, approximate: false)} ${currency.code}',
      if (fiatValue != null && unpricedCount > 0) '$unpricedCount tokens unpriced',
      if (_showPending) pendingLine(pending!, hidden: false),
    ].join(', '));
  }

  Widget _labelRow(BuildContext context) {
    final colors = ArgusColors.of(context);
    return Row(
      children: [
        Expanded(
          child: Wrap(
            spacing: 10,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ExcludeSemantics(
                child: Text(
                  label.toUpperCase(),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(color: colors.muted, fontSize: 12.5),
                ),
              ),
              ?tag,
            ],
          ),
        ),
        IconButton(
          key: const Key('home-hide-balances'),
          onPressed: onToggleHidden,
          tooltip: hidden ? 'Show balances' : 'Hide balances',
          icon: Icon(hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20),
          style: IconButton.styleFrom(
            backgroundColor: colors.inset,
            foregroundColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.75),
            fixedSize: const Size(40, 40),
            minimumSize: const Size(40, 40),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            tapTargetSize: MaterialTapTargetSize.padded,
          ),
        ),
      ],
    );
  }

  Widget _hero(BuildContext context) {
    final colors = ArgusColors.of(context);
    final style = TextStyle(
      fontFamily: 'Newsreader',
      fontWeight: FontWeight.w600,
      fontSize: 44,
      height: 1.15,
      letterSpacing: -0.6,
      color: Theme.of(context).colorScheme.onSurface,
    );
    final nano = nanoErg;
    if (nano == null) {
      return Container(
        width: 168,
        height: 36,
        margin: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: colors.muted.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(8),
        ),
      );
    }
    final (whole, fraction) = hidden ? ('••••••', '') : splitFraction(summaryErg(nano));
    // One line at any text size: a balance broken over two lines reads as
    // two numbers, so it shrinks to fit instead.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text.rich(
        TextSpan(
          children: [
            // Masked, the dots are set smaller than digits (at 44 they
            // read as a password field) in a line box of the same height,
            // so hiding balances doesn't move anything.
            if (hidden)
              TextSpan(
                text: whole,
                style: TextStyle(fontSize: 30, height: 44 * 1.15 / 30, letterSpacing: 2, color: colors.muted),
              )
            else
              TextSpan(text: whole),
            // The fraction is set quieter so the magnitude reads first.
            if (fraction.isNotEmpty) TextSpan(text: fraction, style: TextStyle(color: colors.muted)),
            TextSpan(
              text: ' ERG',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w400, letterSpacing: 0.4, color: colors.muted),
            ),
          ],
        ),
        maxLines: 1,
        softWrap: false,
        style: style,
      ),
    );
  }

  Widget _valueLine(BuildContext context) {
    final colors = ArgusColors.of(context);
    if (fiatValue == null && !_showPending) return const SizedBox(height: 4);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (fiatValue != null)
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: hidden ? '≈$nbsp${currency.symbol}$maskedFigure' : fiatFigure(fiatValue!, currency),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Theme.of(context).colorScheme.onSurface,
                      fontFeatures: tabularFigures,
                    ),
                  ),
                  // Honest about what the value leaves out.
                  if (unpricedCount > 0 && !hidden) TextSpan(text: '  ·  $unpricedCount${nbsp}unpriced'),
                ],
              ),
              style: TextStyle(fontSize: 13.5, color: colors.muted),
            ),
          if (_showPending)
            HomeChip(
              key: const Key('home-pending'),
              icon: Icons.schedule,
              label: pendingLine(pending!, hidden: hidden),
            ),
        ],
      ),
    );
  }

  Widget _note(BuildContext context, BalanceNote note) {
    final colors = ArgusColors.of(context);
    final tappable = note.onTap != null;
    final row = Padding(
      padding: EdgeInsets.fromLTRB(20, tappable ? 0 : 2, tappable ? 14 : 20, tappable ? 0 : 2),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: tappable ? 48 : 0),
        child: Row(
          children: [
            Icon(note.icon, size: 15, color: colors.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                note.text,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color: tappable ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.82) : colors.muted,
                ),
              ),
            ),
            if (tappable) ...[
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 18, color: colors.muted),
            ],
          ],
        ),
      ),
    );
    if (!tappable) return row;
    return TappableNode(
      label: spoken(note.text),
      onTap: note.onTap,
      child: InkWell(key: note.key, onTap: note.onTap, child: row),
    );
  }

  Widget _statusLine(BuildContext context) {
    final colors = ArgusColors.of(context);
    final (String state, Color dot) = switch (network.state) {
      SyncState.synced => ('Synced', moss),
      SyncState.syncing => ('Syncing', colors.accent),
      SyncState.stale => ('Out of date', rustFor(context)),
      SyncState.offline => ('Offline', rustFor(context)),
    };
    final parts = [
      if (network.blockHeight != null) 'Block$nbsp${formatWithCommas(network.blockHeight!)}',
      if (network.age != null) network.age!,
    ];
    // The dot sits on the first line when large text wraps the status.
    final lineHeight = MediaQuery.textScalerOf(context).scale(13) * 1.35;
    final line = Container(
      constraints: const BoxConstraints(minHeight: 48),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.fromLTRB(20, 8, 14, 8),
      child: Row(
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(top: (lineHeight - 8) / 2),
                  child: Icon(Icons.circle, size: 8, color: dot),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: state,
                          style: TextStyle(fontWeight: FontWeight.w500, color: Theme.of(context).colorScheme.onSurface),
                        ),
                        for (final p in parts) TextSpan(text: '  ·  $p'),
                      ],
                    ),
                    style: TextStyle(fontSize: 13, height: 1.35, color: colors.muted, fontFeatures: tabularFigures),
                  ),
                ),
              ],
            ),
          ),
          if (onNetwork != null) ...[
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 18, color: colors.muted),
          ],
        ],
      ),
    );
    return TappableNode(
      label: spoken([state, ...parts].join(', ')),
      hint: onNetwork == null ? null : 'Network settings',
      onTap: onNetwork,
      child: InkWell(key: const Key('home-network'), onTap: onNetwork, child: line),
    );
  }
}

/// The chart slot: the price of one ERG from the source picked in Display
/// settings, its change over the window, and a sparkline of that window.
///
/// It sits below the hairline and names ERG and its source, so it can't
/// be mistaken for the balance's own history. Without history it is just
/// the price and a caption saying why; without a price it says that. The
/// sparkline sits beside the figures, or under them when large text
/// leaves no room.
class ErgPriceStrip extends StatelessWidget {
  const ErgPriceStrip({super.key, required this.price, required this.currency});

  final ErgPriceView price;
  final FiatCurrency currency;

  static const _sparkWidth = 112.0;
  static const _sparkHeight = 36.0;
  static const _gap = 12.0;

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    final ink = Theme.of(context).colorScheme.onSurface;
    final rate = price.fiatPerErg;
    final change = price.changePercent;
    final trend = price.hasTrend && rate != null;
    final rising = (change ?? 0) >= 0;
    final caption = [
      price.source,
      if (trend) price.window else if (rate != null && price.historyUnavailable != null) price.historyUnavailable!,
      if (price.stale) 'stale',
    ].join('  ·  ');
    final figures = rate == null
        ? const TextSpan(text: 'ERG price unavailable')
        : TextSpan(
            children: [
              TextSpan(text: '1${nbsp}ERG  ', style: TextStyle(color: colors.muted, fontWeight: FontWeight.w400)),
              TextSpan(text: '≈$nbsp${ergPriceFigure(rate, currency)}'),
              if (trend)
                TextSpan(
                  text: '   ${percentChange(change!)}',
                  style: TextStyle(color: rising ? mossFor(context) : rustFor(context), fontWeight: FontWeight.w500),
                ),
            ],
          );
    final figureStyle = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: ink, fontFeatures: tabularFigures);
    final captionStyle = TextStyle(fontSize: 12, color: colors.muted);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(figures, style: figureStyle),
        const SizedBox(height: 2),
        Text(caption, style: captionStyle),
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
    return Semantics(
      container: true,
      label: spoken(spokenLabel),
      excludeSemantics: true,
      child: !trend
          ? SizedBox(width: double.infinity, child: text)
          : LayoutBuilder(
              builder: (context, constraints) {
                final needed = math.max(
                  measureSpan(context, TextSpan(style: figureStyle, children: [figures])),
                  measureText(context, caption, captionStyle),
                );
                final spark = SizedBox(
                  key: const Key('home-price-sparkline'),
                  width: _sparkWidth,
                  height: _sparkHeight,
                  child: CustomPaint(painter: SparklinePainter(points: price.points, color: colors.accent)),
                );
                if (needed + _gap + _sparkWidth <= constraints.maxWidth) {
                  return Row(children: [Expanded(child: text), const SizedBox(width: _gap), spark]);
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    text,
                    const SizedBox(height: 10),
                    SizedBox(
                      key: const Key('home-price-sparkline'),
                      width: double.infinity,
                      height: _sparkHeight,
                      child: CustomPaint(painter: SparklinePainter(points: price.points, color: colors.accent)),
                    ),
                  ],
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
          colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(last, 2.8, Paint()..color = color);
  }

  @override
  bool shouldRepaint(SparklinePainter old) => old.color != color || !identical(old.points, points);
}

/// The Tidy up pill's fill: the accent wash over the notice's recessed
/// ground. Exposed for the contrast test.
Color tidyUpFill(ArgusColors colors, Brightness brightness) =>
    Color.alphaBlend(colors.accent.withValues(alpha: brightness == Brightness.dark ? 0.16 : 0.2), colors.inset);

/// "165 UTXOs · Fragmented" with a Tidy up button, inside the balance card.
/// Shown only when there is something to tidy, and drawn as a control so
/// it reads as a thing to do rather than a status to puzzle over.
class FragmentationNotice extends StatelessWidget {
  const FragmentationNotice({super.key, required this.utxoCount, required this.onTidyUp});

  final int utxoCount;
  final VoidCallback? onTidyUp;

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    final warn = rustFor(context);
    final count = groupThousands('$utxoCount');
    return TappableNode(
      label: '$count UTXOs, fragmented. Tidy up',
      onTap: onTidyUp,
      child: Material(
        color: colors.inset,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const Key('home-tidy-up'),
          onTap: onTidyUp,
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            // Full width so the button sits at the far end; it drops under
            // the words when large text leaves no room beside them, rather
            // than breaking a word.
            child: SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.grain, size: 18, color: warn),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(text: '$count${nbsp}UTXOs'),
                                TextSpan(text: '  ·  Fragmented', style: TextStyle(color: warn)),
                              ],
                            ),
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                              color: Theme.of(context).colorScheme.onSurface,
                              fontFeatures: tabularFigures,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
                    decoration: BoxDecoration(
                      color: tidyUpFill(colors, Theme.of(context).brightness),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Tidy up',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: colors.accentText),
                        ),
                        Icon(Icons.chevron_right, size: 16, color: colors.accentText),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
