import 'package:flutter/material.dart';

import 'ageusd_screen.dart';
import 'dexy_screen.dart';
import 'swap_screen.dart';

enum SwapVenue { dexy, spectrum, ageusd }

/// Single entry point for every swap surface: Dexy, Spectrum AMM, AgeUSD.
///
/// Hosts the three protocol screens as embedded bodies (no nested app bars)
/// behind a segmented control, preserving each tab's state while switching.
class SwapHubScreen extends StatefulWidget {
  const SwapHubScreen({
    super.key,
    this.initialTab = SwapVenue.dexy,
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
  late SwapVenue _tab = widget.venue ?? widget.initialTab;

  @override
  void didUpdateWidget(SwapHubScreen old) {
    super.didUpdateWidget(old);
    final v = widget.venue;
    if (v != null && v != old.venue) _tab = v;
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
                segments: const [
                  ButtonSegment(
                    value: SwapVenue.dexy,
                    label: Text('Dexy'),
                    icon: Icon(Icons.currency_exchange, size: 18),
                  ),
                  ButtonSegment(
                    value: SwapVenue.spectrum,
                    label: Text('Spectrum'),
                    icon: Icon(Icons.water_drop_outlined, size: 18),
                  ),
                  ButtonSegment(
                    value: SwapVenue.ageusd,
                    label: Text('AgeUSD'),
                    icon: Icon(Icons.account_balance_outlined, size: 18),
                  ),
                ],
                selected: {_tab},
                showSelectedIcon: false,
                onSelectionChanged: (s) {
                  setState(() => _tab = s.first);
                  widget.onVenueChanged?.call(s.first);
                },
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _tab.index,
                children: [
                  for (final venue in SwapVenue.values)
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
