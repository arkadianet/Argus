import 'package:flutter/material.dart';

import '../../format.dart';
import '../../services/address_holdings.dart';
import '../../services/pending_balance.dart';
import '../../services/wallet_sync_controller.dart';
import '../../theme/argus_theme.dart';
import '../widgets/discover_sheet.dart';
import '../widgets/empty_state.dart';
import '../widgets/erg_rate_line.dart';
import '../widgets/pending_balance_line.dart';
import '../widgets/soft_card.dart';
import '../widgets/activity_tile.dart';
import 'address_breakdown.dart';

// The wallet page, one section per widget. Each takes plain figures and
// callbacks and reads no service of its own, so the page can be recomposed
// or restyled without touching how its data is gathered.

/// "Assets · Main" with an optional "View all ›" on the right.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action, this.onTap});

  final String title;
  final String? action;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Newsreader',
              fontWeight: FontWeight.w600,
              fontSize: 20,
            ),
          ),
        ),
        if (action != null)
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    action!,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: accentOf(context)),
                  ),
                  const SizedBox(width: 2),
                  Icon(Icons.chevron_right, size: 18, color: accentOf(context)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// The small tinted square button used for the hide-balances toggle.
class IconCircle extends StatelessWidget {
  const IconCircle({super.key, required this.icon, this.onTap, this.tooltip});

  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final button = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: dark ? watchfulSurface : bannerTint,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          icon,
          size: 19,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// A headline ERG figure with its unit. A long figure shrinks to fit rather
/// than losing digits to an ellipsis: a balance must never be cut short.
class ErgFigure extends StatelessWidget {
  const ErgFigure({
    super.key,
    required this.text,
    this.textKey,
    this.loading = false,
    this.fontSize = 44,
  });

  final String text;
  final Key? textKey;

  /// No figure yet and one on its way: a placeholder bar, not a zero.
  final bool loading;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Flexible(
          child: loading
              ? Container(
                  width: 150,
                  height: 34,
                  margin: const EdgeInsets.only(bottom: 6),
                  decoration: BoxDecoration(
                    color: muted.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(8),
                  ),
                )
              : FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.bottomLeft,
                  child: Text(
                    text,
                    key: textKey,
                    maxLines: 1,
                    style: Theme.of(
                      context,
                    ).textTheme.displayLarge?.copyWith(fontSize: fontSize),
                  ),
                ),
        ),
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'ERG',
            style: TextStyle(
              fontFamily: 'Newsreader',
              fontSize: 18,
              color: muted,
            ),
          ),
        ),
      ],
    );
  }
}

/// The address a wallet is shown as, with its pinned index when it has one.
class WalletIdentityLine extends StatelessWidget {
  const WalletIdentityLine({
    super.key,
    required this.address,
    this.pinnedIndex,
  });

  final String address;

  /// Shown as "#275" when the identity is a pinned address.
  final int? pinnedIndex;

  @override
  Widget build(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    return Row(
      children: [
        if (pinnedIndex != null && pinnedIndex! > 0) ...[
          Icon(Icons.push_pin_outlined, size: 13, color: muted),
          const SizedBox(width: 3),
          Text('#$pinnedIndex', style: TextStyle(fontSize: 12, color: muted)),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            shorten(address, head: 8, tail: 6),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: monoStyle(context, size: 12).copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

/// The wallet's own balance: one big figure, what it is worth, how it splits,
/// the address it is shown as, and the sync strip underneath.
class WalletBalanceCard extends StatelessWidget {
  const WalletBalanceCard({
    super.key,
    required this.label,
    required this.balanceNano,
    required this.hidden,
    required this.onToggleHidden,
    this.loading = false,
    this.valueLine,
    this.breakdownLine,
    this.pending,
    this.identity,
    this.elsewhere,
    this.onElsewhere,
    this.footer,
  });

  /// "BALANCE", or "WATCH-ONLY" for a watched wallet.
  final String label;
  final int? balanceNano;
  final bool hidden;
  final VoidCallback onToggleHidden;

  /// No figure yet and one on its way: a placeholder bar, not a zero.
  final bool loading;

  /// Fiat value and its caveats, already worded.
  final String? valueLine;

  /// "1.012 public · 1 stealth", when there is more than one pocket.
  final String? breakdownLine;

  /// What is still in the mempool, split against [balanceNano]: "+2.5 ERG
  /// pending · 105.21 confirmed". Nothing shows while nothing is pending.
  final PendingBalance? pending;
  final WalletIdentityLine? identity;

  /// Funds on other addresses of this wallet, and what tapping that line does.
  final FundsElsewhere? elsewhere;
  final VoidCallback? onElsewhere;

  /// Sync and network status, below the figures.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    return SoftCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: Theme.of(
                        context,
                      ).textTheme.titleSmall?.copyWith(color: muted),
                    ),
                    const SizedBox(height: 8),
                    ErgFigure(
                      key: const Key('wallet-balance-figure'),
                      text: hidden
                          ? '••••••'
                          : formatErg(balanceNano, unit: false, maxFrac: 4),
                      textKey: const Key('wallet-balance'),
                      loading: loading,
                    ),
                    if (valueLine != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        valueLine!,
                        style: TextStyle(fontSize: 14, color: muted),
                      ),
                    ],
                    const SizedBox(height: 2),
                    const ErgRateLine(),
                    if (breakdownLine != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        breakdownLine!,
                        style: TextStyle(fontSize: 13, color: muted),
                      ),
                    ],
                    if (balanceNano != null &&
                        (pending?.hasPending ?? false)) ...[
                      const SizedBox(height: 2),
                      PendingBalanceLine(
                        key: const Key('wallet-balance-pending'),
                        pending: pending,
                        hidden: hidden,
                      ),
                    ],
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
          if (identity != null) ...[const SizedBox(height: 10), identity!],
          if (elsewhere != null) ...[
            const SizedBox(height: 4),
            FundsElsewhereLink(
              funds: elsewhere!,
              hidden: hidden,
              onTap: onElsewhere,
            ),
          ],
          if (footer != null) ...[const SizedBox(height: 14), footer!],
        ],
      ),
    );
  }
}

/// Sync, block and UTXO line in the balance card, with the pinned-address
/// warning above it when the pin cannot be derived.
class WalletStatusStrip extends StatelessWidget {
  const WalletStatusStrip({
    super.key,
    required this.status,
    this.pinIssue,
    this.onPinIssue,
    this.onStatus,
    this.onNetwork,
  });

  final SyncStatusLine status;
  final String? pinIssue;
  final VoidCallback? onPinIssue;

  /// Opens the UTXO tools from the status line.
  final VoidCallback? onStatus;
  final VoidCallback? onNetwork;

  @override
  Widget build(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (pinIssue != null) ...[
          InkWell(
            onTap: onPinIssue,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(Icons.push_pin_outlined, size: 14, color: rust),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      pinIssue!,
                      style: TextStyle(fontSize: 12.5, color: rust),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: ArgusColors.of(context).inset,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 0,
            runSpacing: 4,
            children: [
              InkWell(
                onTap: onStatus,
                borderRadius: BorderRadius.circular(8),
                child: status,
              ),
              if (onNetwork != null) ...[
                const SizedBox(width: 8),
                InkWell(
                  onTap: onNetwork,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Network',
                          style: TextStyle(fontSize: 12.5, color: muted),
                        ),
                        Icon(Icons.chevron_right, size: 16, color: muted),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// A plain status line for a watched wallet: no sync phases, no UTXOs.
class WatchedStatusStrip extends StatelessWidget {
  const WatchedStatusStrip({super.key, required this.lines, this.error});

  /// "Watch-only · cannot sign here", "Updated 2m ago", ...
  final List<String> lines;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    final style = TextStyle(fontSize: 12.5, color: muted);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: ArgusColors.of(context).inset,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.visibility_outlined, size: 13, color: muted),
                  const SizedBox(width: 4),
                  Flexible(child: Text(lines.first, style: style)),
                ],
              ),
              for (final line in lines.skip(1)) Text(line, style: style),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 4),
            Text(error!, style: style.copyWith(color: rustFor(context))),
          ],
        ],
      ),
    );
  }
}

/// Primary actions for a wallet without a key on this device. Labels may run
/// to two lines: "Send with offline signer" does not fit a single half-width
/// button, and an ellipsised action name is no name at all.
class WatchOnlyActions extends StatelessWidget {
  const WatchOnlyActions({
    super.key,
    required this.onSend,
    required this.onReceive,
  });

  /// Null while the action cannot work, e.g. before an account's first scan.
  final VoidCallback? onSend;
  final VoidCallback? onReceive;

  @override
  Widget build(BuildContext context) {
    Widget button(Key key, IconData icon, String label, VoidCallback? onTap) =>
        FilledButton.icon(
          key: key,
          onPressed: onTap,
          icon: Icon(icon, size: 17),
          label: Text(label, maxLines: 2, textAlign: TextAlign.center),
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 50),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            textStyle: const TextStyle(
              fontFamily: 'Karla',
              fontWeight: FontWeight.w500,
              fontSize: 14.5,
            ),
          ),
        );
    final send = button(
      const Key('watch-action-send'),
      Icons.north_east,
      'Send with offline signer',
      onSend,
    );
    final receive = button(
      const Key('watch-action-receive'),
      Icons.south_west,
      'Receive',
      onReceive,
    );
    // Large text: one full-width button each, so neither label is cut.
    if (MediaQuery.textScalerOf(context).scale(10) > 13) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [send, const SizedBox(height: 10), receive],
      );
    }
    // Equal heights, whichever label wraps.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: send),
          const SizedBox(width: 10),
          Expanded(child: receive),
        ],
      ),
    );
  }
}

/// A quiet explanation under the actions: what this wallet can and cannot do.
class WalletNotice extends StatelessWidget {
  const WalletNotice({
    super.key,
    required this.lines,
    this.icon = Icons.info_outline,
  });

  final List<String> lines;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 15, color: muted),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      line,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.35,
                        color: muted,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The first few holdings, ERG first, and a way to all of them.
class AssetsSection extends StatelessWidget {
  const AssetsSection({
    super.key,
    required this.title,
    required this.tiles,
    required this.total,
    this.onViewAll,
    this.empty,
  });

  final String title;

  /// Tiles already capped to what the home shows.
  final List<Widget> tiles;

  /// How many holdings there are in all, for "View all (12)".
  final int total;
  final VoidCallback? onViewAll;

  /// Shown instead of the tiles when there are none.
  final Widget? empty;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title,
          action: onViewAll == null
              ? null
              : total > tiles.length
              ? 'View all ($total)'
              : 'View all',
          onTap: onViewAll,
        ),
        const SizedBox(height: 10),
        SoftCard(
          padding: tiles.isEmpty && empty != null ? null : EdgeInsets.zero,
          child: tiles.isEmpty && empty != null
              ? empty!
              : DividedColumn(children: tiles),
        ),
      ],
    );
  }
}

/// The latest few transactions, or an invitation to receive the first one.
class RecentActivitySection extends StatelessWidget {
  const RecentActivitySection({
    super.key,
    required this.rows,
    required this.hidden,
    required this.onOpen,
    this.onViewAll,
    this.emptyBody = 'Share your address to receive your first ERG.',
    this.emptyActionLabel,
    this.onEmptyAction,
    this.loading = false,
    this.error,
  });

  final List<Map<String, dynamic>> rows;
  final bool hidden;
  final ValueChanged<Map<String, dynamic>> onOpen;
  final VoidCallback? onViewAll;
  final String emptyBody;
  final String? emptyActionLabel;
  final VoidCallback? onEmptyAction;

  /// Nothing read yet: a spinner rather than "No activity yet".
  final bool loading;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          'Recent activity',
          action: rows.isNotEmpty && onViewAll != null ? 'View all' : null,
          onTap: onViewAll,
        ),
        const SizedBox(height: 10),
        if (rows.isEmpty && loading)
          const SoftCard(
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (rows.isEmpty)
          SoftCard(
            child: EmptyState(
              compact: true,
              icon: error == null
                  ? Icons.inbox_outlined
                  : Icons.cloud_off_outlined,
              title: error == null ? 'No activity yet' : 'Activity unavailable',
              body: error ?? emptyBody,
              actionLabel: emptyActionLabel,
              onAction: onEmptyAction,
            ),
          )
        else
          SoftCard(
            padding: EdgeInsets.zero,
            child: DividedColumn(
              children: [
                for (final tx in rows)
                  ActivityTile(tx: tx, hidden: hidden, onTap: () => onOpen(tx)),
              ],
            ),
          ),
      ],
    );
  }
}

/// One card in the Discover strip.
class DiscoverCardData {
  const DiscoverCardData(this.feature, {this.subtitle});
  final DiscoverFeature feature;

  /// The wallet's own position in the feature, else its blurb is shown.
  final String? subtitle;
}

/// The horizontal strip of protocol cards.
class DiscoverSection extends StatelessWidget {
  const DiscoverSection({
    super.key,
    required this.cards,
    required this.onExplain,
    this.onExploreAll,
  });

  final List<DiscoverCardData> cards;
  final ValueChanged<DiscoverFeature> onExplain;
  final VoidCallback? onExploreAll;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          'Discover',
          action: onExploreAll == null ? null : 'Explore all',
          onTap: onExploreAll,
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 168,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final card in cards)
                DiscoverCard(
                  feature: card.feature,
                  subtitle: card.subtitle,
                  onTap: () => onExplain(card.feature),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A card opens the feature's explainer; [subtitle] is the wallet's own
/// position when it has one, else the feature's blurb.
class DiscoverCard extends StatelessWidget {
  const DiscoverCard({
    super.key,
    required this.feature,
    required this.onTap,
    this.subtitle,
  });

  final DiscoverFeature feature;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final e = discoverExplainers[feature]!;
    final line = subtitle ?? e.blurb;
    final muted = ArgusColors.of(context).muted;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: 168,
      margin: const EdgeInsets.only(right: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: ArgusColors.of(context).cardBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: dark ? watchfulSurface : bannerTint,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(e.icon, size: 19, color: accentOf(context)),
              ),
              const SizedBox(height: 10),
              Text(
                e.title,
                style: const TextStyle(
                  fontFamily: 'Newsreader',
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 3),
              Expanded(
                child: Text(
                  line,
                  style: TextStyle(fontSize: 12, height: 1.3, color: muted),
                ),
              ),
              Row(
                children: [
                  Text(
                    'What is this?',
                    style: TextStyle(fontSize: 12, color: accentOf(context)),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.arrow_forward, size: 14, color: accentOf(context)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tools that act on this wallet's own coins and tokens.
class ToolsSection extends StatelessWidget {
  const ToolsSection({
    super.key,
    required this.features,
    required this.onOpen,
    required this.onExplain,
  });

  final List<DiscoverFeature> features;
  final ValueChanged<DiscoverFeature> onOpen;
  final ValueChanged<DiscoverFeature> onExplain;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('Tools'),
        const SizedBox(height: 10),
        SoftCard(
          padding: EdgeInsets.zero,
          // A tile draws its tap ripple on the nearest Material above it,
          // and the card's own background would hide it.
          child: Material(
            type: MaterialType.transparency,
            child: DividedColumn(
              children: [
                for (final f in features)
                  ListTile(
                    key: Key('tool-${f.name}'),
                    leading: Icon(
                      discoverExplainers[f]!.icon,
                      color: accentOf(context),
                    ),
                    title: Text(discoverExplainers[f]!.title),
                    subtitle: Text(
                      discoverExplainers[f]!.blurb,
                      style: TextStyle(
                        fontSize: 12,
                        color: ArgusColors.of(context).muted,
                      ),
                    ),
                    trailing: IconButton(
                      tooltip: 'What is this?',
                      icon: const Icon(Icons.info_outline, size: 18),
                      onPressed: () => onExplain(f),
                    ),
                    onTap: () => onOpen(f),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Addresses this wallet has used, each with its label; tapping one labels it.
class AddressesSection extends StatelessWidget {
  const AddressesSection({
    super.key,
    required this.rows,
    required this.hidden,
    required this.labelFor,
    this.onTap,
    this.title = 'Addresses',
  });

  /// `{address, balance_nano_erg}` maps, as discovery reports them.
  final List<Map<String, dynamic>> rows;
  final bool hidden;
  final String? Function(String address) labelFor;
  final ValueChanged<String>? onTap;
  final String title;

  @override
  Widget build(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title),
        const SizedBox(height: 10),
        SoftCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 16),
                () {
                  final addr = rows[i]['address']?.toString() ?? '';
                  final nano = (rows[i]['balance_nano_erg'] as num?)?.toInt();
                  final label = labelFor(addr);
                  return InkWell(
                    onTap: onTap == null ? null : () => onTap!(addr),
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  shorten(addr, head: 10, tail: 8),
                                  style: monoStyle(context, size: 12.5),
                                ),
                                if (label != null && label.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    label,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: muted,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (nano != null)
                            Text(
                              hidden ? '••••' : formatErg(nano, maxFrac: 4),
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                        ],
                      ),
                    ),
                  );
                }(),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Status, block height, UTXO count and sync age on one wrapping line.
class SyncStatusLine extends StatelessWidget {
  const SyncStatusLine({
    super.key,
    required this.status,
    required this.statusColor,
    required this.height,
    required this.count,
    required this.fragmented,
    required this.age,
  });

  /// Keeps the last successful age visible while the next sync is in flight.
  factory SyncStatusLine.wallet({
    Key? key,
    required WalletSyncController sync,
    required bool online,
    required Color statusColor,
    required int? height,
    required bool fragmented,
  }) => SyncStatusLine(
    key: key,
    status: sync.statusLabel(online: online),
    statusColor: statusColor,
    height: height,
    count: sync.utxoCount,
    fragmented: fragmented,
    age: formatSyncAge(sync.lastSyncedAt),
  );

  final String status;
  final Color statusColor;
  final int? height;
  final int count;
  final bool fragmented;
  final String age;

  @override
  Widget build(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    final style = TextStyle(fontSize: 12.5, color: muted);
    return Wrap(
      spacing: 10,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // Each segment keeps its icon with its label, and the label itself
        // gives way at large text sizes rather than running off the line.
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 8, color: statusColor),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                status,
                style: style.copyWith(fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inventory_2_outlined, size: 13, color: muted),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                height == null
                    ? 'Block unavailable'
                    : 'Block ${formatWithCommas(height!)}',
                style: style,
              ),
            ),
          ],
        ),
        Text(
          '$count UTXOs${fragmented ? ' · Fragmented' : ''}',
          style: style.copyWith(
            color: fragmented ? rustFor(context) : muted,
            fontWeight: fragmented ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        if (age.isNotEmpty) Text(age, style: style),
      ],
    );
  }
}
