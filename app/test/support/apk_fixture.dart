import 'dart:convert';
import 'dart:typed_data';

/// Builds APK-shaped byte strings for the signing-block parser and the
/// update flow: local entries, an APK Signing Block, a central directory and
/// an end record. Nothing here is a real archive; it is exactly as much
/// structure as the parser reads, so each test can break one piece.

const v2BlockId = 0x7109871a;
const v3BlockId = 0xf05368c0;
const paddingBlockId = 0x42726577;

Uint8List bytes(List<int> v) => Uint8List.fromList(v);

Uint8List concat(Iterable<List<int>> parts) {
  final out = BytesBuilder(copy: false);
  for (final p in parts) {
    out.add(p);
  }
  return out.takeBytes();
}

Uint8List u16(int v) => (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List();
Uint8List u32(int v) => (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();
Uint8List u64(int v) => (ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List();

/// A u32 length, then [b].
Uint8List lengthPrefixed(List<int> b) => concat([u32(b.length), b]);

/// A certificate stand-in that is shaped like DER (a SEQUENCE spanning every
/// byte) and different for every [seed].
Uint8List fakeCertificate(int seed, {int size = 60}) {
  final body = List<int>.generate(size, (i) => (seed * 31 + i) & 0xff);
  final header = size < 128
      ? [0x30, size]
      : size < 256
          ? [0x30, 0x81, size]
          : [0x30, 0x82, size >> 8, size & 0xff];
  return bytes([...header, ...body]);
}

/// One signer as v2 or v3 writes it. [certificates] is the chain, leaf first.
Uint8List signer(List<Uint8List> certificates, {bool v3 = false}) {
  final digests = lengthPrefixed(lengthPrefixed(concat([u32(0x0103), lengthPrefixed(Uint8List(32))])));
  final chain = lengthPrefixed(concat([for (final c in certificates) lengthPrefixed(c)]));
  final sdk = v3 ? concat([u32(24), u32(0x7fffffff)]) : Uint8List(0);
  final signedData = lengthPrefixed(concat([digests, chain, sdk, lengthPrefixed(Uint8List(0))]));
  final signatures = lengthPrefixed(lengthPrefixed(concat([u32(0x0103), lengthPrefixed(Uint8List(16))])));
  final publicKey = lengthPrefixed(bytes([1, 2, 3, 4]));
  return lengthPrefixed(concat([signedData, sdk, signatures, publicKey]));
}

/// The value of a v2 or v3 pair: the signers as a length-prefixed sequence.
Uint8List schemeValue(List<Uint8List> signers) => lengthPrefixed(concat(signers));

typedef BlockPair = (int id, Uint8List value);

/// An APK Signing Block holding [pairs] in order.
Uint8List signingBlock(List<BlockPair> pairs, {int? sizeOverride, int? trailingSizeOverride}) {
  final body = concat([
    for (final (id, value) in pairs) concat([u64(4 + value.length), u32(id), value]),
  ]);
  final size = body.length + 8 + 16;
  return concat([
    u64(sizeOverride ?? size),
    body,
    u64(trailingSizeOverride ?? size),
    ascii.encode('APK Sig Block 42'),
  ]);
}

/// A block whose pairs are exactly one v2 or v3 signature over [signers].
Uint8List schemeBlock(List<Uint8List> signers, {bool v3 = false}) =>
    signingBlock([(v3 ? v3BlockId : v2BlockId, schemeValue(signers))]);

/// Local entries, [block] (if any), a central directory and the end record.
/// [centralOffsetDelta] and [centralSizeDelta] lie about where the central
/// directory is; [beforeEocd] sits between the directory and the record.
Uint8List apk({
  Uint8List? block,
  List<int> comment = const [],
  int centralOffsetDelta = 0,
  int centralSizeDelta = 0,
  List<int> beforeEocd = const [],
  int? centralOffsetField,
  int entriesLength = 300,
}) {
  final entries = concat([
    [0x50, 0x4b, 0x03, 0x04],
    List<int>.filled(entriesLength - 4, 0x61),
  ]);
  final central = concat([
    [0x50, 0x4b, 0x01, 0x02],
    List<int>.filled(42, 0),
  ]);
  final centralOffset = entries.length + (block?.length ?? 0);
  final eocd = concat([
    [0x50, 0x4b, 0x05, 0x06],
    u16(0),
    u16(0),
    u16(1),
    u16(1),
    u32(central.length + centralSizeDelta),
    u32(centralOffsetField ?? centralOffset + centralOffsetDelta),
    u16(comment.length),
    comment,
  ]);
  return concat([entries, block ?? const <int>[], central, beforeEocd, eocd]);
}

/// A signed APK: [certificate] as the only signer's leaf, in a v2 block.
Uint8List signedApk(Uint8List certificate, {bool v3 = false}) =>
    apk(block: schemeBlock([signer([certificate], v3: v3)], v3: v3));
