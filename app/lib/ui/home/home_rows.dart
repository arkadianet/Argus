import 'package:flutter/material.dart';

import '../../services/token_evidence.dart';
import '../../theme/argus_theme.dart';
import '../../theme/argus_tones.dart';
import '../token_avatar.dart';
import 'home_format.dart';
import 'home_models.dart';
import 'home_style.dart';
import 'home_widgets.dart';

/// One wallet on the overview: name and balance, then a line of facts and
/// the balance's value. A wallet holding funds away from its primary
/// address gets a quiet footnote saying so.
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
    final t = HomeText.of(context);
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
    } else if (!hidden && empty) {
      fact('Empty');
    } else if (!hidden && w.tokenCount > 0) {
      fact(countLabel(w.tokenCount, 'token'));
    }
    // Pending is emphasised by weight, not colour: the accent is kept
    // for the one thing on a screen to act on.
    if (showPending) fact(pendingLine(pending, hidden: hidden, short: true), TextStyle(color: t.ink, fontWeight: FontWeight.w500));
    if (w.asOf != null) fact('as${nbsp}of$nbsp${w.asOf}');

    final amount = nano == null ? '—' : (hidden ? maskedFigure : summaryErg(nano));
    final fiatValue = w.fiatValue;
    final fiat = fiatValue == null || empty ? null : (hidden ? '≈$nbsp$maskedFigure' : fiatFigure(fiatValue, currency));
    final note = w.otherAddresses == null ? null : otherAddressLine(w.otherAddresses!, hidden: hidden, compact: true);

    return HomeRow(
      inkKey: Key('overview-wallet-${w.id}'),
      onTap: onTap,
      onLongPress: onLongPress,
      hint: 'Opens the wallet',
      semanticLabel: spoken([
        w.name,
        if (w.unlocked) 'unlocked',
        if (w.watchOnly) 'watch-only',
        if (nano == null) 'balance unavailable' else if (hidden) 'balance hidden' else '$amount ERG',
        if (fiat != null && !hidden) 'about ${fiatFigure(fiatValue!, currency, approximate: false)} ${currency.code}',
        if (!hidden && empty) 'empty' else if (!hidden && w.tokenCount > 0) countLabel(w.tokenCount, 'token'),
        if (showPending) pendingLine(pending, hidden: hidden),
        if (w.asOf != null) 'as of ${w.asOf}',
        if (note != null) 'incl. $note',
      ].join(', ')),
      leading: WalletMark(name: w.name, kind: w.kind),
      title: Row(
        children: [
          Flexible(child: Text(w.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.primary)),
          if (w.unlocked) ...[
            const SizedBox(width: 6),
            Icon(Icons.lock_open_rounded, size: 14, color: mossFor(context)),
          ],
        ],
      ),
      subtitle: facts.isEmpty ? null : TextSpan(children: facts),
      figure: TextSpan(
        children: [
          TextSpan(text: amount),
          TextSpan(text: '${nbsp}ERG', style: t.secondary),
        ],
      ),
      subfigure: fiat == null ? null : TextSpan(text: fiat),
      footnote: note == null
          ? null
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(Icons.subdirectory_arrow_right, size: 14, color: t.muted),
                ),
                const SizedBox(width: 4),
                Expanded(child: Text(note, style: t.secondary)),
              ],
            ),
    );
  }
}

/// The last row of the wallet list: one quiet way to add a wallet, which
/// opens the choice of creating, restoring or watching one.
class AddWalletRow extends StatelessWidget {
  const AddWalletRow({super.key, required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    return HomeRow(
      inkKey: const Key('overview-add-wallet'),
      onTap: onTap,
      semanticLabel: 'Add a wallet: create, restore or watch',
      leading: HomeDisc(child: Icon(Icons.add, size: 18, color: t.ink)),
      title: Text('Add a wallet', style: t.primary),
      subtitle: const TextSpan(text: 'Create, restore or watch'),
    );
  }
}

/// One holding: mark, ticker and name, then the amount and its value on
/// the shared right edge. ERG's detail line is its price and 24h change.
class HomeAssetRow extends StatelessWidget {
  const HomeAssetRow({super.key, required this.asset, required this.currency, this.hidden = false, this.onTap});

  final AssetRowData asset;
  final FiatCurrency currency;
  final bool hidden;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    final colors = ArgusColors.of(context);
    final isErg = asset.kind == AssetKind.erg;
    // Names are the issuer's words: stripped of bidi and control characters
    // before display, as the token sheet does.
    final ticker = hidden ? maskedFigure : issuerText(asset.ticker, limit: 64);
    final name = hidden ? maskedFigure : issuerText(asset.name ?? '', limit: 96);
    final amount = hidden ? maskedFigure : summaryAmount(asset.amount, asset.decimals);
    final value = asset.fiatValue;
    final fiat = value == null ? null : (hidden ? '≈$nbsp$maskedFigure' : fiatFigure(value, currency));
    final unit = asset.unitFiat;
    final change = asset.changePercent;
    final lp = asset.kind == AssetKind.lpShare;

    final InlineSpan? detail;
    if (!hidden && unit != null) {
      detail = TextSpan(
        children: [
          TextSpan(text: ergPriceFigure(unit, currency)),
          if (change != null)
            TextSpan(
              text: '  ${percentChange(change)}',
              style: TextStyle(color: change >= 0 ? mossFor(context) : rustFor(context), fontWeight: FontWeight.w500),
            ),
        ],
      );
    } else {
      detail = name.isEmpty ? null : TextSpan(text: name);
    }

    return HomeRow(
      inkKey: Key('home-asset-${asset.id}'),
      onTap: hidden ? null : onTap,
      semanticLabel: hidden
          ? 'Asset hidden'
          : spoken([
              ticker,
              if (asset.verified && !isErg) 'verified',
              if (asset.caution) 'caution, named like a verified token',
              if (lp) 'liquidity pool share',
              if (unit != null)
                'price ${fiatFigure(unit, currency, approximate: false)}${change == null ? '' : ', ${change >= 0 ? 'up' : 'down'} ${change.abs().toStringAsFixed(1)}% over 24h'}'
              else if (name.isNotEmpty && name != ticker)
                name,
              amount,
              if (value != null) 'about ${fiatFigure(value, currency, approximate: false)} ${currency.code}',
            ].join(', ')),
      leading: ExcludeSemantics(
        child: TokenAvatar(
          label: hidden ? '?' : asset.ticker,
          tokenId: hidden || isErg ? null : asset.id,
          isErg: isErg && !hidden,
          radius: homeMarkSize / 2,
        ),
      ),
      title: Row(
        children: [
          Flexible(child: Text(ticker, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.primary)),
          if (!hidden && asset.verified && !isErg) ...[
            const SizedBox(width: 4),
            Icon(Icons.verified, size: 14, color: colors.accent),
          ],
          if (!hidden && asset.caution) ...[
            const SizedBox(width: 4),
            const Icon(Icons.warning_amber_rounded, size: 14, color: rust),
          ],
          if (!hidden && lp) ...[
            const SizedBox(width: 6),
            Text('LP', style: t.label.copyWith(letterSpacing: 1)),
          ],
        ],
      ),
      subtitle: detail,
      figure: TextSpan(text: amount),
      subfigure: fiat == null ? null : TextSpan(text: fiat),
    );
  }
}

/// One transaction, read like a statement line: what happened, when and
/// with whom on the left, what moved on the right. The time comes before
/// the counterparty so that a long address, not the time, gives way.
class HomeActivityRow extends StatelessWidget {
  const HomeActivityRow({super.key, required this.item, this.hidden = false, this.onTap});

  final ActivityRowData item;
  final bool hidden;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = HomeText.of(context);
    // Same marks and tints as the Activity tab's rows; only direction is
    // coloured, so a swap or a mix stays neutral.
    final (IconData icon, Color tint) = switch (item.kind) {
      ActivityKind.received => (Icons.arrow_downward, mossFor(context)),
      ActivityKind.sent => (Icons.arrow_upward, rustFor(context)),
      ActivityKind.swap => (Icons.swap_horiz, t.muted),
      ActivityKind.mix => (Icons.blender_outlined, t.muted),
      ActivityKind.selfTransfer => (Icons.sync_alt, t.muted),
      ActivityKind.contract => (Icons.code, t.muted),
    };
    String leg(AmountLeg l) => '${signedSummaryAmount(l.amount, l.decimals)}$nbsp${issuerText(l.unit, limit: 32)}';
    final legs = item.legs;
    final primary = legs.isEmpty ? '0${nbsp}ERG' : (hidden ? maskedFigure : leg(legs.first));
    final incoming = legs.isNotEmpty && legs.first.amount > BigInt.zero;
    final more = legs.length > 2 ? ' + ${legs.length - 2}${nbsp}more' : '';
    final secondary = legs.length < 2 || hidden ? null : '${leg(legs[1])}$more';

    return HomeRow(
      inkKey: Key('home-activity-${item.id}'),
      onTap: onTap,
      semanticLabel: spoken([
        item.title,
        if (item.pending) 'pending',
        if (hidden) 'amount hidden' else ...[primary, ?secondary],
        ?item.counterparty,
        item.time,
      ].join(', ')),
      leading: HomeDisc(fill: tint.withValues(alpha: 0.13), child: Icon(icon, size: 16, color: tint)),
      title: Text(item.title, style: t.primary),
      subtitle: TextSpan(
        children: [
          if (item.pending) TextSpan(text: 'Pending  ·  ', style: TextStyle(color: t.ink, fontWeight: FontWeight.w500)),
          TextSpan(text: item.time),
          if (item.counterparty != null) TextSpan(text: '  ·  ${item.counterparty}'),
        ],
      ),
      figure: TextSpan(text: primary, style: incoming && !hidden ? TextStyle(color: mossFor(context)) : null),
      subfigure: secondary == null ? null : TextSpan(text: secondary),
    );
  }
}
