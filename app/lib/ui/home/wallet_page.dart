import 'package:flutter/material.dart';

import '../../format.dart';
import '../../theme/argus_theme.dart';
import '../../theme/argus_tones.dart';
import 'home_format.dart';
import 'home_hero.dart';
import 'home_models.dart';
import 'home_rows.dart';
import 'home_style.dart';
import 'home_widgets.dart';
import 'wallet_actions.dart';
import 'wallet_tools_sheet.dart';

/// One open wallet's frame: the way back to every wallet, its name, the
/// tab it is on, and its tabs.
///
/// The back arrow returns to the overview, which is where wallets are
/// switched. A seed wallet's header carries the scanner; a watched one's,
/// its refresh. Lock lives in More, settings in their tab.
class WalletPageScreen extends StatelessWidget {
  const WalletPageScreen({
    super.key,
    required this.title,
    required this.body,
    this.onBack,
    this.actions = const [],
    this.navBar,
  });

  final String title;
  final Widget body;
  final VoidCallback? onBack;
  final List<Widget> actions;
  final Widget? navBar;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const Key('wallet-back'),
          icon: const BackButtonIcon(),
          tooltip: 'All wallets',
          onPressed: onBack,
        ),
        titleSpacing: 0,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [...actions, const SizedBox(width: 8)],
      ),
      body: body,
      bottomNavigationBar: navBar,
    );
  }
}

/// The Wallet tab's scrolling body.
///
/// Top to bottom: the raised panel holding the balance, where it sits and
/// the round actions; a line on how current it is, and on anything that
/// needs a look (fragmented boxes, a mix, a pin that cannot be derived);
/// the holdings worth a glance and the last three transactions, flat on
/// the page. Everything else has one home elsewhere: protocols in
/// Discover, tools behind More, the full history in Activity, settings in
/// Settings.
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
    this.onStatus,
    this.onTidyUp,
    this.onOtherAddresses,
    this.onReceive,
    this.onPinIssue,
    this.onMix,
    this.onDismissMix,
    this.onRetry,
    this.onCopyAddress,
    this.onRefresh,
  });

  final WalletPageData data;
  final VoidCallback? onToggleHidden;

  /// Send, Receive, Swap or Send with offline signer. More opens its sheet
  /// here and reports the pick through [onTool].
  final ValueChanged<WalletAction>? onAction;
  final ValueChanged<WalletTool>? onTool;
  final ValueChanged<String>? onAsset;
  final VoidCallback? onAllAssets;
  final ValueChanged<String>? onActivity;
  final VoidCallback? onAllActivity;

  /// The status line: the UTXO tools.
  final VoidCallback? onStatus;

  /// "N UTXOs · Fragmented": the suggested cleanup.
  final VoidCallback? onTidyUp;
  final VoidCallback? onOtherAddresses;

  /// The empty-activity line's link; defaults to the Receive action.
  final VoidCallback? onReceive;
  final VoidCallback? onPinIssue;
  final VoidCallback? onMix;
  final VoidCallback? onDismissMix;

  /// No node answers: look again.
  final VoidCallback? onRetry;

  /// A watched wallet's address, copied.
  final VoidCallback? onCopyAddress;

  /// Pull to refresh.
  final Future<void> Function()? onRefresh;

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
    final list = ListView(
      key: const Key('wallet-list'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      children: [
        _panel(context),
        const SizedBox(height: 4),
        ..._statusLines(context),
        ..._notes(context),
        const SizedBox(height: 4),
        ..._assets(context),
        const SizedBox(height: 4),
        ..._activity(context),
        ..._address(context),
      ],
    );
    final refresh = onRefresh;
    return refresh == null ? list : RefreshIndicator(onRefresh: refresh, child: list);
  }

  Widget _panel(BuildContext context) {
    final wallet = data.wallet;
    final hidden = data.hidden;
    final other = wallet.otherAddresses;
    final address = wallet.address;
    return RaisedPanel(
      corner: HideBalancesButton(hidden: hidden, onPressed: onToggleHidden),
      // Colours are read under the panel, which has its own. Sheets still
      // open from the page's context, so they keep the page's theme.
      child: Builder(
        builder: (hero) {
          final t = HomeText.of(hero);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              HomeBalance(
                label: 'Balance',
                labelExtra: switch (wallet.kind) {
                  WalletKind.seed => null,
                  WalletKind.watchedAddress => 'Watched address',
                  WalletKind.watchedAccount => 'Watched account',
                },
                figureKey: const Key('wallet-balance'),
                pendingKey: const Key('wallet-balance-pending'),
                nanoErg: wallet.nanoErg,
                loading: wallet.loading,
                currency: data.currency,
                fiatValue: wallet.fiatValue,
                unpricedCount: data.unpricedCount,
                pricesNote: data.pricesNote,
                pending: wallet.pending,
                pockets: wallet.pockets,
                pocketsAsOf: wallet.pocketsAsOf,
                hidden: hidden,
              ),
              // The address the wallet is shown as, which is not always
              // where all of its money sits.
              if (address != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: HomeIdentityLine(address: address, pinnedIndex: wallet.pinnedIndex),
                ),
              if (other != null) ...[
                const SizedBox(height: 2),
                HomeLineRow(
                  inkKey: const Key('funds-elsewhere'),
                  onTap: onOtherAddresses,
                  hint: 'Shows each address and what it holds',
                  padding: EdgeInsets.zero,
                  semanticLabel: spoken(otherAddressLine(other, hidden: hidden)),
                  leading: Icon(Icons.subdirectory_arrow_right, size: 18, color: t.muted),
                  text: TextSpan(text: otherAddressLine(other, hidden: hidden), style: TextStyle(color: t.ink)),
                ),
              ] else
                const SizedBox(height: 12),
              const SizedBox(height: 4),
              HomeActionCircles(
                actions: data.actions,
                disabled: data.disabled,
                watched: wallet.watchOnly,
                onAction: (a) => _act(context, a),
              ),
            ],
          );
        },
      ),
    );
  }

  /// How current the figures are, and anything about the wallet that needs
  /// a look, one line each.
  List<Widget> _statusLines(BuildContext context) {
    final t = HomeText.of(context);
    final hidden = data.hidden;
    final utxos = data.utxoCount;
    // Hidden balances keep the advice but not the count, which says how
    // much the wallet has been used.
    final utxoText = utxos == null || hidden ? 'UTXOs' : '${groupThousands('$utxos')}${nbsp}UTXOs';
    final lines = <Widget>[];
    // Each part of a status line wraps as a whole: "Updated just" over
    // "now" reads as two statements.
    String whole(String part) => part.replaceAll(' ', nbsp);
    if (data.status case final status?) {
      final (word, dot, problem) = syncLook(context, status);
      final parts = [
        if (status.blockHeight != null) 'Block$nbsp${formatWithCommas(status.blockHeight!)}',
        // While fragmented the count leads its own line below.
        if (utxos != null && !hidden && !data.fragmented) utxoText,
        if (status.age != null) whole(status.age!),
      ];
      lines.add(HomeLineRow(
        inkKey: const Key('wallet-status'),
        onTap: onStatus,
        hint: onStatus == null ? null : 'UTXO tools',
        semanticLabel: spoken([word, ...parts].join(', ')),
        leading: Container(width: 7, height: 7, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
        text: TextSpan(
          children: [
            TextSpan(text: word, style: TextStyle(color: problem ? rustFor(context) : t.ink, fontWeight: FontWeight.w500)),
            for (final p in parts) TextSpan(text: '   ·   $p'),
          ],
        ),
      ));
    }
    if (data.watched case final watched?) {
      lines.add(HomeLineRow(
        inkKey: const Key('watched-status'),
        semanticLabel: watched.status.join(', '),
        leading: Icon(Icons.visibility_outlined, size: 16, color: t.muted),
        text: TextSpan(
          children: [
            for (final (i, s) in watched.status.indexed)
              TextSpan(
                text: i == 0 ? s : '   ·   ${whole(s)}',
                style: i == 0 ? TextStyle(color: t.ink, fontWeight: FontWeight.w500) : null,
              ),
          ],
        ),
      ));
      if (watched.error case final error?) {
        lines.add(HomeLineRow(
          semanticLabel: error,
          leading: Icon(Icons.cloud_off_outlined, size: 16, color: rustFor(context)),
          text: TextSpan(text: error, style: TextStyle(color: rustFor(context))),
        ));
      }
    }
    if (data.offline) {
      lines.add(HomeLineRow(
        inkKey: const Key('wallet-offline'),
        onTap: onRetry,
        action: onRetry == null ? null : 'Retry',
        semanticLabel: 'No reachable nodes${onRetry == null ? '' : '. Retry'}',
        leading: Icon(Icons.wifi_off_outlined, size: 16, color: rustFor(context)),
        text: TextSpan(text: 'No reachable nodes', style: TextStyle(color: rustFor(context))),
      ));
    }
    if (data.fragmented && utxos != null) {
      lines.add(HomeLineRow(
        inkKey: const Key('utxo-fragmented'),
        onTap: onTidyUp,
        semanticLabel: '${spoken(utxoText)}, fragmented. Tidy up',
        leading: Icon(Icons.grain, size: 18, color: rustFor(context)),
        action: 'Tidy up',
        text: TextSpan(
          children: [
            TextSpan(text: utxoText, style: TextStyle(color: t.ink)),
            TextSpan(text: ' · Fragmented', style: TextStyle(color: rustFor(context), fontWeight: FontWeight.w500)),
          ],
        ),
      ));
    }
    if (data.pinIssue case final issue?) {
      lines.add(HomeLineRow(
        inkKey: const Key('wallet-pin-issue'),
        onTap: onPinIssue,
        semanticLabel: issue,
        leading: Icon(Icons.push_pin_outlined, size: 16, color: rustFor(context)),
        text: TextSpan(text: issue, style: TextStyle(color: rustFor(context))),
      ));
    }
    if (data.mix case final mix?) {
      lines.add(HomeLineRow(
        inkKey: const Key('mix-strip'),
        onTap: onMix,
        semanticLabel: mix.text,
        leading: Icon(Icons.blender_outlined, size: 16, color: mix.finished ? mossFor(context) : t.ink),
        text: TextSpan(text: mix.text, style: TextStyle(color: t.ink)),
        // A finished mix is announced until it is dismissed.
        trailing: mix.finished && onDismissMix != null
            ? Padding(
                padding: const EdgeInsetsDirectional.only(end: homeGutter - 12),
                child: IconButton(
                  key: const Key('mix-strip-dismiss'),
                  tooltip: 'Dismiss',
                  onPressed: onDismissMix,
                  icon: Icon(Icons.close, size: 18, color: t.muted),
                ),
              )
            : null,
      ));
    }
    return lines;
  }

  /// What a watched wallet can and cannot do, said plainly.
  List<Widget> _notes(BuildContext context) {
    final notes = data.watched?.notes ?? const [];
    if (notes.isEmpty) return const [];
    final t = HomeText.of(context);
    return [
      Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(homeGutter, 8, homeGutter, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: homeMarkSize,
              child: Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(Icons.info_outline, size: 16, color: t.muted),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (i, note) in notes.indexed)
                    Padding(
                      padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
                      child: Text(note, style: t.secondary.copyWith(height: 1.4)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _assets(BuildContext context) {
    final hidden = data.hidden;
    return [
      HomeSectionHeader(
        title: 'Assets',
        // A count says how much is held as surely as an amount does.
        count: data.assetCount > 0 && !hidden ? groupThousands('${data.assetCount}') : null,
        action: data.assetCount > 0 && onAllAssets != null ? 'View all' : null,
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
    ];
  }

  List<Widget> _activity(BuildContext context) {
    final t = HomeText.of(context);
    final receive = onReceive ?? (onAction == null ? null : () => onAction!(WalletAction.receive));
    final emptyAction = receive == null ? null : data.activityEmptyAction;
    return [
      HomeSectionHeader(
        title: 'Recent activity',
        action: data.activity.isEmpty || onAllActivity == null ? null : 'View all',
        actionKey: const Key('wallet-all-activity'),
        onAction: onAllActivity,
      ),
      if (data.activity.isNotEmpty)
        for (final tx in data.activity.take(activityLimit))
          HomeActivityRow(item: tx, hidden: data.hidden, onTap: onActivity == null ? null : () => onActivity!(tx.id))
      else if (data.activityLoading)
        HomeLineRow(
          inkKey: const Key('wallet-activity-loading'),
          semanticLabel: 'Reading activity',
          leading: const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          text: const TextSpan(text: 'Reading activity…'),
        )
      else if (data.activityError case final error?)
        HomeLineRow(
          inkKey: const Key('wallet-activity-error'),
          semanticLabel: error,
          leading: Icon(Icons.cloud_off_outlined, size: 18, color: rustFor(context)),
          text: TextSpan(text: error, style: TextStyle(color: rustFor(context))),
        )
      else
        HomeLineRow(
          inkKey: const Key('wallet-no-activity'),
          onTap: emptyAction == null ? null : receive,
          semanticLabel: [data.activityEmpty, ?emptyAction].join('. '),
          leading: Icon(Icons.inbox_outlined, size: 18, color: t.muted),
          action: emptyAction,
          text: TextSpan(text: data.activityEmpty),
        ),
    ];
  }

  /// A watched wallet's address in full, to check against the wallet the
  /// key came from and to copy.
  List<Widget> _address(BuildContext context) {
    final watched = data.watched;
    final address = data.wallet.address;
    if (watched == null || address == null) return const [];
    final t = HomeText.of(context);
    return [
      const SizedBox(height: 4),
      HomeSectionHeader(
        title: watched.addressTitle,
        action: onCopyAddress == null ? null : 'Copy',
        actionKey: const Key('watched-copy-address'),
        onAction: onCopyAddress,
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: homeGutter),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(address, style: monoStyle(context, size: 12.5).copyWith(color: t.ink)),
            if (watched.addressNote case final note?) ...[
              const SizedBox(height: 8),
              Text(note, style: t.secondary.copyWith(height: 1.4)),
            ],
          ],
        ),
      ),
    ];
  }
}
