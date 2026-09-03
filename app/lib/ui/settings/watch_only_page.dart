import 'package:flutter/material.dart';

import '../../format.dart';
import '../../services/address_label_service.dart';
import '../../services/watch_only_service.dart';
import '../../theme/argus_theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/soft_card.dart';
import 'settings_shared.dart';

class WatchOnlyPage extends StatelessWidget {
  const WatchOnlyPage({super.key});

  Future<void> _add(BuildContext context) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Watch an address'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('See balance and activity for any Ergo address. No keys are stored, so it cannot spend.'),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              style: monoStyle(ctx, size: 13),
              decoration: const InputDecoration(labelText: 'Ergo address', hintText: '9...'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Watch')),
        ],
      ),
    );
    final addr = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || addr.isEmpty) return;
    final saved = await watchOnlyService.add(addr);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(saved ? 'Now watching ${shorten(addr, head: 8, tail: 6)}' : 'Not a valid Ergo address, or already watched')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([watchOnlyService, addressLabelService]),
      builder: (context, _) {
        final colors = ArgusColors.of(context);
        final addrs = watchOnlyService.addresses;
        return SettingsPage(
          title: 'Watch-only',
          children: [
            const SectionLabel('Watched addresses', scope: 'App-wide'),
            const SizedBox(height: 10),
            if (addrs.isEmpty)
              SoftCard(
                child: EmptyState(
                  compact: true,
                  icon: Icons.visibility_outlined,
                  title: 'Nothing watched yet',
                  body: 'Follow an address without holding its keys. It appears on the home screen with its balance.',
                  actionLabel: 'Watch an address',
                  onAction: () => _add(context),
                ),
              )
            else ...[
              SoftCard(
                padding: EdgeInsets.zero,
                child: DividedColumn(
                  indent: 16,
                  children: [
                    for (final a in addrs)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
                        child: Row(
                          children: [
                            Icon(Icons.visibility_outlined, size: 20, color: colors.muted),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(addressLabelService.labelFor(a) ?? 'Watched',
                                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                                  const SizedBox(height: 2),
                                  Text(shorten(a, head: 12, tail: 10),
                                      style: monoStyle(context, size: 11.5).copyWith(color: colors.muted)),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Stop watching',
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () => watchOnlyService.remove(a),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => _add(context),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Watch another address'),
              ),
            ],
          ],
        );
      },
    );
  }
}
