/// Issuer declarations are presentation evidence, never spending policy.
enum SupplyEvidence { unknown, originalEmission }

/// What a token's decimals rest on. Only [unknown] and [invalid] leave its
/// amounts in raw units: nothing could be read, or what the issuer wrote
/// cannot be.
enum DecimalsEvidence {
  /// The token's metadata could not be read, so nothing says what its
  /// decimals are. Never "read, and no decimals declared": that is [absent].
  unknown,

  /// Declared: the issuance box's R6, or the provider's token record (which
  /// a node or an explorer derives from R6), the two agreeing where both
  /// were read.
  valid,

  /// An R6 that is not a number of decimals, or one the token record
  /// contradicts.
  invalid,

  /// The issuance box was read and has no R6: zero decimals, as the node's
  /// token record and the explorers report and as EIP-4 tokens without one
  /// are shown everywhere.
  absent,

  /// From a list rather than an issuance read: the curated registry built
  /// into the app, or the token tables of earlier builds.
  listed,
}

extension DecimalsEvidenceScale on DecimalsEvidence {
  /// Whether this evidence settles the token's scale.
  bool get knowsScale =>
      this == DecimalsEvidence.valid ||
      this == DecimalsEvidence.absent ||
      this == DecimalsEvidence.listed;

  /// Whether the decimals were read from the token itself (its R6 or its
  /// record, or their absence), rather than taken from a list.
  bool get readFromToken =>
      this == DecimalsEvidence.valid || this == DecimalsEvidence.absent;
}

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
