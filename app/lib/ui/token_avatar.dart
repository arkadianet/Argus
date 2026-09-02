import 'package:flutter/material.dart';

import '../theme/argus_theme.dart';

/// Round token mark: the token's icon when the node supplied one and it
/// loads, otherwise the first letter of its label (Σ for ERG).
class TokenAvatar extends StatelessWidget {
  const TokenAvatar({
    super.key,
    required this.label,
    this.iconUrl,
    this.isErg = false,
    this.radius = 20,
  });

  final String label;
  final String? iconUrl;
  final bool isErg;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final url = iconUrl;
    if (url != null && url.startsWith('http')) {
      return ClipOval(
        child: SizedBox.square(
          dimension: radius * 2,
          child: Image.network(
            url,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _letter(dark),
          ),
        ),
      );
    }
    return _letter(dark);
  }

  Widget _letter(bool dark) {
    final letter = label.isNotEmpty ? label[0].toUpperCase() : '?';
    return CircleAvatar(
      radius: radius,
      backgroundColor: isErg
          ? iris.withValues(alpha: dark ? 0.25 : 0.2)
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
