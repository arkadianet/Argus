import 'package:flutter/material.dart';

import '../../format.dart';
import '../../services/portfolio.dart';
import '../../theme/argus_theme.dart';
import '../widgets/erg_rate_line.dart';
import '../widgets/pending_balance_line.dart';
import '../widgets/soft_card.dart';
import 'address_breakdown.dart';
import 'overview_model.dart';
import 'wallet_sections.dart';

// The launch overview, one section per widget. Like the wallet page's
// sections, each takes figures and callbacks only.

/// The total across every wallet on the overview.
class OverviewTotalCard extends StatelessWidget {
  const OverviewTotalCard({
    super.key,
    required this.totals,
    required this.hidden,
    required this.onToggleHidden,
    this.valueLine,
    this.loading = false,
  });

  final OverviewTotals totals;
  final bool hidden;
  final VoidCallback onToggleHidden;

  /// Fiat value of the total and its caveats, already worded.
  final String? valueLine;

  /// Nothing known yet and something on its way.
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    final total = totals.total;
    final subtitle = portfolioSubtitle(
      wallets: totals.wallets,
      watched: totals.watched,
      unknown: total.unknown,
    );
    return SoftCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ALL WALLETS',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(color: muted),
                ),
                const SizedBox(height: 8),
                ErgFigure(
                  text: hidden
                      ? '••••••'
                      : total.known == 0
                      ? '—'
                      : formatErg(total.totalNano, unit: false, maxFrac: 4),
                  textKey: const Key('overview-total'),
                  loading: loading && total.known == 0,
                ),
                const SizedBox(height: 6),
                Text(
                  [if (valueLine != null) valueLine!, subtitle].join('  ·  '),
                  style: TextStyle(fontSize: 14, color: muted),
                ),
                if (totals.pending?.hasPending ?? false) ...[
                  const SizedBox(height: 2),
                  PendingBalanceLine(
                    key: const Key('overview-total-pending'),
                    pending: totals.pending,
                    hidden: hidden,
                  ),
                ],
                const SizedBox(height: 2),
                const ErgRateLine(),
              ],
            ),
          ),
          IconCircle(
            icon: hidden
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
            tooltip: hidden ? 'Show balances' : 'Hide balances',
            onTap: onToggleHidden,
          ),
        ],
      ),
    );
  }
}

/// A titled card of wallet rows. Seed wallets can be dragged into a new
/// order by a long press when [onReorder] is given.
class OverviewGroup extends StatelessWidget {
  const OverviewGroup({
    super.key,
    required this.title,
    required this.rows,
    this.scope,
    this.onReorder,
  });

  final String title;
  final String? scope;
  final List<Widget> rows;
  final void Function(int oldIndex, int newIndex)? onReorder;

  @override
  Widget build(BuildContext context) {
    final reorder = onReorder;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(title, scope: scope),
        const SizedBox(height: 10),
        SoftCard(
          padding: EdgeInsets.zero,
          child: Material(
            type: MaterialType.transparency,
            child: reorder == null || rows.length < 2
                ? DividedColumn(indent: 16, children: rows)
                : ReorderableListView(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    // onReorderItem, the replacement, only exists on newer
                    // Flutter than this project builds with; the model
                    // makes the same index adjustment onReorderItem would.
                    // ignore: deprecated_member_use
                    onReorder: reorder,
                    children: [
                      for (final (i, row) in rows.indexed)
                        ReorderableDelayedDragStartListener(
                          // Distinct from the row's own key, which tests
                          // and the row itself use to find the row.
                          key: ValueKey<Object>(('reorder', row.key ?? i)),
                          index: i,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (i > 0) const Divider(height: 1, indent: 16),
                              row,
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

/// One wallet on the overview: what it is, the address it is shown as, and
/// what it holds. Tapping it opens the wallet.
class OverviewWalletRow extends StatelessWidget {
  const OverviewWalletRow({
    super.key,
    required this.entry,
    required this.hidden,
    required this.onTap,
    this.valueText,
  });

  final OverviewEntry entry;
  final bool hidden;
  final VoidCallback onTap;

  /// Fiat value of this row's holdings, already worded.
  final String? valueText;

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    final e = entry;
    final small = TextStyle(fontSize: 12, color: colors.muted);
    final tag = switch (e.state) {
      OverviewRowState.unlocked => 'Unlocked',
      OverviewRowState.locked => 'Locked',
      // The eye mark and the group already say so.
      OverviewRowState.watched => null,
    };
    final tokenCount = e.tokensKnown && !hidden
        ? e.tokens.where((t) => t.amount > 0).map((t) => t.id).toSet().length
        : null;
    final meta = <String>[
      if (tokenCount != null)
        '$tokenCount ${e.publicTokensOnly && !e.watched ? 'public ' : ''}'
            '${tokenCount == 1 ? 'token' : 'tokens'}',
      if (e.asOf != null && e.balanceNano != null)
        'as of ${formatSyncAge(DateTime.now().subtract(e.asOf!))}',
      if (_stealthNote(e) case final note?) note,
    ];
    final balanceText = e.balanceNano == null
        ? (e.loading ? '…' : '—')
        : (hidden ? '••••' : formatErg(e.balanceNano, unit: false, maxFrac: 2));
    final aside = e.balanceNano == null ? e.unavailable : valueText;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            SizedBox(
              width: 14,
              child: Center(child: _stateMark(context, e.state)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Name and figure share the first line; the figure keeps
                  // its full width and the name gives way.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Expanded(
                        child: Text(
                          e.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        balanceText,
                        maxLines: 1,
                        style: const TextStyle(
                          fontFamily: 'Newsreader',
                          fontWeight: FontWeight.w600,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text('ERG', style: small),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          e.address == null || e.address!.isEmpty
                              ? ''
                              : shorten(e.address!, head: 6, tail: 6),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: monoStyle(
                            context,
                            size: 11.5,
                          ).copyWith(color: colors.muted),
                        ),
                      ),
                      if (aside != null) ...[
                        const SizedBox(width: 8),
                        // Up to half the line, flush right like the figure
                        // above it.
                        Flexible(
                          child: Align(
                            alignment: Alignment.topRight,
                            child: Text(
                              aside,
                              textAlign: TextAlign.end,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: small,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (tag != null || meta.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text.rich(
                      TextSpan(
                        children: [
                          if (tag != null)
                            TextSpan(
                              text: tag,
                              style: TextStyle(
                                fontWeight: e.state == OverviewRowState.unlocked
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: e.state == OverviewRowState.unlocked
                                    ? moss
                                    : colors.muted,
                              ),
                            ),
                          TextSpan(
                            text: [if (tag != null) '', ...meta].join(' · '),
                          ),
                        ],
                      ),
                      style: small,
                    ),
                  ],
                  if (e.elsewhere != null) ...[
                    const SizedBox(height: 2),
                    FundsElsewhereLink(
                      funds: e.elsewhere!,
                      hidden: hidden,
                      fontSize: 12,
                    ),
                  ],
                  if (e.balanceNano != null &&
                      (e.pending?.hasPending ?? false)) ...[
                    const SizedBox(height: 2),
                    PendingBalanceLine(
                      pending: e.pending,
                      hidden: hidden,
                      style: small,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 18, color: colors.muted),
          ],
        ),
      ),
    );
  }

  String? _stealthNote(OverviewEntry e) {
    if (hidden || e.stealthNano <= 0) return null;
    final seen = e.stealthAsOf;
    return 'includes ${formatErg(e.stealthNano, maxFrac: 4)} stealth'
        '${e.state == OverviewRowState.locked && seen != null ? ', as of ${formatSyncAge(seen)}' : ''}';
  }

  Widget _stateMark(BuildContext context, OverviewRowState state) {
    final muted = ArgusColors.of(context).muted;
    return switch (state) {
      OverviewRowState.unlocked => Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(color: moss, shape: BoxShape.circle),
      ),
      OverviewRowState.locked => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: muted, width: 1.5),
        ),
      ),
      OverviewRowState.watched => Icon(
        Icons.visibility_outlined,
        size: 14,
        color: muted,
      ),
    };
  }
}

/// Create, restore and watch: every way a wallet gets onto this device.
class OverviewAddActions extends StatelessWidget {
  const OverviewAddActions({
    super.key,
    required this.onCreate,
    required this.onRestore,
    required this.onWatchAddress,
    required this.onWatchAccount,
  });

  final VoidCallback onCreate;
  final VoidCallback onRestore;
  final VoidCallback onWatchAddress;
  final VoidCallback onWatchAccount;

  @override
  Widget build(BuildContext context) {
    Widget button(Key key, IconData icon, String label, VoidCallback onTap) =>
        OutlinedButton.icon(
          key: key,
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          label: Text(label, maxLines: 2, textAlign: TextAlign.center),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          ),
        );
    // Equal heights per row, whichever label wraps at large text.
    Widget pair(Widget a, Widget b) => IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: a),
          const SizedBox(width: 12),
          Expanded(child: b),
        ],
      ),
    );
    return Column(
      children: [
        pair(
          button(const Key('overview-create'), Icons.add, 'Create', onCreate),
          button(
            const Key('overview-restore'),
            Icons.restore,
            'Restore',
            onRestore,
          ),
        ),
        const SizedBox(height: 12),
        pair(
          button(
            const Key('overview-watch-address'),
            Icons.visibility_outlined,
            'Watch address',
            onWatchAddress,
          ),
          button(
            const Key('overview-watch-xpub'),
            Icons.account_tree_outlined,
            'Watch xpub',
            onWatchAccount,
          ),
        ),
      ],
    );
  }
}

/// First launch, or every wallet removed: what Argus is for, and the four
/// ways to start.
class OverviewWelcome extends StatelessWidget {
  const OverviewWelcome({super.key, required this.actions});

  final OverviewAddActions actions;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 40),
        const Center(child: IrisMark(size: 72)),
        const SizedBox(height: 20),
        Text(
          'Argus',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        const Center(child: SizedBox(width: 48, child: Hairline(gold: true))),
        const SizedBox(height: 12),
        Text(
          'No wallets yet. Create a wallet, restore one you already have, or '
          'watch an address or extended public key without its keys.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 28),
        actions,
      ],
    );
  }
}

/// A message the overview must show above everything else: a parked link
/// waiting for an unlock, or an error from startup.
class OverviewNotice extends StatelessWidget {
  const OverviewNotice({super.key, required this.message, this.error = false});

  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final color = error ? rustFor(context) : accentOf(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: ArgusColors.of(context).inset,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            error ? Icons.error_outline : Icons.info_outline,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              message,
              style: TextStyle(fontSize: 13.5, color: color),
            ),
          ),
        ],
      ),
    );
  }
}
