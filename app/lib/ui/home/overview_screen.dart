import 'package:flutter/material.dart';

import '../../theme/argus_theme.dart';
import 'balance_card.dart';
import 'home_models.dart';
import 'home_rows.dart';
import 'home_widgets.dart';

/// The launch screen: every wallet on this phone, seed and watched alike,
/// with the total across them.
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
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Semantics(
          header: true,
          label: 'Argus',
          excludeSemantics: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const IrisMark(size: 32),
              const SizedBox(width: 6),
              Text('Argus', style: Theme.of(context).textTheme.headlineSmall),
            ],
          ),
        ),
        actions: [
          IconButton(
            key: const Key('overview-settings'),
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: onSettings,
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: OverviewView(
        data: data,
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
  }
}

/// The overview's scrolling body, for hosting under another app bar.
class OverviewView extends StatelessWidget {
  const OverviewView({
    super.key,
    required this.data,
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
  final ValueChanged<String>? onOpenWallet;
  final ValueChanged<String>? onWalletOptions;
  final VoidCallback? onCreate;
  final VoidCallback? onRestore;
  final VoidCallback? onWatch;
  final VoidCallback? onToggleHidden;
  final VoidCallback? onNetwork;
  final VoidCallback? onLearnMore;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    if (data.wallets.isEmpty) {
      return _Welcome(
        onCreate: onCreate,
        onRestore: onRestore,
        onWatch: onWatch,
        onLearnMore: onLearnMore,
      );
    }
    return ListView(
      key: const Key('overview-list'),
      padding: EdgeInsets.fromLTRB(16, 4, 16, 28 + bottom),
      children: [
        BalanceCard(
          key: const Key('overview-total'),
          label: 'Total',
          nanoErg: data.totalNano,
          fiatValue: data.totalFiat,
          currency: data.currency,
          unpricedCount: data.unpricedCount,
          pending: data.pending,
          hidden: data.hidden,
          onToggleHidden: onToggleHidden,
          price: data.price,
          network: data.network,
          onNetwork: onNetwork,
        ),
        const SizedBox(height: 28),
        HomeSectionHeader(title: 'Wallets', count: '${data.wallets.length}'),
        const SizedBox(height: 8),
        HomeList(
          indent: 68,
          children: [
            for (final w in data.wallets)
              OverviewWalletRow(
                wallet: w,
                currency: data.currency,
                hidden: data.hidden,
                onTap: onOpenWallet == null ? null : () => onOpenWallet!(w.id),
                onLongPress: onWalletOptions == null ? null : () => onWalletOptions!(w.id),
              ),
          ],
        ),
        const SizedBox(height: 20),
        AddWalletRow(onCreate: onCreate, onRestore: onRestore, onWatch: onWatch),
        const SizedBox(height: 28),
        PrototypeNote(onLearnMore: onLearnMore),
      ],
    );
  }
}

/// Create, restore or watch: three equal choices under the wallet list.
/// They stack when the text is too large for three abreast.
class AddWalletRow extends StatelessWidget {
  const AddWalletRow({super.key, this.onCreate, this.onRestore, this.onWatch});

  final VoidCallback? onCreate;
  final VoidCallback? onRestore;
  final VoidCallback? onWatch;

  static const _labelStyle = TextStyle(fontSize: 14, fontWeight: FontWeight.w500);

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    final choices = [
      (key: 'create', icon: Icons.add, label: 'Create', spoken: 'Create a wallet', onTap: onCreate),
      (key: 'restore', icon: Icons.settings_backup_restore, label: 'Restore', spoken: 'Restore a wallet', onTap: onRestore),
      (key: 'watch', icon: Icons.visibility_outlined, label: 'Watch', spoken: 'Watch an address', onTap: onWatch),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Text(
            'ADD A WALLET',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(color: colors.muted, fontSize: 12),
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final needs = [
              // Icon, gap and padding around each label.
              for (final c in choices) measureText(context, c.label, _labelStyle) + 18 + 8 + 24,
            ];
            final columns = fittingColumns(maxWidth: constraints.maxWidth, gap: 10, needs: needs);
            return EqualColumns(
              columns: columns,
              gap: 10,
              children: [
                for (final c in choices)
                  HomeTile(
                    key: Key('overview-add-${c.key}'),
                    semanticLabel: c.spoken,
                    onTap: c.onTap,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(c.icon, size: 18, color: colors.accentText),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            c.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _labelStyle.copyWith(color: Theme.of(context).colorScheme.onSurface),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// The prototype warning, kept but moved from the top of every screen to
/// the foot of the launch screen: always findable, never in the way.
class PrototypeNote extends StatelessWidget {
  const PrototypeNote({super.key, this.onLearnMore});

  final VoidCallback? onLearnMore;

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    // At large text the link moves under the words instead of squeezing
    // them into a column a few words wide.
    final stacked = MediaQuery.textScalerOf(context).scale(14) / 14 > 1.35;
    final text = Text(
      'Unaudited prototype. Use only funds you can afford to lose.',
      style: TextStyle(fontSize: 12.5, height: 1.35, color: colors.muted),
    );
    final link = TextButton(
      key: const Key('overview-learn-more'),
      onPressed: onLearnMore,
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: stacked ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.centerLeft,
      ),
      child: const Text('Learn more'),
    );
    final shield = Icon(Icons.shield_outlined, size: 16, color: colors.muted);
    if (stacked) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 4),
          Padding(padding: const EdgeInsets.only(top: 4), child: shield),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [text, link]),
          ),
        ],
      );
    }
    return Row(
      children: [
        const SizedBox(width: 4),
        shield,
        const SizedBox(width: 10),
        Expanded(child: text),
        link,
      ],
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
    final colors = ArgusColors.of(context);
    return ListView(
      key: const Key('overview-welcome'),
      // The header already carries the mark; the page opens on the words.
      padding: EdgeInsets.fromLTRB(24, 40, 24, 28 + MediaQuery.paddingOf(context).bottom),
      children: [
        Semantics(
          header: true,
          child: Text('Your wallets live here', style: Theme.of(context).textTheme.headlineSmall),
        ),
        const SizedBox(height: 10),
        Text(
          'Create a new wallet, restore one from its recovery phrase, or watch an '
          'address without its keys. Each one opens from this screen.',
          style: TextStyle(fontSize: 15, height: 1.45, color: colors.muted),
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
        PrototypeNote(onLearnMore: onLearnMore),
      ],
    );
  }
}
