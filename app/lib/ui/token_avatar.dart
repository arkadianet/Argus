import 'package:flutter/material.dart';

import '../theme/argus_theme.dart';
import '../services/token_evidence.dart';
import '../services/verified_tokens.dart';
import 'token_logo_paths.dart';

/// Which bundled logo draws [tokenId], if any. ERG is the Ergo mark. A
/// Rosen-wrapped token in the verified registry gets the mark of the chain
/// it wraps. The match is on the registry's own ticker, never on the
/// issuer's name, which anyone can set. Every other token has no logo
/// (assets/token_logos/NOTICE.md says why).
String? tokenLogoName({String? tokenId, bool isErg = false}) {
  if (isErg) return 'erg';
  final ticker = tokenId == null ? null : verifiedToken(tokenId)?.ticker;
  return switch (ticker) {
    'rsADA' => 'ada',
    'rsBTC' => 'btc',
    'rsETH' => 'eth',
    'rsBNB' => 'bnb',
    'rsDOGE' => 'doge',
    _ => null,
  };
}

/// The colours of a monogram disc: a gradient from [top] to [bottom], and
/// the letter on it.
typedef MonogramLook = ({Color top, Color bottom, Color letter});

/// Hues an unverified mark's disc can take, chosen to sit together: muted,
/// none of them the palette's red or green, so a disc never reads as a
/// rise or a warning.
const _hues = <double>[24, 168, 192, 212, 232, 262, 290, 318];

/// The disc for a token with no logo.
///
/// A verified token's disc is laid in the palette's accent with its
/// letter in the accent's text colour, so the registry's tokens read as one
/// set. Any other token's disc takes a quiet hue from its id (or a
/// wallet's name), so two tokens tell apart at a glance. The letter meets
/// 4.5:1 on both ends of the disc (token_avatar_test.dart).
MonogramLook monogramLook({
  required Brightness brightness,
  required Color accent,
  required Color accentText,
  required Color page,
  required bool verified,
  required String seed,
}) {
  final dark = brightness == Brightness.dark;
  if (verified) {
    return (
      top: Color.alphaBlend(accent.withValues(alpha: dark ? 0.22 : 0.36), page),
      bottom: Color.alphaBlend(accent.withValues(alpha: dark ? 0.12 : 0.16), page),
      // On a light page the accent's text colour is taken a step toward the
      // ink, since the disc under it is darker than the page.
      letter: dark ? accentText : Color.lerp(accentText, ink, 0.3)!,
    );
  }
  var hash = 0;
  for (final unit in seed.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  final hue = _hues[hash % _hues.length];
  HSLColor at(double s, double l) => HSLColor.fromAHSL(1, hue, s, l);
  return dark
      ? (top: at(0.22, 0.25).toColor(), bottom: at(0.24, 0.18).toColor(), letter: at(0.45, 0.82).toColor())
      : (top: at(0.42, 0.90).toColor(), bottom: at(0.38, 0.83).toColor(), letter: at(0.50, 0.26).toColor());
}

/// Local-only token mark. Issuer URIs are inert, including for fungible tokens.
///
/// A token with a bundled logo shows it ([tokenLogoName]). Any other shows a
/// letter, which never comes from the issuer's name, since anyone can set
/// that to dress one token up as another. A token in the verified registry
/// shows the initial of the registry's own ticker (C for COMET). Any other
/// shows the first character of its id.
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
    final theme = Theme.of(context);
    final colors = ArgusColors.of(context);
    final size = radius * 2;
    final logo = tokenLogoName(tokenId: tokenId, isErg: isErg);
    if (logo != null) {
      final art = tokenLogoArt[logo]!;
      // ERG's mark is drawn in the palette's own colours, on its accent:
      // the one mark that is the app's own currency.
      final disc = art.disc == null
          ? LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color.lerp(colors.accent, Colors.white, 0.18)!, colors.accent],
            )
          : null;
      return SizedBox.square(
        key: Key('token-logo-$logo'),
        dimension: size,
        child: CustomPaint(painter: TokenLogoPainter(
          art: art,
          disc: disc,
          mark: colors.onAccent,
          // A chain's own disc can be the colour of the page it sits on
          // (Cardano's navy on Harbor): a faint rim keeps the coin's edge.
          rim: art.disc == null ? null : (theme.brightness == Brightness.dark ? Colors.white : Colors.black).withValues(alpha: 0.12),
        )),
      );
    }
    final verified = tokenId != null && verifiedToken(tokenId!) != null;
    final look = monogramLook(
      brightness: theme.brightness,
      accent: colors.accent,
      accentText: colors.accentText,
      page: theme.colorScheme.surface,
      verified: verified,
      seed: tokenId ?? label,
    );
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [look.top, look.bottom],
        ),
      ),
      child: Text(
        letterFor(tokenId: tokenId, label: label),
        textScaler: TextScaler.noScaling,
        style: TextStyle(
          fontFamily: 'Newsreader',
          fontWeight: FontWeight.w600,
          fontSize: radius * 0.9,
          height: 1,
          color: look.letter,
        ),
      ),
    );
  }
}

/// Draws a bundled logo in a circle: its own disc, or [disc] for a mark
/// that has none, with the mark in [mark] where the logo leaves the colour
/// to the app.
class TokenLogoPainter extends CustomPainter {
  TokenLogoPainter({required this.art, required this.mark, this.disc, this.rim});

  final TokenLogoArt art;
  final Gradient? disc;
  final Color mark;
  final Color? rim;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final circle = Path()..addOval(rect);
    canvas.save();
    canvas.clipPath(circle);
    if (disc != null) {
      canvas.drawRect(rect, Paint()..shader = disc!.createShader(rect));
    }
    // A mark without its own disc is set at about half the circle, as the
    // logos that carry one draw theirs.
    final inset = disc == null ? 0.0 : size.width * 0.24;
    final scale = (size.width - inset * 2) / art.size;
    canvas.translate(inset, inset);
    canvas.scale(scale);
    if (art.disc != null) {
      canvas.drawCircle(Offset(art.size / 2, art.size / 2), art.size / 2, Paint()..color = art.disc!);
    }
    for (final layer in art.layers) {
      canvas.drawPath(layer.path(), Paint()..color = layer.color ?? mark..isAntiAlias = true);
    }
    canvas.restore();
    if (rim != null) {
      canvas.drawCircle(
        rect.center,
        size.width / 2 - 0.5,
        Paint()
          ..color = rim!
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(TokenLogoPainter old) => old.art != art || old.mark != mark || old.disc != disc || old.rim != rim;
}
