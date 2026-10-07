import 'package:flutter/material.dart';

import '../../services/pending_balance.dart';
import '../../theme/argus_theme.dart';

/// "+2.5 ERG pending · 105.21 confirmed" under a balance, or nothing while
/// no transaction touching it is in the mempool.
///
/// The balance above it already counts what is pending, so this line only
/// splits it: how far unconfirmed transactions move it, and what is in
/// blocks. With [withTotal] it stands on its own instead, leading with the
/// balance ("107.71 ERG · +2.5 pending") for rows that show no figure of
/// their own.
class PendingBalanceLine extends StatelessWidget {
  const PendingBalanceLine({
    super.key,
    required this.pending,
    this.hidden = false,
    this.withTotal = false,
    this.style,
  });

  /// Null or empty shows nothing.
  final PendingBalance? pending;

  /// Balances are masked on screen: say something is pending, not how much.
  final bool hidden;
  final bool withTotal;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final text = pendingBalanceText(
      pending,
      hidden: hidden,
      withTotal: withTotal,
    );
    if (text == null) return const SizedBox.shrink();
    final base =
        style ?? TextStyle(fontSize: 13, color: ArgusColors.of(context).muted);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.hourglass_bottom_rounded,
          size: (base.fontSize ?? 13) + 1,
          color: base.color,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            style: base,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
