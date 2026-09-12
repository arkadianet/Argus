import 'package:flutter/widgets.dart';

import '../../services/wallet_sync_controller.dart';

/// Keeps the label and its ledger in one wallet context. No outgoing child is
/// retained for an animation, and a new wallet gets fresh embedded screen state.
class WalletViewBoundary extends StatelessWidget {
  const WalletViewBoundary({
    super.key,
    required this.controller,
    required this.walletId,
    required this.unlocked,
    required this.ledger,
    required this.gate,
  });

  final WalletSyncController controller;
  final String? walletId;
  final bool unlocked;
  final WidgetBuilder ledger;
  final WidgetBuilder gate;

  @override
  Widget build(BuildContext context) {
    if (!unlocked || !controller.ownsWallet(walletId)) return gate(context);
    return KeyedSubtree(key: ValueKey(walletId), child: ledger(context));
  }
}
