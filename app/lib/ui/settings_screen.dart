import 'package:flutter/material.dart';

import '../services/secure_storage.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import '../theme/theme_controller.dart';
import 'pin_fields.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _canBiometric = false;
  bool _hasPin = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final hasPin = await SecureStorageService.hasPinWrap();
    final bio = hasPin &&
        await SecureStorageService.hasBiometric() &&
        await SecureStorageService.hasWrapKey();
    if (!mounted) return;
    setState(() {
      _hasPin = hasPin;
      _canBiometric = bio;
    });
  }

  Future<void> _enableBiometric() async {
    final pin = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm PIN'),
        content: PinFields(pin: pin),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Continue')),
        ],
      ),
    );
    final entered = pin.text;
    pin.dispose();
    if (ok != true) return;
    final pinErr = validatePin(entered);
    if (pinErr != null) {
      _snack(pinErr);
      return;
    }
    setState(() => _busy = true);
    try {
      final pinWrap = await SecureStorageService.loadPinWrap();
      if (pinWrap == null) return;
      final wrapKey = await walletService.unwrapKeyWithPin(pinWrap, entered);
      await SecureStorageService.saveWrapKey(wrapKey);
      if (!mounted) return;
      setState(() => _canBiometric = true);
      _snack('Biometric unlock enabled');
    } catch (e) {
      _snack('Could not enable biometrics: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: themeController,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              const SectionLabel('Appearance'),
              const SizedBox(height: 12),
              const Text(
                'One layout, two palettes. System follows the phone.',
              ),
              const SizedBox(height: 16),
              ...ArgusPalette.values.map((p) {
                final label = switch (p) {
                  ArgusPalette.system => 'System',
                  ArgusPalette.watchful => 'Watchful',
                  ArgusPalette.ledger => 'Ledger',
                };
                final hint = switch (p) {
                  ArgusPalette.system => 'Dark → Watchful, light → Ledger',
                  ArgusPalette.watchful => 'Ink ground, bone type',
                  ArgusPalette.ledger => 'Warm paper, dark ink',
                };
                final selected = themeController.palette == p;
                return InkWell(
                  onTap: () => themeController.setPalette(p),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: Theme.of(context).dividerColor),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(label, style: Theme.of(context).textTheme.titleMedium),
                              const SizedBox(height: 2),
                              Text(hint, style: Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                        ),
                        Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            color: selected ? iris : Colors.transparent,
                            border: Border.all(color: iris, width: 1.2),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
              const SizedBox(height: 28),
              const SectionLabel('Unlock'),
              const SizedBox(height: 12),
              if (!walletService.isUnlocked)
                Text(
                  'Unlock the wallet to change biometric settings.',
                  style: Theme.of(context).textTheme.bodySmall,
                )
              else if (_canBiometric)
                Text(
                  'Biometric unlock is on. The PIN still unwraps the key.',
                  style: Theme.of(context).textTheme.bodyMedium,
                )
              else if (_hasPin)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _busy ? null : _enableBiometric,
                    child: const Text('Enable biometric unlock'),
                  ),
                )
              else
                Text(
                  'Set a PIN when you create or restore a wallet.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          );
        },
      ),
    );
  }
}
