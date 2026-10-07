import 'package:flutter/material.dart';

import '../../theme/argus_theme.dart';
import 'home_models.dart';
import 'home_style.dart';
import 'home_widgets.dart';

/// Mark, name and one line for each tool behind More. The lines are short
/// forms of the Discover explainers, which stay the full account.
({IconData icon, String title, String blurb}) walletToolLook(WalletTool tool) => switch (tool) {
      WalletTool.mix => (
          icon: Icons.blender_outlined,
          title: 'Mix',
          blurb: 'Private ERG through the ErgoMixer pool.',
        ),
      WalletTool.tokens => (
          icon: Icons.token_outlined,
          title: 'Tokens',
          blurb: 'Issue tokens and NFTs, or burn tokens.',
        ),
      WalletTool.utxos => (
          icon: Icons.grid_view_outlined,
          title: 'UTXO management',
          blurb: 'Consolidate, split and tidy up your boxes.',
        ),
      WalletTool.addresses => (
          icon: Icons.account_tree_outlined,
          title: 'Addresses',
          blurb: 'Each address of this wallet and what it holds.',
        ),
      WalletTool.lock => (
          icon: Icons.lock_outline,
          title: 'Lock wallet',
          blurb: 'Opening it again asks for your PIN or fingerprint.',
        ),
    };

/// A flat sheet for the home screens: the same rows, rules and labels as
/// the page beneath, on the palette's surface, under a quiet handle.
Future<T?> showHomeSheet<T>(BuildContext context, {required Widget Function(BuildContext) builder}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    // Tall at large text sizes: it may fill the screen, but not run under
    // the status bar.
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(homeRadius))),
    builder: builder,
  );
}

/// A sheet's handle and its label line ("MORE · MAIN WALLET").
class HomeSheetHeader extends StatelessWidget {
  const HomeSheetHeader({super.key, required this.title, this.subject});

  final String title;

  /// Read after the title in the same capitals, e.g. the wallet's name.
  final String? subject;

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    return Column(
      children: [
        Container(
          width: 32,
          height: 4,
          margin: const EdgeInsets.only(top: 10, bottom: 8),
          decoration: BoxDecoration(color: t.muted.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(2)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Semantics(
                header: true,
                child: Text.rich(
                  TextSpan(
                    text: title.toUpperCase(),
                    children: [if (subject != null) TextSpan(text: '   ·   ${subject!.toUpperCase()}')],
                  ),
                  style: t.label,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Opens More and returns the tool picked, or null if dismissed.
Future<WalletTool?> showWalletToolsSheet(
  BuildContext context, {
  required List<WalletToolEntry> tools,
  required String walletName,
}) {
  return showHomeSheet<WalletTool>(
    context,
    builder: (ctx) => WalletToolsSheet(
      tools: tools,
      walletName: walletName,
      onSelect: (tool) => Navigator.pop(ctx, tool),
    ),
  );
}

/// The More sheet: the wallet's own tools that don't earn a place in the
/// action row. Protocols live in the Discover tab; this is only what acts
/// on the wallet itself, with Lock set apart under a rule.
class WalletToolsSheet extends StatelessWidget {
  const WalletToolsSheet({super.key, required this.tools, required this.walletName, required this.onSelect});

  final List<WalletToolEntry> tools;
  final String walletName;
  final ValueChanged<WalletTool> onSelect;

  @override
  Widget build(BuildContext context) {
    final main = tools.where((t) => t.tool != WalletTool.lock).toList();
    final lock = tools.where((t) => t.tool == WalletTool.lock).toList();
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            HomeSheetHeader(title: 'More', subject: walletName),
            for (final entry in main) _row(context, entry),
            if (lock.isNotEmpty) ...[
              const Padding(padding: EdgeInsets.symmetric(vertical: 4), child: HomeRule()),
              for (final entry in lock) _row(context, entry, chevron: false),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, WalletToolEntry entry, {bool chevron = true}) {
    final t = HomeText.of(context);
    final look = walletToolLook(entry.tool);
    final status = entry.status;
    final warn = rustFor(context);
    return HomeRow(
      inkKey: Key('wallet-tool-${entry.tool.name}'),
      onTap: () => onSelect(entry.tool),
      semanticLabel: [look.title, ?status, look.blurb].join(', '),
      leading: HomeDisc(child: Icon(look.icon, size: 18, color: t.ink)),
      title: Text.rich(
        TextSpan(
          text: look.title,
          children: [
            if (status != null)
              TextSpan(
                text: '   $status',
                style: t.secondary.copyWith(
                  color: entry.warn ? warn : ArgusColors.of(context).accentText,
                  fontWeight: FontWeight.w500,
                ),
              ),
          ],
        ),
        style: t.primary,
      ),
      subtitle: TextSpan(text: look.blurb),
      trailing: chevron ? Icon(Icons.chevron_right, size: 18, color: t.muted) : null,
    );
  }
}

/// What the overview's "Add a wallet" row offers.
enum AddWalletChoice {
  create('overview-create'),
  restore('overview-restore'),
  watchAddress('overview-watch-address'),
  watchAccount('overview-watch-xpub');

  const AddWalletChoice(this.keyName);

  /// The same key wherever the choice is offered: the first-launch page
  /// and the sheet are never on screen together.
  final String keyName;
}

({IconData icon, String title, String blurb}) addWalletLook(AddWalletChoice choice) => switch (choice) {
      AddWalletChoice.create => (
          icon: Icons.add,
          title: 'Create a new wallet',
          blurb: 'A fresh recovery phrase, kept on this phone.',
        ),
      AddWalletChoice.restore => (
          icon: Icons.settings_backup_restore,
          title: 'Restore a wallet',
          blurb: 'From its 12 to 24-word recovery phrase (15 is the Ergo standard).',
        ),
      AddWalletChoice.watchAddress => (
          icon: Icons.visibility_outlined,
          title: 'Watch an address',
          blurb: 'Balance and activity, without its keys.',
        ),
      AddWalletChoice.watchAccount => (
          icon: Icons.account_tree_outlined,
          title: 'Watch an account',
          blurb: 'Every address of an extended public key (xpub).',
        ),
    };

/// Opens the small Add a wallet menu and returns the choice.
Future<AddWalletChoice?> showAddWalletSheet(BuildContext context) {
  return showHomeSheet<AddWalletChoice>(
    context,
    builder: (ctx) => AddWalletSheet(onSelect: (c) => Navigator.pop(ctx, c)),
  );
}

/// Create, restore or watch: four rows in a sheet, so the overview needs
/// only one quiet row for all of them.
class AddWalletSheet extends StatelessWidget {
  const AddWalletSheet({super.key, required this.onSelect});

  final ValueChanged<AddWalletChoice> onSelect;

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const HomeSheetHeader(title: 'Add a wallet'),
            for (final choice in AddWalletChoice.values)
              HomeRow(
                inkKey: Key(choice.keyName),
                onTap: () => onSelect(choice),
                semanticLabel: '${addWalletLook(choice).title}, ${addWalletLook(choice).blurb}',
                leading: HomeDisc(child: Icon(addWalletLook(choice).icon, size: 18, color: t.ink)),
                title: Text(addWalletLook(choice).title, style: t.primary),
                subtitle: TextSpan(text: addWalletLook(choice).blurb),
                trailing: Icon(Icons.chevron_right, size: 18, color: t.muted),
              ),
          ],
        ),
      ),
    );
  }
}
