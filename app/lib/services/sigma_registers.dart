/// Minimal decoder for the two serialized Sigma register types the oracle
/// reader needs. Boxes from the node's blockchain API carry registers as
/// hex-encoded serialized values: a one-byte type code followed by the
/// value (VLQ integers are zigzag-encoded).
library;

const _typeInt = 0x04;
const _typeCollLong = 0x11;

List<int>? _bytes(String hex) {
  final h = hex.trim();
  if (h.isEmpty || h.length.isOdd) return null;
  final out = <int>[];
  for (var i = 0; i < h.length; i += 2) {
    final b = int.tryParse(h.substring(i, i + 2), radix: 16);
    if (b == null) return null;
    out.add(b);
  }
  return out;
}

/// Reads an unsigned VLQ starting at [pos]; returns (value, nextPos).
(int, int)? _vlq(List<int> b, int pos) {
  var result = 0;
  var shift = 0;
  var i = pos;
  while (i < b.length) {
    final byte = b[i++];
    result |= (byte & 0x7f) << shift;
    if (byte & 0x80 == 0) return (result, i);
    shift += 7;
    if (shift > 63) return null;
  }
  return null;
}

int _unzig(int n) => (n >> 1) ^ -(n & 1);

/// Decodes an `SInt` register value, or null when the hex is not one.
int? decodeSigmaInt(String hex) {
  final b = _bytes(hex);
  if (b == null || b.isEmpty || b[0] != _typeInt) return null;
  final r = _vlq(b, 1);
  return r == null ? null : _unzig(r.$1);
}

/// Decodes a `Coll[Long]` register value, or null when the hex is not one.
List<int>? decodeSigmaLongColl(String hex) {
  final b = _bytes(hex);
  if (b == null || b.isEmpty || b[0] != _typeCollLong) return null;
  final count = _vlq(b, 1);
  if (count == null) return null;
  var pos = count.$2;
  final out = <int>[];
  for (var i = 0; i < count.$1; i++) {
    final r = _vlq(b, pos);
    if (r == null) return null;
    out.add(_unzig(r.$1));
    pos = r.$2;
  }
  return out;
}
