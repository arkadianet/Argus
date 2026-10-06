import 'dart:convert';
import 'dart:typed_data';

import 'token_evidence.dart';

/// The scale one issuance inspection establishes for a token, and the
/// metadata state that goes with it.
class DeclaredDecimals {
  const DeclaredDecimals(this.decimals, this.evidence, this.metadataState);

  final int decimals;
  final DecimalsEvidence evidence;
  final MetadataState metadataState;
}

/// The decimals one `inspect_token_metadata` answer establishes.
///
/// The native parser takes R6 only in EIP-4's form, a byte string of
/// decimal digits, and says "unknown" both when nothing could be read and
/// when the issuance box simply has no R6. The wallet's rule:
///
///  * R6, or the token record's decimals with nothing contradicting them:
///    [DecimalsEvidence.valid], as the parser says.
///  * The box was read and has no R6: zero decimals,
///    [DecimalsEvidence.absent]. The node's token record and the explorers
///    say 0, and EIP-4 tokens without an R6 are shown that way everywhere.
///  * R6 written as a plain integer constant instead of digits, as some
///    minting tools write it (`0400`, an Int 0): valid when it is 0–255 and
///    the token record, where there is one, agrees. The node's own record
///    reads such an R6 the same way. The box is then only as invalid as its
///    other registers make it.
///  * Any other R6, or one the record contradicts: [DecimalsEvidence.invalid].
///  * Nothing that says what the decimals are: [DecimalsEvidence.unknown].
DeclaredDecimals declaredDecimals(Map<String, dynamic> m) {
  final reported = (m['decimals'] as num?)?.toInt();
  final state = _byName(
    MetadataState.values,
    m['metadataState'],
    MetadataState.partial,
  );
  final registers = _registers(m['rawRegisters']);
  switch (m['decimalsEvidence']) {
    case 'valid':
      return DeclaredDecimals(reported ?? 0, DecimalsEvidence.valid, state);
    case 'invalid':
      final r6 = registers == null ? null : integerRegister(registers['R6']);
      final readable =
          r6 != null && r6 >= 0 && r6 <= 255 && (reported == null || reported == r6);
      if (!readable) {
        return DeclaredDecimals(reported ?? 0, DecimalsEvidence.invalid, state);
      }
      final repaired =
          state == MetadataState.invalid && _otherRegistersReadable(registers!)
          ? MetadataState.partial
          : state;
      return DeclaredDecimals(r6, DecimalsEvidence.valid, repaired);
    default:
      // A box that conflicts with its token record, or was too large to
      // read, says nothing trustworthy about what it lacks.
      final trusted =
          state != MetadataState.invalid && state != MetadataState.conflict;
      final boxRead = registers != null || m['issuanceTransactionId'] != null;
      if (trusted && boxRead && !(registers?.containsKey('R6') ?? false)) {
        return DeclaredDecimals(0, DecimalsEvidence.absent, state);
      }
      return DeclaredDecimals(reported ?? 0, DecimalsEvidence.unknown, state);
  }
}

/// A register's value as a plain integer constant (SByte, SShort, SInt or
/// SLong, canonically encoded with nothing after it), or null when it is
/// anything else. [value] is a register as a node or an explorer lists it:
/// the hex string, or an object carrying `serializedValue`.
int? integerRegister(Object? value) {
  final bytes = _hexBytes(_serialized(value));
  if (bytes == null || bytes.length < 2) return null;
  switch (bytes[0]) {
    case 0x02: // SByte: one byte, signed.
      if (bytes.length != 2) return null;
      return bytes[1] >= 0x80 ? bytes[1] - 0x100 : bytes[1];
    case 0x03 || 0x04 || 0x05: // SShort, SInt, SLong: zigzag VLQ.
      final (raw, used) = _vlq(bytes, 1) ?? (-1, 0);
      if (raw < 0 || 1 + used != bytes.length) return null;
      return (raw >> 1) ^ -(raw & 1);
    default:
      return null;
  }
}

/// A register's value as a canonically encoded `Coll[Byte]`, or null.
Uint8List? byteStringRegister(Object? value) {
  final bytes = _hexBytes(_serialized(value));
  if (bytes == null || bytes.isEmpty || bytes[0] != 0x0e) return null;
  final (length, used) = _vlq(bytes, 1) ?? (-1, 0);
  if (length < 0 || 1 + used + length != bytes.length) return null;
  return Uint8List.sublistView(bytes, 1 + used);
}

/// R4 and R5, where present, are UTF-8 byte strings, and R7 a byte string:
/// what the native parser would have accepted had R6 not stopped it.
bool _otherRegistersReadable(Map<String, dynamic> registers) {
  bool text(String reg) {
    if (!registers.containsKey(reg)) return true;
    final bytes = byteStringRegister(registers[reg]);
    if (bytes == null) return false;
    try {
      utf8.decode(bytes);
      return true;
    } on FormatException {
      return false;
    }
  }

  return text('R4') &&
      text('R5') &&
      (!registers.containsKey('R7') ||
          byteStringRegister(registers['R7']) != null);
}

/// An unsigned VLQ at [start]: its value and how many bytes it took, or
/// null when it runs off the end, is longer than a 32-bit value needs, or
/// is not minimal.
(int, int)? _vlq(Uint8List bytes, int start) {
  var value = 0;
  var shift = 0;
  for (var i = start; i < bytes.length; i++) {
    final b = bytes[i];
    value |= (b & 0x7f) << shift;
    if (b & 0x80 == 0) {
      final used = i - start + 1;
      // A trailing zero group encodes nothing: not how anyone writes it.
      if (used > 1 && b == 0) return null;
      return (value, used);
    }
    shift += 7;
    if (shift > 28) return null;
  }
  return null;
}

String? _serialized(Object? value) => switch (value) {
  final String hex => hex,
  final Map map => map['serializedValue'] is String
      ? map['serializedValue'] as String
      : null,
  _ => null,
};

final _hex = RegExp(r'^[0-9a-fA-F]+$');

Uint8List? _hexBytes(String? hex) {
  if (hex == null ||
      hex.length.isOdd ||
      hex.length > 16384 ||
      !_hex.hasMatch(hex)) {
    return null;
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) return null;
    out[i] = byte;
  }
  return out;
}

Map<String, dynamic>? _registers(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map ? decoded.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

T _byName<T extends Enum>(List<T> values, Object? raw, T fallback) {
  for (final v in values) {
    if (v.name == raw) return v;
  }
  return fallback;
}
