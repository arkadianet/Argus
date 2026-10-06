import 'dart:convert';

import 'package:http/http.dart' as http;

/// The single-rate oracle pools the pricer reads straight from the user's
/// node, and how old each may be before its rate is no longer current.
///
/// Each pool keeps one box holding its NFT; R4 of that box is the rate as
/// a `Long`. Units were checked against the protocols that settle against
/// them, not assumed:
///
/// - **SigmaUSD ERG/USD** (`011d3364…`): nanoERG per US dollar. The
///   vendored `sigmausd` crate reads R4 as `nanoerg_per_usd` and the
///   AgeUSD bank divides it by 100 for its two-decimal cent; the Dexy USD
///   pool, an independent oracle-core v2 pool, agrees to within 0.01% at
///   the same height. Its box is the original oracle pool's layout, not
///   oracle-core v2's: it carries only the NFT, R5 is the epoch's end
///   height rather than an epoch counter, and R6 a 32-byte hash. Only R4
///   is read, which means the same in both.
/// - **Dexy USD** (`6a2b821b…`, oracle-core v2): nanoERG per US dollar.
/// - **Dexy gold** (`3c45f29a…`, oracle-core v2): nanoERG per kilogram of
///   gold; the Dexy bank divides by 1 000 000 for its milligram token.
///
/// Thresholds are a few of each pool's epochs: SigmaUSD's pool box turns
/// over every two to eight blocks, Dexy USD's about every seven, Dexy
/// gold's about every thirty.
enum OracleFeed {
  sigmaUsd('011d3364de07e5a26f0c4eef0852cddb387039a921b7154ef3cab22c6eda887f', 'SigmaUSD oracle', 60),
  dexyUsd('6a2b821b5727e85beb5e78b4efb9f0250d59cd48481d2ded2c23e91ba1d07c66', 'Dexy USD oracle', 60),
  dexyGold('3c45f29a5165b030fdb5eaf5d81f8108f9d8f507b31487dd51f4ae08fe07cf4a', 'Dexy gold oracle', 90);

  const OracleFeed(this.nft, this.label, this.staleAfterBlocks);
  final String nft;
  final String label;
  final int staleAfterBlocks;
}

/// Milligrams in a troy ounce: the AVL oracle quotes gold per ounce, the
/// DexyGold token is one milligram.
const mgPerTroyOunce = 31103.4768;

/// A pool's newest box: its R4 rate in the pool's own unit, and the height
/// it was written at.
class OracleReading {
  const OracleReading({required this.rate, required this.height, this.boxId});
  final int rate;
  final int height;
  final String? boxId;

  int ageAt(int tip) => tip > height ? tip - height : 0;
}

/// Decodes a serialized `SLong` register (type 0x05, zigzag VLQ), or null.
int? decodeSigmaLong(String hex) {
  final h = hex.trim();
  if (h.length < 4 || h.length.isOdd || h.substring(0, 2) != '05') return null;
  var result = 0;
  var shift = 0;
  for (var i = 2; i < h.length; i += 2) {
    final byte = int.tryParse(h.substring(i, i + 2), radix: 16);
    if (byte == null || shift > 63) return null;
    result |= (byte & 0x7f) << shift;
    if (byte & 0x80 == 0) return (result >> 1) ^ -(result & 1);
    shift += 7;
  }
  return null;
}

/// The reading in a node box JSON, or null when R4 is not a positive Long.
OracleReading? readingFromBox(Map<String, dynamic> box) {
  final regs = (box['additionalRegisters'] as Map?)?.cast<String, dynamic>() ?? const {};
  final r4 = regs['R4'];
  final raw = r4 is String ? r4 : (r4 is Map ? r4['serializedValue'] as String? : null);
  final rate = raw == null ? null : decodeSigmaLong(raw);
  final height = (box['inclusionHeight'] as num?)?.toInt() ?? (box['creationHeight'] as num?)?.toInt();
  if (rate == null || rate <= 0 || height == null) return null;
  return OracleReading(rate: rate, height: height, boxId: box['boxId'] as String?);
}

/// USD per ERG from a pool quoting nanoERG per dollar.
double usdPerErg(OracleReading r) => 1e9 / r.rate;

/// The newest box of [feed]'s pool, from the node's unspent box index.
Future<OracleReading?> fetchOracleReading(String node, OracleFeed feed, {http.Client? client}) async {
  final c = client ?? http.Client();
  final base = node.replaceAll(RegExp(r'/$'), '');
  final res = await c
      .get(Uri.parse('$base/blockchain/box/unspent/byTokenId/${feed.nft}?offset=0&limit=1'))
      .timeout(const Duration(seconds: 10));
  if (res.statusCode != 200) throw Exception('node returned ${res.statusCode}');
  final body = jsonDecode(res.body);
  final items = body is List ? body : (body as Map)['items'] as List? ?? const [];
  if (items.isEmpty) return null;
  return readingFromBox((items.first as Map).cast<String, dynamic>());
}

/// "40 min", "3 h", "22 days": how long [blocks] blocks take at two minutes
/// a block.
String ageText(int blocks) {
  final minutes = blocks * 2;
  if (minutes < 120) return '$minutes min';
  final hours = minutes ~/ 60;
  if (hours < 48) return '$hours h';
  return '${hours ~/ 24} days';
}
