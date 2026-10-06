import 'package:flutter/material.dart';

import '../../theme/argus_theme.dart';
import 'home_models.dart';

/// Icons and label for each tab.
({IconData icon, IconData selected, String label}) walletTabLook(WalletTab tab) => switch (tab) {
      WalletTab.wallet => (
          icon: Icons.account_balance_wallet_outlined,
          selected: Icons.account_balance_wallet,
          label: 'Wallet',
        ),
      WalletTab.activity => (icon: Icons.receipt_long_outlined, selected: Icons.receipt_long, label: 'Activity'),
      WalletTab.discover => (icon: Icons.explore_outlined, selected: Icons.explore, label: 'Discover'),
      WalletTab.settings => (icon: Icons.settings_outlined, selected: Icons.settings, label: 'Settings'),
    };

/// The open wallet's tabs: Wallet, Activity, Discover, Settings.
///
/// Discover takes the old Swap tab's place and gathers every protocol
/// (DEX, AgeUSD, Duckpools, SigmaFi, Mix, Rosen, dApps), so Swap is no
/// longer offered three times. Settings lives here and nowhere in a
/// header. A watched wallet has no keys to use a protocol with, so it
/// has no Discover tab. Activity carries a badge while anything is
/// unconfirmed. Colours come from the theme: the current tab in the
/// accent, the rest quiet.
class WalletNavBar extends StatelessWidget {
  const WalletNavBar({
    super.key,
    required this.current,
    required this.onSelect,
    this.watchOnly = false,
    this.pendingCount = 0,
  });

  final WalletTab current;
  final ValueChanged<WalletTab> onSelect;
  final bool watchOnly;
  final int pendingCount;

  /// The bar's labels stop growing here: at larger sizes they no longer
  /// fit four abreast, and every destination is also announced in full.
  static const maxLabelScale = 1.3;

  List<WalletTab> get tabs => [
        WalletTab.wallet,
        WalletTab.activity,
        if (!watchOnly) WalletTab.discover,
        WalletTab.settings,
      ];

  @override
  Widget build(BuildContext context) {
    final shown = tabs;
    final index = shown.indexOf(current);
    final media = MediaQuery.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The bar shares the page's ground; a hairline keeps the list from
        // appearing to run under it.
        SizedBox(
          height: 1 / media.devicePixelRatio,
          width: double.infinity,
          child: ColoredBox(color: Theme.of(context).colorScheme.outline),
        ),
        MediaQuery(
          data: media.copyWith(textScaler: media.textScaler.clamp(maxScaleFactor: maxLabelScale)),
          child: NavigationBar(
            selectedIndex: index < 0 ? 0 : index,
            onDestinationSelected: (i) => onSelect(shown[i]),
            destinations: [
              for (final tab in shown)
                NavigationDestination(
                  key: Key('wallet-tab-${tab.name}'),
                  icon: _icon(context, tab, walletTabLook(tab).icon),
                  selectedIcon: _icon(context, tab, walletTabLook(tab).selected),
                  label: walletTabLook(tab).label,
                  tooltip: tab == WalletTab.activity && pendingCount > 0
                      ? 'Activity, $pendingCount pending'
                      : walletTabLook(tab).label,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _icon(BuildContext context, WalletTab tab, IconData icon) {
    if (tab != WalletTab.activity || pendingCount == 0) return Icon(icon);
    final colors = ArgusColors.of(context);
    return Badge.count(
      count: pendingCount,
      backgroundColor: colors.accent,
      textColor: colors.onAccent,
      child: Icon(icon),
    );
  }
}
