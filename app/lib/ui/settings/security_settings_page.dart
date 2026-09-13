import '../widgets/error_sheet.dart';
import 'package:flutter/material.dart';

import '../../bridge/argus_error.dart';
import '../../format.dart';
import '../../services/privacy_service.dart';
import '../../services/secure_storage.dart';
import '../../services/session_lock.dart';
import '../../services/battery_service.dart';
import '../../services/mix_service.dart';
import '../widgets/battery_note.dart';
import '../../services/stealth_identities.dart';
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

/// The trade, stated before the switch flips: a key per mix in flight,
/// spendable by anyone with full access to the unlocked phone, and
/// nothing else.
Future<bool> _confirmBackgroundMixing(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Mix with Argus closed?'),
      content: const Text(
        'Argus will keep, in the phone\'s keystore, one key for each mix that '
        'is in the pool. That key can spend that mix\'s money and nothing '
        'else: not your other funds, not your seed. Someone with full '
        'access to this unlocked phone could use it. A lost or wiped phone '
        'loses nothing, because every mix can be rebuilt from your seed. '
        'Keys are deleted when a mix ends or when you turn this off.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Turn on')),
      ],
    ),
  );
  return ok == true;
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

  /// What one stealth identity holds, or why we cannot say.
  String _stealthIdentitySubtitle(int index) {
    final address = stealthService.addressOf(index);
    final where = address == null
        ? 'Unlock to see this address'
        : shortStealth(address);
    if (!stealthService.scanEnabled) return '$where · scanning off';
    final scan = stealthService.lastScan;
    if (scan == null) return '$where · balance unknown';
    final balance = scan.balanceOf(index);
    return balance.ownedCount == 0
        ? '$where · no payments'
        : '$where · ${formatErg(balance.totalNanoErg)} in '
            '${balance.ownedCount} box${balance.ownedCount == 1 ? '' : 'es'}';
  }

  Future<void> _renameStealthIdentity(StealthIdentity id) async {
    final controller = TextEditingController(text: id.label);
    final label = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename stealth address'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Label',
            helperText: 'The address itself does not change.',
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (label == null) return;
    try {
      await stealthService.renameIdentity(id.index, label);
    } catch (_) {
      _snack('Could not save the label');
    }
  }

  /// Adopt stealth identities that hold funds but are missing from this
  /// device's list — the restore case, where the labels were lost with the
  /// old device but the money is still findable.
  Future<void> _discoverStealthIdentities() async {
    setState(() => _busy = true);
    try {
      final result = await stealthService.discoverIdentities();
      if (result.superseded) return;
      // "Could not look" must never be shown as "looked and found nothing":
      // the user is asking whether a restore recovered their money.
      if (result.error != null) {
        _snack(result.error!);
        return;
      }
      final found = result.adopted;
      _snack(
        found.isEmpty
            ? 'No stealth addresses with funds beyond the ones already listed'
            : 'Found ${found.length} stealth '
                'address${found.length == 1 ? '' : 'es'} with funds',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
                    : 'Off: stealth payments stay invisible, with no balance and no notification',
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
              for (final id in stealthService.identities)
                SettingsRow(
                  icon: Icons.alternate_email,
                  title: id.displayLabel,
                  subtitle: _stealthIdentitySubtitle(id.index),
                  onTap: () => _renameStealthIdentity(id),
                ),
              SettingsRow(
                icon: Icons.travel_explore_outlined,
                title: 'Find stealth addresses with funds',
                subtitle:
                    'After restoring, looks for paid stealth addresses this '
                    'device does not know about yet',
                onTap: _discoverStealthIdentities,
              ),
            ],
          ),
        ),
        const SettingsNote(
          'The scan fetches the public list of stealth boxes from the '
          'explorer and tests it on your phone. The explorer learns that '
          'someone asked for the list, never which boxes are yours.',
        ),
        const SettingsNote(
          'Every stealth address comes back from your recovery phrase, so '
          'none of them needs its own backup. Labels are the exception: they '
          'live on this device only, and a restore finds an address by its '
          'payments, so one that was never paid comes back unnamed.',
        ),
        ListenableBuilder(
          listenable: mixService,
          builder: (context, _) => SettingsGroup(
            title: 'Mixing',
            scope: 'App-wide',
            children: [
              SettingsRow(
                icon: Icons.blender_outlined,
                title: 'Enable mixing',
                subtitle: mixService.enabled
                    ? 'Mixes advance on their own while Argus is open and unlocked'
                    : 'Off: no mix is started or advanced',
                trailing: Switch(
                  key: const Key('mixing-switch'),
                  value: mixService.enabled,
                  onChanged: (v) async {
                    try {
                      await mixService.setEnabled(v);
                    } catch (_) {
                      _snack('Could not save the mixing setting');
                    }
                  },
                ),
              ),
              SettingsRow(
                icon: Icons.nightlight_outlined,
                title: 'Keep mixing in the background',
                subtitle: !mixService.enabled
                    ? 'Turn on mixing first'
                    : mixService.backgroundEnabled
                        ? 'Mixes move about every fifteen minutes with Argus closed, from '
                            'per-mix keys in the phone\'s keystore'
                        : 'Off: mixes move only while Argus is open and unlocked',
                trailing: Switch(
                  key: const Key('mixing-background-switch'),
                  value: mixService.backgroundEnabled,
                  onChanged: !mixService.enabled
                      ? null
                      : (v) async {
                          if (v && !await _confirmBackgroundMixing(context)) return;
                          try {
                            await mixService.setBackgroundEnabled(v);
                          } catch (e) {
                            _snack('Could not change background mixing: $e');
                            return;
                          }
                          // Android will delay the job unless the app is exempt
                          // from battery optimisation; offer that now.
                          if (v && await BatteryService.isUnrestricted() == false) {
                            final shown = await BatteryService.requestUnrestricted();
                            if (!shown) await BatteryService.openBatterySettings();
                          }
                        },
                ),
              ),
            ],
          ),
        ),
        const SettingsNote(
          'Mixing uses the public ErgoMixer pool and its contracts. Entering '
          'costs an operator fee; each round needs a stranger to pair with, '
          'so a mix can take hours or days. Not every app store allows a '
          'wallet with a built-in mixer; it stays off until you turn it on.',
        ),
        ListenableBuilder(
          listenable: mixService,
          builder: (context, _) => mixService.backgroundEnabled
              ? const Padding(
                  padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: BatteryNote(),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}
