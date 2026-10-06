import 'package:flutter/material.dart';

import '../widgets/empty_state.dart';
import '../widgets/soft_card.dart';
import 'balance_card.dart';
import 'home_format.dart';
import 'home_models.dart';
import 'home_rows.dart';
import 'home_widgets.dart';
import 'wallet_actions.dart';
import 'wallet_nav_bar.dart';
import 'wallet_tools_sheet.dart';

/// One open wallet, and nothing from any other.
///
/// Top to bottom: the balance card, one row of actions, the holdings
/// worth a glance and the last three transactions. Everything else has
/// one home elsewhere: protocols in Discover, tools behind More, the full
/// history in Activity, settings in Settings. The back arrow returns to
/// the overview, which is where wallets are switched.
class WalletPageScreen extends StatelessWidget {
  const WalletPageScreen({
    super.key,
    required this.data,
    this.tab = WalletTab.wallet,
    this.onTab,
    this.onBack,
    this.onScan,
    this.onToggleHidden,
    this.onAction,
    this.onTool,
    this.onAsset,
    this.onAllAssets,
    this.onActivity,
    this.onAllActivity,
    this.onTidyUp,
    this.onOtherAddresses,
    this.onNetwork,
    this.onReceive,
  });

  final WalletPageData data;
  final WalletTab tab;
  final ValueChanged<WalletTab>? onTab;
  final VoidCallback? onBack;
  final VoidCallback? onScan;
  final VoidCallback? onToggleHidden;

  /// Send, Receive, Swap or Send with offline signer. More opens its sheet
  /// here and reports the pick through [onTool].
  final ValueChanged<WalletAction>? onAction;
  final ValueChanged<WalletTool>? onTool;
  final ValueChanged<String>? onAsset;
  final VoidCallback? onAllAssets;
  final ValueChanged<String>? onActivity;
  final VoidCallback? onAllActivity;
  final VoidCallback? onTidyUp;
  final VoidCallback? onOtherAddresses;
  final VoidCallback? onNetwork;

  /// The empty-activity hint's button; defaults to the Receive action.
  final VoidCallback? onReceive;

  @override
  Widget build(BuildContext context) {
    final wallet = data.wallet;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const Key('wallet-back'),
          icon: const Icon(Icons.arrow_back),
          tooltip: 'All wallets',
          onPressed: onBack,
        ),
        titleSpacing: 0,
        title: Text(wallet.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (!wallet.watchOnly)
            IconButton(
              key: const Key('wallet-scan'),
              icon: const Icon(Icons.qr_code_scanner),
              tooltip: 'Scan a QR code',
              onPressed: onScan,
            ),
          const SizedBox(width: 6),
        ],
      ),
      body: WalletPageView(
        data: data,
        onToggleHidden: onToggleHidden,
        onAction: onAction,
        onTool: onTool,
        onAsset: onAsset,
        onAllAssets: onAllAssets,
        onActivity: onActivity,
        onAllActivity: onAllActivity,
        onTidyUp: onTidyUp,
        onOtherAddresses: onOtherAddresses,
        onNetwork: onNetwork,
        onReceive: onReceive,
      ),
      bottomNavigationBar: WalletNavBar(
        current: tab,
        onSelect: onTab ?? (_) {},
        watchOnly: wallet.watchOnly,
        pendingCount: data.pendingCount,
      ),
    );
  }
}

/// The Wallet tab's scrolling body, for hosting under another scaffold.
class WalletPageView extends StatelessWidget {
  const WalletPageView({
    super.key,
    required this.data,
    this.onToggleHidden,
    this.onAction,
    this.onTool,
    this.onAsset,
    this.onAllAssets,
    this.onActivity,
    this.onAllActivity,
    this.onTidyUp,
    this.onOtherAddresses,
    this.onNetwork,
    this.onReceive,
  });

  final WalletPageData data;
  final VoidCallback? onToggleHidden;
  final ValueChanged<WalletAction>? onAction;
  final ValueChanged<WalletTool>? onTool;
  final ValueChanged<String>? onAsset;
  final VoidCallback? onAllAssets;
  final ValueChanged<String>? onActivity;
  final VoidCallback? onAllActivity;
  final VoidCallback? onTidyUp;
  final VoidCallback? onOtherAddresses;
  final VoidCallback? onNetwork;
  final VoidCallback? onReceive;

  /// Holdings and transactions shown before "View all".
  static const assetLimit = 4;
  static const activityLimit = 3;

  Future<void> _more(BuildContext context) async {
    final tool = await showWalletToolsSheet(context, tools: data.tools, walletName: data.wallet.name);
    if (tool != null) onTool?.call(tool);
  }

  @override
  Widget build(BuildContext context) {
    final wallet = data.wallet;
    final hidden = data.hidden;
    final utxos = data.utxoCount;
    final other = wallet.otherAddresses;
    return ListView(
      key: const Key('wallet-list'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
      children: [
        BalanceCard(
          key: const Key('wallet-balance'),
          label: 'Balance',
          tag: wallet.watchOnly
              ? const HomeChip(label: 'Watch-only', icon: Icons.visibility_outlined, tone: HomeChipTone.quiet, dense: true)
              : null,
          nanoErg: wallet.nanoErg,
          fiatValue: wallet.fiatValue,
          currency: data.currency,
          unpricedCount: data.unpricedCount,
          pending: wallet.pending,
          hidden: hidden,
          onToggleHidden: onToggleHidden,
          notes: [
            // The app marks stealth funds with a closed eye, as the
            // address book does for stealth contacts.
            if (wallet.stealthNano > 0)
              BalanceNote(
                icon: Icons.visibility_off_outlined,
                text: 'incl.$nbsp${hidden ? maskedFigure : summaryErg(wallet.stealthNano)}${nbsp}ERG stealth',
              ),
            if (other != null)
              BalanceNote(
                key: const Key('wallet-other-addresses'),
                icon: Icons.account_tree_outlined,
                text: otherAddressLine(other, hidden: hidden),
                onTap: onOtherAddresses,
              ),
          ],
          price: data.price,
          network: data.network,
          onNetwork: onNetwork,
          notice: data.fragmented && utxos != null ? FragmentationNotice(utxoCount: utxos, onTidyUp: onTidyUp) : null,
        ),
        const SizedBox(height: 16),
        WalletActionRow(
          actions: data.actions,
          onAction: (a) => a == WalletAction.more ? _more(context) : onAction?.call(a),
        ),
        const SizedBox(height: 28),
        HomeSectionHeader(
          title: 'Assets',
          // A count says how much is held as surely as an amount does.
          count: data.assetCount > 0 && !hidden ? groupThousands('${data.assetCount}') : null,
          action: data.assetCount > 0 ? 'View all' : null,
          actionKey: const Key('wallet-all-assets'),
          onAction: onAllAssets,
        ),
        const SizedBox(height: 8),
        HomeList(
          indent: 64,
          children: [
            for (final a in data.assets.take(assetLimit))
              HomeAssetRow(
                asset: a,
                currency: data.currency,
                hidden: hidden,
                onTap: onAsset == null ? null : () => onAsset!(a.id),
              ),
          ],
        ),
        const SizedBox(height: 28),
        HomeSectionHeader(
          title: 'Recent activity',
          action: data.activity.isEmpty ? null : 'View all',
          actionKey: const Key('wallet-all-activity'),
          onAction: onAllActivity,
        ),
        const SizedBox(height: 8),
        if (data.activity.isEmpty)
          SoftCard(
            child: EmptyState(
              compact: true,
              icon: Icons.inbox_outlined,
              title: 'No activity yet',
              body: 'Share your address to receive your first ERG.',
              actionLabel: 'Show my address',
              onAction: onReceive ?? () => onAction?.call(WalletAction.receive),
            ),
          )
        else
          HomeList(
            indent: 64,
            children: [
              for (final t in data.activity.take(activityLimit))
                HomeActivityRow(
                  item: t,
                  hidden: hidden,
                  onTap: onActivity == null ? null : () => onActivity!(t.id),
                ),
            ],
          ),
      ],
    );
  }
}
