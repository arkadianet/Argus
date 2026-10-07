import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/argus_theme.dart';
import 'home_models.dart';
import 'home_style.dart';
import 'home_widgets.dart';

/// Mark and words for each primary action.
({IconData icon, String label}) walletActionLook(WalletAction action) => switch (action) {
      WalletAction.send => (icon: Icons.near_me_outlined, label: 'Send'),
      WalletAction.sendOffline => (icon: Icons.qr_code_2, label: 'Send with offline signer'),
      WalletAction.receive => (icon: Icons.arrow_downward_rounded, label: 'Receive'),
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

/// The wallet's actions: large round buttons on the scene with their names
/// beneath. The first, the wallet's main way to pay, is filled with a
/// glowing gradient of the accent; the rest are thin rings of light round
/// a line icon. Four abreast, then two by two at large text sizes, rather
/// than squeeze a name.
class HomeActionCircles extends StatelessWidget {
  const HomeActionCircles({
    super.key,
    required this.actions,
    required this.onAction,
    this.disabled = const {},
    this.watched = false,
    this.keyPrefix,
    this.gridMore = false,
  });

  final List<WalletAction> actions;
  final ValueChanged<WalletAction> onAction;

  /// Drawn, so the page keeps its shape, but not offered right now.
  final Set<WalletAction> disabled;

  /// A watched wallet's actions keep the keys they have always had
  /// ("watch-action-send"), which other screens' tests look for.
  final bool watched;

  /// Keys "<prefix>-<action>" instead, e.g. the overview's own row.
  final String? keyPrefix;

  /// More as a grid of four dots (the overview's, where it opens more than
  /// one wallet's tools) rather than three.
  final bool gridMore;

  static const _size = 52.0;
  static const _gap = 8.0;

  Key _key(WalletAction action) => keyPrefix != null
      ? Key('$keyPrefix-${action.name}')
      : watched
          ? Key('watch-action-${action == WalletAction.sendOffline ? 'send' : action.name}')
          : Key('wallet-action-${action.name}');

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    final style = t.secondary.copyWith(color: t.ink, fontSize: 13.5);
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
          icon: action == WalletAction.more && gridMore ? null : look.icon,
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

  /// Null draws four dots in a square.
  final IconData? icon;
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
    final spec = ArgusColors.sceneOf(context);
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
              scale: _pressed && !still ? 0.92 : 1,
              duration: still ? Duration.zero : HomeMotion.press,
              curve: Curves.easeOut,
              child: Container(
                width: HomeActionCircles._size,
                height: HomeActionCircles._size,
                decoration: widget.primary
                    ? BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          center: const Alignment(-0.3, -0.45),
                          radius: 0.95,
                          colors: [spec.sendTop, spec.sendBottom],
                        ),
                        border: Border.all(color: spec.sendTop.withValues(alpha: 0.9)),
                        boxShadow: [BoxShadow(color: spec.sendGlow, blurRadius: 22, spreadRadius: 1)],
                      )
                    : BoxDecoration(
                        shape: BoxShape.circle,
                        color: spec.ringFill,
                        border: Border.all(color: spec.ring),
                      ),
                child: widget.icon == null
                    ? _DotGrid(color: tones.ink)
                    : Icon(widget.icon, size: 22, color: widget.primary ? spec.onSend : tones.ink),
              ),
            ),
            const SizedBox(height: 8),
            Text(widget.label, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: widget.style),
          ],
        ),
      ),
    );
  }
}

/// Four dots in a square: the overview's More.
class _DotGrid extends StatelessWidget {
  const _DotGrid({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    Widget dot() => Container(width: 5, height: 5, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
    return Center(
      child: SizedBox(
        width: 15,
        height: 15,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [dot(), dot()]),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [dot(), dot()]),
          ],
        ),
      ),
    );
  }
}
