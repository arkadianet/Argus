import 'package:flutter/material.dart';

import '../../format.dart';
import '../../services/verified_tokens.dart';
import '../../services/wallet_service.dart';
import '../../theme/argus_theme.dart';
import '../token_avatar.dart';

/// Short display symbol for a token: the first word of its name, or the
/// start of its id when it has no name.
String tokenTicker(TokenBalance t) {
  final name = t.name?.trim();
  if (name != null && name.isNotEmpty) {
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
    this.isErg = false,
    this.hidden = false,
    this.onTap,
    this.showChevron = true,
    this.verified = false,
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
        isErg = true,
        verified = true;

  AssetTile.token(
    TokenBalance t, {
    super.key,
    this.hidden = false,
    this.onTap,
    this.showChevron = true,
  })  : ticker = tokenTicker(t),
        name = (t.name?.trim().isNotEmpty ?? false)
            ? t.name!.trim()
            : shorten(t.id, head: 10, tail: 6),
        amountText = t.isNft ? '1' : formatTokenAmountGrouped(t.amount, t.decimals),
        fiatText = null,
        iconUrl = t.iconUrl,
        isErg = false,
        verified = isVerifiedToken(t.id);

  final String ticker;
  final String name;
  final String amountText;
  final String? fiatText;
  final String? iconUrl;
  final bool isErg;
  final bool hidden;
  final VoidCallback? onTap;
  final bool showChevron;

  /// Shows a check next to the ticker for on-chain-verified tokens.
  final bool verified;

  static String _ergAmount(int nano) => formatErg(nano, unit: false, maxFrac: 4);

  @override
  Widget build(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(cardRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            TokenAvatar(label: ticker, iconUrl: iconUrl, isErg: isErg),
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
                          ticker,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (verified && !isErg) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.verified, size: 15, color: accentOf(context)),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    name,
                    style: TextStyle(fontSize: 12.5, color: muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    hidden ? '••••' : '$amountText $ticker',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14.5),
                  ),
                  if (fiatText != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      hidden ? '≈ ••••' : fiatText!,
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                  ],
                ],
              ),
            ),
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
