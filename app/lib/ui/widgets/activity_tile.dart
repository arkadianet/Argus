import 'package:flutter/material.dart';

import '../../format.dart';
import '../../services/activity_classifier.dart';
import '../../services/token_metadata.dart';
import '../../services/wallet_service.dart';
import '../../theme/argus_theme.dart';

/// One transaction row shared by the home card and the Activity tab.
///
/// Tokens are named and scaled by the one token lookup, the same as the
/// asset list, and the row repaints when that lookup learns something.
class ActivityTile extends StatelessWidget {
  const ActivityTile({
    super.key,
    required this.tx,
    this.hidden = false,
    this.onTap,
    this.showTxId = false,
  });

  final Map<String, dynamic> tx;
  final bool hidden;
  final VoidCallback? onTap;

  /// Activity tab: show the shortened id under the amount.
  final bool showTxId;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: walletService.metadataChanges,
    builder: (context, _, _) => _row(context),
  );

  Widget _row(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    // Read from the whole wallet's point of view: the same title, figures
    // and counterparty as the home rows.
    final view = describeActivity(tx, name: (id) => tokenName(id));
    final kind = view.kind;
    final ts = (tx['timestamp'] as num?)?.toInt();
    final height = (tx['height'] as num?)?.toInt() ?? 0;
    final confirmed = height > 0;
    final txId = tx['tx_id']?.toString() ?? '';
    final tint = switch (kind) {
      ActivityKind.received => moss,
      ActivityKind.sent => rust,
      ActivityKind.swap => accentOf(context),
      ActivityKind.mix => accentOf(context),
      _ => muted,
    };
    final icon = switch (kind) {
      ActivityKind.received => Icons.arrow_downward,
      ActivityKind.sent => Icons.arrow_upward,
      ActivityKind.swap => Icons.swap_horiz,
      ActivityKind.selfTransfer => Icons.sync_alt,
      ActivityKind.contract => Icons.code,
      ActivityKind.mix => Icons.blender_outlined,
    };
    final line = activityLine(
      tx,
      hidden: hidden,
      name: (id) => tokenName(id),
      decimals: (id) => tokenDecimals(id),
    );
    final who = view.who;

    final when = Text(
      formatActivityTime(ts),
      style: TextStyle(fontSize: 12, color: muted),
    );
    final status = Text(
      confirmed ? 'Confirmed' : 'Pending',
      style: TextStyle(
        fontSize: 12,
        color: confirmed ? moss : ArgusColors.of(context).accentText,
        fontWeight: FontWeight.w500,
      ),
    );
    // At large text sizes a side column for the time takes half the row and
    // leaves the names a few letters; it moves under the line instead, as
    // the Assets filters do.
    final stacked = MediaQuery.textScalerOf(context).scale(14) / 14 > 1.4;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(cardRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: tint.withValues(alpha: 0.12),
              child: Icon(icon, size: 17, color: tint),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          view.title,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  // Two lines: named tokens and the ERG leg are what the row
                  // is for, and one line cut them off at phone width.
                  Text(
                    [line, if (who != null) who].join(' '),
                    style: TextStyle(fontSize: 12.5, color: muted),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (showTxId && txId.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      shorten(txId, head: 10, tail: 8),
                      style: monoStyle(context, size: 11).copyWith(color: muted),
                    ),
                  ],
                  if (stacked) ...[
                    const SizedBox(height: 3),
                    Wrap(spacing: 10, children: [when, status]),
                  ],
                ],
              ),
            ),
            if (!stacked)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [when, const SizedBox(height: 3), status],
              ),
          ],
        ),
      ),
    );
  }
}
