import 'package:flutter/material.dart';

import '../../services/network_controller.dart';
import '../../services/privacy_service.dart';
import '../../theme/argus_theme.dart';
import '../../theme/theme_controller.dart';
import 'settings_shared.dart';

class DisplaySettingsPage extends StatelessWidget {
  const DisplaySettingsPage({super.key});

  Future<void> _pickFiatCurrency(BuildContext context) async {
    final current = networkController.fiatCode;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Display currency'),
        children: [
          for (final entry in NetworkController.fiatOptions.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, entry.key),
              child: Row(
                children: [
                  Expanded(child: Text('${entry.key.toUpperCase()} (${entry.value})')),
                  if (entry.key == current) const Icon(Icons.check, size: 18),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked == null || picked == current) return;
    await networkController.setFiatCurrency(picked);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([themeController, networkController, privacyService]),
      builder: (context, _) => SettingsPage(
        title: 'Display',
        children: [
          SettingsGroup(
            title: 'Palette',
            scope: 'App-wide',
            children: [
              for (final p in ArgusPalette.values)
                SettingsRow(
                  icon: switch (p) {
                    ArgusPalette.system => Icons.brightness_auto_outlined,
                    ArgusPalette.watchful => Icons.dark_mode_outlined,
                    ArgusPalette.ledger => Icons.light_mode_outlined,
                  },
                  title: switch (p) {
                    ArgusPalette.system => 'System',
                    ArgusPalette.watchful => 'Watchful',
                    ArgusPalette.ledger => 'Ledger',
                  },
                  subtitle: switch (p) {
                    ArgusPalette.system => 'Dark → Watchful, light → Ledger',
                    ArgusPalette.watchful => 'Ink ground, bone type',
                    ArgusPalette.ledger => 'Warm paper, dark ink',
                  },
                  trailing: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: themeController.palette == p ? iris : Colors.transparent,
                      border: Border.all(color: iris, width: 1.2),
                    ),
                  ),
                  onTap: () => themeController.setPalette(p),
                ),
            ],
          ),
          SettingsGroup(
            title: 'Money',
            scope: 'App-wide',
            children: [
              SettingsRow(
                icon: Icons.payments_outlined,
                title: 'Display currency',
                subtitle: 'ERG price shown in ${networkController.fiatCode.toUpperCase()}',
                trailing: Text(networkController.fiatSymbol, style: Theme.of(context).textTheme.titleMedium),
                onTap: () => _pickFiatCurrency(context),
              ),
              SettingsRow(
                icon: Icons.visibility_off_outlined,
                title: 'Hide balances',
                subtitle: 'Mask amounts on the home screen',
                trailing: Switch(
                  value: privacyService.hideBalances,
                  onChanged: (v) => privacyService.setHideBalances(v),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
