import 'dart:async';

import 'package:flutter/foundation.dart';

import 'dexy_service.dart';
import 'wallet_service.dart';

typedef DexyQuoteFn = Future<List<DexyPathQuote>> Function(
  DexyVariant variant,
  int amount,
  int held,
);

/// Debounced, latest-wins quotes for the send screen's auto-buy route.
class DexyQuoteController extends ChangeNotifier {
  DexyQuoteController({
    DexyQuoteFn? quote,
    this.debounce = const Duration(milliseconds: 300),
  }) : _quote = quote ??
            ((v, amount, held) =>
                dexService.quoteTokenSend(v, amount, heldTokens: held));

  final DexyQuoteFn _quote;
  final Duration debounce;

  List<DexyPathQuote>? _quotes;
  Timer? _timer;
  int _generation = 0;

  /// Null before any quote (or after clearing), empty when no route exists.
  List<DexyPathQuote>? get quotes => _quotes;

  void request(DexyVariant variant, String amountText, {required int held}) {
    _timer?.cancel();
    final amount = parseDecimalToBase(amountText, variant.decimals);
    if (amount == null || amount <= 0) {
      _set(null, ++_generation);
      return;
    }
    if (debounce == Duration.zero) {
      _run(variant, amount, held);
    } else {
      _timer = Timer(debounce, () => _run(variant, amount, held));
    }
  }

  void clear() => _set(null, ++_generation);

  Future<void> _run(DexyVariant variant, int amount, int held) async {
    final gen = ++_generation;
    try {
      final result = await _quote(variant, amount, held);
      _set(result, gen);
    } catch (_) {
      _set(null, gen);
    }
  }

  void _set(List<DexyPathQuote>? value, int gen) {
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
