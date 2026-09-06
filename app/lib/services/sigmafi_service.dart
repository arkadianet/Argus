import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../bridge/api.dart' as bridge;
import 'network_controller.dart';
import 'wallet_service.dart';

/// A loan asset SigmaFi lists, with the scripts its boxes sit under.
class SigmaFiAsset {
  const SigmaFiAsset({
    required this.id,
    required this.name,
    required this.decimals,
    required this.orderTree,
    required this.bondTree,
  });

  /// `ERG` or a token id.
  final String id;
  final String name;
  final int decimals;
  final String orderTree;
  final String bondTree;

  bool get isErg => id == 'ERG';

  static SigmaFiAsset fromJson(Map<String, dynamic> m) => SigmaFiAsset(
        id: m['id'] as String,
        name: m['name'] as String,
        decimals: (m['decimals'] as num).toInt(),
        orderTree: m['order_tree'] as String,
        bondTree: m['bond_tree'] as String,
      );
}

/// A token locked as collateral.
typedef SigmaFiToken = ({String id, int amount});

List<SigmaFiToken> _tokens(dynamic v) => [
      for (final t in (v as List? ?? const [])) (id: (t as List)[0] as String, amount: (t[1] as num).toInt()),
    ];

/// A loan request waiting for a lender.
class SigmaFiOrder {
  const SigmaFiOrder({
    required this.boxId,
    required this.loanAsset,
    required this.onClose,
    required this.borrowerAddress,
    required this.principal,
    required this.repayment,
    required this.termBlocks,
    required this.collateralErg,
    required this.collateralTokens,
    required this.interestPercent,
    required this.aprPercent,
    required this.devFee,
    required this.uiFee,
    required this.box,
    this.own = false,
  });

  final String boxId;
  final String loanAsset;

  /// The term starts at the fill; the variant Argus fills.
  final bool onClose;
  final String borrowerAddress;
  final int principal;
  final int repayment;
  final int termBlocks;
  final int collateralErg;
  final List<SigmaFiToken> collateralTokens;
  final double interestPercent;
  final double aprPercent;
  final int devFee;
  final int uiFee;

  /// The box as read, for the spend.
  final Map<String, dynamic> box;

  /// Posted by this wallet.
  final bool own;

  int get lenderCost => principal + devFee + uiFee;

  static SigmaFiOrder fromJson(Map<String, dynamic> m, {required bool own}) => SigmaFiOrder(
        boxId: m['box_id'] as String,
        loanAsset: m['loan_asset'] as String,
        onClose: m['on_close'] as bool,
        borrowerAddress: m['borrower_address'] as String,
        principal: (m['principal'] as num).toInt(),
        repayment: (m['repayment'] as num).toInt(),
        termBlocks: (m['term_blocks'] as num).toInt(),
        collateralErg: (m['collateral_erg'] as num).toInt(),
        collateralTokens: _tokens(m['collateral_tokens']),
        interestPercent: (m['interest_percent'] as num).toDouble(),
        aprPercent: (m['apr_percent'] as num).toDouble(),
        devFee: (m['dev_fee'] as num).toInt(),
        uiFee: (m['ui_fee'] as num).toInt(),
        box: (m['box'] as Map).cast<String, dynamic>(),
        own: own,
      );
}

/// A filled loan holding collateral until repayment or maturity.
class SigmaFiBond {
  const SigmaFiBond({
    required this.boxId,
    required this.loanAsset,
    required this.orderBoxId,
    required this.borrowerAddress,
    required this.lenderAddress,
    required this.repayment,
    required this.maturityHeight,
    required this.collateralErg,
    required this.collateralTokens,
    required this.blocksRemaining,
    required this.box,
    this.ownBorrow = false,
    this.ownLend = false,
  });

  final String boxId;
  final String loanAsset;
  final String orderBoxId;
  final String borrowerAddress;
  final String lenderAddress;
  final int repayment;
  final int maturityHeight;
  final int collateralErg;
  final List<SigmaFiToken> collateralTokens;

  /// Zero or negative once the lender may liquidate.
  final int blocksRemaining;
  final Map<String, dynamic> box;
  final bool ownBorrow;
  final bool ownLend;

  bool get matured => blocksRemaining <= 0;
  bool get repayable => ownBorrow && !matured;
  bool get liquidatable => ownLend && matured;

  static SigmaFiBond fromJson(Map<String, dynamic> m, {required bool ownBorrow, required bool ownLend}) => SigmaFiBond(
        boxId: m['box_id'] as String,
        loanAsset: m['loan_asset'] as String,
        orderBoxId: m['order_box_id'] as String,
        borrowerAddress: m['borrower_address'] as String,
        lenderAddress: m['lender_address'] as String,
        repayment: (m['repayment'] as num).toInt(),
        maturityHeight: (m['maturity_height'] as num).toInt(),
        collateralErg: (m['collateral_erg'] as num).toInt(),
        collateralTokens: _tokens(m['collateral_tokens']),
        blocksRemaining: (m['blocks_remaining'] as num).toInt(),
        box: (m['box'] as Map).cast<String, dynamic>(),
        ownBorrow: ownBorrow,
        ownLend: ownLend,
      );
}

/// The Rust side, behind a seam so the service can be tested without it.
abstract class SigmaFiGateway {
  String? get nodeUrl;
  String get explorerBase;
  String? get walletId;
  int? get chainHeight;
  String contracts();
  String market(String boxesJson, int height);
  Future<String> prepareOpen({
    required String loanAsset,
    required int principal,
    required int repayment,
    required int termBlocks,
    required int collateralErg,
    required String collateralTokensJson,
    required String userAddress,
    required List<String> spendAddresses,
    required String changeAddress,
  });
  Future<String> prepareSpend({
    required String action,
    required String boxJson,
    required String userAddress,
    required List<String> spendAddresses,
  });
}

class LiveSigmaFiGateway implements SigmaFiGateway {
  const LiveSigmaFiGateway();
  @override
  String? get nodeUrl => networkController.activeUrl;
  @override
  String get explorerBase => networkController.explorer;
  @override
  String? get walletId => walletService.activeWalletId;
  @override
  int? get chainHeight => networkController.height;
  @override
  String contracts() => bridge.sigmafiContracts();
  @override
  String market(String boxesJson, int height) => bridge.sigmafiMarket(boxesJson: boxesJson, height: height);
  @override
  Future<String> prepareOpen({
    required String loanAsset,
    required int principal,
    required int repayment,
    required int termBlocks,
    required int collateralErg,
    required String collateralTokensJson,
    required String userAddress,
    required List<String> spendAddresses,
    required String changeAddress,
  }) =>
      walletService.sigmafiPrepareOpen(
        loanAsset: loanAsset,
        principal: principal,
        repayment: repayment,
        termBlocks: termBlocks,
        collateralErg: collateralErg,
        collateralTokensJson: collateralTokensJson,
        userAddress: userAddress,
        spendAddresses: spendAddresses,
        changeAddress: changeAddress,
      );
  @override
  Future<String> prepareSpend({
    required String action,
    required String boxJson,
    required String userAddress,
    required List<String> spendAddresses,
  }) =>
      walletService.sigmafiPrepareSpend(
        action: action,
        boxJson: boxJson,
        userAddress: userAddress,
        spendAddresses: spendAddresses,
      );
}

typedef SigmaFiHttpGet = Future<String> Function(Uri uri);
typedef SigmaFiHttpPost = Future<String> Function(Uri uri, String jsonBody);

const _timeout = Duration(seconds: 45);

Future<String> _httpGet(Uri uri) async {
  final res = await http.get(uri).timeout(_timeout);
  if (res.statusCode != 200) throw StateError('${uri.host} returned HTTP ${res.statusCode}');
  return res.body;
}

Future<String> _httpPost(Uri uri, String body) async {
  final res = await http
      .post(uri, headers: const {'Content-Type': 'application/json'}, body: body)
      .timeout(_timeout);
  if (res.statusCode != 200) throw StateError('${uri.host} returned HTTP ${res.statusCode}');
  return res.body;
}

/// The SigmaFi bond market: every open order and active bond under the
/// contracts, and which of them are this wallet's.
class SigmaFiService extends ChangeNotifier {
  SigmaFiService({SigmaFiGateway? gateway, SigmaFiHttpGet? get, SigmaFiHttpPost? post})
      : _gw = gateway ?? const LiveSigmaFiGateway(),
        _get = get ?? _httpGet,
        _post = post ?? _httpPost;

  final SigmaFiGateway _gw;
  final SigmaFiHttpGet _get;
  final SigmaFiHttpPost _post;

  List<SigmaFiAsset>? _assets;
  List<SigmaFiOrder> orders = const [];
  List<SigmaFiBond> bonds = const [];

  /// Boxes under a SigmaFi script that did not read as one, with why.
  List<String> skipped = const [];
  String? lastError;
  DateTime? lastRefreshedAt;
  int? lastHeight;
  bool _busy = false;
  bool get busy => _busy;

  /// The wallet the market was last read for.
  String? _walletId;

  List<SigmaFiAsset> get assets => _assets ??= [
        for (final m in (jsonDecode(_gw.contracts()) as List)) SigmaFiAsset.fromJson((m as Map).cast()),
      ];

  SigmaFiAsset? asset(String id) {
    for (final a in assets) {
      if (a.id.toLowerCase() == id.toLowerCase()) return a;
    }
    return null;
  }

  /// Orders other people posted that Argus can fill.
  List<SigmaFiOrder> get openOrders => [for (final o in orders) if (!o.own && o.onClose) o];
  List<SigmaFiOrder> get myOrders => [for (final o in orders) if (o.own) o];
  List<SigmaFiBond> get myBorrows => [for (final b in bonds) if (b.ownBorrow) b];
  List<SigmaFiBond> get myLends => [for (final b in bonds) if (b.ownLend) b];

  /// One line for the Discover card, or null when the wallet has nothing
  /// in the market.
  String? positionLine() {
    final parts = <String>[];
    if (myOrders.isNotEmpty) parts.add('${myOrders.length} open ${myOrders.length == 1 ? 'request' : 'requests'}');
    if (myBorrows.isNotEmpty) parts.add('${myBorrows.length} borrowed');
    if (myLends.isNotEmpty) parts.add('${myLends.length} lent');
    return parts.isEmpty ? null : parts.join(', ');
  }

  /// Read the whole market and mark what belongs to `ownAddresses`.
  Future<void> refresh(Set<String> ownAddresses) async {
    if (_busy) return;
    _busy = true;
    final forWallet = _gw.walletId;
    notifyListeners();
    try {
      final height = _gw.chainHeight ?? await _explorerHeight();
      final trees = [for (final a in assets) ...[a.orderTree, a.bondTree]];
      // Every script at once: one slow answer must not hold the others.
      final results = await Future.wait([
        for (final t in trees)
          _boxesUnderScript(t).then<(List<dynamic>?, Object?)>((b) => (b, null), onError: (Object e) => (null, e)),
      ]);
      final boxes = <dynamic>[];
      final failures = <String>[];
      for (var i = 0; i < results.length; i++) {
        final (b, e) = results[i];
        if (b != null) {
          boxes.addAll(b);
        } else {
          failures.add('${assets[i ~/ 2].name} ${i.isEven ? 'orders' : 'bonds'}: $e');
        }
      }
      if (failures.length == results.length) throw StateError(failures.first);
      final raw = (jsonDecode(_gw.market(jsonEncode(boxes), height)) as Map).cast<String, dynamic>();
      // A wallet switch while the network answered: the answer is not for
      // the wallet now active, so it is dropped rather than shown as its.
      if (_gw.walletId != forWallet) return;
      orders = [
        for (final m in (raw['orders'] as List))
          SigmaFiOrder.fromJson((m as Map).cast(), own: ownAddresses.contains(m['borrower_address'])),
      ]..sort((a, b) => b.aprPercent.compareTo(a.aprPercent));
      bonds = [
        for (final m in (raw['bonds'] as List))
          SigmaFiBond.fromJson(
            (m as Map).cast(),
            ownBorrow: ownAddresses.contains(m['borrower_address']),
            ownLend: ownAddresses.contains(m['lender_address']),
          ),
      ]..sort((a, b) => a.blocksRemaining.compareTo(b.blocksRemaining));
      skipped = [for (final s in (raw['skipped'] as List? ?? const [])) s as String];
      lastHeight = height;
      _walletId = forWallet;
      lastError = failures.isEmpty ? null : 'Part of the market could not be read: ${failures.join('; ')}';
      lastRefreshedAt = DateTime.now();
    } catch (e) {
      lastError = e.toString();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Forget a wallet's view of the market when another becomes active.
  void clearIfForeign() {
    if (_walletId != null && _walletId != _gw.walletId) {
      orders = const [];
      bonds = const [];
      skipped = const [];
      lastRefreshedAt = null;
      _walletId = null;
      notifyListeners();
    }
  }

  Future<int> _explorerHeight() async {
    final base = _gw.explorerBase.replaceAll(RegExp(r'/+$'), '');
    final body = jsonDecode(await _get(Uri.parse('$base/api/v1/networkState')));
    final h = body is Map ? body['height'] : null;
    if (h is num) return h.toInt();
    throw StateError('The chain height is not known yet');
  }

  /// Unspent boxes under `tree`: node first, explorer second, every page.
  Future<List<dynamic>> _boxesUnderScript(String tree) async {
    const page = 100;
    final node = _gw.nodeUrl?.replaceAll(RegExp(r'/+$'), '');
    if (node != null) {
      try {
        final out = <dynamic>[];
        for (var offset = 0;; offset += page) {
          final decoded = jsonDecode(await _post(
            Uri.parse('$node/blockchain/box/unspent/byErgoTree?offset=$offset&limit=$page'),
            jsonEncode(tree),
          ));
          final items = decoded is List
              ? decoded
              : decoded is Map && decoded['items'] is List
                  ? decoded['items'] as List
                  : throw StateError('no box list');
          out.addAll(items);
          if (items.length < page) return out;
        }
      } catch (_) {
        // Fall through to the explorer.
      }
    }
    final base = _gw.explorerBase.replaceAll(RegExp(r'/+$'), '');
    final out = <dynamic>[];
    for (var offset = 0;; offset += page) {
      final body = jsonDecode(
        await _get(Uri.parse('$base/api/v1/boxes/unspent/byErgoTree/$tree?offset=$offset&limit=$page')),
      );
      if (body is! Map || body['items'] is! List) throw StateError('${Uri.parse(base).host} returned no box list');
      final items = body['items'] as List;
      out.addAll(items);
      final total = body['total'];
      if (items.length < page || (total is num && out.length >= total)) return out;
    }
  }

  /// The wallet orders are prepared for right now.
  String? get activeWalletId => _gw.walletId;

  /// Whether `prepared` can still be broadcast: the wallet it was
  /// prepared for is the one active.
  bool canCommit(Map<String, dynamic> prepared) {
    final id = prepared['wallet_id'] as String?;
    return id != null && id == _gw.walletId;
  }

  Future<Map<String, dynamic>> prepareOpen({
    required String loanAsset,
    required int principal,
    required int repayment,
    required int termBlocks,
    required int collateralErg,
    required List<SigmaFiToken> collateralTokens,
    required String userAddress,
    required List<String> spendAddresses,
    required String changeAddress,
  }) async {
    final walletId = _gw.walletId;
    final raw = await _gw.prepareOpen(
      loanAsset: loanAsset,
      principal: principal,
      repayment: repayment,
      termBlocks: termBlocks,
      collateralErg: collateralErg,
      collateralTokensJson: jsonEncode([
        for (final t in collateralTokens) {'token_id': t.id, 'amount': t.amount},
      ]),
      userAddress: userAddress,
      spendAddresses: spendAddresses,
      changeAddress: changeAddress,
    );
    return (jsonDecode(raw) as Map).cast<String, dynamic>()..['wallet_id'] = walletId;
  }

  /// `action` is `cancel`, `close`, `repay` or `liquidate`.
  Future<Map<String, dynamic>> prepareSpend({
    required String action,
    required Map<String, dynamic> box,
    required String userAddress,
    required List<String> spendAddresses,
  }) async {
    final walletId = _gw.walletId;
    final raw = await _gw.prepareSpend(
      action: action,
      boxJson: jsonEncode(box),
      userAddress: userAddress,
      spendAddresses: spendAddresses,
    );
    return (jsonDecode(raw) as Map).cast<String, dynamic>()..['wallet_id'] = walletId;
  }
}

final sigmafiService = SigmaFiService();
