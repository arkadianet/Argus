import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/token_pricer.dart';
import 'package:argus_wallet/services/token_pricing.dart';
import 'package:argus_wallet/ui/widgets/erg_rate_line.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    networkController.fiatCode = 'usd';
    networkController.setErgRate(fiatPerErg: null, usdPerErg: null);
    tokenPricer.result = const PricingResult(
      ergUsd: null,
      ergVia: null,
      prices: {},
    );
    tokenPricer.stale = false;
  });

  testWidgets(
    'unit rate names actual source, selected currency and staleness',
    (tester) async {
      networkController.fiatCode = 'aud';
      networkController.setErgRate(fiatPerErg: 0.36, usdPerErg: 0.24);
      tokenPricer.result = const PricingResult(
        ergUsd: 0.24,
        ergVia: 'Oracle pool',
        prices: {},
      );
      tokenPricer.stale = true;
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ErgRateLine())),
      );
      expect(
        find.text('1 ERG ≈ A\$0.36 AUD · Oracle pool · stale'),
        findsOneWidget,
      );
      networkController.setErgRate(fiatPerErg: null, usdPerErg: 0.24);
      await tester.pump();
      expect(
        find.text('1 ERG · Rate unknown (AUD) · Oracle pool · stale'),
        findsOneWidget,
      );
    },
  );

  testWidgets('missing rate and source are unknown, never zero', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ErgRateLine())),
    );
    expect(
      find.text('1 ERG · Rate unknown (USD) · Source unknown'),
      findsOneWidget,
    );
    expect(find.textContaining('0.00'), findsNothing);
  });
}
