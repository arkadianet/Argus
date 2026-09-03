import 'package:argus_wallet/services/sigma_registers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decodes a serialized SInt register', () {
    // 0x04 = SInt, then zigzag VLQ of 14011 (28022 = 0xDA 0x76 in VLQ).
    expect(decodeSigmaInt('04f6da01'), 14011);
    expect(decodeSigmaInt('042a'), 21);
    expect(decodeSigmaInt('0401'), -1);
  });

  test('decodes a serialized Coll[Long] register', () {
    // 0x11 = Coll[Long], count 3, then zigzag VLQs: 1, -2, 300
    expect(decodeSigmaLongColl('11030203d804'), [1, -2, 300]);
  });

  test('returns null for other types or malformed hex', () {
    expect(decodeSigmaInt('07ab'), isNull);
    expect(decodeSigmaLongColl('0401'), isNull);
    expect(decodeSigmaLongColl('11'), isNull);
    expect(decodeSigmaInt('zz'), isNull);
  });

  test('handles a real oracle price vector', () {
    // Coll[Long] with 21 entries as published by an AVL oracle box.
    final v = decodeSigmaLongColl('1115' '02040608' '${'00' * 17}');
    expect(v, isNotNull);
    expect(v!.length, 21);
    expect(v.take(5).toList(), [1, 2, 3, 4, 0]);
  });
}
