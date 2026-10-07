import 'package:flutter/material.dart';

import '../../format.dart';
import '../../theme/argus_theme.dart';
import '../pin_fields.dart';
import 'home_hero.dart';
import 'home_scene.dart';
import 'wallet_page.dart';
import 'home_style.dart';

/// How a locked seed wallet can be opened on this device.
enum UnlockMethod {
  /// Biometric copy of the wrap key, PIN as the alternative.
  biometric,

  /// PIN only.
  pin,

  /// An old wallet with a stored wrap key and no PIN yet.
  legacy,

  /// No sealed seed here: nothing can unlock it.
  none,
}

/// A locked seed wallet's page. It never asks for biometrics on its own:
/// opening the wallet asks once, and after a cancel only [onUnlock] does.
///
/// It is the wallet's own page, locked: the same scene and medallion with
/// the last figure that needs no key to show, and the way in beneath it.
class UnlockGate extends StatelessWidget {
  const UnlockGate({
    super.key,
    required this.name,
    required this.method,
    required this.pinController,
    required this.busy,
    required this.usePin,
    required this.onUnlock,
    required this.onUsePin,
    required this.onUnlockWithPin,
    required this.onUnlockLegacy,
    this.onUseBiometrics,
    this.address,
    this.pinnedIndex,
    this.lastKnownNano,
    this.lastKnownAge,
    this.hidden = false,
    this.status,
    this.statusIsError = false,
  });

  final String name;
  final String? address;
  final int? pinnedIndex;

  /// The wallet's last public figure, which needs no key to show.
  final int? lastKnownNano;
  final Duration? lastKnownAge;
  final bool hidden;

  final UnlockMethod method;
  final TextEditingController pinController;
  final bool busy;

  /// The PIN field is showing although biometrics are set up.
  final bool usePin;

  /// Biometric unlock: the explicit retry after a cancel.
  final VoidCallback onUnlock;
  final VoidCallback onUsePin;
  final VoidCallback? onUseBiometrics;
  final VoidCallback onUnlockWithPin;
  final VoidCallback onUnlockLegacy;

  /// Why the wallet is still locked ("Biometric cancelled…"), or an error.
  final String? status;
  final bool statusIsError;

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    final spinner = const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
    final showPin = method == UnlockMethod.pin || (method == UnlockMethod.biometric && usePin);
    final age = lastKnownAge;
    final initial = name.trim().isEmpty ? '?' : String.fromCharCode(name.trim().runes.first).toUpperCase();
    const medallion = WalletPageScreen.medallionSize;
    return ListView(
      key: const ValueKey('gate'),
      padding: EdgeInsets.only(bottom: 40 + MediaQuery.paddingOf(context).bottom),
      children: [
        // On the scene the page's frame paints.
        Padding(
          padding: const EdgeInsets.fromLTRB(homeGutter, 18, homeGutter, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  if (lastKnownNano != null)
                    HomeBalance(
                      label: 'Balance',
                      labelExtra: 'Locked',
                      nanoErg: lastKnownNano,
                      // No fiat value: it would be today's price on an old
                      // balance. The age says what the figure is.
                      asOf: age == null ? null : formatSyncAge(DateTime.now().subtract(age)),
                      hidden: hidden,
                      figureReserve: medallion - 18,
                      // The header says the wallet is locked.
                      showLabel: false,
                    )
                  else
                    SizedBox(
                      height: 104,
                      child: Row(
                        children: [
                          Icon(Icons.lock_outline, size: 14, color: t.muted),
                          const SizedBox(width: 6),
                          Text('LOCKED', style: t.label),
                        ],
                      ),
                    ),
                  PositionedDirectional(top: -18, end: -14, child: WalletMedallion(letter: initial, size: medallion)),
                ],
              ),
              if (address != null) ...[
                const SizedBox(height: 18),
                IdentityPill(address: address!, pinnedIndex: pinnedIndex),
              ],
              const SizedBox(height: 14),
              Text('Unlock to see activity, send and receive.', style: t.secondary.copyWith(color: t.ink, fontSize: 14.5)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (method == UnlockMethod.biometric && !usePin) ...[
                FilledButton.icon(
                  key: const Key('gate-unlock'),
                  onPressed: busy ? null : onUnlock,
                  icon: busy ? spinner : const Icon(Icons.fingerprint),
                  label: const Text('Unlock'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  key: const Key('gate-use-pin'),
                  onPressed: busy ? null : onUsePin,
                  style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  child: const Text('Use PIN'),
                ),
              ] else if (showPin) ...[
                PinFields(
                  pin: pinController,
                  label: 'PIN',
                  onSubmitted: (_) {
                    if (!busy) onUnlockWithPin();
                  },
                ),
                const SizedBox(height: 16),
                FilledButton(
                  key: const Key('gate-unlock-pin'),
                  onPressed: busy ? null : onUnlockWithPin,
                  child: busy ? spinner : const Text('Unlock'),
                ),
                if (method == UnlockMethod.biometric && onUseBiometrics != null) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: busy ? null : onUseBiometrics,
                    style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    child: const Text('Use biometrics'),
                  ),
                ],
              ] else if (method == UnlockMethod.legacy)
                FilledButton(
                  onPressed: busy ? null : onUnlockLegacy,
                  child: busy ? spinner : const Text('Unlock and set PIN'),
                )
              else
                Text(
                  "This wallet's keys are not stored on this device.",
                  textAlign: TextAlign.center,
                  style: t.secondary.copyWith(color: rustFor(context)),
                ),
              if (status != null) ...[
                const SizedBox(height: 16),
                Text(
                  status!,
                  key: const Key('gate-status'),
                  textAlign: TextAlign.center,
                  style: t.secondary.copyWith(color: statusIsError ? rustFor(context) : t.muted),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
