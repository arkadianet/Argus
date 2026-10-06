import 'package:flutter/material.dart';

import '../../theme/argus_theme.dart';
import 'home_hero.dart';
import 'home_models.dart';
import 'home_rows.dart';
import 'home_style.dart';
import 'home_widgets.dart';
import 'wallet_tools_sheet.dart';

/// The launch screen: every wallet on this phone, seed and watched alike,
/// under the total across them.
///
/// It is the level above an open wallet, so it has no tab bar: its header
/// carries the app's settings (there is no other way to reach them before
/// a wallet is open, and a careful user sets their own node before the
/// first restore). Opening a wallet is the only step that asks for a PIN
/// or fingerprint.
class OverviewScreen extends StatelessWidget {
  const OverviewScreen({
    super.key,
    required this.data,
    this.direction = HomeDirection.ruled,
    this.onOpenWallet,
    this.onWalletOptions,
    this.onCreate,
    this.onRestore,
    this.onWatch,
    this.onSettings,
    this.onToggleHidden,
    this.onNetwork,
    this.onLearnMore,
  });

  final OverviewData data;
  final HomeDirection direction;
  final ValueChanged<String>? onOpenWallet;

  /// Long press: rename or remove without opening the wallet.
  final ValueChanged<String>? onWalletOptions;
  final VoidCallback? onCreate;
  final VoidCallback? onRestore;
  final VoidCallback? onWatch;
  final VoidCallback? onSettings;
  final VoidCallback? onToggleHidden;
  final VoidCallback? onNetwork;
  final VoidCallback? onLearnMore;

  @override
  Widget build(BuildContext context) {
    final ruled = direction == HomeDirection.ruled;
    final scaffold = Scaffold(
      backgroundColor: ruled ? Colors.transparent : null,
      appBar: AppBar(
        titleSpacing: homeGutter,
        title: Semantics(
          header: true,
          label: 'Argus',
          excludeSemantics: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const IrisMark(size: 28),
              const SizedBox(width: 6),
              Text('Argus', style: Theme.of(context).textTheme.titleLarge),
            ],
          ),
        ),
        actions: [
          // Ruled keeps the eye in the bar; raised pins it to its panel.
          if (ruled && data.wallets.isNotEmpty) HideBalancesButton(hidden: data.hidden, onPressed: onToggleHidden),
          IconButton(
            key: const Key('overview-settings'),
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: onSettings,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: OverviewView(
        data: data,
        direction: direction,
        onOpenWallet: onOpenWallet,
        onWalletOptions: onWalletOptions,
        onCreate: onCreate,
        onRestore: onRestore,
        onWatch: onWatch,
        onToggleHidden: onToggleHidden,
        onNetwork: onNetwork,
        onLearnMore: onLearnMore,
      ),
    );
    return ruled ? HomeGlow(child: scaffold) : scaffold;
  }
}

/// The overview's scrolling body, for hosting under another app bar.
class OverviewView extends StatelessWidget {
  const OverviewView({
    super.key,
    required this.data,
    this.direction = HomeDirection.ruled,
    this.onOpenWallet,
    this.onWalletOptions,
    this.onCreate,
    this.onRestore,
    this.onWatch,
    this.onToggleHidden,
    this.onNetwork,
    this.onLearnMore,
  });

  final OverviewData data;
  final HomeDirection direction;
  final ValueChanged<String>? onOpenWallet;
  final ValueChanged<String>? onWalletOptions;
  final VoidCallback? onCreate;
  final VoidCallback? onRestore;
  final VoidCallback? onWatch;
  final VoidCallback? onToggleHidden;
  final VoidCallback? onNetwork;
  final VoidCallback? onLearnMore;

  Future<void> _add(BuildContext context) async {
    final choice = await showAddWalletSheet(context);
    switch (choice) {
      case AddWalletChoice.create:
        onCreate?.call();
      case AddWalletChoice.restore:
        onRestore?.call();
      case AddWalletChoice.watch:
        onWatch?.call();
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    if (data.wallets.isEmpty) {
      return _Welcome(onCreate: onCreate, onRestore: onRestore, onWatch: onWatch, onLearnMore: onLearnMore);
    }
    final ruled = direction == HomeDirection.ruled;
    final balance = HomeBalance(
      label: 'Total balance',
      nanoErg: data.totalNano,
      currency: data.currency,
      fiatValue: data.totalFiat,
      unpricedCount: data.unpricedCount,
      pending: data.pending,
      hidden: data.hidden,
      labelEndInset: ruled ? 0 : 40,
    );
    final price = data.price == null ? null : ErgPriceStrip(price: data.price!, currency: data.currency);
    final wallets = [
      for (final w in data.wallets)
        OverviewWalletRow(
          wallet: w,
          currency: data.currency,
          hidden: data.hidden,
          onTap: onOpenWallet == null ? null : () => onOpenWallet!(w.id),
          onLongPress: onWalletOptions == null ? null : () => onWalletOptions!(w.id),
        ),
      AddWalletRow(onTap: () => _add(context)),
    ];
    return ListView(
      key: const Key('overview-list'),
      padding: EdgeInsets.only(top: 4, bottom: 24 + bottom),
      children: [
        if (ruled) ...[
          Padding(padding: const EdgeInsets.fromLTRB(homeGutter, 8, homeGutter, 16), child: balance),
          if (price != null) ...[
            const HomeRule(),
            Padding(padding: const EdgeInsets.symmetric(horizontal: homeGutter, vertical: 12), child: price),
          ],
          const HomeRule(),
          homeNetworkRow(context, data.network, onTap: onNetwork),
          const HomeRule(),
          const SizedBox(height: 8),
        ] else ...[
          RaisedPanel(
            corner: HideBalancesButton(hidden: data.hidden, onPressed: onToggleHidden),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                balance,
                if (price != null) ...[
                  const SizedBox(height: 14),
                  const HomeRule(indent: 0, endIndent: 0),
                  const SizedBox(height: 12),
                  price,
                ],
              ],
            ),
          ),
          const SizedBox(height: 4),
          homeNetworkRow(context, data.network, onTap: onNetwork),
          const SizedBox(height: 4),
        ],
        HomeSectionHeader(title: 'Wallets', count: '${data.wallets.length}'),
        if (ruled) const HomeRule(),
        for (var i = 0; i < wallets.length; i++) ...[
          if (ruled && i > 0) const HomeRule(indent: homeTextStart),
          wallets[i],
        ],
        if (ruled) const HomeRule(),
        const SizedBox(height: 20),
        PrototypeNote(onLearnMore: onLearnMore),
      ],
    );
  }
}

/// The prototype warning, kept but moved from the top of every screen to
/// the foot of the launch screen: always findable, never in the way.
class PrototypeNote extends StatelessWidget {
  const PrototypeNote({super.key, this.onLearnMore, this.inset = true});

  final VoidCallback? onLearnMore;

  /// Keep to the page's gutters; off where the parent already does.
  final bool inset;

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    // At large text the link moves under the words instead of squeezing
    // them into a column a few words wide.
    final stacked = homeLargeText(context);
    final text = Text('Unaudited prototype. Use only funds you can afford to lose.', style: t.secondary);
    final link = TextButton(
      key: const Key('overview-learn-more'),
      onPressed: onLearnMore,
      style: TextButton.styleFrom(
        foregroundColor: t.ink,
        minimumSize: const Size(48, 48),
        padding: stacked ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 10),
        alignment: AlignmentDirectional.centerStart,
        textStyle: t.link,
      ),
      child: const Text('Learn more'),
    );
    final shield = SizedBox(
      width: homeMarkSize,
      child: Center(child: Icon(Icons.shield_outlined, size: 16, color: t.muted)),
    );
    return Padding(
      padding: inset ? const EdgeInsetsDirectional.only(start: homeGutter, end: homeGutter - 10) : EdgeInsets.zero,
      child: stacked
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(padding: const EdgeInsets.only(top: 2), child: shield),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [text, link])),
              ],
            )
          : Row(children: [shield, const SizedBox(width: 12), Expanded(child: text), link]),
    );
  }
}

/// First launch: no wallets yet, so the three ways in are the page.
class _Welcome extends StatelessWidget {
  const _Welcome({this.onCreate, this.onRestore, this.onWatch, this.onLearnMore});

  final VoidCallback? onCreate;
  final VoidCallback? onRestore;
  final VoidCallback? onWatch;
  final VoidCallback? onLearnMore;

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    return ListView(
      key: const Key('overview-welcome'),
      // The header already carries the mark; the page opens on the words.
      padding: EdgeInsets.fromLTRB(homeGutter, 40, homeGutter, 28 + MediaQuery.paddingOf(context).bottom),
      children: [
        Semantics(
          header: true,
          child: Text('Your wallets live here', style: Theme.of(context).textTheme.headlineSmall),
        ),
        const SizedBox(height: 8),
        Text(
          'Create a new wallet, restore one from its recovery phrase, or watch an '
          'address without its keys. Each one opens from this screen.',
          style: t.secondary.copyWith(fontSize: 15, height: 1.45),
        ),
        const SizedBox(height: 28),
        FilledButton.icon(
          key: const Key('overview-add-create'),
          onPressed: onCreate,
          icon: const Icon(Icons.add, size: 20),
          label: const Text('Create a wallet'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('overview-add-restore'),
          onPressed: onRestore,
          icon: const Icon(Icons.settings_backup_restore, size: 20),
          label: const Text('Restore from recovery phrase'),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          key: const Key('overview-add-watch'),
          onPressed: onWatch,
          style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          icon: const Icon(Icons.visibility_outlined, size: 20),
          label: const Text('Watch an address'),
        ),
        const SizedBox(height: 36),
        PrototypeNote(onLearnMore: onLearnMore, inset: false),
      ],
    );
  }
}
