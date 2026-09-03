import 'package:argus_wallet/services/media_url.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ipfs links resolve to a gateway', () {
    expect(resolveMediaUrl('ipfs://bafy123/img.png'), 'https://ipfs.io/ipfs/bafy123/img.png');
    expect(resolveMediaUrl('ipfs://ipfs/bafy123'), 'https://ipfs.io/ipfs/bafy123');
  });

  test('http links pass through and others are dropped', () {
    expect(resolveMediaUrl('https://x/y.png'), 'https://x/y.png');
    expect(resolveMediaUrl('http://x/y.png'), 'http://x/y.png');
    expect(resolveMediaUrl('javascript:alert(1)'), isNull);
    expect(resolveMediaUrl(null), isNull);
    expect(resolveMediaUrl(''), isNull);
  });
}
