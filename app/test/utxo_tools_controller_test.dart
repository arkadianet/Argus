import 'package:argus_wallet/services/utxo_tools_controller.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:flutter_test/flutter_test.dart';

InputBoxInput box(String id, int nano, {List<String> tokens = const []}) => InputBoxInput(
      boxId: id,
      valueNanoErg: BigInt.from(nano),
      creationHeight: 1,
      assets: [for (final t in tokens) InputAsset(tokenId: t, amount: BigInt.one)],
    );

void main() {
  final boxes = [
    box('aaa1', 5000000000),
    box('bbb2', 50000000),
    box('ccc3', 2000000000, tokens: ['tokX']),
  ];

  test('filters by kind', () {
    final c = UtxoToolsController()..setBoxes(boxes);
    expect(c.filtered.map((b) => b.boxId), ['aaa1', 'bbb2', 'ccc3']);
    c.setFilter(UtxoFilter.ergOnly);
    expect(c.filtered.map((b) => b.boxId), ['aaa1', 'bbb2']);
    c.setFilter(UtxoFilter.withTokens);
    expect(c.filtered.map((b) => b.boxId), ['ccc3']);
    c.setFilter(UtxoFilter.dust);
    expect(c.filtered.map((b) => b.boxId), ['bbb2']);
  });

  test('search matches box id or token id, case-insensitively', () {
    final c = UtxoToolsController()..setBoxes(boxes);
    c.setSearch('TOKX');
    expect(c.filtered.map((b) => b.boxId), ['ccc3']);
    c.setSearch('bb');
    expect(c.filtered.map((b) => b.boxId), ['bbb2']);
  });

  test('selection toggles, selects all filtered, clears, and survives reload', () {
    final c = UtxoToolsController()..setBoxes(boxes);
    c.toggle('aaa1');
    expect(c.selectedIds, {'aaa1'});
    c.toggle('aaa1');
    expect(c.selectedIds, isEmpty);
    c.setFilter(UtxoFilter.ergOnly);
    c.selectAllFiltered();
    expect(c.selectedIds, {'aaa1', 'bbb2'});
    c.setBoxes([boxes[0]]);
    expect(c.selectedIds, {'aaa1'});
    c.clearSelection();
    expect(c.selectedIds, isEmpty);
  });

  test('consolidation targets are the selection, else everything', () {
    final c = UtxoToolsController()..setBoxes(boxes);
    expect(c.consolidateTargets.length, 3);
    c.toggle('ccc3');
    expect(c.consolidateTargets.map((b) => b.boxId), ['ccc3']);
    expect(c.selectedBoxIdsOrNull, ['ccc3']);
    c.clearSelection();
    expect(c.selectedBoxIdsOrNull, isNull);
  });

  test('totals sum selected value', () {
    final c = UtxoToolsController()..setBoxes(boxes);
    c.toggle('aaa1');
    c.toggle('bbb2');
    expect(c.selectedNano, BigInt.from(5050000000));
    expect(c.totalNano, BigInt.from(7050000000));
  });
}
