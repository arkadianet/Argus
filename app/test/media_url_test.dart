import 'package:argus_wallet/services/media_url.dart';
import 'package:flutter_test/flutter_test.dart';
void main() {
  test('issuer URLs never become automatically fetchable widget URLs', () {
    for (final uri in [null, '', 'https://x/y.png', 'http://x/y.png',
      'ipfs://bafy123/img.png', 'file:///secret', 'data:image/png;base64,AA',
      'https://127.0.0.1/a', 'https://[::ffff:127.0.0.1]/a']) {
      expect(resolveMediaUrl(uri), isNull);
    }
  });
}
