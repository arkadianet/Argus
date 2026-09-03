import 'package:argus_wallet/ui/swap_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('known Rust error codes become plain sentences', () {
    expect(swapQuoteError('Exception: {"code":"Generic","message":"NO_POOL: no pool"}'), contains('No Spectrum pool'));
    expect(swapQuoteError('EXTRA_INDEX_REQUIRED'), contains("doesn't support pool discovery"));
    expect(swapQuoteError('Amount must be positive'), contains('greater than zero'));
  });

  test('other errors keep the message from the JSON envelope', () {
    expect(swapQuoteError('Exception: {"code":"NodeError","message":"timed out"}'), 'Quote failed: timed out');
    expect(swapQuoteError('Exception: boom'), 'Quote failed: boom');
  });
}
