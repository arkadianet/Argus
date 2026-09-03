import 'package:argus_wallet/services/route_quote_controller.dart';
import 'package:argus_wallet/services/token_router.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  RouteQuote q(int cost) => RouteQuote(protocol: 'Dexy', path: 'FreeMint', tokenId: 't', acquire: 1, held: 0, ergCostNano: cost, minerFeeNano: 1);

  test('a blank or zero amount clears quotes without calling the network', () async {
    var calls = 0;
    final c = RouteQuoteController(quote: (id, wanted, held) async { calls++; return [q(1)]; }, debounce: Duration.zero);
    c.request('t', '0', decimals: 0, held: 0);
    await Future<void>.delayed(Duration.zero);
    expect(c.quotes, isNull);
    expect(calls, 0);
  });

  test('the latest request wins over a slower earlier one', () async {
    final c = RouteQuoteController(
      quote: (id, wanted, held) async {
        if (wanted == 1) await Future<void>.delayed(const Duration(milliseconds: 30));
        return [q(wanted)];
      },
      debounce: Duration.zero,
    );
    c.request('t', '1', decimals: 0, held: 0);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    c.request('t', '2', decimals: 0, held: 0);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(c.quotes?.single.ergCostNano, 2);
  });

  test('a failed quote clears the list', () async {
    final c = RouteQuoteController(quote: (id, wanted, held) async => throw Exception('down'), debounce: Duration.zero);
    c.request('t', '3', decimals: 0, held: 0);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(c.quotes, isNull);
  });

  test('held tokens are passed through and decimals scale the amount', () async {
    int? seenWanted;
    int? seenHeld;
    final c = RouteQuoteController(quote: (id, wanted, held) async { seenWanted = wanted; seenHeld = held; return []; }, debounce: Duration.zero);
    c.request('t', '1.5', decimals: 2, held: 40);
    await Future<void>.delayed(Duration.zero);
    expect(seenWanted, 150);
    expect(seenHeld, 40);
  });
}
