import 'dart:math' as math;

import 'package:flutter/material.dart';

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

/// Width an action's name needs under its button: a one-word name whole, a
/// longer one as two even lines.
double _labelNeed(BuildContext context, String label, TextStyle style) {
  final words = label.split(' ');
  final whole = measureText(context, label, style);
  if (words.length == 1) return whole;
  final longestWord = words.map((w) => measureText(context, w, style)).reduce(math.max);
  return math.max(longestWord, whole / 2 + 8);
}

/// The wallet's actions: round buttons on the hero with their names
/// beneath. The first, the wallet's main way to pay, is the one filled
/// button; the rest sit in tonal wells. Colours come from where they sit
/// ([HomeTones]). Four abreast, then two by two at large text sizes, rather
/// than squeeze a name.
class HomeActionCircles extends StatelessWidget {
  const HomeActionCircles({
    super.key,
    required this.actions,
    required this.onAction,
    this.disabled = const {},
    this.watched = false,
  });

  final List<WalletAction> actions;
  final ValueChanged<WalletAction> onAction;

  /// Drawn, so the page keeps its shape, but not offered right now.
  final Set<WalletAction> disabled;

  /// A watched wallet's actions keep the keys they have always had
  /// ("watch-action-send"), which other screens' tests look for.
  final bool watched;

  static const _size = 44.0;
  static const _gap = 8.0;

  Key _key(WalletAction action) => watched
      ? Key('watch-action-${action == WalletAction.sendOffline ? 'send' : action.name}')
      : Key('wallet-action-${action.name}');

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
    final enabled = !disabled.contains(action);
    // Disabled reads as the same button at a lower opacity, so the page
    // keeps its shape while, say, an account's first scan runs.
    return TappableNode(
      label: look.label,
      onTap: enabled ? () => onAction(action) : null,
      button: true,
      child: Opacity(
        opacity: enabled ? 1 : 0.38,
        child: _RoundAction(
          inkKey: _key(action),
          icon: look.icon,
          label: balancedLabel(context, look.label, style, labelWidth),
          style: style,
          primary: primary,
          onTap: enabled ? () => onAction(action) : null,
        ),
      ),
    );
  }
}

/// One round action: its circle gives a little under a finger, with the
/// ink spreading over it, and springs back on release. The filled one sits
/// on a soft shadow of its own colour, so it reads as the one to press.
class _RoundAction extends StatefulWidget {
  const _RoundAction({
    required this.inkKey,
    required this.icon,
    required this.label,
    required this.style,
    required this.primary,
    required this.onTap,
  });

  final Key inkKey;
  final IconData icon;
  final String label;
  final TextStyle style;
  final bool primary;
  final VoidCallback? onTap;

  @override
  State<_RoundAction> createState() => _RoundActionState();
}

class _RoundActionState extends State<_RoundAction> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final tones = HomeTones.of(context);
    final still = homeReducedMotion(context);
    final fill = widget.primary ? tones.filled : tones.tonal;
    return InkWell(
      key: widget.inkKey,
      onTap: widget.onTap,
      onHighlightChanged: (down) => setState(() => _pressed = down),
      borderRadius: BorderRadius.circular(homeRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedScale(
              scale: _pressed && !still ? 0.9 : 1,
              duration: still ? Duration.zero : HomeMotion.press,
              curve: Curves.easeOut,
              child: Container(
                width: HomeActionCircles._size,
                height: HomeActionCircles._size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: fill,
                  boxShadow: [
                    if (widget.primary)
                      BoxShadow(color: fill.withValues(alpha: 0.35), blurRadius: 10, spreadRadius: -2, offset: const Offset(0, 4)),
                  ],
                ),
                child: Icon(widget.icon, size: homeIconSize, color: widget.primary ? tones.onFilled : tones.onTonal),
              ),
            ),
            const SizedBox(height: 6),
            Text(widget.label, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: widget.style),
          ],
        ),
      ),
    );
  }
}
