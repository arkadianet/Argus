import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../format.dart';
import '../../services/media_url.dart';
import '../../services/verified_tokens.dart';
import '../../services/wallet_service.dart';
import '../../theme/argus_theme.dart';
import '../token_avatar.dart';
import 'asset_tile.dart';

/// Everything about one held token: full id, amount, decimals, explorer
/// link, and a shortcut to send it.
class TokenDetailSheet extends StatelessWidget {
  const TokenDetailSheet({
    super.key,
    required this.token,
    required this.explorerUrl,
    this.onSend,
  });

  final TokenBalance token;
  final String explorerUrl;
  final ValueChanged<TokenBalance>? onSend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = ArgusColors.of(context).muted;
    final ticker = tokenTicker(token);
    final amount = token.isNft ? '1' : formatTokenAmountGrouped(token.amount, token.decimals);
    final media = token.isNft ? resolveMediaUrl(token.iconUrl) : null;
    final verified = verifiedToken(token.id);
    final caution = cautionedToken(token.id);
    final impersonates = impersonatedToken(tokenId: token.id, name: token.name);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                TokenAvatar(label: ticker, iconUrl: token.iconUrl, radius: 24),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(child: Text(token.label, style: theme.textTheme.titleLarge, maxLines: 1, overflow: TextOverflow.ellipsis)),
                          if (verified != null) ...[
                            const SizedBox(width: 6),
                            Icon(Icons.verified, size: 18, color: accentOf(context)),
                          ],
                          if (caution != null) ...[
                            const SizedBox(width: 6),
                            const Icon(Icons.warning_amber_rounded, size: 18, color: rust),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        verified != null
                            ? 'Verified · ${verified.project}${token.isNft ? '' : ' · ${token.decimals} decimals'}'
                            : (token.isNft ? 'NFT' : 'Token · ${token.decimals} decimals'),
                        style: TextStyle(fontSize: 12.5, color: verified != null ? accentOf(context) : muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (media != null) ...[
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Image.network(
                    media,
                    fit: BoxFit.cover,
                    loadingBuilder: (ctx, child, progress) => progress == null
                        ? child
                        : Container(color: ArgusColors.of(ctx).chip),
                    errorBuilder: (ctx, _, _) => Container(
                      color: ArgusColors.of(ctx).chip,
                      alignment: Alignment.center,
                      child: Text('Artwork unavailable', style: TextStyle(color: muted, fontSize: 12.5)),
                    ),
                  ),
                ),
              ),
            ],
            if (caution != null) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: rust.withValues(alpha: 0.1),
                  border: Border.all(color: rust.withValues(alpha: 0.5)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: rust, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Caution: ${caution.note ?? 'this token is flagged.'}',
                        style: TextStyle(fontSize: 13, color: rustFor(context)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (impersonates != null) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: rust.withValues(alpha: 0.1),
                  border: Border.all(color: rust.withValues(alpha: 0.5)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.gpp_bad_outlined, color: rust, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'This token is named like ${impersonates.ticker}, but it is not the verified ${impersonates.ticker} from ${impersonates.project}. Check the id before trusting it.',
                        style: TextStyle(fontSize: 13, color: rustFor(context)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            Text('YOU HOLD', style: theme.textTheme.titleSmall?.copyWith(color: muted)),
            const SizedBox(height: 4),
            Text(
              '$amount $ticker',
              style: const TextStyle(
                fontFamily: 'Newsreader',
                fontWeight: FontWeight.w600,
                fontSize: 28,
              ),
            ),
            const SizedBox(height: 18),
            Text('TOKEN ID', style: theme.textTheme.titleSmall?.copyWith(color: muted)),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: ArgusColors.of(context).inset,
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(token.id, style: monoStyle(context, size: 12)),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: token.id));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Token id copied')),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy id'),
                ),
                TextButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse(explorerUrl),
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.open_in_browser, size: 16),
                  label: const Text('Explorer'),
                ),
              ],
            ),
            if (onSend != null) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => onSend!(token),
                icon: const Icon(Icons.north_east, size: 17),
                label: Text('Send ${token.label}'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

Future<void> showTokenDetailSheet(
  BuildContext context, {
  required TokenBalance token,
  required String explorerUrl,
  ValueChanged<TokenBalance>? onSend,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(cardRadius)),
    ),
    builder: (ctx) => TokenDetailSheet(
      token: token,
      explorerUrl: explorerUrl,
      onSend: onSend == null
          ? null
          : (t) {
              Navigator.pop(ctx);
              onSend(t);
            },
    ),
  );
}
