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
  const SwapHubScreen({super.key, this.initialTab = SwapVenue.dexy});

  final SwapVenue initialTab;

  @override
  State<SwapHubScreen> createState() => _SwapHubScreenState();
}

class _SwapHubScreenState extends State<SwapHubScreen> {
  late SwapVenue _tab = widget.initialTab;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Swap')),
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
                onSelectionChanged: (s) => setState(() => _tab = s.first),
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _tab.index,
                children: const [
                  DexyScreen(embedded: true),
                  SwapScreen(embedded: true),
                  AgeUsdScreen(embedded: true),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
