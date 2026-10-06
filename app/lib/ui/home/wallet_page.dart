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
/// Top to bottom: the balance, one row of actions, any note about where
/// the money sits or how it is stored, the holdings worth a glance and the
/// last three transactions. Everything else has one home elsewhere:
/// protocols in Discover, tools behind More, the full history in Activity,
/// settings in Settings. The back arrow returns to the overview, which is
/// where wallets are switched.
class WalletPageScreen extends StatelessWidget {
  const WalletPageScreen({
    super.key,
    required this.data,
    this.direction = HomeDirection.ruled,
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
  final HomeDirection direction;
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
    final ruled = direction == HomeDirection.ruled;
    final scaffold = Scaffold(
      backgroundColor: ruled ? Colors.transparent : null,
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
          if (ruled) HideBalancesButton(hidden: data.hidden, onPressed: onToggleHidden),
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
        direction: direction,
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
    return ruled ? HomeGlow(child: scaffold) : scaffold;
  }
}

/// The Wallet tab's scrolling body, for hosting under another scaffold.
class WalletPageView extends StatelessWidget {
  const WalletPageView({
    super.key,
    required this.data,
    this.direction = HomeDirection.ruled,
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
  final HomeDirection direction;
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
    final ruled = direction == HomeDirection.ruled;
    final other = wallet.otherAddresses;
    final utxos = data.utxoCount;

    final balance = HomeBalance(
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
      labelEndInset: ruled ? 0 : 40,
    );
    Widget otherRow({EdgeInsetsGeometry? padding}) => HomeLineRow(
          inkKey: const Key('wallet-other-addresses'),
          onTap: onOtherAddresses,
          padding: padding ?? const EdgeInsets.symmetric(horizontal: homeGutter),
          semanticLabel: spoken(otherAddressLine(other!, hidden: hidden)),
          leading: Icon(Icons.subdirectory_arrow_right, size: 18, color: t.muted),
          text: TextSpan(text: otherAddressLine(other, hidden: hidden), style: TextStyle(color: t.ink)),
        );
    // Hidden balances keep the advice but not the count, which says how
    // much the wallet has been used.
    final utxoText = hidden ? 'UTXOs' : '${groupThousands('$utxos')}${nbsp}UTXOs';
    final fragmented = data.fragmented && utxos != null
        ? HomeLineRow(
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
          )
        : null;

    final assets = [
      for (final a in data.assets.take(assetLimit))
        HomeAssetRow(
          asset: a,
          currency: data.currency,
          hidden: hidden,
          onTap: onAsset == null ? null : () => onAsset!(a.id),
        ),
    ];
    final activity = [
      for (final tx in data.activity.take(activityLimit))
        HomeActivityRow(item: tx, hidden: hidden, onTap: onActivity == null ? null : () => onActivity!(tx.id)),
    ];
    List<Widget> list(List<Widget> rows) => [
          if (ruled) const HomeRule(),
          for (var i = 0; i < rows.length; i++) ...[
            if (ruled && i > 0) const HomeRule(indent: homeTextStart),
            rows[i],
          ],
          if (ruled) const HomeRule(),
        ];

    return ListView(
      key: const Key('wallet-list'),
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      children: [
        if (ruled) ...[
          Padding(padding: const EdgeInsets.fromLTRB(homeGutter, 8, homeGutter, 16), child: balance),
          const HomeRule(),
          HomeActionBar(actions: data.actions, onAction: (a) => _act(context, a)),
          const HomeRule(),
          if (other != null) ...[otherRow(), const HomeRule()],
          if (fragmented != null) ...[fragmented, const HomeRule()],
          const SizedBox(height: 12),
        ] else ...[
          RaisedPanel(
            corner: HideBalancesButton(hidden: hidden, onPressed: onToggleHidden),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                balance,
                if (other != null) ...[
                  const SizedBox(height: 4),
                  otherRow(padding: EdgeInsets.zero),
                ] else
                  const SizedBox(height: 12),
                const SizedBox(height: 4),
                HomeActionCircles(actions: data.actions, onAction: (a) => _act(context, a)),
              ],
            ),
          ),
          if (fragmented != null) ...[const SizedBox(height: 4), fragmented],
          const SizedBox(height: 4),
        ],
        HomeSectionHeader(
          title: 'Assets',
          // A count says how much is held as surely as an amount does.
          count: data.assetCount > 0 && !hidden ? groupThousands('${data.assetCount}') : null,
          action: data.assetCount > 0 ? 'View all' : null,
          actionKey: const Key('wallet-all-assets'),
          onAction: onAllAssets,
        ),
        ...list(assets),
        const SizedBox(height: 4),
        HomeSectionHeader(
          title: 'Recent activity',
          action: data.activity.isEmpty ? null : 'View all',
          actionKey: const Key('wallet-all-activity'),
          onAction: onAllActivity,
        ),
        if (data.activity.isEmpty)
          ...list([
            HomeLineRow(
              inkKey: const Key('wallet-no-activity'),
              onTap: onReceive ?? () => onAction?.call(WalletAction.receive),
              semanticLabel: 'No activity yet. Show my address',
              leading: Icon(Icons.inbox_outlined, size: 18, color: t.muted),
              action: 'Show my address',
              text: const TextSpan(text: 'No activity yet'),
            ),
          ])
        else
          ...list(activity),
      ],
    );
  }
}
