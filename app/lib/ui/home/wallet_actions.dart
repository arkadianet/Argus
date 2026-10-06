import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/argus_theme.dart';
import 'home_models.dart';
import 'home_style.dart';
import 'home_widgets.dart';

/// Mark and words for each primary action.
({IconData icon, String label}) walletActionLook(WalletAction action) => switch (action) {
      WalletAction.send => (icon: Icons.north_east, label: 'Send'),
      WalletAction.sendOffline => (icon: Icons.qr_code_2, label: 'Send with offline signer'),
      WalletAction.receive => (icon: Icons.south_west, label: 'Receive'),
      WalletAction.swap => (icon: Icons.swap_horiz, label: 'Swap'),
      WalletAction.more => (icon: Icons.more_horiz, label: 'More'),
    };

/// Width an action needs beside its icon: a one-word label whole, a longer
/// one as two even lines.
double _labelNeed(BuildContext context, String label, TextStyle style) {
  final words = label.split(' ');
  final whole = measureText(context, label, style);
  if (words.length == 1) return whole;
  final longestWord = words.map((w) => measureText(context, w, style)).reduce(math.max);
  return math.max(longestWord, whole / 2 + 8);
}

/// The ruled direction's actions: one slim bar between hairlines, split by
/// hairlines, each action an icon beside its name. It falls back to two
/// by two, then one per line, rather than squeeze a name.
class HomeActionBar extends StatelessWidget {
  const HomeActionBar({super.key, required this.actions, required this.onAction});

  final List<WalletAction> actions;
  final ValueChanged<WalletAction> onAction;

  static const _iconGap = 6.0;
  static const _pad = 4.0;

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    final style = t.secondary.copyWith(color: t.ink, fontWeight: FontWeight.w500);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: homeGutter),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final needs = [
            for (final a in actions) homeIconSize + _iconGap + _labelNeed(context, walletActionLook(a).label, style) + _pad * 2,
          ];
          final columns = fittingColumns(maxWidth: constraints.maxWidth, gap: 0, needs: needs);
          final labelWidth = constraints.maxWidth / columns - homeIconSize - _iconGap - _pad * 2;
          final rows = <List<WalletAction>>[
            for (var i = 0; i < actions.length; i += columns) actions.sublist(i, math.min(i + columns, actions.length)),
          ];
          final rule = Theme.of(context).colorScheme.outline;
          final px = 1 / MediaQuery.devicePixelRatioOf(context);
          return Column(
            children: [
              for (var r = 0; r < rows.length; r++) ...[
                if (r > 0) SizedBox(height: px, width: double.infinity, child: ColoredBox(color: rule)),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < columns; i++) ...[
                        if (i > 0)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: SizedBox(width: px, child: ColoredBox(color: rule)),
                          ),
                        Expanded(
                          child: i < rows[r].length
                              ? _segment(context, rows[r][i], style, labelWidth)
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _segment(BuildContext context, WalletAction action, TextStyle style, double labelWidth) {
    final look = walletActionLook(action);
    final t = HomeText.of(context);
    return TappableNode(
      label: look.label,
      onTap: () => onAction(action),
      child: InkWell(
        key: Key('wallet-action-${action.name}'),
        onTap: () => onAction(action),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: homeLineHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: _pad, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(look.icon, size: homeIconSize, color: t.ink),
                  const SizedBox(width: _iconGap),
                  Flexible(
                    child: Text(
                      balancedLabel(context, look.label, style, labelWidth),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The raised direction's actions: round buttons on the panel with their
/// names beneath. The first, the wallet's main way to pay, is filled with
/// the accent; the rest sit recessed in the panel. Four abreast, then two
/// by two at large text sizes.
class HomeActionCircles extends StatelessWidget {
  const HomeActionCircles({super.key, required this.actions, required this.onAction});

  final List<WalletAction> actions;
  final ValueChanged<WalletAction> onAction;

  static const _size = 44.0;
  static const _gap = 8.0;

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    final style = t.secondary.copyWith(color: t.ink, fontWeight: FontWeight.w500);
    return LayoutBuilder(
      builder: (context, constraints) {
        final needs = [
          for (final a in actions) math.max(_size, _labelNeed(context, walletActionLook(a).label, style)) + 8,
        ];
        final columns = fittingColumns(maxWidth: constraints.maxWidth, gap: _gap, needs: needs);
        final width = (constraints.maxWidth - _gap * (columns - 1)) / columns - 8;
        final rows = <List<WalletAction>>[
          for (var i = 0; i < actions.length; i += columns) actions.sublist(i, math.min(i + columns, actions.length)),
        ];
        return Column(
          children: [
            for (var r = 0; r < rows.length; r++) ...[
              if (r > 0) const SizedBox(height: _gap),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < columns; i++) ...[
                      if (i > 0) const SizedBox(width: _gap),
                      Expanded(
                        child: i < rows[r].length
                            ? _button(context, rows[r][i], style, width, primary: rows[r][i] == actions.first)
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _button(BuildContext context, WalletAction action, TextStyle style, double labelWidth, {required bool primary}) {
    final look = walletActionLook(action);
    final colors = ArgusColors.of(context);
    final t = HomeText.of(context);
    return TappableNode(
      label: look.label,
      onTap: () => onAction(action),
      child: InkWell(
        key: Key('wallet-action-${action.name}'),
        onTap: () => onAction(action),
        borderRadius: BorderRadius.circular(homeRadius),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: _size,
                height: _size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: primary ? colors.accent : colors.inset,
                ),
                child: Icon(look.icon, size: homeIconSize, color: primary ? colors.onAccent : t.ink),
              ),
              const SizedBox(height: 6),
              Text(
                balancedLabel(context, look.label, style, labelWidth),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
