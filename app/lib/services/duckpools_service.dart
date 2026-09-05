import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../bridge/api.dart' as bridge;
import 'package:shared_preferences/shared_preferences.dart';

import 'network_controller.dart';
import 'wallet_service.dart';

/// One Duckpools lending pool as deployed.
class DuckPool {
  const DuckPool({
    required this.key,
    required this.ticker,
    required this.decimals,
    required this.poolNft,
    required this.lendToken,
    required this.borrowToken,
    required this.currencyId,
    required this.ergoTree,
    required this.interestParamNft,
    this.paramNft = '',
    this.childNft = '',
    this.parentNft = '',
    this.collateralErgoTree = '',
    this.ergDexNft,
    this.dexNfts = const [],
    this.tokenCollaterals = const [],
  });

  final String key;
  final String ticker;
  final int decimals;
  final String poolNft;
  final String lendToken;
  final String borrowToken;

  /// Null for the ERG pool.
  final String? currencyId;
  final String ergoTree;
  final String interestParamNft;

  /// The pool parameter box NFT (thresholds, penalties, price sources).
  final String paramNft;

  /// The interest history boxes' NFTs.
  final String childNft;
  final String parentNft;

  /// The script every loan of this pool sits under.
  final String collateralErgoTree;

  /// The Spectrum pool that prices ERG collateral; null where the pool
  /// takes none (the ERG pool).
  final String? ergDexNft;

  /// Every Spectrum pool NFT that prices this pool's collateral.
  final List<String> dexNfts;

  /// The tokens the ERG pool lends against; empty for token pools.
  final List<DuckCollateralAsset> tokenCollaterals;

  /// Whether Argus can borrow from this pool.
  bool get lends => dexNfts.isNotEmpty && collateralErgoTree.isNotEmpty;

  /// Ticker and decimals of a collateral: ERG, or one of the ERG pool's
  /// tokens.
  (String, int) collateralUnit(String? asset) {
    if (asset == null) return ('ERG', 9);
    for (final c in tokenCollaterals) {
      if (c.id == asset) return (c.ticker, c.decimals);
    }
    return (asset.substring(0, 8), 0);
  }

  static DuckPool fromJson(Map<String, dynamic> m) => DuckPool(
        key: m['key'] as String,
        ticker: m['ticker'] as String,
        decimals: (m['decimals'] as num).toInt(),
        poolNft: m['pool_nft'] as String,
        lendToken: m['lend_token'] as String,
        borrowToken: m['borrow_token'] as String,
        currencyId: m['currency_id'] as String?,
        ergoTree: m['ergo_tree'] as String,
        interestParamNft: m['interest_param_nft'] as String? ?? '',
        paramNft: m['param_nft'] as String? ?? '',
        childNft: m['child_nft'] as String? ?? '',
        parentNft: m['parent_nft'] as String? ?? '',
        collateralErgoTree: m['collateral_ergo_tree'] as String? ?? '',
        ergDexNft: m['erg_dex_nft'] as String?,
        dexNfts: [for (final n in (m['dex_nfts'] as List? ?? const [])) n as String],
        tokenCollaterals: [
          for (final c in (m['token_collaterals'] as List? ?? const [])) DuckCollateralAsset.fromJson((c as Map).cast()),
        ],
      );
}

/// A token the ERG pool takes as collateral.
class DuckCollateralAsset {
  const DuckCollateralAsset({required this.id, required this.ticker, required this.decimals, required this.dexNft});
  final String id;
  final String ticker;
  final int decimals;
  final String dexNft;

  static DuckCollateralAsset fromJson(Map<String, dynamic> m) => DuckCollateralAsset(
        id: m['id'] as String,
        ticker: m['ticker'] as String,
        decimals: (m['decimals'] as num).toInt(),
        dexNft: m['dex_nft'] as String,
      );
}

/// A loan this wallet holds: a collateral box under a pool's contract.
class DuckLoan {
  const DuckLoan({
    required this.pool,
    required this.ticker,
    required this.decimals,
    required this.boxId,
    required this.collateralNano,
    required this.loan,
    required this.owed,
    this.collateralAsset,
    this.collateralAmount = 0,
    required this.collateralValue,
    required this.threshold,
    required this.penalty,
    required this.healthBps,
    required this.liquidationValue,
    required this.liquidatable,
    required this.forcedLiquidationHeight,
  });

  final String pool;
  final String ticker;
  final int decimals;
  final String boxId;

  /// The box's ERG: the collateral itself in a token pool.
  final int collateralNano;

  /// The collateral token (ERG pool loans), or null for ERG.
  final String? collateralAsset;

  /// Units of collateral: nanoERG, or the token's units.
  final int collateralAmount;

  /// Principal, asset units.
  final int loan;

  /// What repaying now costs, asset units.
  final int owed;

  /// What the contract values the collateral at, asset units.
  final int collateralValue;
  final int threshold;
  final int penalty;

  /// 10 000 is the liquidation line; higher is safer.
  final int healthBps;
  final int liquidationValue;
  final bool liquidatable;
  final int forcedLiquidationHeight;

  /// Collateral value over what is owed, as a percentage.
  double get ratioPercent => owed == 0 ? double.infinity : collateralValue * 100 / owed;

  static DuckLoan fromJson(Map<String, dynamic> m) => DuckLoan(
        pool: m['pool'] as String,
        ticker: m['ticker'] as String,
        decimals: (m['decimals'] as num).toInt(),
        boxId: m['box_id'] as String,
        collateralNano: (m['collateral_nano'] as num).toInt(),
        collateralAsset: m['collateral_asset'] as String?,
        collateralAmount: (m['collateral_amount'] as num?)?.toInt() ?? (m['collateral_nano'] as num).toInt(),
        loan: (m['loan'] as num).toInt(),
        owed: (m['owed'] as num).toInt(),
        collateralValue: (m['collateral_value'] as num).toInt(),
        threshold: (m['threshold'] as num).toInt(),
        penalty: (m['penalty'] as num).toInt(),
        healthBps: (m['health_bps'] as num).toInt(),
        liquidationValue: (m['liquidation_value'] as num).toInt(),
        liquidatable: m['liquidatable'] == true,
        forcedLiquidationHeight: (m['forced_liquidation_height'] as num).toInt(),
      );
}

/// A pool's borrowing terms right now, or why they could not be read.
class DuckMarket {
  const DuckMarket({
    required this.pool,
    required this.ticker,
    required this.decimals,
    this.threshold,
    this.penalty,
    this.ergValue,
    this.loans,
    this.error,
    this.collaterals = const [],
  });

  final String pool;
  final String ticker;
  final int decimals;

  /// Collateral must be worth at least `threshold / 1000` of the debt.
  final int? threshold;
  final int? penalty;

  /// What one ERG of collateral counts for, asset units.
  final int? ergValue;

  /// Loans open in the pool, anyone's.
  final int? loans;
  final String? error;

  /// The ERG pool's token collaterals and their terms.
  final List<DuckMarketCollateral> collaterals;

  /// Whether a borrow can be quoted: ERG terms for a token pool, or at
  /// least one token collateral with a price for the ERG pool.
  bool get ready => error == null && ((threshold != null && ergValue != null) || collaterals.any((c) => c.ready));

  static DuckMarket fromJson(Map<String, dynamic> m) => DuckMarket(
        pool: m['pool'] as String,
        ticker: m['ticker'] as String,
        decimals: (m['decimals'] as num).toInt(),
        threshold: (m['threshold'] as num?)?.toInt(),
        penalty: (m['penalty'] as num?)?.toInt(),
        ergValue: (m['erg_value'] as num?)?.toInt(),
        loans: (m['loans'] as num?)?.toInt(),
        error: m['error'] as String?,
        collaterals: [
          for (final c in (m['collaterals'] as List? ?? const [])) DuckMarketCollateral.fromJson((c as Map).cast()),
        ],
      );
}

/// One token the ERG pool takes, with its terms and price right now.
class DuckMarketCollateral {
  const DuckMarketCollateral({
    required this.asset,
    required this.ticker,
    required this.decimals,
    required this.ready,
    this.threshold,
    this.penalty,
    this.unitValueNano,
  });
  final String asset;
  final String ticker;
  final int decimals;
  final bool ready;
  final int? threshold;
  final int? penalty;

  /// What one whole token sells for, nanoERG, before the network fee.
  final int? unitValueNano;

  static DuckMarketCollateral fromJson(Map<String, dynamic> m) => DuckMarketCollateral(
        asset: m['asset'] as String,
        ticker: m['ticker'] as String,
        decimals: (m['decimals'] as num).toInt(),
        ready: m['ready'] == true,
        threshold: (m['threshold'] as num?)?.toInt(),
        penalty: (m['penalty'] as num?)?.toInt(),
        unitValueNano: (m['unit_value_nano'] as num?)?.toInt(),
      );
}

/// A pool right now, and what the wallet holds in it.
class DuckPoolState {
  const DuckPoolState({
    required this.pool,
    required this.ticker,
    required this.decimals,
    required this.lendToken,
    required this.boxId,
    required this.pooled,
    required this.borrowed,
    required this.lendCirculating,
    required this.utilisationBps,
    required this.lendTokenPrice,
    required this.walletLendTokens,
    required this.walletValue,
    this.borrowAprBps,
    this.lendAprBps,
  });

  final String pool;
  final String ticker;
  final int decimals;
  final String lendToken;
  final String boxId;

  /// Asset units in the pool box.
  final int pooled;

  /// Asset units out on loan (principal).
  final int borrowed;
  final int lendCirculating;

  /// Share of lenders' assets lent out, in basis points.
  final int utilisationBps;

  /// Asset units per lend token, for display.
  final double lendTokenPrice;

  /// The wallet's lend tokens and what they redeem for today.
  final int walletLendTokens;
  final int walletValue;

  /// Yearly rates in basis points, when the interest boxes were read.
  final int? borrowAprBps;
  final int? lendAprBps;

  bool get hasPosition => walletLendTokens > 0;
  int get totalAssets => pooled + borrowed;

  static DuckPoolState fromJson(Map<String, dynamic> m) => DuckPoolState(
        pool: m['pool'] as String,
        ticker: m['ticker'] as String,
        decimals: (m['decimals'] as num).toInt(),
        lendToken: m['lend_token'] as String,
        boxId: m['box_id'] as String,
        pooled: (m['pooled'] as num).toInt(),
        borrowed: (m['borrowed'] as num).toInt(),
        lendCirculating: (m['lend_circulating'] as num).toInt(),
        utilisationBps: (m['utilisation_bps'] as num).toInt(),
        lendTokenPrice: (m['lend_token_price'] as num).toDouble(),
        walletLendTokens: (m['wallet_lend_tokens'] as num).toInt(),
        walletValue: (m['wallet_value'] as num).toInt(),
        borrowAprBps: (m['borrow_apr_bps'] as num?)?.toInt(),
        lendAprBps: (m['lend_apr_bps'] as num?)?.toInt(),
      );
}

/// An order this wallet posted: a proxy box a bot fills, or that comes
/// back after its refund height.
class DuckOrder {
  DuckOrder({
    required this.kind,
    required this.pool,
    required this.ticker,
    required this.decimals,
    required this.proxyBoxId,
    required this.txId,
    required this.amount,
    required this.expected,
    required this.minOut,
    required this.refundHeight,
    required this.createdAt,
    this.status = 'pending',
    this.outcomeTxId,
    this.received,
    this.lastError,
    this.collateralBoxId,
    this.collateralNano,
    this.collateralAsset,
  });

  /// `lend`, `withdraw`, `borrow`, `repay` or `partial_repay`.
  final String kind;
  final String pool;
  final String ticker;
  final int decimals;
  final String proxyBoxId;
  final String txId;

  /// Asset units in (lend, repay, partial repay), lend tokens in
  /// (withdraw), or the loan asked for (borrow).
  final int amount;

  /// Lend tokens (lend), asset units (withdraw), the loan (borrow), the
  /// collateral back (repay) or the principal left (partial repay).
  final int expected;
  final int minOut;
  final int refundHeight;
  final DateTime createdAt;

  /// `pending`, `refundable`, `filled`, `refunded`, `refund_sent`.
  String status;
  String? outcomeTxId;
  int? received;
  String? lastError;

  /// The loan a repayment is for; the collateral a borrow puts up (units
  /// of `collateralAsset`, or nanoERG when that is null).
  final String? collateralBoxId;
  final int? collateralNano;
  final String? collateralAsset;

  bool get isLoanSide => kind == 'borrow' || kind == 'repay' || kind == 'partial_repay';

  bool get open => status == 'pending' || status == 'refundable' || status == 'refund_sent';

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'pool': pool,
        'ticker': ticker,
        'decimals': decimals,
        'proxy_box_id': proxyBoxId,
        'tx_id': txId,
        'amount': amount,
        'expected': expected,
        'min_out': minOut,
        'refund_height': refundHeight,
        'created_at': createdAt.millisecondsSinceEpoch,
        'status': status,
        if (outcomeTxId != null) 'outcome_tx_id': outcomeTxId,
        if (received != null) 'received': received,
        if (lastError != null) 'last_error': lastError,
        if (collateralBoxId != null) 'collateral_box_id': collateralBoxId,
        if (collateralNano != null) 'collateral_nano': collateralNano,
        if (collateralAsset != null) 'collateral_asset': collateralAsset,
      };

  static DuckOrder fromJson(Map<String, dynamic> m) => DuckOrder(
        kind: m['kind'] as String,
        pool: m['pool'] as String,
        ticker: m['ticker'] as String,
        decimals: (m['decimals'] as num).toInt(),
        proxyBoxId: m['proxy_box_id'] as String,
        txId: m['tx_id'] as String,
        amount: (m['amount'] as num).toInt(),
        expected: (m['expected'] as num).toInt(),
        minOut: (m['min_out'] as num).toInt(),
        refundHeight: (m['refund_height'] as num).toInt(),
        createdAt: DateTime.fromMillisecondsSinceEpoch((m['created_at'] as num).toInt()),
        status: m['status'] as String? ?? 'pending',
        outcomeTxId: m['outcome_tx_id'] as String?,
        received: (m['received'] as num?)?.toInt(),
        lastError: m['last_error'] as String?,
        collateralBoxId: m['collateral_box_id'] as String?,
        collateralNano: (m['collateral_nano'] as num?)?.toInt(),
        collateralAsset: m['collateral_asset'] as String?,
      );
}

/// The Rust side, behind a seam so the service can be tested without it.
abstract class DuckpoolsGateway {
  String? get nodeUrl;
  String get explorerBase;
  String? get walletId;
  bool get isUnlocked;
  int? get chainHeight;
  String pools();
  String state(String poolBoxesJson, String holdingsJson, String interestBoxesJson);
  String quote(String poolBoxesJson, String poolKey, String kind, int amount, int slippageBps, int refundHeight);
  String loans(String loanBoxesJson, List<String> walletAddresses, int height);
  String loanQuote({
    required String poolBoxesJson,
    required String loanBoxesJson,
    required String poolKey,
    required String kind,
    required int amount,
    required String collateralAsset,
    required int collateralAmount,
    required String collateralBoxId,
    required int height,
  });
  Future<String> prepareOrder({
    required String poolBoxesJson,
    required String poolKey,
    required String kind,
    required int amount,
    required int slippageBps,
    required int refundAfterBlocks,
    required String userAddress,
    required List<String> spendAddresses,
    required String changeAddress,
    String? loanBoxesJson,
    String? collateralAsset,
    int? collateralAmount,
    String? collateralBoxId,
  });
  Future<String> prepareRefund(String proxyBoxJson, String userAddress);
  String orderOutcome(String kind, String proxyBoxId, String txJson);
}

class LiveDuckpoolsGateway implements DuckpoolsGateway {
  const LiveDuckpoolsGateway();
  @override
  String? get nodeUrl => networkController.activeUrl;
  @override
  String get explorerBase => networkController.explorer;
  @override
  String? get walletId => walletService.activeWalletId;
  @override
  bool get isUnlocked => walletService.isUnlocked;
  @override
  int? get chainHeight => networkController.height;
  @override
  String pools() => bridge.duckpoolsPools();
  @override
  String state(String poolBoxesJson, String holdingsJson, String interestBoxesJson) => bridge.duckpoolsState(
        poolBoxesJson: poolBoxesJson,
        holdingsJson: holdingsJson,
        interestBoxesJson: interestBoxesJson,
      );
  @override
  String quote(String poolBoxesJson, String poolKey, String kind, int amount, int slippageBps, int refundHeight) =>
      bridge.duckpoolsQuote(
        poolBoxesJson: poolBoxesJson,
        poolKey: poolKey,
        kind: kind,
        amount: amount,
        slippageBps: slippageBps,
        refundHeight: refundHeight,
      );
  @override
  String loans(String loanBoxesJson, List<String> walletAddresses, int height) =>
      bridge.duckpoolsLoans(loanBoxesJson: loanBoxesJson, walletAddresses: walletAddresses, height: height);
  @override
  String loanQuote({
    required String poolBoxesJson,
    required String loanBoxesJson,
    required String poolKey,
    required String kind,
    required int amount,
    required String collateralAsset,
    required int collateralAmount,
    required String collateralBoxId,
    required int height,
  }) =>
      bridge.duckpoolsLoanQuote(
        poolBoxesJson: poolBoxesJson,
        loanBoxesJson: loanBoxesJson,
        poolKey: poolKey,
        kind: kind,
        amount: amount,
        collateralAsset: collateralAsset,
        collateralAmount: collateralAmount,
        collateralBoxId: collateralBoxId,
        height: height,
      );
  @override
  Future<String> prepareOrder({
    required String poolBoxesJson,
    required String poolKey,
    required String kind,
    required int amount,
    required int slippageBps,
    required int refundAfterBlocks,
    required String userAddress,
    required List<String> spendAddresses,
    required String changeAddress,
    String? loanBoxesJson,
    String? collateralAsset,
    int? collateralAmount,
    String? collateralBoxId,
  }) =>
      walletService.duckpoolsPrepareOrder(
        poolBoxesJson: poolBoxesJson,
        poolKey: poolKey,
        kind: kind,
        amount: amount,
        slippageBps: slippageBps,
        refundAfterBlocks: refundAfterBlocks,
        userAddress: userAddress,
        spendAddresses: spendAddresses,
        changeAddress: changeAddress,
        loanBoxesJson: loanBoxesJson,
        collateralAsset: collateralAsset,
        collateralAmount: collateralAmount,
        collateralBoxId: collateralBoxId,
      );
  @override
  Future<String> prepareRefund(String proxyBoxJson, String userAddress) =>
      walletService.duckpoolsPrepareRefund(proxyBoxJson: proxyBoxJson, userAddress: userAddress);
  @override
  String orderOutcome(String kind, String proxyBoxId, String txJson) =>
      bridge.duckpoolsOrderOutcome(kind: kind, proxyBoxId: proxyBoxId, txJson: txJson);
}

typedef DuckHttpGet = Future<String> Function(Uri uri);
typedef DuckHttpPost = Future<String> Function(Uri uri, String jsonBody);

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

/// Reads the eight Duckpools pools, values the lend tokens this wallet
/// holds, tracks its orders, and reads its loans.
class DuckpoolsService extends ChangeNotifier {
  DuckpoolsService({DuckpoolsGateway? gateway, DuckHttpGet? get, DuckHttpPost? post})
      : _gw = gateway ?? const LiveDuckpoolsGateway(),
        _get = get ?? _httpGet,
        _post = post ?? _httpPost;

  final DuckpoolsGateway _gw;
  final DuckHttpGet _get;
  final DuckHttpPost _post;

  List<DuckPool>? _pools;

  /// The pools as deployed.
  List<DuckPool> get pools => _pools ??= [
        for (final m in (jsonDecode(_gw.pools()) as List)) DuckPool.fromJson((m as Map).cast()),
      ];

  /// Lend token ids, for spotting positions in a balance.
  List<String> get lendTokenIds => [for (final p in pools) p.lendToken];

  /// Last successful read, in the pools' order.
  List<DuckPoolState> states = const [];
  DateTime? lastRefreshedAt;
  String? lastError;
  bool _busy = false;
  bool get busy => _busy;

  /// The pool boxes of the last read, for quoting and building orders
  /// without another round trip.
  String? lastPoolBoxesJson;

  /// The wallet's loans and each pool's borrowing terms, from the last
  /// [refreshLoans].
  List<DuckLoan> loans = const [];
  List<DuckMarket> markets = const [];
  String? loansError;
  DateTime? loansRefreshedAt;
  bool _loansBusy = false;
  bool get loansBusy => _loansBusy;

  /// The loan boxes of the last read, for quoting and building loan
  /// orders without another round trip.
  String? lastLoanBoxesJson;

  /// Orders of the loaded wallet, newest first.
  List<DuckOrder> orders = const [];
  String? _walletId;
  static String _ordersKey(String walletId) => 'argus_duck_orders_v1_$walletId';

  List<DuckOrder> get openOrders => orders.where((o) => o.open).toList();

  /// Pools the wallet holds lend tokens in.
  List<DuckPoolState> get positions => states.where((s) => s.hasPosition).toList();

  /// "You lend 1.002 ERG · 12.5 SigUSD" or null.
  String? positionLine(String Function(int amount, int decimals) fmt) {
    final parts = [
      for (final s in positions) '${fmt(s.walletValue, s.decimals)} ${s.ticker}',
    ];
    if (parts.isEmpty) return null;
    return 'You lend ${parts.take(2).join(' · ')}';
  }

  DuckMarket? marketFor(String poolKey) {
    for (final m in markets) {
      if (m.pool == poolKey) return m;
    }
    return null;
  }

  /// "You owe 239.39 SigUSD" or null.
  String? loanLine(String Function(int amount, int decimals) fmt) {
    if (loans.isEmpty) return null;
    final parts = [for (final l in loans) '${fmt(l.owed, l.decimals)} ${l.ticker}'];
    return 'You owe ${parts.take(2).join(' · ')}';
  }

  /// Load this wallet's orders.
  Future<void> load() async {
    _walletId = _gw.walletId;
    final id = _walletId;
    if (id == null) {
      orders = const [];
      notifyListeners();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    // The wallet may have locked or changed while this was in flight; a
    // stale load must not restore another wallet's orders.
    if (_gw.walletId != id || _walletId != id) return;
    final raw = prefs.getString(_ordersKey(id));
    orders = raw == null
        ? const []
        : [for (final m in (jsonDecode(raw) as List)) DuckOrder.fromJson((m as Map).cast())];
    notifyListeners();
  }

  void reset() {
    _walletId = null;
    orders = const [];
    loans = const [];
    markets = const [];
    lastLoanBoxesJson = null;
    loansError = null;
    loansRefreshedAt = null;
    notifyListeners();
  }

  Future<void> _persistOrders() async {
    final id = _walletId;
    if (id == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ordersKey(id), jsonEncode([for (final o in orders) o.toJson()]));
    notifyListeners();
  }

  /// Read every pool's boxes, node first (by script), explorer when the
  /// node cannot answer, the interest parameter boxes for the rates, and
  /// value `holdings` (token id to amount). The Rust side picks the real
  /// pool box among what sits under a script: the one carrying the pool
  /// NFT exactly once.
  Future<void> refresh(Map<String, int> holdings) async {
    if (_busy) return;
    _busy = true;
    notifyListeners();
    try {
      // Every pool at once: one slow explorer answer must not hold the
      // others, or `_busy`, for its whole timeout.
      final results = await Future.wait([
        for (final p in pools)
          _boxesUnderScript(p).then<(DuckPool, List<dynamic>?, Object?)>(
            (b) => (p, b, null),
            onError: (Object e) => (p, null, e),
          ),
      ]);
      final boxes = <dynamic>[];
      final failures = <String>[];
      final read = <String>{};
      for (final (p, b, e) in results) {
        if (b != null) {
          boxes.addAll(b);
          read.add(p.key);
        } else {
          failures.add('${p.ticker}: $e');
        }
      }
      if (read.isEmpty) {
        throw StateError(failures.first);
      }
      // The parameter boxes share one script and are few; a failure here
      // only costs the rates. Read together, like the pools.
      final params = <dynamic>[];
      await Future.wait([
        for (final p in pools)
          _boxesByToken(p.interestParamNft).then(params.addAll, onError: (Object _) {
            // No rate for this pool this time.
          }),
      ]);
      lastPoolBoxesJson = jsonEncode(boxes);
      final raw = _gw.state(lastPoolBoxesJson!, jsonEncode(holdings), jsonEncode(params));
      final fresh = {
        for (final m in (jsonDecode(raw) as List)) (m as Map)['pool'] as String: DuckPoolState.fromJson(m.cast()),
      };
      // A pool that could not be read keeps its last state rather than
      // vanishing, and the failure is reported alongside the fresh data.
      final prior = {for (final s in states) s.pool: s};
      states = [
        for (final p in pools)
          if (fresh[p.key] != null || (!read.contains(p.key) && prior[p.key] != null)) (fresh[p.key] ?? prior[p.key])!,
      ];
      lastError = failures.isEmpty ? null : 'Some pools could not be read: ${failures.join('; ')}';
      lastRefreshedAt = DateTime.now();
    } catch (e) {
      lastError = e.toString();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Read every borrowing pool's loan boxes: the collateral boxes under
  /// its contract, its interest history, its price source and its
  /// parameter box; then the wallet's loans among them. A pool whose
  /// boxes cannot all be read is reported in its market, not thrown.
  Future<void> refreshLoans(List<String> walletAddresses) async {
    if (_loansBusy) return;
    _loansBusy = true;
    notifyListeners();
    try {
      final collateral = <dynamic>[];
      final parents = <dynamic>[];
      final children = <dynamic>[];
      final dex = <dynamic>[];
      final params = <dynamic>[];
      Future<void> gather(List<dynamic> into, Future<List<dynamic>> Function() read) async {
        try {
          into.addAll(await read());
        } catch (_) {
          // The pool's market reports what is missing.
        }
      }

      final reads = <Future<void>>[];
      for (final p in pools.where((p) => p.lends)) {
        reads.add(gather(collateral, () => _boxesUnderTree(p.collateralErgoTree, limit: 100)));
        reads.add(gather(parents, () => _boxesByToken(p.parentNft)));
        reads.add(gather(children, () => _boxesByToken(p.childNft, limit: 50)));
        for (final nft in p.dexNfts) {
          reads.add(gather(dex, () => _boxesByToken(nft)));
        }
        reads.add(gather(params, () => _boxesByToken(p.paramNft)));
      }
      await Future.wait(reads);
      final height = await _height() ?? 0;
      lastLoanBoxesJson = jsonEncode({
        'collateral': collateral,
        'parents': parents,
        'children': children,
        'dex': dex,
        'params': params,
      });
      final raw = (jsonDecode(_gw.loans(lastLoanBoxesJson!, walletAddresses, height)) as Map).cast<String, dynamic>();
      loans = [for (final m in (raw['positions'] as List)) DuckLoan.fromJson((m as Map).cast())];
      markets = [for (final m in (raw['markets'] as List)) DuckMarket.fromJson((m as Map).cast())];
      loansError = null;
      loansRefreshedAt = DateTime.now();
    } catch (e) {
      loansError = e.toString();
    } finally {
      _loansBusy = false;
      notifyListeners();
    }
  }

  /// A borrow, repay or partial-repay quote at the last read state.
  Map<String, dynamic> loanQuote({
    required String poolKey,
    required String kind,
    int amount = 0,
    String collateralAsset = '',
    int collateralAmount = 0,
    String collateralBoxId = '',
  }) {
    final boxes = lastPoolBoxesJson;
    final loanBoxes = lastLoanBoxesJson;
    if (boxes == null || loanBoxes == null) throw StateError('Read the pools first');
    return (jsonDecode(_gw.loanQuote(
      poolBoxesJson: boxes,
      loanBoxesJson: loanBoxes,
      poolKey: poolKey,
      kind: kind,
      amount: amount,
      collateralAsset: collateralAsset,
      collateralAmount: collateralAmount,
      collateralBoxId: collateralBoxId,
      height: _gw.chainHeight ?? 0,
    )) as Map)
        .cast<String, dynamic>();
  }

  /// Unspent boxes carrying `tokenId`: node first, explorer second.
  Future<List<dynamic>> _boxesByToken(String tokenId, {int limit = 10}) async {
    final node = _gw.nodeUrl?.replaceAll(RegExp(r'/+$'), '');
    if (node != null) {
      try {
        final decoded = jsonDecode(await _get(Uri.parse('$node/blockchain/box/unspent/byTokenId/$tokenId?offset=0&limit=$limit')));
        if (decoded is List) return decoded;
        if (decoded is Map && decoded['items'] is List) return decoded['items'] as List;
      } catch (_) {
        // Fall through.
      }
    }
    final base = _gw.explorerBase.replaceAll(RegExp(r'/+$'), '');
    final body = jsonDecode(await _get(Uri.parse('$base/api/v1/boxes/unspent/byTokenId/$tokenId?offset=0&limit=$limit')));
    if (body is Map && body['items'] is List) return body['items'] as List;
    throw StateError('no box list');
  }

  /// A box by id with its `spentTransactionId`, or null when neither the
  /// node nor the explorer knows it. Only a body that is the box counts.
  Future<Map<String, dynamic>?> _boxById(String id) async {
    Map<String, dynamic>? accept(String body) {
      final d = jsonDecode(body);
      return d is Map && d['boxId'] == id ? d.cast<String, dynamic>() : null;
    }

    final node = _gw.nodeUrl?.replaceAll(RegExp(r'/+$'), '');
    if (node != null) {
      try {
        final b = accept(await _get(Uri.parse('$node/blockchain/box/byId/$id')));
        if (b != null) return b;
      } catch (_) {
        // Fall through.
      }
    }
    final base = _gw.explorerBase.replaceAll(RegExp(r'/+$'), '');
    try {
      return accept(await _get(Uri.parse('$base/api/v1/boxes/$id')));
    } catch (_) {
      return null;
    }
  }

  /// A transaction by id, or null. Only a body with outputs counts.
  Future<Map<String, dynamic>?> _txById(String id) async {
    Map<String, dynamic>? accept(String body) {
      final d = jsonDecode(body);
      return d is Map && d['outputs'] is List ? d.cast<String, dynamic>() : null;
    }

    final node = _gw.nodeUrl?.replaceAll(RegExp(r'/+$'), '');
    if (node != null) {
      try {
        final t = accept(await _get(Uri.parse('$node/blockchain/transaction/byId/$id')));
        if (t != null) return t;
      } catch (_) {
        // Fall through.
      }
    }
    final base = _gw.explorerBase.replaceAll(RegExp(r'/+$'), '');
    try {
      return accept(await _get(Uri.parse('$base/api/v1/transactions/$id')));
    } catch (_) {
      return null;
    }
  }

  Future<int?> _height() async {
    final known = _gw.chainHeight;
    if (known != null && known > 0) return known;
    final node = _gw.nodeUrl?.replaceAll(RegExp(r'/+$'), '');
    if (node == null) return null;
    try {
      final info = jsonDecode(await _get(Uri.parse('$node/info'))) as Map;
      return (info['fullHeight'] as num?)?.toInt();
    } catch (_) {
      return null;
    }
  }

  /// A quote at the last read pool state. `amount` is asset units for a
  /// lend, lend tokens for a withdraw.
  Map<String, dynamic> quote({
    required String poolKey,
    required String kind,
    required int amount,
    int slippageBps = 100,
  }) {
    final boxes = lastPoolBoxesJson;
    if (boxes == null) throw StateError('Read the pools first');
    return (jsonDecode(_gw.quote(boxes, poolKey, kind, amount, slippageBps, 0)) as Map).cast<String, dynamic>();
  }

  /// Prepare an order. The result carries `preparation_id` for the confirm
  /// sheet and everything [commitOrder] needs.
  Future<Map<String, dynamic>> prepareOrder({
    required String poolKey,
    required String kind,
    required int amount,
    required String userAddress,
    required List<String> spendAddresses,
    required String changeAddress,
    int slippageBps = 100,
    int refundAfterBlocks = 720,
    String? collateralAsset,
    int? collateralAmount,
    String? collateralBoxId,
  }) async {
    final boxes = lastPoolBoxesJson;
    if (boxes == null) throw StateError('Read the pools first');
    final loanSide = kind == 'borrow' || kind == 'repay' || kind == 'partial_repay';
    if (loanSide && lastLoanBoxesJson == null) throw StateError('Read the loans first');
    final raw = await _gw.prepareOrder(
      poolBoxesJson: boxes,
      poolKey: poolKey,
      kind: kind,
      amount: amount,
      slippageBps: slippageBps,
      refundAfterBlocks: refundAfterBlocks,
      userAddress: userAddress,
      spendAddresses: spendAddresses,
      changeAddress: changeAddress,
      loanBoxesJson: loanSide ? lastLoanBoxesJson : null,
      collateralAsset: collateralAsset,
      collateralAmount: collateralAmount,
      collateralBoxId: collateralBoxId,
    );
    return (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  /// Record a broadcast order.
  Future<DuckOrder> commitOrder(Map<String, dynamic> prepared, String txId) async {
    final q = (prepared['quote'] as Map).cast<String, dynamic>();
    final kind = q['kind'] as String;
    final pool = pools.firstWhere((p) => p.key == q['pool']);
    int n(String key) => (q[key] as num).toInt();
    final (amount, expected, minOut) = switch (kind) {
      'lend' => (n('amount'), n('lend_tokens_expected'), n('min_lend_tokens')),
      'withdraw' => (n('lend_tokens'), n('out'), n('min_out')),
      'borrow' => (n('loan'), n('loan'), n('loan')),
      'repay' => (n('repayment'), n('collateral_nano'), n('collateral_nano')),
      'partial_repay' => (n('repayment'), n('final_borrow_tokens'), n('final_borrow_tokens')),
      _ => throw StateError('unknown order kind $kind'),
    };
    final order = DuckOrder(
      kind: kind,
      pool: pool.key,
      ticker: pool.ticker,
      decimals: pool.decimals,
      proxyBoxId: prepared['proxy_box_id'] as String,
      txId: txId,
      amount: amount,
      expected: expected,
      minOut: minOut,
      refundHeight: (prepared['refund_height'] as num).toInt(),
      createdAt: DateTime.now(),
      collateralBoxId: q['collateral_box_id'] as String?,
      collateralNano: (q['collateral_amount'] as num?)?.toInt() ?? (q['collateral_nano'] as num?)?.toInt(),
      collateralAsset: q['collateral_asset'] as String?,
    );
    orders = [order, ...orders];
    await _persistOrders();
    return order;
  }

  bool _ticking = false;

  /// Look at every open order once: still unspent (and refundable once
  /// past its height), filled, or refunded. Never throws; a tick that
  /// arrives while one is running is dropped.
  Future<void> tickOrders() async {
    if (_ticking || openOrders.isEmpty || _walletId == null) return;
    _ticking = true;
    try {
      await _tickOrders();
    } finally {
      _ticking = false;
    }
  }

  Future<void> _tickOrders() async {
    final height = await _height();
    var changed = false;
    for (final o in openOrders) {
      try {
        final box = await _boxById(o.proxyBoxId);
        if (box == null) {
          // Not seen yet, or the node forgot it: leave the status alone.
          continue;
        }
        final spentBy = box['spentTransactionId']?.toString();
        if (spentBy == null || spentBy.isEmpty) {
          final next = (height != null && height >= o.refundHeight) ? 'refundable' : 'pending';
          if (o.status == 'refund_sent') continue;
          if (o.status != next) {
            o.status = next;
            changed = true;
          }
          continue;
        }
        final tx = await _txById(spentBy);
        if (tx == null) continue;
        final outcome = (jsonDecode(_gw.orderOutcome(o.kind, o.proxyBoxId, jsonEncode(tx))) as Map).cast<String, dynamic>();
        final kind = outcome['outcome'] as String? ?? 'unknown';
        if (kind == 'filled') {
          o.status = 'filled';
          o.outcomeTxId = spentBy;
          final assets = (outcome['assets'] as List? ?? const []).cast<Map>();
          final pool = pools.firstWhere((p) => p.key == o.pool);
          int tokenAmount(String? id) => int.tryParse(
                  assets.firstWhere((a) => a['token_id'] == id, orElse: () => {'amount': '0'})['amount'].toString()) ??
              0;
          o.received = switch (o.kind) {
            'lend' => tokenAmount(pool.lendToken),
            'borrow' => tokenAmount(pool.currencyId),
            _ => (outcome['value'] as num?)?.toInt(),
          };
          changed = true;
        } else if (kind == 'refunded') {
          o.status = 'refunded';
          o.outcomeTxId = spentBy;
          changed = true;
        }
        o.lastError = null;
      } catch (e) {
        o.lastError = e.toString();
        changed = true;
      }
    }
    if (changed) await _persistOrders();
  }

  /// Prepare the refund of a refundable order. The proxy box is read
  /// fresh; the contract lets anyone build this, but only to the user.
  Future<Map<String, dynamic>> prepareRefund(DuckOrder o, {required String userAddress}) async {
    final box = await _boxById(o.proxyBoxId);
    if (box == null) throw StateError('The order box could not be found on chain');
    if ((box['spentTransactionId']?.toString() ?? '').isNotEmpty) {
      throw StateError('The order was already spent; the next check will say how');
    }
    final raw = await _gw.prepareRefund(jsonEncode(box), userAddress);
    return (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  Future<void> markRefundSent(DuckOrder o, String txId) async {
    o.status = 'refund_sent';
    o.outcomeTxId = txId;
    await _persistOrders();
  }

  Future<void> removeOrder(DuckOrder o) async {
    if (o.open) throw StateError('This order is still open');
    orders = orders.where((x) => x.proxyBoxId != o.proxyBoxId).toList();
    await _persistOrders();
  }

  /// Unspent boxes under the pool's script. A node that answers, even
  /// with an empty list, is believed; only a node that cannot answer
  /// sends the query to the explorer.
  Future<List<dynamic>> _boxesUnderScript(DuckPool p) => _boxesUnderTree(p.ergoTree, limit: 20);

  Future<List<dynamic>> _boxesUnderTree(String ergoTree, {required int limit}) async {
    final node = _gw.nodeUrl?.replaceAll(RegExp(r'/+$'), '');
    if (node != null) {
      try {
        final decoded = jsonDecode(await _post(
          Uri.parse('$node/blockchain/box/unspent/byErgoTree?offset=0&limit=$limit'),
          jsonEncode(ergoTree),
        ));
        if (decoded is List) return decoded;
        if (decoded is Map && decoded['items'] is List) return decoded['items'] as List;
      } catch (_) {
        // Fall through to the explorer.
      }
    }
    final base = _gw.explorerBase.replaceAll(RegExp(r'/+$'), '');
    final body = jsonDecode(
      await _get(Uri.parse('$base/api/v1/boxes/unspent/byErgoTree/$ergoTree?offset=0&limit=$limit')),
    );
    if (body is Map && body['items'] is List) return body['items'] as List;
    throw StateError('${Uri.parse(base).host} returned no box list');
  }
}

final duckpoolsService = DuckpoolsService();
