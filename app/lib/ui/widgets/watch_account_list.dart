import 'package:flutter/material.dart';

import '../../services/watch_account_service.dart';
import '../../services/watch_only_service.dart';
import '../../theme/argus_theme.dart';

// The two ways to watch a wallet without its keys. Both start from the
// overview; a watched wallet then opens the standard wallet page.

/// Asks for an Ergo address or a P2PK public key and watches it. Returns
/// true when one was added.
Future<bool> addWatchAddress(BuildContext context) async {
  final text = (await showDialog<String>(
    context: context,
    builder: (_) => const _WatchAddressDialog(),
  ))
      ?.trim();
  if (text == null || text.isEmpty || !context.mounted) return false;
  final bool added;
  try {
    added = await watchOnlyService.add(text);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not add watched address: $e')),
      );
    }
    return false;
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added
              ? 'Watch-only address added'
              : 'Already watched or invalid input. Use an Ergo address, a '
                  '33-byte compressed public key, or its 0008cd P2PK tree '
                  '(hex, no 0x). Raw keys use mainnet.',
        ),
      ),
    );
  }
  return added;
}

/// Owns its field's controller: one disposed as soon as `showDialog` returns
/// would still be in use by the dialog animating out.
class _WatchAddressDialog extends StatefulWidget {
  const _WatchAddressDialog();
  @override
  State<_WatchAddressDialog> createState() => _WatchAddressDialogState();
}

class _WatchAddressDialogState extends State<_WatchAddressDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Watch an address'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'See balance and activity for any Ergo address. No keys are '
              'stored, so it cannot spend.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              style: monoStyle(context, size: 13),
              decoration: const InputDecoration(
                labelText: 'Address or public key',
                helperText: 'Mainnet key hex: 02/03… or 0008cd02/03…',
                helperMaxLines: 2,
                hintText: '9...',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, _controller.text),
            child: const Text('Watch'),
          ),
        ],
      );
}

/// Asks for an Ergo Wallet App extended public key and watches its account,
/// after saying what holding that key reveals.
Future<void> addWatchAccount(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => const _ImportAccountDialog(),
    );

class _ImportAccountDialog extends StatefulWidget {
  const _ImportAccountDialog();
  @override
  State<_ImportAccountDialog> createState() => _ImportAccountDialogState();
}

class _ImportAccountDialogState extends State<_ImportAccountDialog> {
  final controller = TextEditingController();
  String? error;
  var busy = false;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Watch an extended public key'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(watchAccountDisclosure),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Ergo Wallet App extended public key',
                  helperText:
                      '156 hex characters, mainnet. No checksum: verify the first address with the source wallet.',
                  helperMaxLines: 3,
                ),
              ),
              if (error != null) Text(error!),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() => busy = true);
                    try {
                      final saved = await watchAccountService.add(controller.text);
                      if (!context.mounted) return;
                      if (saved) {
                        Navigator.pop(context);
                      } else {
                        setState(() {
                          error = 'This extended key is already watched.';
                          busy = false;
                        });
                      }
                    } catch (e) {
                      if (context.mounted) {
                        setState(() {
                          error = e is StateError
                              ? e.message.toString()
                              : watchAccountExpected;
                          busy = false;
                        });
                      }
                    }
                  },
            child: const Text('Watch account'),
          ),
        ],
      );
}
