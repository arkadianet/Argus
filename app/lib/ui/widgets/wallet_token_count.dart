import 'package:flutter/material.dart';

import '../../theme/argus_theme.dart';

/// Counts token IDs, including NFTs, only for a known holdings snapshot.
/// Locked snapshots contain public tokens only; say so rather than imply
/// that an unavailable stealth scan found none.
class WalletTokenCount extends StatelessWidget {
  const WalletTokenCount({
    super.key,
    required this.holdings,
    this.publicOnly = false,
    this.hidden = false,
  });

  final Iterable<({String id, int amount})>? holdings;
  final bool publicOnly;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    if (holdings == null || hidden) return const SizedBox.shrink();
    final count = holdings!
        .where((t) => t.amount > 0)
        .map((t) => t.id)
        .toSet()
        .length;
    return Text(
      '$count ${publicOnly ? 'public ' : ''}token ${count == 1 ? 'ID' : 'IDs'} (incl. NFTs)',
      textAlign: TextAlign.end,
      style: TextStyle(fontSize: 12, color: ArgusColors.of(context).muted),
    );
  }
}
