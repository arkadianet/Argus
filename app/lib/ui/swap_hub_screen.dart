import 'package:flutter/material.dart';

import '../features.dart';
import 'ageusd_screen.dart';
import 'dexy_screen.dart';
import 'swap_screen.dart';

enum SwapVenue { dexy, spectrum, ageusd }

/// The venues the hub shows, in tab order: every venue whose switch is on.
List<SwapVenue> enabledVenues({bool dexy = dexyEnabled}) =>
    [for (final v in SwapVenue.values) if (v != SwapVenue.dexy || dexy) v];

/// `venue` if it is on, else the first venue that is: a remembered or
/// requested tab must never land on a paused protocol.
SwapVenue coerceVenue(SwapVenue venue, {bool dexy = dexyEnabled}) {
  final on = enabledVenues(dexy: dexy);
  return on.contains(venue) ? venue : on.first;
}

/// Single entry point for every swap surface: Dexy, Spectrum AMM, AgeUSD.
///
/// Hosts the three protocol screens as embedded bodies (no nested app bars)
/// behind a segmented control, preserving each tab's state while switching.
class SwapHubScreen extends StatefulWidget {
  const SwapHubScreen({
    super.key,
    this.initialTab = SwapVenue.spectrum,
    this.embedded = false,
    this.venue,
    this.onVenueChanged,
  });

  final SwapVenue initialTab;

  /// Hosted as a home tab: no app bar of its own.
  final bool embedded;

  /// When set, the selected venue is controlled by the parent.
  final SwapVenue? venue;
  final ValueChanged<SwapVenue>? onVenueChanged;

  @override
  State<SwapHubScreen> createState() => _SwapHubScreenState();
}

class _SwapHubScreenState extends State<SwapHubScreen> {
  late SwapVenue _tab = coerceVenue(widget.venue ?? widget.initialTab);

  @override
  void didUpdateWidget(SwapHubScreen old) {
    super.didUpdateWidget(old);
    final v = widget.venue;
    if (v != null && v != old.venue) _tab = coerceVenue(v);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.embedded ? null : AppBar(title: const Text('Swap')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: SegmentedButton<SwapVenue>(
                segments: [
                  for (final v in enabledVenues())
                    switch (v) {
                      SwapVenue.dexy => const ButtonSegment(
                          value: SwapVenue.dexy,
                          label: Text('Dexy'),
                          icon: Icon(Icons.currency_exchange, size: 18),
                        ),
                      SwapVenue.spectrum => const ButtonSegment(
                          value: SwapVenue.spectrum,
                          label: Text('Spectrum'),
                          icon: Icon(Icons.water_drop_outlined, size: 18),
                        ),
                      SwapVenue.ageusd => const ButtonSegment(
                          value: SwapVenue.ageusd,
                          label: Text('AgeUSD'),
                          icon: Icon(Icons.account_balance_outlined, size: 18),
                        ),
                    },
                ],
                selected: {_tab},
                showSelectedIcon: false,
                onSelectionChanged: (s) {
                  setState(() => _tab = s.first);
                  widget.onVenueChanged?.call(s.first);
                },
              ),
            ),
            if (_tab == SwapVenue.spectrum)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: TextButton.icon(
                    key: const Key('swap-liquidity'),
                    onPressed: () => Navigator.pushNamed(context, '/liquidity'),
                    icon: const Icon(Icons.water_drop, size: 18),
                    label: const Text('Liquidity'),
                  ),
                ),
              ),
            Expanded(
              child: IndexedStack(
                index: enabledVenues().indexOf(_tab),
                children: [
                  for (final venue in enabledVenues())
                    switch (venue) {
                      SwapVenue.dexy => const DexyScreen(embedded: true),
                      SwapVenue.spectrum => const SwapScreen(embedded: true),
                      SwapVenue.ageusd => const AgeUsdScreen(embedded: true),
                    },
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
