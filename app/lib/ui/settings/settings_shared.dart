import 'package:flutter/material.dart';

import '../../theme/argus_theme.dart';
import '../widgets/soft_card.dart';

/// One tappable row in a settings group.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    final fg = danger ? rustFor(context) : Theme.of(context).colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(cardRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: colors.chip,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 19, color: danger ? rustFor(context) : iris),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: fg)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(fontSize: 12.5, color: colors.muted),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            trailing ??
                (onTap != null
                    ? Icon(Icons.chevron_right, size: 18, color: colors.muted)
                    : const SizedBox.shrink()),
          ],
        ),
      ),
    );
  }
}

/// Labelled card of [SettingsRow]s.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.title, required this.children, this.scope});

  final String title;
  final String? scope;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(title, scope: scope),
        const SizedBox(height: 10),
        SoftCard(padding: EdgeInsets.zero, child: DividedColumn(indent: 66, children: children)),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// Scaffold for a settings sub-page.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
        children: children,
      ),
    );
  }
}

/// Small explanatory paragraph under a group.
class SettingsNote extends StatelessWidget {
  const SettingsNote(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 24),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}
