import 'package:flutter/material.dart';

import '../../format.dart';
import '../../services/storage_rent.dart';
import '../../services/utxo_plans.dart';
import '../../theme/argus_theme.dart';

/// When a box's storage rent falls due, what it costs, and whether the
/// box can pay it.
///
/// A box worth no more than its rent is flagged "at risk" only when it
/// holds tokens, which a collector would take with it. An ERG-only box like
/// that is just dust its rent would use up, said plainly and without the
/// warning colour, so a wallet with many small boxes does not look
/// alarming.
class BoxRentLine extends StatelessWidget {
  const BoxRentLine({
    super.key,
    required this.rent,
    required this.parameters,
    required this.hasTokens,
  });

  final BoxRent rent;
  final RentParameters parameters;

  /// Whether a collector would take tokens along with the ERG.
  final bool hasTokens;

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    // Unrounded: a voted factor can make any nanoERG amount.
    final fee = formatErg(rent.feeNano);
    final when = rentWhen(
      rent.blocksUntilDue,
      blockSeconds: parameters.blockSeconds,
    );
    final block = 'block ${formatWithCommas(rent.dueHeight)}';
    // What a collector takes from a box worth no more than its rent: all of
    // it.
    final whole = formatErg(rent.chargeNano);
    final (IconData icon, Color color, String text) = switch (rent) {
      BoxRent(charge: RentCharge.none) => (
        Icons.hourglass_empty,
        colors.muted,
        parameters.noChargeReason,
      ),
      BoxRent(atRisk: true, collectableNow: true) when hasTokens => (
        Icons.warning_amber_rounded,
        rustFor(context),
        'At risk: it holds no more than its $fee rent, so it can be '
            'collected now, tokens included.',
      ),
      BoxRent(atRisk: true) when hasTokens => (
        Icons.warning_amber_rounded,
        rustFor(context),
        'At risk: it holds no more than its $fee rent. From $block '
            '($when) it can be collected whole, tokens included.',
      ),
      BoxRent(atRisk: true, collectableNow: true) => (
        Icons.hourglass_bottom,
        colors.muted,
        'Rent would take this whole box ($whole); it can be collected now.',
      ),
      BoxRent(atRisk: true) => (
        Icons.hourglass_bottom,
        colors.muted,
        'Rent would take this whole box ($whole), from $block ($when).',
      ),
      BoxRent(collectableNow: true) => (
        Icons.schedule,
        colors.accentText,
        'Storage rent of $fee can be charged now (due $block).',
      ),
      BoxRent(dueSoon: true) => (
        Icons.schedule,
        colors.accentText,
        'Storage rent of $fee due $when ($block).',
      ),
      _ => (
        Icons.hourglass_bottom,
        colors.muted,
        'Storage rent of $fee due $when ($block).',
      ),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 14, color: color),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 12, color: color)),
        ),
      ],
    );
  }
}

/// The cleanup the screen proposes, at the top of the list.
class CleanupSuggestionCard extends StatelessWidget {
  const CleanupSuggestionCard({
    super.key,
    required this.suggestion,
    required this.resultingBoxes,
    required this.fragmented,
    this.highlight = false,
    this.onReview,
  });

  final CleanupSuggestion suggestion;

  /// Boxes the cleanup creates, or null when the layout is unknown.
  final int? resultingBoxes;

  /// The wallet has more boxes than the home screen calls tidy.
  final bool fragmented;

  /// Opened from the home screen to show this suggestion.
  final bool highlight;
  final VoidCallback? onReview;

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    final s = suggestion;
    final n = s.boxes.length;
    final into = switch (resultingBoxes) {
      1 => 'into one',
      final int count => 'into $count',
      null => s.tokens.isEmpty ? 'into one' : 'into one or more',
    };
    final of = s.leftAtAddress > 0 ? ' of ${n + s.leftAtAddress}' : '';
    final reasons = <String>[
      if (s.forRent) _rentReason(s),
      if (fragmented) 'Fewer boxes keep every send small and cheap.',
      if (!s.forRent)
        'Moving old boxes also restarts their 4-year storage-rent clock.',
    ];
    final bodySmall = Theme.of(context).textTheme.bodySmall;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(cardRadius),
        border: Border.all(
          color: highlight ? accentOf(context) : colors.cardBorder,
          width: highlight ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.auto_fix_high_outlined,
                size: 18,
                color: accentOf(context),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Suggested cleanup',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Merge $n$of boxes at ${shorten(s.address, head: 6, tail: 4)} $into.',
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500),
          ),
          for (final reason in reasons) ...[
            const SizedBox(height: 4),
            Text(reason, style: bodySmall),
          ],
          const SizedBox(height: 4),
          Text(
            'Fee ${formatErg(s.feesNano)}. Only this address\'s boxes move, so no addresses are linked.',
            style: bodySmall?.copyWith(color: colors.muted),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: const Icon(Icons.merge_type, size: 18),
            label: const Text('Review cleanup'),
            onPressed: onReview,
          ),
        ],
      ),
    );
  }

  static String _rentReason(CleanupSuggestion s) {
    final parts = <String>[
      if (s.atRiskCount > 0)
        s.atRiskCount == 1
            ? '1 box can\'t cover its storage rent'
            : '${s.atRiskCount} boxes can\'t cover their storage rent',
      if (s.dueSoonCount > 0)
        '${s.dueSoonCount} ${s.dueSoonCount == 1 ? 'falls' : 'fall'} due within $rentSoonDays days',
    ];
    return '${parts.join(' and ')}. Moving them starts a new 4-year rent clock.';
  }
}

/// One line on storage rent across the listed boxes: how many are at risk
/// or due soon, how many ERG-only boxes rent would take whole, how many
/// have no figures, and the rate they are judged at. Only the first two
/// are a warning.
class RentSummaryLine extends StatelessWidget {
  const RentSummaryLine({
    super.key,
    required this.parameters,
    required this.atRisk,
    this.wholeErgOnly = 0,
    required this.dueSoon,
    required this.unmeasured,
    required this.loading,
    required this.failed,
  });

  /// Null until a report arrives, or after one failed.
  final RentParameters? parameters;

  /// Listed boxes holding tokens that cannot pay their rent: a collector
  /// would take the tokens too.
  final int atRisk;

  /// Listed ERG-only boxes that cannot pay their rent: dust rent would use
  /// up whole. Counted apart from [atRisk] and not a warning.
  final int wholeErgOnly;

  /// Listed boxes due within [rentSoonDays] that can pay it.
  final int dueSoon;

  /// Listed boxes the report has no figures for: unparseable, or listed
  /// differently between the two reads.
  final int unmeasured;
  final bool loading;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final parameters = this.parameters;
    if (parameters == null) {
      if (loading) {
        return Row(
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text('Checking storage rent…', style: style)),
          ],
        );
      }
      return Text(
        failed
            ? 'Storage rent unavailable: your node could not be read. Refresh to try again.'
            : 'Storage rent not checked yet.',
        style: style,
      );
    }
    final parts = [
      if (atRisk > 0)
        '$atRisk ${atRisk == 1 ? 'box' : 'boxes'} at risk of collection',
      if (dueSoon > 0) '$dueSoon due within $rentSoonDays days',
    ];
    final missing = unmeasured == 0
        ? ''
        : ' $unmeasured ${unmeasured == 1 ? 'box' : 'boxes'} could not be measured.';
    final rate = 'Rate ${parameters.rateLabel}.$missing';
    final dust = wholeErgOnly == 0
        ? ''
        : wholeErgOnly == 1
        ? '1 ERG-only box is worth no more than its rent, which would take '
              'it whole. '
        : '$wholeErgOnly ERG-only boxes are worth no more than their rent, '
              'which would take them whole. ';
    final measured = unmeasured == 0 ? '' : 'measured ';
    final lead = parts.isNotEmpty
        ? 'Storage rent: ${parts.join(' · ')}.'
        : wholeErgOnly == 0
        ? 'Storage rent: nothing due within $rentSoonDays days, and every '
              '${measured}box covers its rent.'
        : 'Storage rent: no ${measured}box with tokens is at risk, and '
              'nothing else is due within $rentSoonDays days.';
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: lead,
            style: parts.isEmpty
                ? null
                : TextStyle(
                    color: rustFor(context),
                    fontWeight: FontWeight.w500,
                  ),
          ),
          TextSpan(text: ' $dust$rate'),
        ],
      ),
      style: style,
    );
  }
}
