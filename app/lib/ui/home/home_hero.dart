import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../format.dart';
import '../../theme/argus_theme.dart';
import 'home_format.dart';
import 'home_glass.dart';
import 'home_models.dart';
import 'home_style.dart';
import 'home_widgets.dart';

/// The balance, set straight onto the scene as type: a label in spaced
/// capitals with the hide-balances eye beside it, the serif numeral, its
/// value in the same serif, then quieter lines for what is pending, what
/// is not on public addresses and how old the figures are. Tokens the value
/// leaves out are counted in a pill under it.
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
    this.onToggleHidden,
    this.onUnpriced,
    this.figureReserve = 0,
    this.showLabel = true,
    this.unpricedPill = true,
  });

  /// The "83 unpriced tokens" pill under the value; a wallet's page counts
  /// its holdings on its Assets tab instead.
  final bool unpricedPill;

  /// The label line ("TOTAL BALANCE" and the eye). Without it the figure
  /// leads, as on a wallet's own page whose title already names it, and
  /// the eye sits beside the figure's value instead.
  final bool showLabel;

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

  /// The eye beside the label; without it there is none.
  final VoidCallback? onToggleHidden;

  /// Where the unpriced-tokens pill leads; without it the pill only says.
  final VoidCallback? onUnpriced;

  /// Room kept clear at the end of the figure and its value, e.g. for the
  /// wallet's medallion beside them.
  final double figureReserve;

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
    final eye = onToggleHidden;
    if (!showLabel) {
      final lines = _lines(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The figures are read as one sentence, from the numeral; the
          // lines under it are in that sentence, so they are not read again.
          Semantics(
            container: true,
            label: _spoken(),
            excludeSemantics: true,
            child: Padding(padding: EdgeInsetsDirectional.only(end: figureReserve), child: _numeral(context)),
          ),
          // The eye beside the value it hides.
          Padding(
            padding: EdgeInsetsDirectional.only(end: figureReserve > 48 ? figureReserve - 48 : 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (lines.isNotEmpty) Flexible(child: ExcludeSemantics(child: lines.first)),
                if (eye != null) HideBalancesButton(hidden: hidden, onPressed: eye),
              ],
            ),
          ),
          ExcludeSemantics(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: lines.skip(1).toList()),
          ),
          ..._unpriced(),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(minHeight: eye == null ? 24 : 48),
          child: Row(
            children: [
              Flexible(
                child: Text.rich(
                  TextSpan(
                    text: label.toUpperCase(),
                    children: [if (labelExtra != null) TextSpan(text: '   ·   ${labelExtra!.toUpperCase()}')],
                  ),
                  style: t.label,
                ),
              ),
              if (eye != null) HideBalancesButton(hidden: hidden, onPressed: eye),
            ],
          ),
        ),
        // The figures are read as one sentence: amount, value, what the
        // value leaves out, and what is on its way.
        Semantics(
          container: true,
          label: _spoken(),
          excludeSemantics: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: EdgeInsetsDirectional.only(end: figureReserve), child: _numeral(context)),
              ..._lines(context),
            ],
          ),
        ),
        ..._unpriced(),
      ],
    );
  }

  List<Widget> _unpriced() => [
        if (_showUnpriced && unpricedPill) ...[
          const SizedBox(height: 12),
          OutlinePill(
            inkKey: const Key('home-unpriced'),
            text: '$unpricedCount unpriced ${unpricedCount == 1 ? 'token' : 'tokens'}',
            semanticLabel: '$unpricedCount unpriced ${unpricedCount == 1 ? 'token' : 'tokens'}',
            onTap: onUnpriced,
          ),
        ],
      ];

  Widget _numeral(BuildContext context) {
    final t = HomeText.of(context);
    final nano = nanoErg;
    // Newsreader at display size: the one serif figure on the page, large
    // enough to read across a room.
    final style = TextStyle(
      fontFamily: 'Newsreader',
      fontWeight: FontWeight.w500,
      fontSize: 49,
      height: 1.08,
      letterSpacing: -1,
      color: t.ink,
      fontFeatures: const [FontFeature.liningFigures()],
    );
    if (nano == null && loading) {
      return Container(
        width: 170,
        height: 38,
        margin: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(color: t.muted.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(8)),
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
              TextSpan(text: whole, style: TextStyle(fontSize: 28, height: 49 * 1.08 / 28, letterSpacing: 3, color: t.muted))
            else
              TextSpan(text: whole, style: nano == null ? TextStyle(color: t.muted) : null),
            // The fraction in the same cut, a size down, so the magnitude
            // reads first.
            if (fraction.isNotEmpty) TextSpan(text: fraction, style: const TextStyle(fontSize: 35, letterSpacing: -0.5)),
            TextSpan(
              text: '${nbsp}ERG',
              style: TextStyle(
                fontFamily: 'Karla',
                fontSize: 18,
                fontWeight: FontWeight.w400,
                letterSpacing: 1.6,
                color: t.muted,
                fontFeatures: const [],
              ),
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
    final fiat = _fiat;
    if (fiat != null) {
      lines.add(Padding(
        padding: EdgeInsetsDirectional.only(end: showLabel ? figureReserve : 0),
        child: Text(
          hidden ? '≈$nbsp${fiat.currency.symbol}$maskedFigure' : fiatFigure(fiat.value, fiat.currency),
          style: TextStyle(
            fontFamily: 'Newsreader',
            fontSize: 23,
            height: 1.2,
            fontWeight: FontWeight.w400,
            color: t.ink,
            fontFeatures: const [FontFeature.liningFigures()],
          ),
        ),
      ));
    }
    // Honest about how old the figures are and what they leave out.
    final notes = _notes();
    if (notes.isNotEmpty) {
      lines.add(Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(notes.join('   ·   '), style: t.secondary.copyWith(fontSize: 14.5)),
      ));
    }
    if (pendingText(pending, hidden: hidden) != null) {
      lines.add(Padding(
        padding: const EdgeInsets.only(top: 6),
        child: HomePendingLine(key: pendingKey, pending: pending, hidden: hidden),
      ));
    }
    if (pocketsLine(pockets, hidden: hidden, asOf: pocketsAsOf) case final note?) {
      lines.add(Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(note, style: t.secondary.copyWith(fontSize: 15, letterSpacing: 0.3)),
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

/// The address a wallet is shown as, on a pill of glass: its pinned index
/// when it has one, the address shortened, and a button that copies it
/// whole.
class IdentityPill extends StatelessWidget {
  const IdentityPill({super.key, required this.address, this.pinnedIndex, this.onCopy});

  final String address;
  final int? pinnedIndex;

  /// Copies the address; without one the pill copies it itself and says so.
  final VoidCallback? onCopy;

  void _copy(BuildContext context) {
    if (onCopy != null) return onCopy!();
    Clipboard.setData(ClipboardData(text: address));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Address copied')));
  }

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    final pinned = pinnedIndex != null && pinnedIndex! > 0;
    final short = shorten(address, head: 8, tail: 6);
    return GlassPill(
      inkKey: const Key('wallet-identity'),
      semanticLabel: spoken('${pinned ? 'Pinned address #$pinnedIndex, ' : 'Address '}$short'),
      leading: Icon(Icons.person_outline, size: 20, color: HomeTones.of(context).accent),
      trailing: IconButton(
        key: const Key('wallet-copy-address'),
        tooltip: 'Copy address',
        onPressed: () => _copy(context),
        icon: Icon(Icons.copy_rounded, size: 19, color: t.muted),
      ),
      child: Row(
        children: [
          if (pinned) ...[
            Text('#$pinnedIndex', style: t.secondary.copyWith(color: t.ink, fontSize: 13.5)),
            const SizedBox(width: 14),
          ],
          Flexible(
            child: Text(
              short,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.secondary.copyWith(color: t.ink, fontSize: 13.5, letterSpacing: 0.8),
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
    this.markWidth = homeMarkSize,
    this.chevron = true,
  });

  /// Whether a line that leads somewhere ends in a chevron.
  final bool chevron;

  /// The column the leading mark is centred in.
  final double markWidth;

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
          SizedBox(width: markWidth, child: Center(child: leading)),
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
          if (onTap != null && trailing == null && chevron)
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

/// The hide-balances eye, beside the label of the figure it hides.
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
      color: HomeText.of(context).muted,
      iconSize: 19,
      icon: Icon(hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined),
    );
  }
}

/// A status on a pill of glass, full width: a coloured dot, the word for
/// the state in ink and the facts after it, and a chevron when it leads
/// somewhere ("● Connected · Block 1,889,207 ›").
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.status,
    this.facts = const [],
    this.onTap,
    this.hint,
    this.action,
    this.inkKey,
  });

  final NetworkStatus status;
  final List<String> facts;
  final VoidCallback? onTap;
  final String? hint;

  /// A link's words in the accent, e.g. "Retry" when no node answers.
  final String? action;
  final Key? inkKey;

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    final (word, dot, problem) = syncLook(context, status);
    return GlassPill(
      inkKey: inkKey,
      onTap: onTap,
      hint: hint,
      semanticLabel: spoken([word, ...facts, ?action].join(', ')),
      leading: _Dot(color: dot),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: word, style: TextStyle(color: problem ? rustFor(context) : t.ink)),
            for (final f in facts) TextSpan(text: '   ·   $f', style: TextStyle(color: t.muted)),
            if (action != null)
              TextSpan(text: '   $action', style: TextStyle(color: HomeTones.of(context).accent)),
          ],
        ),
        style: t.secondary.copyWith(fontSize: 13.5),
      ),
    );
  }
}

/// A status dot with a soft halo of its own colour.
class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: color.withValues(alpha: 0.55), blurRadius: 8)],
        ),
      );
}

/// The overview's network pill: whether a node answers and how far the
/// chain has got. It opens the network settings, or with no node looks
/// again.
Widget homeNetworkPill(
  BuildContext context,
  NetworkStatus network, {
  VoidCallback? onTap,
  String? action,
  String? hint,
}) =>
    StatusPill(
      inkKey: const Key('home-network'),
      status: network,
      onTap: onTap,
      action: action,
      hint: hint ?? (onTap == null ? null : 'Network settings'),
      facts: [
        if (network.blockHeight != null) 'Block$nbsp${formatWithCommas(network.blockHeight!)}',
        if (network.age != null) network.age!,
      ],
    );
