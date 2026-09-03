import 'package:flutter/material.dart';

import '../../format.dart';
import '../../services/activity_classifier.dart';
import '../../services/wallet_service.dart';
import '../../theme/argus_theme.dart';

/// One transaction row shared by the home card and the Activity tab.
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
  Widget build(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    final nano = (tx['value_nano_erg'] as num?)?.toInt() ?? 0;
    final kind = classifyActivity(tx);
    final outgoing = kind == ActivityKind.sent || (kind != ActivityKind.received && nano < 0);
    final ts = (tx['timestamp'] as num?)?.toInt();
    final height = (tx['height'] as num?)?.toInt() ?? 0;
    final confirmed = height > 0;
    final txId = tx['tx_id']?.toString() ?? '';
    final counterparty = tx['counterparty']?.toString();
    final tint = switch (kind) {
      ActivityKind.received => moss,
      ActivityKind.sent => rust,
      ActivityKind.swap => iris,
      _ => muted,
    };
    final icon = switch (kind) {
      ActivityKind.received => Icons.arrow_downward,
      ActivityKind.sent => Icons.arrow_upward,
      ActivityKind.swap => Icons.swap_horiz,
      ActivityKind.selfTransfer => Icons.sync_alt,
      ActivityKind.contract => Icons.code,
    };
    final line = activityLine(
      tx,
      hidden: hidden,
      name: (id) => walletService.cachedTokenMeta(id)?.name,
      decimals: (id) => walletService.cachedTokenMeta(id)?.decimals ?? 0,
    );
    final who = counterparty == null || counterparty.isEmpty
        ? null
        : (isContractAddress(counterparty)
            ? (kind == ActivityKind.swap ? null : 'contract ${shorten(counterparty, head: 6, tail: 4)}')
            : '${outgoing ? 'to' : 'from'} ${shorten(counterparty, head: 6, tail: 4)}');

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
                      Text(
                        activityTitle(kind),
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [line, if (who != null) who].join(' '),
                    style: TextStyle(fontSize: 12.5, color: muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (showTxId && txId.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      shorten(txId, head: 10, tail: 8),
                      style: monoStyle(context, size: 11).copyWith(color: muted),
                    ),
                  ],
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(formatActivityTime(ts), style: TextStyle(fontSize: 12, color: muted)),
                const SizedBox(height: 3),
                Text(
                  confirmed ? 'Confirmed' : 'Pending',
                  style: TextStyle(
                    fontSize: 12,
                    color: confirmed ? moss : iris,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
