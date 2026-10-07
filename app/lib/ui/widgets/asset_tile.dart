import 'package:flutter/material.dart';

import '../../format.dart';
import '../../services/token_metadata.dart';
import '../../services/verified_tokens.dart';
import '../../services/wallet_service.dart';
import '../../theme/argus_theme.dart';
import '../token_avatar.dart';

/// Short display symbol for a token: the first word of its name, or the
/// start of its id when it has no name.
String tokenTicker(TokenBalance t) {
  final name = issuerText(t.name).trim();
  if (name.isNotEmpty) {
    return name.contains(' ') ? name.split(' ').first : name;
  }
  return t.id.length > 6 ? t.id.substring(0, 6).toUpperCase() : t.id;
}

/// One asset row: avatar, ticker and name, amount and fiat on the right.
class AssetTile extends StatelessWidget {
  const AssetTile({
    super.key,
    required this.ticker,
    required this.name,
    required this.amountText,
    this.fiatText,
    this.iconUrl,
    this.tokenId,
    this.isErg = false,
    this.hidden = false,
    this.onTap,
    this.showChevron = true,
    this.verified = false,
    this.caution = false,
    this.rawUnits = false,
  });

  AssetTile.erg({
    super.key,
    required int? balanceNano,
    this.fiatText,
    this.hidden = false,
    this.onTap,
    this.showChevron = true,
  })  : ticker = 'ERG',
        name = 'Ergo',
        amountText = balanceNano == null
            ? '—'
            : _ergAmount(balanceNano),
        iconUrl = null,
        tokenId = null,
        isErg = true,
        verified = true,
        caution = false,
        rawUnits = false;

  AssetTile.token(
    TokenBalance t, {
    super.key,
    this.fiatText,
    this.hidden = false,
    this.onTap,
    this.showChevron = true,
  })  : ticker = tokenTicker(t),
        name = issuerText(t.name).trim().isNotEmpty
            ? issuerText(t.name).trim()
            : shorten(t.id, head: 10, tail: 6),
        amountText = holdingAmountText(t),
        iconUrl = t.iconUrl,
        tokenId = t.id,
        isErg = false,
        verified = isVerifiedToken(t.id),
        caution = cautionedToken(t.id) != null,
        rawUnits = !hasKnownScale(t);

  final String ticker;
  final String name;
  final String amountText;
  final String? fiatText;
  final String? iconUrl;
  final String? tokenId;
  final bool isErg;
  final bool hidden;
  final VoidCallback? onTap;
  final bool showChevron;

  /// Shows a check next to the ticker for on-chain-verified tokens.
  final bool verified;

  /// Shows a warning next to the ticker for cautioned tokens.
  final bool caution;

  /// Nothing knows the token's decimals: [amountText] is base units and
  /// already says so, so the ticker is not appended as if it were a scale.
  final bool rawUnits;

  static String _ergAmount(int nano) => formatErg(nano, unit: false, maxFrac: 4);

  @override
  Widget build(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    final amount = Text(
      hidden
          ? '••••'
          : rawUnits
          ? amountText
          : '$amountText $ticker',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14.5),
    );
    final fiat = fiatText == null
        ? null
        : Text(
            hidden ? '≈ ••••' : fiatText!,
            style: TextStyle(fontSize: 12, color: muted),
          );
    // At large text sizes a side column for the amount leaves it a few
    // letters — "5,000 r…" — so it moves under the name instead.
    final stacked = MediaQuery.textScalerOf(context).scale(14) / 14 > 1.4;
    return InkWell(
      onTap: hidden ? null : onTap,
      borderRadius: BorderRadius.circular(cardRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            TokenAvatar(label: hidden ? '?' : ticker, iconUrl: iconUrl, tokenId: hidden ? null : tokenId, isErg: isErg),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          hidden ? '••••' : ticker,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (verified && !isErg) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.verified, size: 15, color: accentOf(context)),
                      ],
                      if (caution) ...[
                        const SizedBox(width: 4),
                        const Icon(Icons.warning_amber_rounded, size: 15, color: rust),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hidden ? '••••' : name,
                    style: TextStyle(fontSize: 12.5, color: muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (stacked) ...[
                    const SizedBox(height: 4),
                    amount,
                    if (fiat != null) ...[const SizedBox(height: 2), fiat],
                  ],
                ],
              ),
            ),
            if (!stacked) ...[
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    amount,
                    if (fiat != null) ...[const SizedBox(height: 2), fiat],
                  ],
                ),
              ),
            ],
            if (showChevron && onTap != null) ...[
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 18, color: muted),
            ],
          ],
        ),
      ),
    );
  }
}
