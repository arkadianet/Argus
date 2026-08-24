import 'package:flutter/material.dart';

import '../services/network_controller.dart';
import '../theme/argus_theme.dart';

/// Offline notice for money screens.
///
/// Renders nothing while a node is reachable or a probe is running, so it
/// can be dropped at the top of any screen without conditional wiring.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key, this.margin = const EdgeInsets.only(bottom: 12)});

  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: networkController,
      builder: (context, _) {
        if (networkController.activeUrl != null || networkController.probing) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: margin,
          child: Material(
            color: rust.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.wifi_off_outlined, color: rust, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'No reachable nodes. Tap Retry to check.',
                      style: TextStyle(color: rustFor(context), fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: networkController.probing
                        ? null
                        : networkController.probe,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
