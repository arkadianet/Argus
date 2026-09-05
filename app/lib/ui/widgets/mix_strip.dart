import 'package:flutter/material.dart';

import '../../services/mix_activity.dart';
import '../../services/mix_service.dart';
import '../../theme/argus_theme.dart';

/// One line about mixes on the home screen, and nothing at all when there
/// are none. A finished mix is announced until dismissed.
class MixStrip extends StatelessWidget {
  const MixStrip({super.key, required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: mixService,
      builder: (context, _) {
        final summary = mixStripSummary(mixService.records);
        if (summary == null) return const SizedBox.shrink();
        final colors = ArgusColors.of(context);
        final finished = summary.finished;
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: colors.inset,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.blender_outlined, size: 16, color: finished != null ? moss : accentOf(context)),
                const SizedBox(width: 8),
                Expanded(
                  child: InkWell(
                    key: const Key('mix-strip'),
                    onTap: onOpen,
                    borderRadius: BorderRadius.circular(8),
                    child: Text(
                      summary.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: colors.muted),
                    ),
                  ),
                ),
                if (finished != null)
                  IconButton(
                    key: const Key('mix-strip-dismiss'),
                    tooltip: 'Dismiss',
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    onPressed: () => mixService.acknowledge(finished),
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
