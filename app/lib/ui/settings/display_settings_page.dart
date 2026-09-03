import 'package:flutter/material.dart';

import '../../services/network_controller.dart';
import '../../services/privacy_service.dart';
import '../../theme/argus_theme.dart';
import '../../theme/theme_controller.dart';
import 'settings_shared.dart';

class DisplaySettingsPage extends StatelessWidget {
  const DisplaySettingsPage({super.key});

  Widget _radio(bool on) => Builder(
        builder: (context) => Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: on ? accentOf(context) : Colors.transparent,
            border: Border.all(color: accentOf(context), width: 1.2),
          ),
        ),
      );

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
            title: 'Appearance',
            scope: 'App-wide',
            children: [
              for (final m in ArgusThemeMode.values)
                SettingsRow(
                  icon: switch (m) {
                    ArgusThemeMode.system => Icons.brightness_auto_outlined,
                    ArgusThemeMode.dark => Icons.dark_mode_outlined,
                    ArgusThemeMode.light => Icons.light_mode_outlined,
                  },
                  title: switch (m) {
                    ArgusThemeMode.system => 'Follow system',
                    ArgusThemeMode.dark => 'Always dark',
                    ArgusThemeMode.light => 'Always light',
                  },
                  subtitle: switch (m) {
                    ArgusThemeMode.system => 'Dark → ${themeController.darkPalette.name}, light → ${themeController.lightPalette.name}',
                    ArgusThemeMode.dark => themeController.darkPalette.name,
                    ArgusThemeMode.light => themeController.lightPalette.name,
                  },
                  trailing: _radio(themeController.mode == m),
                  onTap: () => themeController.setMode(m),
                ),
            ],
          ),
          const SectionLabel('Dark palette', scope: 'App-wide'),
          const SizedBox(height: 10),
          _PaletteRow(
            palettes: allPalettes.where((p) => p.isDark).toList(),
            selected: themeController.darkPalette,
            onPick: themeController.setDarkPalette,
          ),
          const SizedBox(height: 24),
          const SectionLabel('Light palette', scope: 'App-wide'),
          const SizedBox(height: 10),
          _PaletteRow(
            palettes: allPalettes.where((p) => !p.isDark).toList(),
            selected: themeController.lightPalette,
            onPick: themeController.setLightPalette,
          ),
          const SizedBox(height: 24),
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

/// Swatch cards for one brightness: background, surface, ink and accent.
class _PaletteRow extends StatelessWidget {
  const _PaletteRow({required this.palettes, required this.selected, required this.onPick});
  final List<PaletteSpec> palettes;
  final PaletteSpec selected;
  final ValueChanged<PaletteSpec> onPick;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 132,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: palettes.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final p = palettes[i];
          final on = p.id == selected.id;
          return InkWell(
            onTap: () => onPick(p),
            borderRadius: BorderRadius.circular(16),
            child: Container(
              width: 150,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: p.background,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: on ? p.accent : p.cardBorder, width: on ? 2 : 1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 36,
                    decoration: BoxDecoration(
                      color: p.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: p.cardBorder),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '1,277.94',
                      style: TextStyle(fontFamily: 'Newsreader', fontWeight: FontWeight.w600, fontSize: 16, color: p.ink),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Container(width: 22, height: 22, decoration: BoxDecoration(color: p.accent, borderRadius: BorderRadius.circular(6))),
                      const SizedBox(width: 6),
                      Container(width: 22, height: 22, decoration: BoxDecoration(color: p.muted, borderRadius: BorderRadius.circular(6))),
                      const Spacer(),
                      if (on) Icon(Icons.check_circle, size: 18, color: p.accent),
                    ],
                  ),
                  const Spacer(),
                  Text(p.name, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: p.ink)),
                  Text(p.hint, style: TextStyle(fontSize: 11, color: p.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
