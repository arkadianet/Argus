import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../format.dart';
import '../../services/token_pricer.dart';
import '../../services/network_controller.dart';
import '../../services/privacy_service.dart';
import '../../services/token_pricing.dart';
import '../../services/verified_tokens.dart';
import '../../services/wallet_service.dart';
import '../../theme/argus_theme.dart';
import '../token_avatar.dart';
import 'asset_tile.dart';

class TokenDetailSheet extends StatefulWidget {
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
  State<TokenDetailSheet> createState() => _TokenDetailSheetState();
}

class _TokenDetailSheetState extends State<TokenDetailSheet>
    with WidgetsBindingObserver {
  bool _loading = false;
  bool _concealed = false;
  String? _error;
  late final String? _wallet = walletService.currentWalletId.value;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    walletService.unlocked.addListener(_securityChanged);
    walletService.currentWalletId.addListener(_securityChanged);
  }

  void _securityChanged() {
    if (!walletService.isUnlocked ||
        _wallet != walletService.currentWalletId.value) {
      walletService.clearSessionMetadata();
      if (mounted) setState(() => _concealed = true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      walletService.clearSessionMetadata();
      if (mounted) setState(() => _concealed = true);
    }
  }

  @override
  void dispose() {
    if (_loading) walletService.clearSessionMetadata();
    WidgetsBinding.instance.removeObserver(this);
    walletService.unlocked.removeListener(_securityChanged);
    walletService.currentWalletId.removeListener(_securityChanged);
    super.dispose();
  }

  Future<void> _load({bool node = false}) async {
    final provider = node
        ? networkController.activeUrl
        : networkController.explorer;
    if (provider == null) return;
    final host = Uri.tryParse(provider)?.host ?? '';
    if (host.isEmpty || host.runes.any((c) => c > 127)) {
      setState(
        () => _error = 'Configure an ASCII/punycode HTTPS metadata provider',
      );
      return;
    }
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Load metadata from $host'),
        content: Text(
          'This provider can see your IP address and the token ID requested. '
          '${widget.token.hasStealth ? 'Loading may link this private holding to this connection. ' : ''}'
          'Issuer text may be misleading. No artwork will be downloaded.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Load metadata'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted || _concealed) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await walletService.loadMetadata(
        widget.token,
        provider: provider,
        providerIsNode: node,
      );
    } catch (_) {
      if (mounted) setState(() => _error = 'Metadata unavailable from $host');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      privacyService,
      walletService.metadataChanges,
      networkController,
    ]),
    builder: (context, _) {
      if (_concealed || privacyService.hideBalances) {
        return const SafeArea(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('Asset details hidden'),
          ),
        );
      }
      final token = walletService.displayMetadata(widget.token);
      return SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _TokenDetailBody(
              token: token,
              explorerUrl: widget.explorerUrl,
              onSend: widget.onSend,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                children: [
                  if (_error != null) Text(_error!),
                  if (networkController.activeUrl == null)
                    const Text('Metadata unavailable offline'),
                  if (_loading)
                    TextButton(
                      onPressed: walletService.clearSessionMetadata,
                      child: const Text('Cancel metadata request'),
                    ),
                  TextButton(
                    onPressed:
                        _loading ||
                            networkController.activeUrl == null ||
                            !walletService.isUnlocked
                        ? null
                        : () => _load(node: true),
                    child: Text(
                      'Load metadata from ${Uri.tryParse(networkController.activeUrl ?? "")?.host ?? "node"} (node)',
                    ),
                  ),
                  TextButton(
                    onPressed:
                        _loading ||
                            networkController.activeUrl == null ||
                            !walletService.isUnlocked
                        ? null
                        : () => _load(),
                    child: Text(
                      _loading
                          ? 'Loading metadata…'
                          : 'Load metadata from ${Uri.tryParse(networkController.explorer)?.host ?? "provider"}',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// Everything about one held token: full id, amount, decimals, explorer
/// link, and a shortcut to send it.
class _TokenDetailBody extends StatelessWidget {
  const _TokenDetailBody({
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
    final amount = formatTokenAmountGrouped(token.amount, token.decimals);
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
                TokenAvatar(
                  label: ticker,
                  tokenId: token.id,
                  iconUrl: token.iconUrl,
                  radius: 24,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              token.label,
                              textDirection: TextDirection.ltr,
                              style: theme.textTheme.titleLarge,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (verified != null) ...[
                            const SizedBox(width: 6),
                            Icon(
                              Icons.verified,
                              size: 18,
                              color: accentOf(context),
                            ),
                          ],
                          if (caution != null) ...[
                            const SizedBox(width: 6),
                            const Icon(
                              Icons.warning_amber_rounded,
                              size: 18,
                              color: rust,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        verified != null
                            ? 'Curated token · ${verified.project}'
                            : token.classification,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: verified != null ? accentOf(context) : muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (!token.isCollectible) ...[
              const SizedBox(height: 12),
              _PriceLine(token: token),
            ],
            if (token.hasStealth) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.visibility_off_outlined, size: 16, color: muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${formatTokenAmountGrouped(token.stealthAmount, token.decimals)} '
                      'of this sits in stealth boxes. Sweep it from Receive '
                      'before spending it.',
                      style: TextStyle(fontSize: 12.5, color: muted),
                    ),
                  ),
                ],
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
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: rust,
                      size: 20,
                    ),
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
            Text(
              'YOU HOLD',
              style: theme.textTheme.titleSmall?.copyWith(color: muted),
            ),
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
            Text(token.classification, textDirection: TextDirection.ltr),
            const SizedBox(height: 8),
            Text(
              token.supplyEvidence == SupplyEvidence.originalEmission
                  ? 'Original emission: ${token.emissionAmount} (provider reported)'
                  : 'Original emission unavailable',
            ),
            Text('Decimals evidence: ${token.decimalsEvidence.name}'),
            Text('Declared artwork kind: ${token.declaredAssetKind.name}'),
            if (token.source != null)
              Text(
                'Metadata source: ${token.source}',
                textDirection: TextDirection.ltr,
              ),
            const SizedBox(height: 8),
            Text(
              token.description == null
                  ? 'Description unavailable'
                  : issuerText(token.description, limit: 4096),
              textDirection: TextDirection.ltr,
            ),
            const SizedBox(height: 8),
            Text(switch (token.mediaState) {
              MediaState.absent => 'No media link in issuance metadata.',
              MediaState.unknown => 'Media metadata unavailable',
              MediaState.unsupported => 'Preview not supported',
              MediaState.notLoaded =>
                'Remote preview not loaded · preview support unavailable in this build',
            }),
            Text(
              token.issuanceHash == null
                  ? 'Issuance media hash missing or invalid'
                  : 'Issuance media hash: ${token.issuanceHash}',
              textDirection: TextDirection.ltr,
            ),
            if (token.iconUrl != null)
              TextButton(
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: token.iconUrl!)),
                child: const Text('Copy media URI as text'),
              ),
            if (token.rawRegisters != null)
              ExpansionTile(
                title: const Text('Original issuance registers (hex)'),
                children: [
                  SelectableText(
                    token.rawRegisters!,
                    textDirection: TextDirection.ltr,
                  ),
                ],
              ),
            const SizedBox(height: 18),
            Text(
              'TOKEN ID',
              style: theme.textTheme.titleSmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: ArgusColors.of(context).inset,
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                token.id,
                style: monoStyle(context, size: 12),
              ),
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
                  onPressed: () async {
                    final uri = Uri.tryParse(explorerUrl);
                    if (uri == null ||
                        uri.scheme != 'https' ||
                        uri.userInfo.isNotEmpty)
                      return;
                    final yes = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text('Leave Argus for ${uri.host}?'),
                        content: const Text(
                          'The explorer can see your IP address and this token ID.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Open explorer'),
                          ),
                        ],
                      ),
                    );
                    if (yes == true)
                      await launchUrl(
                        uri,
                        mode: LaunchMode.externalApplication,
                      );
                  },
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

/// "≈ $0.0125 each · ≈ $2.50 held · Spectrum pool, 500 ERG deep", or why
/// there is no price.
class _PriceLine extends StatelessWidget {
  const _PriceLine({required this.token});
  final TokenBalance token;

  @override
  Widget build(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    final price = tokenPricer.priceOf(token.id);
    final unit = tokenPricer.unitFiatText(token.id);
    final held = tokenPricer.fiatTextFor(
      tokenId: token.id,
      amount: token.amount,
      decimals: token.decimals,
    );
    final String text;
    if (price == null || unit == null) {
      text = tokenPricer.result.ergUsd == null
          ? 'No price yet · ${tokenPricer.source.label} has not answered'
          : 'No price · no ERG pool at least ${poolDepthFloorErg.toStringAsFixed(0)} ERG deep';
    } else {
      final via = price.depthErg == null
          ? price.via
          : '${price.via}, ${price.depthErg!.toStringAsFixed(0)} ERG deep';
      text = [
        '$unit each',
        if (held != null) '$held held',
        via,
        if (!price.countsInTotal) 'not counted in totals (unverified)',
      ].join(' · ');
    }
    return Text(text, style: TextStyle(fontSize: 12.5, color: muted));
  }
}
