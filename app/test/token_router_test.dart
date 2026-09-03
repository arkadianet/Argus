import 'package:argus_wallet/services/token_router.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeProvider implements RouteProvider {
  FakeProvider(this.protocol, {required this.tokens, required this.costs, this.failBuild = false});
  final String protocol;
  final Set<String> tokens;
  final Map<String, int> costs; // path -> erg cost
  final bool failBuild;
  final builtPaths = <String>[];

  @override
  bool supports(String tokenId) => tokens.contains(tokenId);

  @override
  Future<List<RouteQuote>> quote(String tokenId, int acquire, int held) async => [
        for (final e in costs.entries)
          RouteQuote(
            protocol: protocol,
            path: e.key,
            tokenId: tokenId,
            acquire: acquire,
            held: held,
            ergCostNano: e.value,
            minerFeeNano: 1100000,
          ),
      ];

  @override
  Future<RouteBuild> build(RouteQuote q, {required String recipient, required String changeAddress, required List<String> spendAddresses}) async {
    builtPaths.add(q.path);
    if (failBuild) throw Exception('$protocol down');
    return RouteBuild(
      preparationId: 7,
      protocol: protocol,
      path: q.path,
      tokenId: q.tokenId,
      delivered: q.acquire + q.held,
      acquired: q.acquire,
      held: q.held,
      ergCostNano: q.ergCostNano,
      minerFeeNano: q.minerFeeNano,
      protocolFeeNano: 0,
      changeNanoErg: 0,
    );
  }
}

void main() {
  test('quotes only the shortfall and sorts across protocols by cost', () async {
    final r = TokenRouter([
      FakeProvider('Dexy', tokens: {'usd'}, costs: {'FreeMint': 300, 'LP Swap': 250}),
      FakeProvider('Spectrum', tokens: {'usd', 'rsn'}, costs: {'Pool': 200}),
    ]);
    final quotes = await r.quote('usd', wanted: 10, held: 3);
    expect(quotes.map((q) => q.path), ['Pool', 'LP Swap', 'FreeMint']);
    expect(quotes.every((q) => q.acquire == 7 && q.held == 3), isTrue);
  });

  test('nothing to acquire yields no quotes', () async {
    final r = TokenRouter([FakeProvider('Dexy', tokens: {'usd'}, costs: {'FreeMint': 1})]);
    expect(await r.quote('usd', wanted: 5, held: 5), isEmpty);
    expect(await r.quote('usd', wanted: 5, held: 9), isEmpty);
  });

  test('unsupported token has no route', () async {
    final r = TokenRouter([FakeProvider('Dexy', tokens: {'usd'}, costs: {'FreeMint': 1})]);
    expect(await r.quote('xyz', wanted: 5, held: 0), isEmpty);
    expect(r.build('xyz', wanted: 5, held: 0, recipient: 'r', changeAddress: 'c', spendAddresses: ['s']),
        throwsA(isA<NoRouteException>()));
  });

  test('build takes the cheapest route and falls back when it fails', () async {
    final spectrum = FakeProvider('Spectrum', tokens: {'usd'}, costs: {'Pool': 100}, failBuild: true);
    final dexy = FakeProvider('Dexy', tokens: {'usd'}, costs: {'FreeMint': 150});
    final r = TokenRouter([dexy, spectrum]);
    final b = await r.build('usd', wanted: 10, held: 2, recipient: 'r', changeAddress: 'c', spendAddresses: ['s']);
    expect(spectrum.builtPaths, ['Pool']);
    expect(b.protocol, 'Dexy');
    expect(b.delivered, 10);
    expect(b.acquired, 8);
  });

  test('every route failing reports each failure', () async {
    final r = TokenRouter([FakeProvider('Dexy', tokens: {'usd'}, costs: {'FreeMint': 1}, failBuild: true)]);
    expect(
      () => r.build('usd', wanted: 1, held: 0, recipient: 'r', changeAddress: 'c', spendAddresses: ['s']),
      throwsA(isA<NoRouteException>().having((e) => e.message, 'message', contains('Dexy down'))),
    );
  });
}
