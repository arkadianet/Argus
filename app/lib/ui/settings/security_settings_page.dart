import '../widgets/error_sheet.dart';
import 'package:flutter/material.dart';

import '../../bridge/argus_error.dart';
import '../../services/privacy_service.dart';
import '../../services/secure_storage.dart';
import '../../services/session_lock.dart';
import '../../services/stealth_service.dart';
import '../../services/wallet_service.dart';
import '../pin_fields.dart';
import 'settings_shared.dart';

/// Auto-lock (app-wide) plus this wallet's PIN and biometric unlock.
class SecuritySettingsPage extends StatefulWidget {
  const SecuritySettingsPage({super.key, this.walletId});
  final String? walletId;

  @override
  State<SecuritySettingsPage> createState() => _SecuritySettingsPageState();
}

class _SecuritySettingsPageState extends State<SecuritySettingsPage> {
  bool _canBiometric = false;
  bool _hasPin = false;
  bool _loadFailed = false;
  bool _busy = false;
  int _graceKey = 0;

  String? get _walletId => widget.walletId ?? walletService.activeWalletId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final hasPin = await SecureStorageService.hasPinWrap(walletId: _walletId);
      final bio = hasPin &&
          await SecureStorageService.hasBiometric() &&
          await SecureStorageService.hasWrapKey(walletId: _walletId);
      if (!mounted) return;
      setState(() {
        _hasPin = hasPin;
        _canBiometric = bio;
        _loadFailed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadFailed = true);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _disableBiometric() async {
    setState(() => _busy = true);
    try {
      await SecureStorageService.deleteWrapKey(walletId: _walletId);
      await _load();
      _snack('Biometric unlock disabled');
    } catch (_) {
      _snack('Could not disable biometrics');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
    try {
      final blocked = await SecureStorageService.pinBlockedMessage();
      if (blocked != null) {
        _snack(blocked);
        return;
      }
    } on SecureStorageException {
      _snack('Could not check PIN lockout');
      return;
    }
    setState(() => _busy = true);
    try {
      final saved = await sessionLock.run(() async {
        final pinWrap = await SecureStorageService.loadPinWrap(walletId: _walletId);
        if (pinWrap == null) return false;
        final wrapKey = await walletService.unwrapKeyWithPin(pinWrap, entered);
        await SecureStorageService.saveWrapKey(wrapKey, walletId: _walletId);
        await SecureStorageService.clearPinGate();
        return true;
      });
      if (!mounted) return;
      if (!saved) {
        _snack('No PIN-protected wallet found.');
        return;
      }
      setState(() => _canBiometric = true);
      _snack('Biometric unlock enabled');
    } on ArgusException catch (e) {
      if (isIncorrectPin(e)) {
        try {
          await SecureStorageService.recordPinFailure();
        } catch (_) {}
        _snack('Incorrect PIN');
      } else {
        _snack('Could not enable biometrics');
      }
    } catch (_) {
      _snack('Could not enable biometrics');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changePin() async {
    final oldPin = TextEditingController();
    final newPin = TextEditingController();
    final confirmPin = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PinFields(pin: oldPin, label: 'Current PIN'),
            const SizedBox(height: 12),
            PinFields(pin: newPin, confirm: confirmPin, label: 'New PIN'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Change')),
        ],
      ),
    );
    final old = oldPin.text;
    final next = newPin.text;
    final confirm = confirmPin.text;
    oldPin.dispose();
    newPin.dispose();
    confirmPin.dispose();
    if (ok != true) return;
    final pinErr = validatePin(next);
    if (pinErr != null) {
      _snack(pinErr);
      return;
    }
    if (next != confirm) {
      _snack('PINs do not match');
      return;
    }
    setState(() => _busy = true);
    try {
      var changed = false;
      await sessionLock.run(() async {
        final pinWrap = await SecureStorageService.loadPinWrap(walletId: _walletId);
        if (pinWrap == null) {
          _snack('No PIN-protected wallet found');
          return;
        }
        final blocked = await SecureStorageService.pinBlockedMessage();
        if (blocked != null) {
          _snack(blocked);
          return;
        }
        final wrapKey = await walletService.unwrapKeyWithPin(pinWrap, old);
        final newPinWrap = await walletService.wrapKeyWithPin(wrapKey, next);
        await SecureStorageService.savePinWrap(newPinWrap, walletId: _walletId);
        changed = true;
      });
      if (changed) {
        _snack('PIN changed');
        try {
          await SecureStorageService.clearPinGate();
        } catch (_) {
          _snack('PIN changed but lockout state could not be reset');
        }
      }
    } on ArgusException catch (e) {
      if (isIncorrectPin(e)) {
        try {
          await SecureStorageService.recordPinFailure();
        } catch (_) {}
        _snack('Incorrect PIN');
      } else {
        showErrorSheet(context, code: e.code, message: e.message);
      }
    } catch (_) {
      _snack('Could not change PIN');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static const _graceOptions = [
    (0, 'Immediately'),
    (2, 'After 2 seconds'),
    (30, 'After 30 seconds'),
    (60, 'After 1 minute'),
    (300, 'After 5 minutes'),
  ];

  Future<void> _pickGrace() async {
    final current = sessionLock.grace.inSeconds;
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Lock when backgrounded'),
        children: [
          for (final (secs, label) in _graceOptions)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, secs),
              child: Row(
                children: [
                  Expanded(child: Text(label)),
                  if (secs == current) const Icon(Icons.check, size: 18),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked == null || picked == current) return;
    try {
      await sessionLock.setGrace(Duration(seconds: picked));
    } catch (_) {
      _snack('Could not update auto-lock');
    }
    if (mounted) setState(() => _graceKey++);
  }

  @override
  Widget build(BuildContext context) {
    final unlocked = walletService.isUnlocked;
    final graceLabel = _graceOptions
        .firstWhere((o) => o.$1 == sessionLock.grace.inSeconds, orElse: () => (0, '${sessionLock.grace.inSeconds}s'))
        .$2;
    return SettingsPage(
      title: 'Security',
      children: [
        SettingsGroup(
          title: 'Auto-lock',
          scope: 'App-wide',
          children: [
            SettingsRow(
              key: ValueKey(_graceKey),
              icon: Icons.timer_outlined,
              title: 'Lock when backgrounded',
              subtitle: graceLabel,
              onTap: _pickGrace,
            ),
          ],
        ),
        SettingsGroup(
          title: 'Unlock',
          scope: 'This wallet',
          children: [
            if (!unlocked)
              const SettingsRow(
                icon: Icons.lock_outline,
                title: 'Unlock the wallet first',
                subtitle: 'Biometric and PIN settings need an unlocked wallet.',
              )
            else if (_loadFailed)
              SettingsRow(
                icon: Icons.refresh,
                title: 'Retry unlock settings',
                subtitle: 'Could not read the current setup.',
                onTap: _busy ? null : _load,
              )
            else ...[
              SettingsRow(
                icon: Icons.fingerprint,
                title: 'Biometric unlock',
                subtitle: _canBiometric
                    ? 'On. The PIN still unwraps the key.'
                    : (_hasPin ? 'Off' : 'Set a PIN when you create or restore a wallet.'),
                trailing: _hasPin
                    ? Switch(
                        value: _canBiometric,
                        onChanged: _busy ? null : (v) => v ? _enableBiometric() : _disableBiometric(),
                      )
                    : null,
              ),
              if (_hasPin)
                SettingsRow(
                  icon: Icons.lock_reset,
                  title: 'Change PIN',
                  onTap: _busy ? null : _changePin,
                ),
            ],
          ],
        ),
        const SettingsNote(
          'Five wrong PINs lock the gate for a while. Argus never stores the PIN; it only unwraps the key that decrypts the seed.',
        ),
        ListenableBuilder(
          listenable: privacyService,
          builder: (context, _) => SettingsGroup(
            title: 'Screen',
            scope: 'App-wide',
            children: [
              SettingsRow(
                icon: Icons.screenshot_monitor_outlined,
                title: 'Block screenshots',
                subtitle: privacyService.blockScreenshots
                    ? 'Screens cannot be captured or recorded'
                    : 'Off: you can capture screens to report issues',
                trailing: Switch(
                  value: privacyService.blockScreenshots,
                  onChanged: (v) => privacyService.setBlockScreenshots(v),
                ),
              ),
            ],
          ),
        ),
        const SettingsNote(
          'Seed phrase screens always block capture, whatever this setting says.',
        ),
        ListenableBuilder(
          listenable: stealthService,
          builder: (context, _) => SettingsGroup(
            title: 'Stealth',
            scope: 'App-wide',
            children: [
              SettingsRow(
                icon: Icons.visibility_off_outlined,
                title: 'Scan for stealth payments',
                subtitle: stealthService.scanEnabled
                    ? 'Each sync asks the explorer for stealth boxes'
                    : 'Off: payments to your stealth address stay invisible',
                trailing: Switch(
                  key: const Key('stealth-scan-switch'),
                  value: stealthService.scanEnabled,
                  onChanged: (v) async {
                    try {
                      await stealthService.setScanEnabled(v);
                    } catch (_) {
                      _snack('Could not save the stealth scan setting');
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        const SettingsNote(
          'The scan fetches the public list of stealth boxes from the '
          'explorer and tests it on your phone. The explorer learns that '
          'someone asked for the list, never which boxes are yours.',
        ),
      ],
    );
  }
}
