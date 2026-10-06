import 'dart:convert';
import 'dart:io';

import 'package:argus_wallet/services/oracle_feeds.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _box(String name) {
  final raw = jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map;
  return ((raw['items'] as List).first as Map).cast<String, dynamic>();
}

void main() {
  test('SLong registers decode', () {
    // The SigmaUSD pool's R4 at height 1,888,755.
    expect(decodeSigmaLong('0584f19fa317'), 3123969090);
    expect(decodeSigmaLong('0500'), 0);
    expect(decodeSigmaLong('0501'), -1);
    expect(decodeSigmaLong('04ca0f'), isNull, reason: 'an Int is not a Long');
    expect(decodeSigmaLong('05'), isNull);
    expect(decodeSigmaLong('05ff'), isNull, reason: 'unterminated VLQ');
  });

  /// Recorded from node.kadia.io: the SigmaUSD ERG/USD pool box. It holds
  /// only the pool NFT, R5 is the epoch's end height (one block past its
  /// inclusion) and R6 a 32-byte hash: the original oracle pool layout, not
  /// oracle-core v2's. R4 is nanoERG per dollar.
  test('the real SigmaUSD pool box reads as nanoERG per dollar', () {
    final box = _box('sigmausd_oracle_pool_box.json');
    expect(((box['assets'] as List).single as Map)['tokenId'], OracleFeed.sigmaUsd.nft);
    final r = readingFromBox(box)!;
    expect(r.rate, 3123969090);
    expect(r.height, 1888755);
    expect(usdPerErg(r), closeTo(0.32011, 0.00001));
    // An independent oracle-core v2 pool quoting the same unit agrees.
    final dexyUsd = readingFromBox(_box('dexy_usd_oracle_box.json'))!;
    expect((usdPerErg(dexyUsd) - usdPerErg(r)).abs() / usdPerErg(r), lessThan(0.0001));
  });

  test('the real Dexy gold pool box reads as nanoERG per kilogram', () {
    final r = readingFromBox(_box('dexy_gold_oracle_box.json'))!;
    expect(r.height, 1888750);
    final usdPerMg = r.rate / 1e6 / 1e9 * 0.32011;
    final usdPerOunce = usdPerMg * mgPerTroyOunce;
    // Gold's dollar price, not a milligram's nanoERG or a kilogram's.
    expect(usdPerOunce, inInclusiveRange(1000, 10000));
  });

  test('a box without a Long rate is no reading', () {
    expect(readingFromBox({'additionalRegisters': {'R4': '04ca0f'}, 'inclusionHeight': 1}), isNull);
    expect(readingFromBox({'additionalRegisters': {}, 'inclusionHeight': 1}), isNull);
    expect(readingFromBox({'additionalRegisters': {'R4': '0500'}, 'inclusionHeight': 1}), isNull);
    final nested = readingFromBox({
      'additionalRegisters': {
        'R4': {'serializedValue': '0584f19fa317'},
      },
      'creationHeight': 7,
    })!;
    expect(nested.rate, 3123969090);
    expect(nested.height, 7, reason: 'creation height when inclusion height is absent');
  });

  test('ages read in plain units', () {
    expect(ageText(10), '20 min');
    expect(ageText(90), '3 h');
    expect(ageText(15939), '22 days');
  });

  test('the newest pool box comes from the node\'s unspent index', () async {
    Uri? asked;
    final client = MockClient((req) async {
      asked = req.url;
      return http.Response(jsonEncode({'items': [_box('sigmausd_oracle_pool_box.json')], 'total': 1}), 200);
    });
    final r = await fetchOracleReading('https://node.example/', OracleFeed.sigmaUsd, client: client);
    expect(r!.rate, 3123969090);
    expect(asked.toString(),
        'https://node.example/blockchain/box/unspent/byTokenId/${OracleFeed.sigmaUsd.nft}?offset=0&limit=1');
    final missing = MockClient((_) async => http.Response('{"items":[],"total":0}', 200));
    expect(await fetchOracleReading('https://node.example', OracleFeed.dexyGold, client: missing), isNull);
  });
}
