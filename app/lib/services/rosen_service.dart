import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../bridge/api.dart' as bridge;
import 'network_controller.dart';

/// Where an Ergo asset can go over the bridge.
class RosenTarget {
  const RosenTarget({required this.chain, required this.tokenId, required this.name, required this.decimals});
  final String chain;
  final String tokenId;
  final String name;
  final int decimals;

  static RosenTarget fromJson(Map<String, dynamic> m) => RosenTarget(
        chain: m['chain'] as String,
        tokenId: m['token_id'] as String,
        name: m['name'] as String,
        decimals: (m['decimals'] as num).toInt(),
      );
}

/// An Ergo asset the bridge takes.
class RosenToken {
  const RosenToken({required this.ergoTokenId, required this.name, required this.decimals, required this.residency, required this.targets});
  final String ergoTokenId;
  final String name;
  final int decimals;
  final String residency;
  final List<RosenTarget> targets;

  bool get isErg => ergoTokenId == 'erg';

  static RosenToken fromJson(Map<String, dynamic> m) => RosenToken(
        ergoTokenId: m['ergo_token_id'] as String,
        name: m['name'] as String,
        decimals: (m['decimals'] as num).toInt(),
        residency: m['residency'] as String? ?? '',
        targets: [for (final t in (m['targets'] as List)) RosenTarget.fromJson((t as Map).cast())],
      );
}

/// What a transfer costs and delivers, in the token's units.
class RosenQuote {
  const RosenQuote({
    required this.amount,
    required this.bridgeFee,
    required this.networkFee,
    required this.receiving,
    required this.minTransfer,
    required this.feeRatioBps,
  });
  final int amount;
  final int bridgeFee;
  final int networkFee;
  final int receiving;
  final int minTransfer;

  /// The bridge's cut of the amount, out of 10 000.
  final int feeRatioBps;

  static RosenQuote fromJson(Map<String, dynamic> m) {
    final q = (m['quote'] as Map).cast<String, dynamic>();
    final f = (m['fee'] as Map).cast<String, dynamic>();
    return RosenQuote(
      amount: (q['amount'] as num).toInt(),
      bridgeFee: (q['bridge_fee'] as num).toInt(),
      networkFee: (q['network_fee'] as num).toInt(),
      receiving: (q['receiving'] as num).toInt(),
      minTransfer: (q['min_transfer'] as num).toInt(),
      feeRatioBps: (f['fee_ratio'] as num).toInt(),
    );
  }
}

/// Human names for the bridge's chain keys.
String rosenChainName(String chain) => switch (chain) {
      'cardano' => 'Cardano',
      'bitcoin' => 'Bitcoin',
      'bitcoin-runes' => 'Bitcoin (Runes)',
      'ethereum' => 'Ethereum',
      'binance' => 'BNB Chain',
      'base' => 'Base',
      'doge' => 'Dogecoin',
      'firo' => 'Firo',
      'ergo' => 'Ergo',
      _ => chain,
    };

/// The Rust side, behind a seam so the service can be tested without it.
abstract class RosenGateway {
  String? get nodeUrl;
  String get explorerBase;
  int? get chainHeight;
  String info();
  String quote(String feeBoxesJson, String tokenId, String toChain, int amount, int height);
  String validateAddress(String chain, String address);
}

class LiveRosenGateway implements RosenGateway {
  const LiveRosenGateway();
  @override
  String? get nodeUrl => networkController.activeUrl;
  @override
  String get explorerBase => networkController.explorer;
  @override
  int? get chainHeight => networkController.height;
  @override
  String info() => bridge.rosenInfo();
  @override
  String quote(String feeBoxesJson, String tokenId, String toChain, int amount, int height) =>
      bridge.rosenQuote(feeBoxesJson: feeBoxesJson, tokenId: tokenId, toChain: toChain, amount: amount, height: height);
  @override
  String validateAddress(String chain, String address) => bridge.rosenValidateAddress(chain: chain, address: address);
}

typedef RosenHttpGet = Future<String> Function(Uri uri);

Future<String> _httpGet(Uri uri) async {
  final res = await http.get(uri).timeout(const Duration(seconds: 45));
  if (res.statusCode != 200) throw StateError('${uri.host} returned HTTP ${res.statusCode}');
  return res.body;
}

/// Rosen bridge: which assets can leave Ergo, what it costs, and the
/// fee boxes that say so.
class RosenService extends ChangeNotifier {
  RosenService({RosenGateway? gateway, RosenHttpGet? get})
      : _gw = gateway ?? const LiveRosenGateway(),
        _get = get ?? _httpGet;

  final RosenGateway _gw;
  final RosenHttpGet _get;

  Map<String, dynamic>? _info;
  Map<String, dynamic> get _loadedInfo => _info ??= (jsonDecode(_gw.info()) as Map).cast<String, dynamic>();

  String get lockAddress => _loadedInfo['lock_address'] as String;
  String get minFeeNft => _loadedInfo['min_fee_nft'] as String;
  String get contractsVersion => _loadedInfo['contracts_version'] as String;

  /// Every bridged token, as vendored.
  List<RosenToken> get tokens => [
        for (final t in (_loadedInfo['tokens'] as List)) RosenToken.fromJson((t as Map).cast()),
      ];

  /// The bridged tokens this wallet holds (ERG always), with what it holds.
  List<(RosenToken, int)> holdings(int ergNano, Map<String, int> tokenHoldings) {
    final out = <(RosenToken, int)>[];
    for (final t in tokens) {
      if (t.isErg) {
        out.add((t, ergNano));
      } else if ((tokenHoldings[t.ergoTokenId] ?? 0) > 0) {
        out.add((t, tokenHoldings[t.ergoTokenId]!));
      }
    }
    return out;
  }

  /// The minimum-fee boxes of the last read, every token's.
  String? lastFeeBoxesJson;
  DateTime? feesReadAt;
  String? lastError;
  bool _busy = false;
  bool get busy => _busy;

  /// Read every minimum-fee box (they all carry one NFT): node first,
  /// explorer second.
  Future<void> refreshFees() async {
    if (_busy) return;
    _busy = true;
    notifyListeners();
    try {
      final all = <dynamic>[];
      const page = 100;
      for (var offset = 0;; offset += page) {
        final batch = await _boxesByToken(minFeeNft, offset: offset, limit: page);
        all.addAll(batch);
        if (batch.length < page) break;
      }
      lastFeeBoxesJson = jsonEncode(all);
      feesReadAt = DateTime.now();
      lastError = null;
    } catch (e) {
      lastError = e.toString();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<List<dynamic>> _boxesByToken(String tokenId, {required int offset, required int limit}) async {
    final node = _gw.nodeUrl?.replaceAll(RegExp(r'/+$'), '');
    if (node != null) {
      try {
        final decoded = jsonDecode(await _get(Uri.parse('$node/blockchain/box/unspent/byTokenId/$tokenId?offset=$offset&limit=$limit')));
        if (decoded is List) return decoded;
        if (decoded is Map && decoded['items'] is List) return decoded['items'] as List;
      } catch (_) {
        // Fall through.
      }
    }
    final base = _gw.explorerBase.replaceAll(RegExp(r'/+$'), '');
    final body = jsonDecode(await _get(Uri.parse('$base/api/v1/boxes/unspent/byTokenId/$tokenId?offset=$offset&limit=$limit')));
    if (body is Map && body['items'] is List) return body['items'] as List;
    throw StateError('no box list');
  }

  /// What sending `amount` of `tokenId` to `toChain` costs right now.
  RosenQuote quote({required String tokenId, required String toChain, required int amount}) {
    final boxes = lastFeeBoxesJson;
    if (boxes == null) throw StateError('Read the bridge fees first');
    final height = _gw.chainHeight;
    if (height == null || height <= 0) throw StateError('The chain height could not be read');
    return RosenQuote.fromJson((jsonDecode(_gw.quote(boxes, tokenId, toChain, amount, height)) as Map).cast<String, dynamic>());
  }

  /// Empty when `address` is well formed for `chain`, else the reason.
  String addressProblem(String chain, String address) => _gw.validateAddress(chain, address);

  /// Where to follow a transfer once its lock transaction is on chain.
  static String trackingUrl(String lockTxId) => 'https://app.rosen.tech/events?search=$lockTxId';
}

final rosenService = RosenService();
