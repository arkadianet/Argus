import 'package:flutter/material.dart';

import '../../format.dart';
import '../../theme/argus_theme.dart';
import '../../theme/argus_tones.dart';
import 'home_format.dart';
import 'home_glass.dart';
import 'home_hero.dart';
import 'home_models.dart';
import 'home_rows.dart';
import 'home_scene.dart';
import 'home_style.dart';
import 'home_widgets.dart';
import 'wallet_actions.dart';
import 'wallet_tools_sheet.dart';

/// One open wallet's frame: the way back to every wallet, its name and
/// state, the tab it is on, and its tabs.
///
/// The back chevron returns to the overview, which is where wallets are
/// switched. A seed wallet's header carries the scanner; a watched one's,
/// its refresh. On the Wallet tab the header is [immersive]: it lies over
/// the scene the page opens on, clear until the page scrolls under it.
class WalletPageScreen extends StatelessWidget {
  const WalletPageScreen({
    super.key,
    required this.title,
    required this.body,
    this.onBack,
    this.actions = const [],
    this.navBar,
    this.subtitle,
    this.subtitleLive = false,
    this.immersive = true,
  });

  final String title;
  final Widget body;
  final VoidCallback? onBack;
  final List<Widget> actions;
  final Widget? navBar;

  /// Under the title: the wallet's state, e.g. "Unlocked", with a green dot
  /// when [subtitleLive].
  final String? subtitle;
  final bool subtitleLive;

  /// The page lies on the scene, its header clear until the page scrolls
  /// under it. Off for the tabs that are lists of their own.
  final bool immersive;

  /// The wallet's medallion, where every immersive page sets it: beside the
  /// balance, the first thing under the header.
  static const medallionSize = 112.0;
  static const medallionInset = homeGutter - 14;

  @override
  Widget build(BuildContext context) {
    final page = Theme.of(context).scaffoldBackgroundColor;
    final t = HomeText.of(context);
    final live = mossFor(context);
    final toolbar = subtitle == null ? kToolbarHeight : 66.0;
    final scaffold = Scaffold(
      backgroundColor: immersive ? Colors.transparent : null,
      appBar: AppBar(
        backgroundColor: immersive
            ? WidgetStateColor.resolveWith(
                (states) => states.contains(WidgetState.scrolledUnder) ? page.withValues(alpha: 0.94) : page.withValues(alpha: 0),
              )
            : null,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        toolbarHeight: toolbar,
        leading: IconButton(
          key: const Key('wallet-back'),
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 22),
          tooltip: 'All wallets',
          onPressed: onBack,
        ),
        titleSpacing: 0,
        title: subtitle == null
            ? Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (subtitleLive) ...[
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: live,
                            shape: BoxShape.circle,
                            boxShadow: [BoxShadow(color: live.withValues(alpha: 0.5), blurRadius: 6)],
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        subtitle!,
                        style: t.secondary.copyWith(fontFamily: 'Karla', fontSize: 14, color: subtitleLive ? live : t.muted),
                      ),
                    ],
                  ),
                ],
              ),
        actions: [...actions, const SizedBox(width: 4)],
      ),
      body: body,
      bottomNavigationBar: navBar,
    );
    if (!immersive) return scaffold;
    final media = MediaQuery.of(context);
    final top = media.padding.top + toolbar;
    return ColoredBox(
      color: page,
      child: HomeScene(
        light: SceneLight.medallion,
        lightAt: Offset(medallionInset + medallionSize / 2, top + medallionSize / 2 - 4),
        height: top + 560,
        child: scaffold,
      ),
    );
  }
}

/// The tabs under a wallet's actions.
enum WalletPageTab { assets, activity, addresses, utxos }

/// The Wallet tab's scrolling body.
///
/// Top to bottom: the scene, with the balance set straight onto it beside
/// the wallet's medallion, the address it is shown as and what sits on its
/// other addresses on pills of glass, and the round actions; a line on how
/// current it is, and on anything that needs a look (fragmented boxes, a
/// mix, a pin that cannot be derived); then tabs. Assets shows the holdings
/// worth a glance and the last three transactions; Activity, Addresses and
/// UTXOs each lead on to their tool. Protocols live in Discover, settings
/// in Settings.
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
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        // The page settles in from the top: the scene, its lines, then the
        // tabs.
        HomeEntrance(child: _top(context)),
        HomeEntrance(
          order: 1,
          child: Column(
            children: [
              const HomeRule(),
              ..._statusLines(context),
              ..._notes(context),
            ],
          ),
        ),
        const SizedBox(height: 4),
        HomeEntrance(
          order: 2,
          child: _WalletTabs(
            tabs: [
              WalletPageTab.assets,
              WalletPageTab.activity,
              WalletPageTab.addresses,
              if (!data.wallet.watchOnly) WalletPageTab.utxos,
            ],
            content: (tab) => switch (tab) {
              WalletPageTab.assets => [..._assets(context), const SizedBox(height: 16), ..._activity(context)],
              WalletPageTab.activity => _activity(context, all: true),
              WalletPageTab.addresses => _addresses(context),
              WalletPageTab.utxos => _utxos(context),
            },
          ),
        ),
      ],
    );
    final refresh = onRefresh;
    return refresh == null ? list : RefreshIndicator(onRefresh: refresh, child: list);
  }

  /// The balance beside the medallion, the address pills and the actions,
  /// on the scene the page's frame paints.
  Widget _top(BuildContext context) {
    final wallet = data.wallet;
    final hidden = data.hidden;
    final other = wallet.otherAddresses;
    final address = wallet.address;
    final t = HomeText.of(context);
    final name = wallet.name.trim();
    const medallion = WalletPageScreen.medallionSize;
    final seed = wallet.kind == WalletKind.seed;
    return Padding(
      padding: EdgeInsets.fromLTRB(homeGutter, seed ? 18 : 4, homeGutter, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Stack(
            clipBehavior: Clip.none,
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
                onToggleHidden: onToggleHidden,
                onUnpriced: onAllAssets,
                figureReserve: medallion - 18,
                showLabel: wallet.kind != WalletKind.seed,
                unpricedPill: false,
              ),
              PositionedDirectional(
                top: seed ? -18 : 26,
                end: -(homeGutter - WalletPageScreen.medallionInset),
                child: WalletMedallion(
                  letter: name.isEmpty ? '?' : String.fromCharCode(name.runes.first).toUpperCase(),
                  size: medallion,
                ),
              ),
            ],
          ),
          // The address the wallet is shown as, which is not always where
          // all of its money sits.
          if (address != null) ...[
            const SizedBox(height: 18),
            IdentityPill(address: address, pinnedIndex: wallet.pinnedIndex, onCopy: onCopyAddress),
          ],
          if (other != null) ...[
            const SizedBox(height: 10),
            GlassPill(
              inkKey: const Key('funds-elsewhere'),
              onTap: onOtherAddresses,
              hint: 'Shows each address and what it holds',
              semanticLabel: spoken(otherAddressLine(other, hidden: hidden)),
              leading: Icon(Icons.subdirectory_arrow_right, size: 20, color: t.muted),
              child: Text(otherAddressLine(other, hidden: hidden), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
          const SizedBox(height: 20),
          HomeActionCircles(
            actions: data.actions,
            disabled: data.disabled,
            watched: wallet.watchOnly,
            onAction: (a) => _act(context, a),
          ),
        ],
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
        markWidth: 14,
        chevron: false,
        leading: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: dot,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: dot.withValues(alpha: 0.5), blurRadius: 6)],
          ),
        ),
        text: TextSpan(
          children: [
            TextSpan(text: word, style: TextStyle(color: problem ? rustFor(context) : t.ink, fontWeight: FontWeight.w500)),
            for (final p in parts) TextSpan(text: '  ·  $p'),
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
                text: i == 0 ? s : '  ·  ${whole(s)}',
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
    final shown = data.assets.take(assetLimit).toList();
    return [
      const SizedBox(height: 14),
      if (shown.isNotEmpty)
        GlassCard(
          key: const Key('wallet-assets'),
          dividers: true,
          children: [
            for (final a in shown)
              HomeAssetRow(
                asset: a,
                currency: data.currency,
                hidden: hidden,
                onTap: onAsset == null ? null : () => onAsset!(a.id),
              ),
          ],
        ),
      // A count says how much is held as surely as an amount does.
      if (data.assetCount > shown.length && onAllAssets != null)
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(end: homeGutter - 6),
            child: HomeLink(
              text: hidden ? 'All assets' : 'All ${groupThousands('${data.assetCount}')} assets',
              onPressed: onAllAssets,
              linkKey: const Key('wallet-all-assets'),
              quiet: true,
            ),
          ),
        ),
    ];
  }

  /// The latest transactions, or with [all] every one the page has, each
  /// row titled and figured as the activity model says.
  List<Widget> _activity(BuildContext context, {bool all = false}) {
    final t = HomeText.of(context);
    final receive = onReceive ?? (onAction == null ? null : () => onAction!(WalletAction.receive));
    final emptyAction = receive == null ? null : data.activityEmptyAction;
    final shown = all ? data.activity : data.activity.take(activityLimit).toList();
    return [
      if (all)
        const SizedBox(height: 14)
      else
        HomeHeading(
          title: 'Recent Activity',
          action: data.activity.isEmpty || onAllActivity == null ? null : 'View all',
          actionKey: const Key('wallet-all-activity'),
          onAction: onAllActivity,
        ),
      GlassCard(
        key: const Key('wallet-activity'),
        dividers: true,
        children: [
          if (shown.isNotEmpty)
            for (final tx in shown)
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
        ],
      ),
      if (all && data.activity.isNotEmpty && onAllActivity != null)
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(end: homeGutter - 6),
            child: HomeLink(text: 'Full history', onPressed: onAllActivity, quiet: true),
          ),
        ),
    ];
  }

  /// Where the wallet's funds sit: the address it is shown as, its other
  /// addresses and the way to every one; a watched wallet's address in
  /// full, to check against the wallet the key came from and to copy.
  List<Widget> _addresses(BuildContext context) {
    final t = HomeText.of(context);
    final wallet = data.wallet;
    final address = wallet.address;
    final other = wallet.otherAddresses;
    final watched = data.watched;
    return [
      const SizedBox(height: 14),
      GlassCard(
        dividers: true,
        dividerIndent: glassGutter,
        children: [
          if (watched != null && address != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(glassGutter, 4, glassGutter - 6, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(watched.addressTitle, style: t.title)),
                      if (onCopyAddress != null)
                        HomeLink(text: 'Copy', onPressed: onCopyAddress, linkKey: const Key('watched-copy-address')),
                    ],
                  ),
                  SelectableText(address, style: monoStyle(context, size: 12.5).copyWith(color: t.ink)),
                  if (watched.addressNote case final note?) ...[
                    const SizedBox(height: 8),
                    Text(note, style: t.secondary.copyWith(height: 1.4)),
                  ],
                ],
              ),
            )
          else if (address != null)
            HomeLineRow(
              semanticLabel: spoken('${wallet.pinnedIndex != null ? 'Pinned address #${wallet.pinnedIndex}, ' : ''}'
                  '${shorten(address, head: 8, tail: 6)}'),
              leading: Icon(Icons.person_outline, size: 18, color: HomeTones.of(context).accent),
              text: TextSpan(
                children: [
                  if (wallet.pinnedIndex != null) TextSpan(text: '#${wallet.pinnedIndex}   ', style: TextStyle(color: t.ink)),
                  TextSpan(text: shorten(address, head: 10, tail: 8)),
                ],
              ),
            ),
          if (other != null)
            HomeLineRow(
              onTap: onOtherAddresses,
              semanticLabel: spoken(otherAddressLine(other, hidden: data.hidden)),
              leading: Icon(Icons.subdirectory_arrow_right, size: 18, color: t.muted),
              text: TextSpan(text: otherAddressLine(other, hidden: data.hidden)),
            ),
          if (!wallet.watchOnly && onTool != null)
            HomeLineRow(
              inkKey: const Key('wallet-every-address'),
              onTap: () => onTool!(WalletTool.addresses),
              semanticLabel: 'Every address and what it holds',
              leading: Icon(Icons.account_tree_outlined, size: 18, color: t.muted),
              text: TextSpan(text: 'Every address and what it holds', style: TextStyle(color: t.ink)),
            ),
          // Nothing known yet (a watched account before its first scan): the
          // tab says so rather than showing an empty pane.
          if (address == null && other == null && (wallet.watchOnly || onTool == null))
            HomeLineRow(
              inkKey: const Key('wallet-no-addresses'),
              semanticLabel: 'No addresses read yet',
              leading: Icon(Icons.account_tree_outlined, size: 18, color: t.muted),
              text: TextSpan(
                text: wallet.watchOnly ? 'No addresses read yet. They appear after the first scan.' : 'No addresses read yet.',
              ),
            ),
        ],
      ),
    ];
  }

  /// The wallet's boxes: how many, whether they are fragmented, and the
  /// way to the UTXO tools.
  List<Widget> _utxos(BuildContext context) {
    final t = HomeText.of(context);
    final utxos = data.utxoCount;
    final count = utxos == null || data.hidden ? 'UTXOs' : '${groupThousands('$utxos')}${nbsp}UTXOs';
    return [
      const SizedBox(height: 14),
      GlassCard(
        dividers: true,
        dividerIndent: glassGutter,
        children: [
          HomeLineRow(
            semanticLabel: spoken('$count${data.fragmented ? ', fragmented' : ''}'),
            leading: Icon(Icons.grain, size: 18, color: data.fragmented ? rustFor(context) : t.muted),
            text: TextSpan(
              children: [
                TextSpan(text: count, style: TextStyle(color: t.ink)),
                if (data.fragmented)
                  TextSpan(text: ' · Fragmented', style: TextStyle(color: rustFor(context))),
              ],
            ),
            action: data.fragmented && onTidyUp != null ? 'Tidy up' : null,
            onTap: data.fragmented ? onTidyUp : null,
          ),
          HomeLineRow(
            inkKey: const Key('wallet-utxo-tools'),
            onTap: onTool == null ? onStatus : () => onTool!(WalletTool.utxos),
            semanticLabel: 'UTXO tools',
            leading: Icon(Icons.tune, size: 18, color: t.muted),
            text: TextSpan(text: 'UTXO tools', style: TextStyle(color: t.ink)),
          ),
        ],
      ),
    ];
  }
}

/// The wallet page's tabs: names in a row, the current one in ink over a
/// line of the accent, the rest quiet, with what the current tab holds
/// beneath.
class _WalletTabs extends StatefulWidget {
  const _WalletTabs({required this.tabs, required this.content});

  final List<WalletPageTab> tabs;
  final List<Widget> Function(WalletPageTab tab) content;

  @override
  State<_WalletTabs> createState() => _WalletTabsState();
}

class _WalletTabsState extends State<_WalletTabs> {
  WalletPageTab _tab = WalletPageTab.assets;

  static String _name(WalletPageTab tab) => switch (tab) {
        WalletPageTab.assets => 'Assets',
        WalletPageTab.activity => 'Activity',
        WalletPageTab.addresses => 'Addresses',
        WalletPageTab.utxos => 'UTXOs',
      };

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    final accent = ArgusColors.of(context).accent;
    final tab = widget.tabs.contains(_tab) ? _tab : widget.tabs.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter - 8),
          child: Row(
            children: [
              for (final each in widget.tabs)
                Expanded(
                  child: Semantics(
                    selected: each == tab,
                    child: InkWell(
                      key: Key('wallet-page-tab-${each.name}'),
                      onTap: () => setState(() => _tab = each),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 50),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Text(
                                _name(each),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: t.primary.copyWith(fontSize: 14.5, color: each == tab ? t.ink : t.muted),
                              ),
                            ),
                            Container(
                              height: 2,
                              margin: const EdgeInsets.symmetric(horizontal: 6),
                              decoration: BoxDecoration(
                                color: each == tab ? accent : Colors.transparent,
                                borderRadius: BorderRadius.circular(1),
                                boxShadow: [
                                  if (each == tab) BoxShadow(color: accent.withValues(alpha: 0.5), blurRadius: 6),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const HomeRule(indent: homeGutter - 8, endIndent: homeGutter - 8),
        ...widget.content(tab),
      ],
    );
  }
}
