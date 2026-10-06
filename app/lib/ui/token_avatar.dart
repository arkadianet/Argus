import 'package:flutter/material.dart';

import '../theme/argus_theme.dart';
import '../services/token_evidence.dart';
import '../services/verified_tokens.dart';

/// Local-only token mark. Issuer URIs are inert, including for fungible tokens.
///
/// The letter never comes from the issuer's name, which anyone can set to
/// dress one token up as another: a token in the verified registry shows
/// the initial of the registry's own ticker (C for COMET), any other the
/// first character of its id. ERG alone gets the sigma on a gold disc.
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

  /// The character the mark shows for [tokenId] (or [label] without one).
  static String letterFor({String? tokenId, required String label}) {
    final vetted = tokenId == null ? null : verifiedToken(tokenId)?.ticker;
    final text = issuerText(vetted ?? tokenId ?? label);
    return text.isNotEmpty ? String.fromCharCode(text.runes.first).toUpperCase() : '?';
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final colors = ArgusColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    // The disc takes the palette's raised surface with a hairline ring: the
    // old fixed fill was the card colour itself on dark palettes, so on a
    // card the mark showed as a bare letter.
    return Container(
      width: radius * 2,
      height: radius * 2,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isErg ? accentOf(context).withValues(alpha: dark ? 0.25 : 0.2) : scheme.surfaceContainerHighest,
        border: isErg ? null : Border.all(color: colors.cardBorder),
      ),
      child: Text(
        isErg ? 'Σ' : letterFor(tokenId: tokenId, label: label),
        textScaler: TextScaler.noScaling,
        style: TextStyle(
          fontFamily: 'Newsreader',
          fontWeight: FontWeight.w600,
          fontSize: radius * 0.8,
          height: 1,
          color: isErg || dark ? scheme.onSurface : colors.muted,
        ),
      ),
    );
  }
}
