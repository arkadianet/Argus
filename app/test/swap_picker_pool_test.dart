import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/ui/swap_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TokenBalance held(String id) => TokenBalance(id: id, amount: 1);

  test('tradable holdings come first, untradable ones are kept', () {
    final rows = heldByTradability(
      [held('nopool'), held('traded'), held('alsonopool')],
      {'traded'},
    );
    expect(rows.map((t) => t.id), ['traded', 'nopool', 'alsonopool']);
  });

  test('nothing is dropped', () {
    // A wallet token vanishing from its own section reads as a bug, so the
    // picker lists every holding and disables the ones it cannot trade.
    final rows = heldByTradability([held('a'), held('b')], const {});
    expect(rows, hasLength(2));
  });

  test('order within each group is preserved', () {
    final rows = heldByTradability(
      [held('p1'), held('x1'), held('p2'), held('x2')],
      {'p1', 'p2'},
    );
    expect(rows.map((t) => t.id), ['p1', 'p2', 'x1', 'x2']);
  });

  test('an empty pool set leaves every holding untradable', () {
    final rows = heldByTradability([held('a')], const {});
    expect(rows.single.id, 'a');
  });
}
