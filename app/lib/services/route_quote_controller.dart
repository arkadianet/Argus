import 'dart:async';

import 'package:flutter/foundation.dart';

import 'token_router.dart';
import 'wallet_service.dart';

typedef RouteQuoteFn = Future<List<RouteQuote>> Function(String tokenId, int wanted, int held);

/// Debounced, latest-wins buy-and-send quotes for the send screen.
class RouteQuoteController extends ChangeNotifier {
  RouteQuoteController({
    RouteQuoteFn? quote,
    this.debounce = const Duration(milliseconds: 300),
  }) : _quote = quote ?? ((id, wanted, held) => tokenRouter.quote(id, wanted: wanted, held: held));

  final RouteQuoteFn _quote;
  final Duration debounce;

  List<RouteQuote>? _quotes;
  Timer? _timer;
  int _generation = 0;

  /// Null before any quote (or after clearing), empty when no route exists.
  List<RouteQuote>? get quotes => _quotes;

  void request(String tokenId, String amountText, {required int decimals, required int held}) {
    _timer?.cancel();
    final wanted = parseDecimalToBase(amountText, decimals);
    if (wanted == null || wanted <= 0) {
      _set(null, ++_generation);
      return;
    }
    if (debounce == Duration.zero) {
      _run(tokenId, wanted, held);
    } else {
      _timer = Timer(debounce, () => _run(tokenId, wanted, held));
    }
  }

  void clear() => _set(null, ++_generation);

  Future<void> _run(String tokenId, int wanted, int held) async {
    final gen = ++_generation;
    try {
      _set(await _quote(tokenId, wanted, held), gen);
    } catch (_) {
      _set(null, gen);
    }
  }

  void _set(List<RouteQuote>? value, int gen) {
    if (gen != _generation) return;
    _quotes = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
