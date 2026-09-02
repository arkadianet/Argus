import 'package:flutter/material.dart';

import '../../theme/argus_theme.dart';

/// The soft bordered surface used for every grouped list on the home,
/// assets and activity screens.
class SoftCard extends StatelessWidget {
  const SoftCard({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(cardRadius),
        border: Border.all(
          color: dark ? const Color(0xFF262C29) : const Color(0xFFEDE4D3),
        ),
      ),
      child: child,
    );
  }
}

/// Rows separated by an inset hairline, for use inside a [SoftCard].
class DividedColumn extends StatelessWidget {
  const DividedColumn({super.key, required this.children, this.indent = 68});

  final List<Widget> children;
  final double indent;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) Divider(height: 1, indent: indent),
          children[i],
        ],
      ],
    );
  }
}
