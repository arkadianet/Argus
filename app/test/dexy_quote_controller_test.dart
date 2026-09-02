import 'package:argus_wallet/services/dexy_quote_controller.dart';
import 'package:argus_wallet/services/dexy_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DexyPathQuote q(int cost) => DexyPathQuote(path: 'FreeMint', ergCostNano: cost);

  test('a blank or zero amount clears quotes without calling the network', () async {
    var calls = 0;
    final c = DexyQuoteController(
      quote: (v, amount, held) async {
        calls++;
        return [q(1)];
      },
      debounce: Duration.zero,
    );
    c.request(DexyVariant.gold, '0', held: 0);
    await Future<void>.delayed(Duration.zero);
    expect(c.quotes, isNull);
    expect(calls, 0);
  });

  test('the latest request wins over a slower earlier one', () async {
    final c = DexyQuoteController(
      quote: (v, amount, held) async {
        if (amount == 1) await Future<void>.delayed(const Duration(milliseconds: 30));
        return [q(amount)];
      },
      debounce: Duration.zero,
    );
    c.request(DexyVariant.gold, '1', held: 0);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    c.request(DexyVariant.gold, '2', held: 0);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(c.quotes?.single.ergCostNano, 2);
  });

  test('a failed quote clears the list', () async {
    final c = DexyQuoteController(
      quote: (v, amount, held) async => throw Exception('down'),
      debounce: Duration.zero,
    );
    c.request(DexyVariant.gold, '3', held: 0);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(c.quotes, isNull);
  });
}
