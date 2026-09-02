import 'package:argus_wallet/services/network_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sigmaspace token url', () {
    expect(explorerTokenUrl('https://api.sigmaspace.io', 'abc'),
        'https://sigmaspace.io/en/token/abc');
  });
  test('ergoplatform token url', () {
    expect(explorerTokenUrl('https://api.ergoplatform.com', 'abc'),
        'https://explorer.ergoplatform.com/en/token/abc');
  });
  test('unknown explorer falls back to a path on the explorer host', () {
    expect(explorerTokenUrl('https://x.example/', 'abc'),
        'https://x.example/en/token/abc');
  });
}
