import 'package:flutter/material.dart';

import '../../format.dart';
import '../../services/storage_rent.dart';
import '../../theme/argus_theme.dart';

/// Storage-rent note under the ERG amount of a recipient that receives
/// tokens: what the new box will owe after four years untouched, and the
/// amount that keeps it (and its tokens) from being collected. Advice only;
/// the user may keep any amount the send itself accepts.
class RentHint extends StatelessWidget {
  const RentHint({super.key, required this.estimate, this.onUseSuggested});

  final OutputRentEstimate estimate;

  /// Puts [OutputRentEstimate.suggestedNano] in the amount field.
  final VoidCallback? onUseSuggested;

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    final first = estimate.first;
    final body = TextStyle(fontSize: 12.5, height: 1.35, color: colors.muted);
    final String text;
    if (!estimate.chargeable) {
      text = estimate.parameters.noChargeReason;
    } else {
      final rate = estimate.parameters.factorFromNode
          ? ''
          : ' at the default rate';
      // Unrounded: a voted factor can make any nanoERG amount.
      final fee = formatErg(first.feeNano);
      text = [
        'Ergo charges storage rent on boxes left unmoved for 4 years: about '
            '$fee$rate for this ${first.sizeBytes}-byte box.',
        estimate.covered && !estimate.belowSuggestion
            ? 'This amount covers it.'
            : 'A box holding less can be collected whole, tokens included.',
        if (estimate.boxes.length > 1)
          'These tokens need ${estimate.boxes.length} boxes; the extra ones '
              'carry only their minimum ERG.',
      ].join(' ');
    }
    final warn = estimate.chargeable && !estimate.covered;
    final suggested = estimate.suggestedNano;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: colors.inset,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  warn ? Icons.warning_amber_rounded : Icons.hourglass_bottom,
                  size: 16,
                  color: warn ? rustFor(context) : colors.accentText,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(text, style: body)),
            ],
          ),
          if (estimate.belowSuggestion && suggested != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 24),
              // Full width so the button sits at the end; it wraps under
              // the amount at large text sizes instead of squeezing it.
              child: SizedBox(
                width: double.infinity,
                child: Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  alignment: WrapAlignment.spaceBetween,
                  children: [
                    Text(
                      'Suggested ${formatErg(suggested, maxFrac: 4)}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextButton(
                      // A Wrap offers unbounded width; keep the button its
                      // label's size.
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 40),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      onPressed: onUseSuggested,
                      child: const Text('Use suggested'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
