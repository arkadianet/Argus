import 'package:argus_wallet/services/token_router.dart';
import 'package:argus_wallet/ui/send_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  RouteQuote q(String protocol, String path, int cost, {String? note}) => RouteQuote(
        protocol: protocol, path: path, tokenId: 't', acquire: 1, held: 0, ergCostNano: cost, minerFeeNano: 1, note: note);

  test('quote line states the ERG unit exactly once and names the route', () {
    final label = routeQuoteLabel(q('Dexy', 'FreeMint', 3719600000), cheapest: true);
    expect(label, '≈ 3.7196 ERG · Dexy FreeMint  ·  cheapest');
    expect('ERG'.allMatches(label), hasLength(1));
  });

  test('quote line marks only the cheapest route and carries a note', () {
    expect(routeQuoteLabel(q('Spectrum', 'Pool', 3700970000, note: '0.3% pool fee'), cheapest: false),
        '≈ 3.70097 ERG · Spectrum Pool (0.3% pool fee)');
  });

  test('amount label names the token', () {
    expect(buyAmountLabel(const BuyableToken(id: 'x', name: 'SigUSD', decimals: 2, protocol: 'AgeUSD')), 'SigUSD amount to deliver');
  });
}
