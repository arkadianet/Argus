import 'package:argus_wallet/services/explorer_presets.dart';
import 'package:argus_wallet/services/network_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  _presetTests();
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

void _presetTests() {
  test('every site opens a transaction and a token on its own host', () {
    expect(sigmaSpaceSite.tx('abc'), 'https://sigmaspace.io/en/transaction/abc');
    expect(ergoPlatformSite.tx('abc'),
        'https://explorer.ergoplatform.com/en/transactions/abc');
    expect(ergExplorerSite.tx('abc'), 'https://ergexplorer.com/transactions/abc');
    expect(kadiaSite.tx('abc'), 'https://explorer.kadia.io/tx/abc');
    expect(ergExplorerSite.token('t'), 'https://ergexplorer.com/token/t');
    expect(kadiaSite.token('t'), 'https://explorer.kadia.io/token/t');
  });
  test('only SigmaSpace and Ergo Platform can be the API', () {
    expect(explorerApiSites.map((s) => s.id), ['sigmaspace', 'ergoplatform']);
  });
  test('a saved API maps to its own site, unknown ones to none', () {
    expect(explorerSiteForApi('https://api.sigmaspace.io'), sigmaSpaceSite);
    expect(explorerSiteForApi('https://api.ergoplatform.com'), ergoPlatformSite);
    expect(explorerSiteForApi('https://x.example'), isNull);
  });
  test('custom links use the Ergo Platform paths on the given site', () {
    expect(
      explorerTxLink(siteId: 'custom', custom: 'https://x.example/', txId: 'abc'),
      'https://x.example/en/transactions/abc',
    );
    expect(
      explorerTokenLink(siteId: null, custom: 'https://x.example', tokenId: 't'),
      'https://x.example/en/token/t',
    );
  });
  test('a chosen site wins over the custom address', () {
    expect(
      explorerTxLink(siteId: 'kadia', custom: 'https://x.example', txId: 'abc'),
      'https://explorer.kadia.io/tx/abc',
    );
  });
}
