import 'package:flutter/material.dart';

import '../theme/argus_theme.dart';
import '../services/token_evidence.dart';

/// Local-only token mark. Issuer URIs are inert, including for fungible tokens.
class TokenAvatar extends StatelessWidget {
  const TokenAvatar({
    super.key,
    required this.label,
    this.iconUrl,
    this.tokenId,
    this.isErg = false,
    this.radius = 20,
  });

  final String label;
  final String? iconUrl;
  final String? tokenId;
  final bool isErg;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return _letter(context, dark);
  }

  Widget _letter(BuildContext context, bool dark) {
    final text = issuerText(tokenId ?? label);
    final letter = text.isNotEmpty ? String.fromCharCode(text.runes.first).toUpperCase() : '?';
    return CircleAvatar(
      radius: radius,
      backgroundColor: isErg
          ? accentOf(context).withValues(alpha: dark ? 0.25 : 0.2)
          : (dark ? watchfulSurface : bannerTint),
      child: Text(
        isErg ? 'Σ' : letter,
        style: TextStyle(
          fontFamily: 'Newsreader',
          fontWeight: FontWeight.w600,
          fontSize: radius * 0.8,
          color: isErg ? (dark ? bone : ledgerInk) : (dark ? bone : ledgerMuted),
        ),
      ),
    );
  }
}
