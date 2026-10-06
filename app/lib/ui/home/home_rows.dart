import 'package:flutter/material.dart';

import '../../services/token_evidence.dart';
import '../../theme/argus_theme.dart';
import '../../theme/argus_tones.dart';
import 'home_format.dart';
import 'home_models.dart';
import 'home_widgets.dart';

/// Text scale above which a row stacks its figures under its name: two
/// columns of large text leave the name a few letters wide.
const _stackAtScale = 1.35;

bool _stacked(BuildContext context) => MediaQuery.textScalerOf(context).scale(14) / 14 > _stackAtScale;

/// One wallet on the overview, set as two aligned lines: name and balance,
/// then a line of facts and the balance's value. A wallet holding funds
/// away from its primary address gets a quiet third line saying so.
class OverviewWalletRow extends StatelessWidget {
  const OverviewWalletRow({
    super.key,
    required this.wallet,
    required this.currency,
    this.hidden = false,
    this.onTap,
    this.onLongPress,
  });

  final WalletSummary wallet;
  final FiatCurrency currency;
  final bool hidden;
  final VoidCallback? onTap;

  /// Rename or remove without opening (and unlocking) the wallet.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    final ink = Theme.of(context).colorScheme.onSurface;
    final w = wallet;
    final nano = w.nanoErg;
    final empty = nano == 0 && w.tokenCount == 0;
    final pending = w.pending;
    final showPending = pending != null && !pending.isEmpty;

    final facts = <InlineSpan>[];
    void fact(String text, [TextStyle? style]) {
      if (facts.isNotEmpty) facts.add(const TextSpan(text: '  ·  '));
      facts.add(TextSpan(text: text, style: style));
    }

    // Hidden balances drop "Empty" and the token count as well as the
    // figures: either tells an onlooker as much as an amount would.
    if (w.watchOnly) fact('Watch-only');
    if (nano == null) {
      fact('Balance unavailable');
    } else if (hidden) {
      // Nothing about size.
    } else if (empty) {
      fact('Empty');
    } else if (w.tokenCount > 0) {
      fact(countLabel(w.tokenCount, 'token'));
    }
    if (showPending) {
      fact(
        pendingLine(pending, hidden: hidden, short: true),
        TextStyle(color: colors.accentText, fontWeight: FontWeight.w500),
      );
    }
    if (w.asOf != null) fact('as${nbsp}of$nbsp${w.asOf}');

    final amount = nano == null ? '—' : (hidden ? maskedFigure : summaryErg(nano));
    final fiatValue = w.fiatValue;
    final fiat = fiatValue == null || empty ? null : (hidden ? '≈$nbsp$maskedFigure' : fiatFigure(fiatValue, currency));
    final note = w.otherAddresses == null ? null : otherAddressLine(w.otherAddresses!, hidden: hidden, compact: true);

    final spokenLabel = spoken([
      w.name,
      if (w.unlocked) 'unlocked',
      if (w.watchOnly) 'watch-only',
      if (nano == null) 'balance unavailable' else if (hidden) 'balance hidden' else '$amount ERG',
      if (fiat != null && !hidden) 'about ${fiatFigure(fiatValue!, currency, approximate: false)} ${currency.code}',
      if (!hidden && empty) 'empty' else if (!hidden && w.tokenCount > 0) countLabel(w.tokenCount, 'token'),
      if (showPending) pendingLine(pending, hidden: hidden),
      if (w.asOf != null) 'as of ${w.asOf}',
      if (note != null) 'incl. $note',
    ].join(', '));

    final stacked = _stacked(context);
    final name = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            w.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: ink),
          ),
        ),
        if (w.unlocked) ...[
          const SizedBox(width: 6),
          Icon(Icons.lock_open_rounded, size: 14, color: mossFor(context)),
        ],
      ],
    );
    final factLine = facts.isEmpty
        ? null
        : Text.rich(TextSpan(children: facts), style: TextStyle(fontSize: 12.5, height: 1.35, color: colors.muted));
    final amountText = Text.rich(
      TextSpan(
        children: [
          TextSpan(text: amount),
          TextSpan(
            text: '${nbsp}ERG',
            style: TextStyle(fontFamily: 'Karla', fontSize: 12, fontWeight: FontWeight.w500, color: colors.muted),
          ),
        ],
      ),
      style: TextStyle(
        fontFamily: 'Newsreader',
        fontWeight: FontWeight.w600,
        fontSize: 18,
        height: 1.2,
        color: ink,
        fontFeatures: tabularFigures,
      ),
    );
    final fiatText = fiat == null
        ? null
        : Text(fiat, style: TextStyle(fontSize: 12.5, height: 1.35, color: colors.muted, fontFeatures: tabularFigures));

    final Widget body;
    if (stacked) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          name,
          if (factLine != null) ...[const SizedBox(height: 2), factLine],
          const SizedBox(height: 6),
          amountText,
          ?fiatText,
        ],
      );
    } else {
      body = Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(child: name),
              const SizedBox(width: 12),
              amountText,
            ],
          ),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(child: factLine ?? const SizedBox.shrink()),
              if (fiatText != null) ...[const SizedBox(width: 12), fiatText],
            ],
          ),
        ],
      );
    }

    return TappableNode(
      label: spokenLabel,
      hint: 'Opens the wallet',
      onTap: onTap,
      onLongPress: onLongPress,
      child: InkWell(
        key: Key('overview-wallet-${w.id}'),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: stacked ? CrossAxisAlignment.start : CrossAxisAlignment.center,
                children: [
                  WalletMark(name: w.name, kind: w.kind),
                  const SizedBox(width: 12),
                  Expanded(child: body),
                  const SizedBox(width: 2),
                  Icon(Icons.chevron_right, size: 20, color: colors.muted),
                ],
              ),
              if (note != null)
                Padding(
                  padding: const EdgeInsets.only(left: 52, top: 8, right: 22),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 1.5),
                        child: Icon(Icons.account_tree_outlined, size: 14, color: colors.muted),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(note, style: TextStyle(fontSize: 12.5, height: 1.35, color: colors.muted)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lets a figures column take what it needs up to just under half the
/// row, so a long amount ellipsizes before it pushes the name out, and a
/// short one leaves the name the rest of the line. (An [Expanded] beside
/// a [Flexible] would split the line in half regardless.)
class _FiguresColumn extends StatelessWidget {
  const _FiguresColumn({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final rowWidth = MediaQuery.sizeOf(context).width;
    return ConstrainedBox(constraints: BoxConstraints(maxWidth: rowWidth * 0.42), child: child);
  }
}

/// One holding on the wallet page: mark, ticker and name on the left, the
/// amount and its value on the right. The ticker is not repeated after
/// the amount, which keeps long LP names from crowding the figure out.
class HomeAssetRow extends StatelessWidget {
  const HomeAssetRow({super.key, required this.asset, required this.currency, this.hidden = false, this.onTap});

  final AssetRowData asset;
  final FiatCurrency currency;
  final bool hidden;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    final ink = Theme.of(context).colorScheme.onSurface;
    final isErg = asset.kind == AssetKind.erg;
    // Names are the issuer's words: stripped of bidi and control characters
    // before display, as the token sheet does.
    final ticker = hidden ? maskedFigure : issuerText(asset.ticker, limit: 64);
    final name = hidden ? maskedFigure : issuerText(asset.name ?? '', limit: 96);
    final amount = hidden ? maskedFigure : summaryAmount(asset.amount, asset.decimals);
    final value = asset.fiatValue;
    final fiat = value == null ? null : (hidden ? '≈$nbsp$maskedFigure' : fiatFigure(value, currency));
    final stacked = _stacked(context);

    final spokenLabel = hidden
        ? 'Asset hidden'
        : spoken([
            ticker,
            if (asset.verified && !isErg) 'verified',
            if (asset.caution) 'caution, named like a verified token',
            if (asset.kind == AssetKind.lpShare) 'liquidity pool share',
            if (name.isNotEmpty && name != ticker) name,
            amount,
            if (value != null) 'about ${fiatFigure(value, currency, approximate: false)} ${currency.code}',
          ].join(', '));

    final title = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            ticker,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: ink),
          ),
        ),
        if (!hidden && asset.verified && !isErg) ...[
          const SizedBox(width: 4),
          Icon(Icons.verified, size: 15, color: colors.accent),
        ],
        if (!hidden && asset.caution) ...[
          const SizedBox(width: 4),
          const Icon(Icons.warning_amber_rounded, size: 15, color: rust),
        ],
        if (!hidden && asset.kind == AssetKind.lpShare) ...[
          const SizedBox(width: 6),
          const HomeChip(label: 'LP', tone: HomeChipTone.quiet, dense: true),
        ],
      ],
    );
    final figures = Column(
      crossAxisAlignment: stacked ? CrossAxisAlignment.start : CrossAxisAlignment.end,
      children: [
        Text(
          amount,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontWeight: FontWeight.w500, fontSize: 15, color: ink, fontFeatures: tabularFigures),
        ),
        if (fiat != null)
          Text(fiat, style: TextStyle(fontSize: 12.5, color: colors.muted, fontFeatures: tabularFigures)),
      ],
    );

    return TappableNode(
      label: spokenLabel,
      onTap: hidden ? null : onTap,
      child: InkWell(
        key: Key('home-asset-${asset.id}'),
        onTap: hidden ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: stacked ? CrossAxisAlignment.start : CrossAxisAlignment.center,
            children: [
              HomeTokenMark(tokenId: hidden || isErg ? null : asset.id, isErg: isErg && !hidden),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    title,
                    if (name.isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: colors.muted),
                      ),
                    ],
                    if (stacked) ...[const SizedBox(height: 4), figures],
                  ],
                ),
              ),
              if (!stacked) ...[
                const SizedBox(width: 12),
                _FiguresColumn(child: figures),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One transaction in Recent activity, read like a statement line: what
/// happened, when and with whom on the left, what moved on the right.
/// The time comes before the counterparty so that a long address, not
/// the time, is what gives way.
class HomeActivityRow extends StatelessWidget {
  const HomeActivityRow({super.key, required this.item, this.hidden = false, this.onTap});

  final ActivityRowData item;
  final bool hidden;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    final ink = Theme.of(context).colorScheme.onSurface;
    // Same marks and tints as the Activity tab's rows.
    final (IconData icon, Color tint) = switch (item.kind) {
      ActivityKind.received => (Icons.arrow_downward, mossFor(context)),
      ActivityKind.sent => (Icons.arrow_upward, rustFor(context)),
      ActivityKind.swap => (Icons.swap_horiz, colors.accentText),
      ActivityKind.mix => (Icons.blender_outlined, colors.accentText),
      ActivityKind.selfTransfer => (Icons.sync_alt, colors.muted),
      ActivityKind.contract => (Icons.code, colors.muted),
    };
    String leg(AmountLeg l) => '${signedSummaryAmount(l.amount, l.decimals)}$nbsp${issuerText(l.unit, limit: 32)}';
    final legs = item.legs;
    final primary = legs.isEmpty ? '0${nbsp}ERG' : (hidden ? maskedFigure : leg(legs.first));
    final incoming = legs.isNotEmpty && legs.first.amount > BigInt.zero;
    final more = legs.length > 2 ? ' + ${legs.length - 2}${nbsp}more' : '';
    final secondary = legs.length < 2 || hidden ? null : '${leg(legs[1])}$more';
    final subtitle = [item.time, ?item.counterparty].join('  ·  ');
    final stacked = _stacked(context);

    final spokenLabel = spoken([
      item.title,
      if (item.pending) 'pending',
      if (hidden) 'amount hidden' else ...[primary, ?secondary],
      ?item.counterparty,
      item.time,
    ].join(', '));

    final figures = Column(
      crossAxisAlignment: stacked ? CrossAxisAlignment.start : CrossAxisAlignment.end,
      children: [
        Text(
          primary,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w500,
            fontSize: 15,
            color: incoming && !hidden ? mossFor(context) : ink,
            fontFeatures: tabularFigures,
          ),
        ),
        if (secondary != null)
          Text(
            secondary,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, color: colors.muted, fontFeatures: tabularFigures),
          ),
      ],
    );

    return TappableNode(
      label: spokenLabel,
      onTap: onTap,
      child: InkWell(
        key: Key('home-activity-${item.id}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: stacked ? CrossAxisAlignment.start : CrossAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: tint.withValues(alpha: 0.13),
                child: Icon(icon, size: 17, color: tint),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(item.title, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: ink)),
                        if (item.pending) const HomeChip(label: 'Pending', icon: Icons.schedule, dense: true),
                      ],
                    ),
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      maxLines: stacked ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: colors.muted),
                    ),
                    if (stacked) ...[const SizedBox(height: 4), figures],
                  ],
                ),
              ),
              if (!stacked) ...[
                const SizedBox(width: 12),
                _FiguresColumn(child: figures),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
