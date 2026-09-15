/// Issuer declarations are presentation evidence, never spending policy.
enum SupplyEvidence { unknown, originalEmission }

enum DecimalsEvidence { unknown, valid, invalid }

enum DeclaredAssetKind {
  none,
  picture,
  audio,
  video,
  collection,
  attachments,
  unsupported,
}

enum MetadataState { unavailable, partial, complete, invalid, conflict }

enum MediaState { unknown, absent, notLoaded, unsupported }

String issuerText(String? value, {int limit = 256}) {
  final out = <int>[];
  var bytes = 0;
  for (final c in (value ?? '').runes) {
    if (c < 32 ||
        (c >= 127 && c <= 159) ||
        (c >= 0x202a && c <= 0x202e) ||
        (c >= 0x2066 && c <= 0x2069) ||
        (c >= 0x200b && c <= 0x200f) ||
        c == 0x061c ||
        c == 0xfeff ||
        c == 0x2028 ||
        c == 0x2029)
      continue;
    final width = c <= 0x7f
        ? 1
        : c <= 0x7ff
        ? 2
        : c <= 0xffff
        ? 3
        : 4;
    if (bytes + width > limit) break;
    bytes += width;
    out.add(c);
  }
  return String.fromCharCodes(out);
}
