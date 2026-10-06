import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Reads which certificate an APK says it is signed with, straight from its
/// APK Signing Block (signature scheme v2 or v3), so a downloaded update can
/// be compared with the key the running app was signed with before Android is
/// asked to install it.
///
/// What this is and is not. It reads the signer the APK *claims*; it does not
/// verify the signature or the digests of the archive. Android's installer
/// does that, and it also refuses an update signed with a different key than
/// the installed app. What the installer cannot do is warn someone who is
/// about to uninstall first and install the download as a new app (beta.1 had
/// to be installed that way): any validly signed APK is accepted as new.
/// Comparing the signer with this app's own key catches that before anything
/// is uninstalled.
///
/// Layout, from the end of the file:
///
///     ... local entries | APK Signing Block | central directory | EOCD
///
/// The EOCD gives the central directory's offset; the block ends right there
/// with its own size and the 16-byte magic `APK Sig Block 42`. Between the
/// two size fields sits a sequence of length-prefixed ID-value pairs.
enum ApkSignatureScheme { v2, v3 }

/// Why the signing block could not be read.
enum ApkSignatureProblem {
  /// No ZIP end-of-central-directory record: not an APK, or cut short.
  notAnApk,

  /// A ZIP64 archive. The v2 and v3 schemes do not support those.
  unsupported,

  /// A ZIP with no signing block in front of its central directory: unsigned,
  /// or signed with the old JAR scheme only.
  noSigningBlock,

  /// A signing block with neither a v2 nor a v3 signature in it.
  noSupportedScheme,

  /// A structure whose lengths do not add up, or a signer with no certificate.
  malformed,
}

class ApkSignatureException implements Exception {
  const ApkSignatureException(this.problem, this.message);

  final ApkSignatureProblem problem;
  final String message;

  @override
  String toString() => message;
}

/// The signers an APK declares, in signing-block order.
class ApkSigners {
  const ApkSigners(this.scheme, this.certificates);

  final ApkSignatureScheme scheme;

  /// The first certificate of each signer, DER encoded. Never empty. The
  /// first entry is the one the update check compares.
  final List<Uint8List> certificates;

  Uint8List get first => certificates.first;
}

/// Random access to an APK without holding all of it in memory: only the
/// last 64 KiB and the signing block are ever read, and a release APK is
/// 50 to 100 MB.
abstract interface class ApkSource {
  int get length;

  /// Exactly [length] bytes from [offset]; throws when the source is shorter.
  Future<Uint8List> read(int offset, int length);
}

class BytesApkSource implements ApkSource {
  BytesApkSource(this._bytes);

  final Uint8List _bytes;

  @override
  int get length => _bytes.length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    if (offset < 0 || length < 0 || offset + length > _bytes.length) {
      throw RangeError('Read past the end of the APK.');
    }
    return Uint8List.sublistView(_bytes, offset, offset + length);
  }
}

class _FileApkSource implements ApkSource {
  _FileApkSource(this._file, this.length);

  final RandomAccessFile _file;

  @override
  final int length;

  @override
  Future<Uint8List> read(int offset, int count) async {
    await _file.setPosition(offset);
    // A read may come back short without being at the end, so go on until
    // there is all of it.
    final out = Uint8List(count);
    var filled = 0;
    while (filled < count) {
      final got = await _file.readInto(out, filled, count);
      if (got <= 0) {
        throw const ApkSignatureException(ApkSignatureProblem.malformed, 'The file ended unexpectedly.');
      }
      filled += got;
    }
    return out;
  }
}

const _eocdSignature = 0x06054b50;
const _eocdMinSize = 22;
const _maxZipComment = 0xffff;
const _zip64LocatorSignature = 0x07064b50;
const _zip64LocatorSize = 20;

/// The block's trailing size field (8) and magic (16).
const _footerSize = 24;
const _magic = 'APK Sig Block 42';

const _v2BlockId = 0x7109871a;
const _v3BlockId = 0xf05368c0;

/// Real signing blocks are a few KiB: certificates, signatures and a little
/// padding. A claimed size beyond this is a lie to make us allocate.
const _maxSigningBlockBytes = 8 * 1024 * 1024;

/// Opens [file], reads its signers and closes it again.
Future<ApkSigners> readApkSignersFromFile(File file) async {
  final raf = await file.open();
  try {
    return await readApkSigners(_FileApkSource(raf, await raf.length()));
  } finally {
    await raf.close();
  }
}

/// The signers [source] declares in its v3 signature, or its v2 signature
/// when it has no v3 one. A present but unreadable v3 block is an error, not
/// a reason to fall back to v2: that would let a damaged or tampered block
/// quietly select the weaker scheme.
Future<ApkSigners> readApkSigners(ApkSource source) async {
  final total = source.length;
  if (total < _eocdMinSize) {
    throw const ApkSignatureException(ApkSignatureProblem.notAnApk, 'The file is too small to be an APK.');
  }

  // The end-of-central-directory record is the last thing in the file, but a
  // ZIP comment of up to 64 KiB may follow it.
  final tailSize = math.min(total, _eocdMinSize + _maxZipComment);
  final tailStart = total - tailSize;
  final tail = await source.read(tailStart, tailSize);
  final eocd = _findEocd(tail);
  if (eocd < 0) {
    throw const ApkSignatureException(ApkSignatureProblem.notAnApk, 'The file is not a ZIP archive.');
  }
  if (eocd >= _zip64LocatorSize && _u32(tail, eocd - _zip64LocatorSize) == _zip64LocatorSignature) {
    throw const ApkSignatureException(ApkSignatureProblem.unsupported, 'ZIP64 archives are not supported.');
  }

  final eocdAt = tailStart + eocd;
  final cdSize = _u32(tail, eocd + 12);
  final cdOffset = _u32(tail, eocd + 16);
  if (cdSize == 0xffffffff || cdOffset == 0xffffffff) {
    throw const ApkSignatureException(ApkSignatureProblem.unsupported, 'ZIP64 archives are not supported.');
  }
  // Android requires the central directory to run straight into the EOCD;
  // anything else cannot carry a valid v2 or v3 signature.
  if (cdOffset + cdSize != eocdAt) {
    throw const ApkSignatureException(
      ApkSignatureProblem.malformed,
      'The central directory is not followed directly by the end record.',
    );
  }

  if (cdOffset < _footerSize) {
    throw const ApkSignatureException(ApkSignatureProblem.noSigningBlock, 'The APK has no signing block.');
  }
  final footer = await source.read(cdOffset - _footerSize, _footerSize);
  if (!_hasMagic(footer, 8)) {
    throw const ApkSignatureException(ApkSignatureProblem.noSigningBlock, 'The APK has no signing block.');
  }

  // The size counts everything after the leading size field: the pairs, this
  // trailing size field and the magic.
  final blockSize = _u64(footer, 0);
  if (blockSize < _footerSize || blockSize > _maxSigningBlockBytes) {
    throw const ApkSignatureException(ApkSignatureProblem.malformed, 'The signing block has an impossible size.');
  }
  final blockStart = cdOffset - (blockSize + 8);
  if (blockStart < 0) {
    throw const ApkSignatureException(ApkSignatureProblem.malformed, 'The signing block is larger than the file before it.');
  }
  final block = await source.read(blockStart, blockSize + 8);
  if (_u64(block, 0) != blockSize) {
    throw const ApkSignatureException(ApkSignatureProblem.malformed, 'The signing block\'s two size fields disagree.');
  }

  Uint8List? v2;
  Uint8List? v3;
  final pairsEnd = block.length - _footerSize;
  var at = 8;
  while (at < pairsEnd) {
    if (pairsEnd - at < 12) {
      throw const ApkSignatureException(ApkSignatureProblem.malformed, 'The signing block ends inside a pair.');
    }
    // The length covers the 4-byte id and the value.
    final length = _u64(block, at);
    if (length < 4 || length > pairsEnd - at - 8) {
      throw const ApkSignatureException(ApkSignatureProblem.malformed, 'A signing block pair runs past the block.');
    }
    final id = _u32(block, at + 8);
    final value = Uint8List.sublistView(block, at + 12, at + 8 + length);
    // The first pair with an id is the one Android uses.
    if (id == _v3BlockId) v3 ??= value;
    if (id == _v2BlockId) v2 ??= value;
    at += 8 + length;
  }

  if (v3 != null) return ApkSigners(ApkSignatureScheme.v3, _signerCertificates(v3));
  if (v2 != null) return ApkSigners(ApkSignatureScheme.v2, _signerCertificates(v2));
  throw const ApkSignatureException(
    ApkSignatureProblem.noSupportedScheme,
    'The signing block has no v2 or v3 signature.',
  );
}

/// First certificate of every signer in a v2 or v3 scheme block. Both
/// schemes start a signer the same way: signed data, which opens with the
/// digests and then the certificates. Nothing after that is needed here.
List<Uint8List> _signerCertificates(Uint8List value) {
  final signers = _Reader(value).lengthPrefixed();
  final out = <Uint8List>[];
  while (signers.remaining > 0) {
    final signer = signers.lengthPrefixed();
    final signedData = signer.lengthPrefixed();
    signedData.lengthPrefixed(); // digests
    final certificates = signedData.lengthPrefixed();
    if (certificates.remaining == 0) {
      throw const ApkSignatureException(ApkSignatureProblem.malformed, 'A signer has no certificate.');
    }
    final der = certificates.lengthPrefixed().rest();
    if (!_isDerSequence(der)) {
      throw const ApkSignatureException(ApkSignatureProblem.malformed, 'A signer\'s certificate is not DER.');
    }
    out.add(der);
  }
  if (out.isEmpty) {
    throw const ApkSignatureException(ApkSignatureProblem.malformed, 'The signature has no signers.');
  }
  return out;
}

/// Last offset in [tail] where an EOCD record starts and its comment length
/// reaches exactly to the end of the file. Searching from the end and
/// insisting on that is how Android finds it too, so a comment that happens
/// to contain the record's signature cannot point us somewhere else.
int _findEocd(Uint8List tail) {
  for (var at = tail.length - _eocdMinSize; at >= 0; at--) {
    if (_u32(tail, at) != _eocdSignature) continue;
    final comment = _u16(tail, at + 20);
    if (at + _eocdMinSize + comment == tail.length) return at;
  }
  return -1;
}

bool _hasMagic(Uint8List bytes, int at) {
  for (var i = 0; i < _magic.length; i++) {
    if (bytes[at + i] != _magic.codeUnitAt(i)) return false;
  }
  return true;
}

/// An X.509 certificate is a DER SEQUENCE: tag 0x30, a definite length that
/// accounts for every remaining byte. A cheap guard that a truncated or
/// shifted structure was not mistaken for a certificate.
bool _isDerSequence(Uint8List b) {
  if (b.length < 2 || b[0] != 0x30) return false;
  var length = b[1];
  var header = 2;
  if (length & 0x80 != 0) {
    final count = length & 0x7f;
    if (count == 0 || count > 4 || b.length < 2 + count) return false;
    length = 0;
    for (var i = 0; i < count; i++) {
      length = (length << 8) | b[2 + i];
    }
    header = 2 + count;
  }
  return header + length == b.length;
}

int _u16(Uint8List b, int at) => b[at] | (b[at + 1] << 8);

int _u32(Uint8List b, int at) => b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24);

/// Little-endian 64-bit length. Anything past 2^53 is no length of ours.
int _u64(Uint8List b, int at) {
  final high = _u32(b, at + 4);
  if (high >= 0x200000) {
    throw const ApkSignatureException(ApkSignatureProblem.malformed, 'A length field is impossibly large.');
  }
  return _u32(b, at) + high * 0x100000000;
}

/// Bounds-checked cursor over a byte range; every read that would run past
/// the end is a [ApkSignatureProblem.malformed], never a RangeError.
class _Reader {
  _Reader(this._bytes);

  final Uint8List _bytes;
  int _at = 0;

  int get remaining => _bytes.length - _at;

  /// A u32 length, then that many bytes as their own reader.
  _Reader lengthPrefixed() {
    if (remaining < 4) {
      throw const ApkSignatureException(ApkSignatureProblem.malformed, 'A length prefix is cut short.');
    }
    final length = _u32(_bytes, _at);
    _at += 4;
    if (length > remaining) {
      throw const ApkSignatureException(ApkSignatureProblem.malformed, 'A length prefix runs past its container.');
    }
    final slice = Uint8List.sublistView(_bytes, _at, _at + length);
    _at += length;
    return _Reader(slice);
  }

  Uint8List rest() => Uint8List.sublistView(_bytes, _at);
}

/// Lower-case hex SHA-256 of a DER certificate: the fingerprint `keytool` and
/// `apksigner` print, without the colons.
String certificateSha256(List<int> der) => sha256.convert(der).toString();

/// `E5:8B:18:…`, the form fingerprints are published in. [hex] is 64 hex
/// digits in either case.
String formatFingerprint(String hex) {
  final upper = hex.toUpperCase();
  return [for (var i = 0; i + 2 <= upper.length; i += 2) upper.substring(i, i + 2)].join(':');
}

/// [text] as lower-case hex without separators, or null when it is not a
/// SHA-256 value (64 hex digits, optionally colon-separated).
String? normalizeSha256(String text) {
  final hex = text.replaceAll(':', '').toLowerCase();
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(hex) ? hex : null;
}
