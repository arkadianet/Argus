import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/argus_theme.dart';
import 'home_models.dart';
import 'home_widgets.dart';

/// Mark and words for each primary action.
({IconData icon, String label}) walletActionLook(WalletAction action) => switch (action) {
      WalletAction.send => (icon: Icons.north_east, label: 'Send'),
      WalletAction.sendOffline => (icon: Icons.qr_code_2, label: 'Send with offline signer'),
      WalletAction.receive => (icon: Icons.south_west, label: 'Receive'),
      WalletAction.swap => (icon: Icons.swap_horiz, label: 'Swap'),
      WalletAction.more => (icon: Icons.more_horiz, label: 'More'),
    };

/// The wallet page's one row of actions: Send, Receive, Swap, More.
///
/// Each is a quiet tile with its mark above its name, so four fit one
/// line on a small phone where four filled buttons clipped "Receive".
/// When the text is too large for that, the tiles fall back to two per
/// line rather than shrink a label; a longer label breaks evenly in two.
class WalletActionRow extends StatelessWidget {
  const WalletActionRow({super.key, required this.actions, required this.onAction});

  final List<WalletAction> actions;
  final ValueChanged<WalletAction> onAction;

  static const _gap = 10.0;
  static const _labelStyle = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, height: 1.25);
  static const _sidePadding = 10.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final needs = [
          for (final a in actions) _need(context, walletActionLook(a).label),
        ];
        final columns = fittingColumns(maxWidth: constraints.maxWidth, gap: _gap, needs: needs);
        // The tile's own width, less its padding and hairline border.
        final textWidth = (constraints.maxWidth - _gap * (columns - 1)) / columns - _sidePadding * 2 - 2;
        return EqualColumns(
          columns: columns,
          gap: _gap,
          children: [
            for (final a in actions)
              _tile(context, a, balancedLabel(context, walletActionLook(a).label, _labelStyle, textWidth)),
          ],
        );
      },
    );
  }

  /// Width a tile needs: a one-word label must fit whole; a longer one may
  /// take two lines, so it needs its longest word and about half its length.
  double _need(BuildContext context, String label) {
    final words = label.split(' ');
    final longestWord = words.map((w) => measureText(context, w, _labelStyle)).reduce(math.max);
    final whole = measureText(context, label, _labelStyle);
    final need = words.length == 1 ? whole : math.max(longestWord, whole / 2 + 8);
    return need + _sidePadding * 2 + 2;
  }

  Widget _tile(BuildContext context, WalletAction action, String label) {
    final look = walletActionLook(action);
    final colors = ArgusColors.of(context);
    return HomeTile(
      key: Key('wallet-action-${action.name}'),
      semanticLabel: look.label,
      onTap: () => onAction(action),
      padding: const EdgeInsets.symmetric(horizontal: _sidePadding, vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(look.icon, size: 22, color: colors.accentText),
          const SizedBox(height: 6),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: _labelStyle.copyWith(color: Theme.of(context).colorScheme.onSurface),
          ),
        ],
      ),
    );
  }
}
