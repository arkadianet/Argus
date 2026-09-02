import 'package:flutter/foundation.dart';

import 'wallet_service.dart';

enum UtxoFilter { all, ergOnly, withTokens, dust }

/// Boxes below this are "dust" for the UTXO tools filter.
const dustThresholdNano = 100000000;

/// Box list, filter, search and selection for the UTXO tools screen.
/// Pure state: loading and transaction flows stay in the screen.
class UtxoToolsController extends ChangeNotifier {
  List<InputBoxInput> _boxes = const [];
  final Set<String> _selected = {};
  UtxoFilter filter = UtxoFilter.all;
  String _search = '';

  List<InputBoxInput> get boxes => _boxes;
  Set<String> get selectedIds => Set.unmodifiable(_selected);
  String get search => _search;

  void setBoxes(List<InputBoxInput> boxes) {
    _boxes = List.unmodifiable(boxes);
    _selected.retainAll(boxes.map((b) => b.boxId));
    notifyListeners();
  }

  void setFilter(UtxoFilter next) {
    if (next == filter) return;
    filter = next;
    notifyListeners();
  }

  void setSearch(String query) {
    final q = query.trim().toLowerCase();
    if (q == _search) return;
    _search = q;
    notifyListeners();
  }

  List<InputBoxInput> get filtered => _boxes.where((box) {
        switch (filter) {
          case UtxoFilter.all:
            break;
          case UtxoFilter.ergOnly:
            if (box.assets.isNotEmpty) return false;
          case UtxoFilter.withTokens:
            if (box.assets.isEmpty) return false;
          case UtxoFilter.dust:
            if (box.valueNanoErg >= BigInt.from(dustThresholdNano)) return false;
        }
        if (_search.isEmpty) return true;
        return box.boxId.toLowerCase().contains(_search) ||
            box.assets.any((a) => a.tokenId.toLowerCase().contains(_search));
      }).toList();

  bool isSelected(String boxId) => _selected.contains(boxId);

  void toggle(String boxId) {
    if (!_selected.remove(boxId)) _selected.add(boxId);
    notifyListeners();
  }

  void selectAllFiltered() {
    _selected.addAll(filtered.map((b) => b.boxId));
    notifyListeners();
  }

  void clearSelection() {
    if (_selected.isEmpty) return;
    _selected.clear();
    notifyListeners();
  }

  /// Selected boxes, or every box when nothing is selected.
  List<InputBoxInput> get consolidateTargets => _selected.isEmpty
      ? _boxes
      : _boxes.where((b) => _selected.contains(b.boxId)).toList();

  /// Selection as the wallet core expects it: null means "let the builder
  /// choose".
  List<String>? get selectedBoxIdsOrNull =>
      _selected.isEmpty ? null : _selected.toList();

  BigInt get selectedNano => _boxes
      .where((b) => _selected.contains(b.boxId))
      .fold(BigInt.zero, (sum, b) => sum + b.valueNanoErg);

  BigInt get totalNano =>
      _boxes.fold(BigInt.zero, (sum, b) => sum + b.valueNanoErg);
}
