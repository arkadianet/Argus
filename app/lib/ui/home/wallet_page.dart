import 'package:flutter/material.dart';

import '../../theme/argus_theme.dart';
import 'home_format.dart';
import 'home_hero.dart';
import 'home_models.dart';
import 'home_rows.dart';
import 'home_style.dart';
import 'home_widgets.dart';
import 'wallet_actions.dart';
import 'wallet_nav_bar.dart';
import 'wallet_tools_sheet.dart';

/// One open wallet, and nothing from any other.
///
/// Top to bottom: the raised panel holding the balance, where it sits and
/// the round actions; a line about how the money is stored when it needs
/// tidying; the holdings worth a glance and the last three transactions,
/// flat on the page. Everything else has one home elsewhere: protocols in
/// Discover, tools behind More, the full history in Activity, settings in
/// Settings. The back arrow returns to the overview, which is where
/// wallets are switched.
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

  /// The empty-activity line's link; defaults to the Receive action.
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
          const SizedBox(width: 8),
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
  final VoidCallback? onReceive;

  /// Holdings and transactions shown before "View all".
  static const assetLimit = 6;
  static const activityLimit = 3;

  Future<void> _more(BuildContext context) async {
    final tool = await showWalletToolsSheet(context, tools: data.tools, walletName: data.wallet.name);
    if (tool != null) onTool?.call(tool);
  }

  void _act(BuildContext context, WalletAction a) => a == WalletAction.more ? _more(context) : onAction?.call(a);

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    final wallet = data.wallet;
    final hidden = data.hidden;
    final other = wallet.otherAddresses;
    final utxos = data.utxoCount;
    // Hidden balances keep the advice but not the count, which says how
    // much the wallet has been used.
    final utxoText = hidden ? 'UTXOs' : '${groupThousands('$utxos')}${nbsp}UTXOs';

    return ListView(
      key: const Key('wallet-list'),
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      children: [
        RaisedPanel(
          corner: HideBalancesButton(hidden: hidden, onPressed: onToggleHidden),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              HomeBalance(
                label: 'Balance',
                labelExtra: wallet.watchOnly ? 'Watch-only' : null,
                status: data.network,
                nanoErg: wallet.nanoErg,
                currency: data.currency,
                fiatValue: wallet.fiatValue,
                unpricedCount: data.unpricedCount,
                pending: wallet.pending,
                stealthNano: wallet.stealthNano,
                hidden: hidden,
              ),
              if (other != null) ...[
                const SizedBox(height: 4),
                HomeLineRow(
                  inkKey: const Key('wallet-other-addresses'),
                  onTap: onOtherAddresses,
                  padding: EdgeInsets.zero,
                  semanticLabel: spoken(otherAddressLine(other, hidden: hidden)),
                  leading: Icon(Icons.subdirectory_arrow_right, size: 18, color: t.muted),
                  text: TextSpan(text: otherAddressLine(other, hidden: hidden), style: TextStyle(color: t.ink)),
                ),
              ] else
                const SizedBox(height: 12),
              const SizedBox(height: 4),
              HomeActionCircles(actions: data.actions, onAction: (a) => _act(context, a)),
            ],
          ),
        ),
        if (data.fragmented && utxos != null) ...[
          const SizedBox(height: 4),
          HomeLineRow(
            inkKey: const Key('home-tidy-up'),
            onTap: onTidyUp,
            semanticLabel: '${spoken(utxoText)}, fragmented. Tidy up',
            leading: Icon(Icons.grain, size: 18, color: rustFor(context)),
            action: 'Tidy up',
            text: TextSpan(
              children: [
                TextSpan(text: utxoText, style: TextStyle(color: t.ink)),
                TextSpan(text: '   ·   Fragmented', style: TextStyle(color: rustFor(context), fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ],
        const SizedBox(height: 4),
        HomeSectionHeader(
          title: 'Assets',
          // A count says how much is held as surely as an amount does.
          count: data.assetCount > 0 && !hidden ? groupThousands('${data.assetCount}') : null,
          action: data.assetCount > 0 ? 'View all' : null,
          actionKey: const Key('wallet-all-assets'),
          onAction: onAllAssets,
        ),
        for (final a in data.assets.take(assetLimit))
          HomeAssetRow(
            asset: a,
            currency: data.currency,
            hidden: hidden,
            onTap: onAsset == null ? null : () => onAsset!(a.id),
          ),
        const SizedBox(height: 4),
        HomeSectionHeader(
          title: 'Recent activity',
          action: data.activity.isEmpty ? null : 'View all',
          actionKey: const Key('wallet-all-activity'),
          onAction: onAllActivity,
        ),
        if (data.activity.isEmpty)
          HomeLineRow(
            inkKey: const Key('wallet-no-activity'),
            onTap: onReceive ?? () => onAction?.call(WalletAction.receive),
            semanticLabel: 'No activity yet. Show my address',
            leading: Icon(Icons.inbox_outlined, size: 18, color: t.muted),
            action: 'Show my address',
            text: const TextSpan(text: 'No activity yet'),
          )
        else
          for (final tx in data.activity.take(activityLimit))
            HomeActivityRow(item: tx, hidden: hidden, onTap: onActivity == null ? null : () => onActivity!(tx.id)),
      ],
    );
  }
}
