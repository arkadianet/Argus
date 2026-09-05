import 'package:flutter/material.dart';

/// One primary action on the home screen.
class HomeAction {
  const HomeAction({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

/// Width a labelled action button needs to show its label without
/// clipping at the app's text size, gaps included.
const homeActionMinWidth = 100.0;

/// The home screen's primary actions: one row when every button gets at
/// least [homeActionMinWidth], otherwise two rows of two. A phone at
/// 360 dp gives four buttons about 74 dp each, which clips "Receive".
class HomeActionRow extends StatelessWidget {
  const HomeActionRow({super.key, required this.actions, this.gap = 10});

  final List<HomeAction> actions;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final n = actions.length;
        final perButton = (constraints.maxWidth - gap * (n - 1)) / n;
        final perRow = perButton >= homeActionMinWidth || n <= 2 ? n : (n / 2).ceil();
        final rows = <List<HomeAction>>[];
        for (var i = 0; i < n; i += perRow) {
          rows.add(actions.sublist(i, (i + perRow).clamp(0, n)));
        }
        return Column(
          children: [
            for (var r = 0; r < rows.length; r++) ...[
              if (r > 0) SizedBox(height: gap),
              Row(
                children: [
                  for (var i = 0; i < rows[r].length; i++) ...[
                    if (i > 0) SizedBox(width: gap),
                    Expanded(child: _button(rows[r][i])),
                  ],
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _button(HomeAction a) {
    return FilledButton.icon(
      key: Key('home-action-${a.label.toLowerCase()}'),
      onPressed: a.onTap,
      icon: Icon(a.icon, size: 17),
      label: Text(a.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 50),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        textStyle: const TextStyle(
          fontFamily: 'Karla',
          fontWeight: FontWeight.w500,
          fontSize: 14.5,
        ),
      ),
    );
  }
}
