import 'package:flutter/material.dart';

import '../../theme/argus_theme.dart';

/// Empty or error state that says what happened and what to do next.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
    this.tone = EmptyStateTone.neutral,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;
  final EmptyStateTone tone;

  /// Inline inside a card rather than centred in a full screen.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    final accent = tone == EmptyStateTone.error ? rust : iris;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: compact ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        Container(
          width: compact ? 36 : 56,
          height: compact ? 36 : 56,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(compact ? 10 : 18),
          ),
          child: Icon(icon, size: compact ? 19 : 28, color: accent),
        ),
        SizedBox(height: compact ? 10 : 16),
        Text(
          title,
          textAlign: compact ? TextAlign.start : TextAlign.center,
          style: TextStyle(
            fontFamily: 'Newsreader',
            fontWeight: FontWeight.w600,
            fontSize: compact ? 17 : 22,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          body,
          textAlign: compact ? TextAlign.start : TextAlign.center,
          style: TextStyle(fontSize: 13.5, height: 1.4, color: colors.muted),
        ),
        if (actionLabel != null && onAction != null) ...[
          SizedBox(height: compact ? 12 : 20),
          if (compact)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: onAction, child: Text(actionLabel!)),
            )
          else
            FilledButton(
              onPressed: onAction,
              style: FilledButton.styleFrom(minimumSize: const Size(160, 48)),
              child: Text(actionLabel!),
            ),
        ],
      ],
    );
    if (compact) return content;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 48),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 360), child: content),
      ),
    );
  }
}

enum EmptyStateTone { neutral, error }
