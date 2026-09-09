import 'package:argus_wallet/ui/rosen_screen.dart';
import 'package:argus_wallet/services/app_fee.dart';
import 'dart:convert';

import 'package:argus_wallet/services/rosen_service.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeGateway implements RosenGateway {
  int? height = 1866700;
  final validated = <String>[];
  @override
  String? get nodeUrl => 'http://node';
  @override
  String get explorerBase => 'https://explorer/';
  @override
  int? get chainHeight => height;
  @override
  String info() => jsonEncode({
        'lock_address': 'nB3L2PD',
        'min_fee_nft': 'fee-nft',
        'contracts_version': '7.1.0',
        'tokens_map_version': '7.1.0',
        'chains': ['cardano', 'bitcoin'],
        'tokens': [
          {
            'ergo_token_id': 'erg', 'name': 'ERG', 'decimals': 9, 'residency': 'native',
            'targets': [
              {'chain': 'cardano', 'token_id': 'rserg', 'name': 'rsERG', 'decimals': 9},
            ],
          },
          {
            'ergo_token_id': 'sigusd', 'name': 'SigUSD', 'decimals': 2, 'residency': 'native',
            'targets': [
              {'chain': 'cardano', 'token_id': 'rssigusd', 'name': 'rsSigUSD', 'decimals': 2},
              {'chain': 'bitcoin', 'token_id': 'x', 'name': 'rsSigUSD', 'decimals': 2},
            ],
          },
        ],
      });
  @override
  String quote(String feeBoxesJson, String tokenId, String toChain, int amount, int height) {
    final boxes = jsonDecode(feeBoxesJson) as List;
    if (boxes.isEmpty) throw StateError('no fee box');
    // Minimum 3.00, ratio 0.5%, network 1.00.
    final variable = amount * 50 ~/ 10000;
    final bridge = variable > 300 ? variable : 300;
    return jsonEncode({
      'fee': {'bridge_fee': 300, 'network_fee': 100, 'fee_ratio': 50, 'rsn_ratio': 1, 'rsn_ratio_divisor': 1},
      'quote': {'amount': amount, 'bridge_fee': bridge, 'network_fee': 100, 'receiving': amount - bridge - 100, 'min_transfer': 401},
      'fee_box_id': 'fb',
    });
  }
  @override
  String validateAddress(String chain, String address) {
    validated.add('$chain:$address');
    return address.startsWith('addr1') ? '' : 'not a cardano address: bad bech32 checksum';
  }
}

void main() {
  test('ERG MAX reserves fees and change when tokens remain', () {
    expect(rosenMaxAmount(held: 1000000000, isErg: true, availableErg: 1000000000,
      hasTokens: false), 1000000000 - txOverheadNano());
    expect(rosenMaxAmount(held: 1000000000, isErg: true, availableErg: 1000000000,
      hasTokens: true), 1000000000 - txOverheadNano() - 1000000);
    expect(rosenMaxAmount(held: 1, isErg: true, availableErg: 1, hasTokens: false), 0);
    expect(rosenMaxAmount(held: 500, isErg: false, availableErg: 0, hasTokens: true), 0);
    expect(rosenMaxAmount(held: 500, isErg: false, availableErg: 1000000000, hasTokens: true), 500);
  });

  test('holdings pair the vendored tokens with what the wallet holds, ERG always', () {
    final svc = RosenService(gateway: FakeGateway(), get: (_) async => '[]');
    final h = svc.holdings(5, {'sigusd': 700, 'other': 9});
    expect(h.map((x) => '${x.$1.name}:${x.$2}'), ['ERG:5', 'SigUSD:700']);
    expect(svc.lockAddress, 'nB3L2PD');
    expect(svc.tokens.last.targets.map((t) => t.chain), ['cardano', 'bitcoin']);
    expect(rosenChainName('binance'), 'BNB Chain');
  });

  test('fees are read page by page and a quote comes from them', () async {
    final gw = FakeGateway();
    final requests = <String>[];
    final svc = RosenService(
      gateway: gw,
      get: (uri) async {
        requests.add(uri.toString());
        final offset = int.parse(uri.queryParameters['offset']!);
        if (offset == 0) return jsonEncode([for (var i = 0; i < 100; i++) {'boxId': 'b$i'}]);
        return jsonEncode([{'boxId': 'b100'}]);
      },
    );
    expect(() => svc.quote(tokenId: 'sigusd', toChain: 'cardano', amount: 1000), throwsStateError, reason: 'fees not read');
    await svc.refreshFees();
    expect(svc.lastError, isNull);
    expect(requests.length, 2, reason: 'a full page asks for the next');
    expect(requests.first, contains('byTokenId/fee-nft'));
    expect((jsonDecode(svc.lastFeeBoxesJson!) as List).length, 101);
    final q = svc.quote(tokenId: 'sigusd', toChain: 'cardano', amount: 100000);
    expect(q.bridgeFee, 500, reason: '0.5% of 1,000.00 beats the 3.00 minimum');
    expect(q.receiving, 100000 - 500 - 100);
    expect(q.minTransfer, 401);
    gw.height = null;
    expect(() => svc.quote(tokenId: 'sigusd', toChain: 'cardano', amount: 1), throwsStateError, reason: 'no height');
  });

  test('addresses are checked through the bridge codec and the tracking link names the tx', () {
    final gw = FakeGateway();
    final svc = RosenService(gateway: gw, get: (_) async => '[]');
    expect(svc.addressProblem('cardano', 'addr1qx'), isEmpty);
    expect(svc.addressProblem('cardano', 'DH5y'), contains('checksum'));
    expect(gw.validated, ['cardano:addr1qx', 'cardano:DH5y']);
    expect(RosenService.trackingUrl('abc'), contains('abc'));
  });
}
