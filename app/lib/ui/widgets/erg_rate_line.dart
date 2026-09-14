import 'package:flutter/material.dart';

import '../../services/network_controller.dart';
import '../../services/token_pricer.dart';
import '../../theme/argus_theme.dart';

/// The quoted unit price and its actual source, independent of hidden balances.
class ErgRateLine extends StatelessWidget {
  const ErgRateLine({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([networkController, tokenPricer]),
    builder: (context, _) {
      final source = tokenPricer.result.ergVia;
      final rate = source == null
          ? null
          : networkController.fiatText(1000000000);
      return Text(
        [
          rate == null
              ? '1 ERG · Rate unknown (${networkController.fiatCode.toUpperCase()})'
              : '1 ERG $rate',
          source ?? 'Source unknown',
          if (tokenPricer.stale) 'stale',
        ].join(' · '),
        style: TextStyle(fontSize: 14, color: ArgusColors.of(context).muted),
      );
    },
  );
}
