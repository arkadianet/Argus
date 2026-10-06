import 'package:flutter/material.dart';

import '../../format.dart';
import '../../theme/argus_theme.dart';
import '../pin_fields.dart';
import '../widgets/soft_card.dart';
import 'wallet_sections.dart';

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
    final muted = ArgusColors.of(context).muted;
    final spinner = const SizedBox(
      width: 20,
      height: 20,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
    final showPin =
        method == UnlockMethod.pin ||
        (method == UnlockMethod.biometric && usePin);
    return ListView(
      key: const ValueKey('gate'),
      padding: EdgeInsets.fromLTRB(
        24,
        28,
        24,
        40 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.lock_outline, size: 18, color: muted),
                  const SizedBox(width: 8),
                  Text(
                    'LOCKED',
                    style: Theme.of(
                      context,
                    ).textTheme.titleSmall?.copyWith(color: muted),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Newsreader',
                  fontWeight: FontWeight.w600,
                  fontSize: 24,
                ),
              ),
              if (address != null) ...[
                const SizedBox(height: 4),
                WalletIdentityLine(address: address!, pinnedIndex: pinnedIndex),
              ],
              if (lastKnownNano != null) ...[
                const SizedBox(height: 10),
                Text(
                  [
                    hidden ? '•••• ERG' : formatErg(lastKnownNano, maxFrac: 4),
                    if (lastKnownAge != null)
                      'as of ${formatSyncAge(DateTime.now().subtract(lastKnownAge!))}',
                  ].join(' · '),
                  style: TextStyle(fontSize: 14, color: muted),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                'Unlock to see activity, send and receive.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
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
          if (method == UnlockMethod.biometric && onUseBiometrics != null)
            TextButton(
              onPressed: busy ? null : onUseBiometrics,
              child: const Text('Use biometrics'),
            ),
        ] else if (method == UnlockMethod.legacy)
          FilledButton(
            onPressed: busy ? null : onUnlockLegacy,
            child: busy ? spinner : const Text('Unlock and set PIN'),
          )
        else
          Text(
            "This wallet's keys are not stored on this device.",
            textAlign: TextAlign.center,
            style: TextStyle(color: rustFor(context)),
          ),
        if (status != null) ...[
          const SizedBox(height: 16),
          Text(
            status!,
            key: const Key('gate-status'),
            textAlign: TextAlign.center,
            style: TextStyle(color: statusIsError ? rustFor(context) : muted),
          ),
        ],
      ],
    );
  }
}
