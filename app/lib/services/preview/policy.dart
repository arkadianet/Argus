import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

class PreviewFailure implements Exception {
  const PreviewFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

Never refuse(String message) => throw PreviewFailure(message);
const maxPreviewBytes = 5 * 1024 * 1024;

Uri gatewayOrigin(String value) {
  final uri = Uri.tryParse(value);
  if (value.length > 2048 ||
      uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.host.runes.any((c) => c > 127) ||
      uri.port != 443 ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    refuse(
      'Use an HTTPS gateway origin on port 443, without credentials, path or query.',
    );
  }
  final host = uri.host.replaceAll('[', '').replaceAll(']', '');
  final literal = InternetAddress.tryParse(host);
  if (literal != null && !publicAddress(literal))
    refuse('Gateway address is not public.');
  if (literal == null &&
      (!host.contains('.') ||
          host.endsWith('.') ||
          !RegExp(r'^[a-z0-9.-]+$').hasMatch(host) ||
          [
            'localhost',
            'local',
            'internal',
            'home',
            'lan',
            'test',
            'invalid',
          ].any((s) => host == s || host.endsWith('.$s')))) {
    refuse('Use a public gateway hostname.');
  }
  return uri.replace(path: '');
}

// Conservative global-unicast allowlist. Reject special-use ranges even when
// an OS resolver reports them as ordinary addresses. No mapped IPv4 or tunnels.
bool publicAddress(InternetAddress address) {
  final b = address.rawAddress;
  if (b.length == 4) {
    final a = b[0], c = b[1];
    return !(a == 0 ||
        a == 10 ||
        a == 127 ||
        a >= 224 ||
        (a == 100 && c >= 64 && c <= 127) ||
        (a == 169 && c == 254) ||
        (a == 172 && c >= 16 && c <= 31) ||
        (a == 192 && (c == 0 || c == 168 || (c == 88 && b[2] == 99))) ||
        (a == 198 && (c == 18 || c == 19 || (c == 51 && b[2] == 100))) ||
        (a == 203 && c == 0 && b[2] == 113));
  }
  return b.length == 16 &&
      b[0] >= 0x20 &&
      b[0] <= 0x3f &&
      !(b[0] == 0x20 &&
          b[1] == 1 &&
          (b[2] < 2 || (b[2] == 0x0d && b[3] == 0xb8))) &&
      !(b[0] == 0x20 && b[1] == 2) &&
      !(b[0] == 0x3f && b[1] == 0xff);
}

List<int> _base(String text, String alphabet) {
  var n = BigInt.zero;
  for (final c in text.split('')) {
    final digit = alphabet.indexOf(c);
    if (digit < 0) refuse('Malformed IPFS CID.');
    n = n * BigInt.from(alphabet.length) + BigInt.from(digit);
  }
  final bytes = <int>[];
  while (n > BigInt.zero) {
    bytes.add((n & BigInt.from(255)).toInt());
    n >>= 8;
  }
  return bytes.reversed.toList();
}

/// CIDv0 (base58btc) and CIDv1 (canonical lowercase base32), optional safe path.
/// Never use Uri.host for a CIDv0: host normalization would change its case.
List<String> ipfsPath(String raw) {
  if (!raw.startsWith('ipfs://') || raw.length > 2048) {
    refuse(
      'Only IPFS artwork can be displayed. Issuer hosts are refused because the issuer would choose who learns you looked.',
    );
  }
  final parts = raw.substring(7).split('/');
  final cid = parts.first;
  if (cid.length > 160 || cid.isEmpty) refuse('Malformed IPFS CID.');
  if (cid.startsWith('Qm')) {
    final b = _base(
      cid,
      '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz',
    );
    if (cid.length != 46 || b.length != 34 || b[0] != 0x12 || b[1] != 32)
      refuse('Malformed IPFS CID.');
  } else if (cid.startsWith('b')) {
    final bytes = <int>[];
    var bits = 0, buffer = 0;
    for (final c in cid.substring(1).split('')) {
      final v = 'abcdefghijklmnopqrstuvwxyz234567'.indexOf(c);
      if (v < 0) refuse('Malformed IPFS CID.');
      buffer = (buffer << 5) | v;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        bytes.add((buffer >> bits) & 255);
        buffer &= (1 << bits) - 1;
      }
    }
    if (bits >= 5 || buffer != 0) refuse('Noncanonical IPFS CID.');
    var offset = 0;
    int varint() {
      var value = 0, shift = 0;
      while (offset < bytes.length && shift < 35) {
        final b = bytes[offset++];
        value |= (b & 127) << shift;
        if (b < 128) {
          if (shift > 0 && b == 0) refuse('Noncanonical IPFS CID.');
          return value;
        }
        shift += 7;
      }
      refuse('Malformed IPFS CID.');
    }

    if (varint() != 1 || varint() == 0 || varint() == 0)
      refuse('Unsupported IPFS CID.');
    final length = varint();
    if (length < 1 || length > 64 || bytes.length - offset != length)
      refuse('Malformed IPFS CID.');
  } else {
    refuse('Use a CIDv0 or lowercase base32 CIDv1 IPFS URI.');
  }
  for (final part in parts.skip(1)) {
    if (part.isEmpty ||
        part == '.' ||
        part == '..' ||
        !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(part))
      refuse('Unsupported IPFS path.');
  }
  return ['ipfs', ...parts];
}

class CheckedImage {
  const CheckedImage(this.width, this.height, this.matchesHash);
  final int width, height;
  final bool matchesHash;
}

void _dimensions(int w, int h) {
  if (w < 1 || h < 1 || w > 4096 || h > 4096 || w * h > 8000000)
    refuse('Image dimensions exceed 4096 per axis or 8 megapixels.');
}

/// Header-only inspection: no image codec or pixel allocation is invoked here.
CheckedImage inspectImage(Uint8List bytes, String mime, String? hash) {
  if (bytes.length > maxPreviewBytes) refuse('Artwork exceeds 5 MiB.');
  final data = ByteData.sublistView(bytes);
  var w = 0, h = 0;
  final png =
      bytes.length >= 33 &&
      [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
      ].asMap().entries.every((e) => bytes[e.key] == e.value);
  final jpeg = bytes.length >= 4 && bytes[0] == 255 && bytes[1] == 216;
  if (png && mime == 'image/png') {
    var pos = 8;
    var ihdr = false, idat = false, end = false;
    while (pos + 12 <= bytes.length) {
      final length = data.getUint32(pos);
      if (length > bytes.length - pos - 12) refuse('Malformed PNG.');
      final type = String.fromCharCodes(bytes.sublist(pos + 4, pos + 8));
      if (type == 'acTL' || type == 'fcTL' || type == 'fdAT')
        refuse('Animated PNG is unsupported.');
      if (!ihdr && type != 'IHDR') refuse('Malformed PNG.');
      if (type == 'IHDR') {
        if (ihdr || length != 13) refuse('Malformed PNG.');
        ihdr = true;
        w = data.getUint32(pos + 8);
        h = data.getUint32(pos + 12);
        _dimensions(w, h);
      }
      if (type == 'IDAT') idat = true;
      pos += length + 12;
      if (type == 'IEND') {
        end = length == 0 && pos == bytes.length;
        break;
      }
    }
    if (!ihdr || !idat || !end) refuse('Malformed PNG.');
  } else if (jpeg && mime == 'image/jpeg') {
    var pos = 2;
    var sof = false, scan = false;
    while (pos < bytes.length) {
      if (bytes[pos++] != 255) refuse('Malformed JPEG.');
      while (pos < bytes.length && bytes[pos] == 255) {
        pos++;
      }
      if (pos + 2 >= bytes.length) refuse('Malformed JPEG.');
      final marker = bytes[pos++];
      final length = data.getUint16(pos);
      if (length < 2 || pos + length > bytes.length) refuse('Malformed JPEG.');
      if (marker >= 0xc0 &&
          marker <= 0xcf &&
          marker != 0xc4 &&
          marker != 0xc8 &&
          marker != 0xcc) {
        if (sof || (marker != 0xc0 && marker != 0xc2) || length < 8)
          refuse('Unsupported JPEG frame.');
        sof = true;
        h = data.getUint16(pos + 3);
        w = data.getUint16(pos + 5);
        _dimensions(w, h);
      }
      if (marker == 0xda) {
        scan = true;
        break;
      }
      pos += length;
    }
    if (!sof || !scan) refuse('Malformed JPEG.');
    // Forbid later frame headers and DNL (which could change dimensions).
    for (var i = pos; i + 1 < bytes.length; i++) {
      if (bytes[i] != 255) continue;
      final m = bytes[i + 1];
      if (m == 0xdc ||
          (m >= 0xc0 && m <= 0xcf && m != 0xc4 && m != 0xc8 && m != 0xcc))
        refuse('Unsupported JPEG frame.');
    }
  } else {
    refuse(
      'Only static PNG and JPEG with matching bytes and MIME are supported.',
    );
  }
  final validHash = hash != null && RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(hash);
  final digest = sha256.convert(bytes).toString();
  if (validHash && digest != hash.toLowerCase())
    refuse('Content differs from issuance hash.');
  return CheckedImage(w, h, validHash);
}
