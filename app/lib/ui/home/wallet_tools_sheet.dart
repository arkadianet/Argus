import 'package:flutter/material.dart';

import '../../theme/argus_theme.dart';
import 'home_models.dart';
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

/// Opens More and returns the tool picked, or null if dismissed.
Future<WalletTool?> showWalletToolsSheet(
  BuildContext context, {
  required List<WalletToolEntry> tools,
  required String walletName,
}) {
  return showModalBottomSheet<WalletTool>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    // Tall at large text sizes: it may fill the screen, but not run under
    // the status bar.
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(cardRadius))),
    builder: (ctx) => WalletToolsSheet(
      tools: tools,
      walletName: walletName,
      onSelect: (tool) => Navigator.pop(ctx, tool),
    ),
  );
}

/// The More sheet: the wallet's own tools that don't earn a place in the
/// action row. Protocols live in the Discover tab; this is only what acts
/// on the wallet itself, with Lock set apart at the end.
class WalletToolsSheet extends StatelessWidget {
  const WalletToolsSheet({super.key, required this.tools, required this.walletName, required this.onSelect});

  final List<WalletToolEntry> tools;
  final String walletName;
  final ValueChanged<WalletTool> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    final main = tools.where((t) => t.tool != WalletTool.lock).toList();
    final lock = tools.where((t) => t.tool == WalletTool.lock).toList();
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // A handle in the card's own muted ink rather than the bright
            // default, which outshone the sheet's contents.
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(top: 12, bottom: 14),
                decoration: BoxDecoration(
                  color: colors.muted.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                spacing: 10,
                crossAxisAlignment: WrapCrossAlignment.end,
                children: [
                  Semantics(header: true, child: Text('More', style: Theme.of(context).textTheme.titleLarge)),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(walletName, style: TextStyle(fontSize: 13.5, color: colors.muted)),
                  ),
                ],
              ),
            ),
            for (final entry in main) _row(context, entry),
            if (lock.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Divider(height: 1),
              ),
              for (final entry in lock) _row(context, entry, chevron: false),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, WalletToolEntry entry, {bool chevron = true}) {
    final colors = ArgusColors.of(context);
    final look = walletToolLook(entry.tool);
    final status = entry.status;
    void select() => onSelect(entry.tool);
    return TappableNode(
      label: [look.title, ?status, look.blurb].join(', '),
      onTap: select,
      child: InkWell(
        key: Key('wallet-tool-${entry.tool.name}'),
        borderRadius: BorderRadius.circular(14),
        onTap: select,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: colors.inset, borderRadius: BorderRadius.circular(12)),
                child: Icon(look.icon, size: 20, color: colors.accentText),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(look.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                        if (status != null)
                          HomeChip(
                            label: status,
                            dense: true,
                            tone: entry.warn ? HomeChipTone.warn : HomeChipTone.accent,
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(look.blurb, style: TextStyle(fontSize: 12.5, height: 1.35, color: colors.muted)),
                  ],
                ),
              ),
              if (chevron) ...[
                const SizedBox(width: 8),
                Icon(Icons.chevron_right, size: 18, color: colors.muted),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
