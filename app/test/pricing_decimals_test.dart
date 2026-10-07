import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/amm_service.dart';
import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/oracle_feeds.dart';
import 'package:argus_wallet/services/token_catalog.dart';
import 'package:argus_wallet/services/token_pricer.dart';
import 'package:argus_wallet/services/token_pricing.dart';
import 'package:argus_wallet/services/verified_tokens.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Pricing scales every token by the one token lookup. A held token the
// public catalog has not reached yet is still known from this wallet's own
// descriptors, and must be priced per whole token at that scale, never per
// base unit as if its decimals were zero. A token whose scale nothing knows
// is left unpriced and out of totals.

const _node = 'https://node.example';
const _wallet = 'pricing-decimals';

/// Held by the wallet, described by the node with 6 decimals, in no
/// catalog and on no curated list.
final _held = 'c6' * 32;

/// Held too, but nothing has described it.
final _unscaled = 'd7' * 32;

/// The wallet's node: it describes [_held] when the sync's name pass asks,
/// and nothing else.
class DescriptorApi extends RustLibApi {
  @override
  Future<BigInt> crateApiWalletRestore({
    required String encryptedSeedJson,
    String? wrapKey,
  }) async => BigInt.one;

  @override
  Future<void> crateApiWalletLock({required BigInt handleId}) async {}

  @override
  void crateApiCancelTokenMetadata() {}

  @override
  Future<String> crateApiInspectTokenMetadata({
    required String tokenId,
    required String providerUrl,
    required bool providerIsNode,
  }) async {
    if (tokenId != _held) throw '{"code":"NOT_FOUND","message":"no issuance box"}';
    return jsonEncode({
      'id': tokenId,
      'name': 'Six',
      'decimals': 6,
      'decimalsEvidence': 'valid',
      'supplyEvidence': 'originalEmission',
      'emissionAmount': 1000000000000,
      'declaredAssetKind': 'none',
      'metadataState': 'complete',
      'mediaState': 'unknown',
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A pricer over fixed reads: ERG at $0.50 from the SigmaUSD oracle pool,
/// and a pool quote of 4 nanoERG per base unit for both held tokens.
class _Pricing {
  int poolPriceCalls = 0;

  late final deps = PricerDeps(
    nodeUrl: () => _node,
    tipHeight: () => 1000,
    fiatCode: () => 'usd',
    oracle: (_) async => null,
    coingecko: (_, _) async => const {},
    pools: () async => const AmmPoolSet(truncated: false, pools: [], tokens: {}),
    poolPrices: (_) async {
      poolPriceCalls++;
      return PoolPriceBook(
        tokens: {
          for (final id in [_held, _unscaled])
            id: PoolQuote(nanoErgPerUnit: 4, depthNano: 1000000000000, trusted: true, poolId: 'pool-$id'),
        },
      );
    },
    sigRsvPriceNano: () async => null,
    oracleReading: (_, feed) async =>
        feed == OracleFeed.sigmaUsd ? OracleReading(rate: 2000000000, height: 999) : null,
    onRate: (_, _) {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    RustLib.initMock(api: DescriptorApi());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.argus.wallet/secure_storage'),
      (call) async => null,
    );
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    publicTokenCatalog.debugReset();
    networkController.activeUrl = _node;
    await walletService.restoreWallet('mock', walletId: _wallet);
  });

  tearDown(() async {
    networkController.activeUrl = null;
    if (walletService.isUnlocked) await walletService.lock();
  });

  /// What the sync's name pass does for the wallet's holdings.
  Future<void> describeHoldings() => walletService.prefetchTokenMeta(
        [_held, _unscaled],
        walletId: _wallet,
        servedBy: _node,
        stillCurrent: () => true,
      );

  test('a held token known only from the wallet\'s descriptors is priced per whole token', () async {
    await describeHoldings();
    // Only the wallet's own descriptor knows the scale.
    expect(publicTokenCatalog.lookup(_held), isNull);
    expect(knownToken(_held), isNull);
    expect(walletService.cachedTokenMeta(_held)?.decimals, 6);

    final p = TokenPricer(_Pricing().deps);
    addTearDown(p.dispose);
    await p.refresh();
    expect(p.result.ergUsd, 0.5);

    // 4 nanoERG per base unit is 0.004 ERG per token: $0.002 at $0.50.
    final price = p.priceOf(_held)!;
    expect(price.usd, closeTo(0.002, 1e-12));
    expect(price.decimals, 6);
    // 2.5 tokens.
    expect(p.usdOf(_held, 2500000, 6), closeTo(0.005, 1e-12));
    final value = holdingsValue(
      ergNano: 0,
      tokens: [(id: _held, amount: 2500000, decimals: 6)],
      result: p.result,
    );
    expect(value.priced, 1);
    expect(value.usd, closeTo(0.005, 1e-12));
  });

  test('a held token whose scale nothing knows is unpriced and left out of totals', () async {
    await describeHoldings();
    expect(walletService.cachedTokenMeta(_unscaled), isNull);

    final p = TokenPricer(_Pricing().deps);
    addTearDown(p.dispose);
    await p.refresh();
    expect(p.priceOf(_unscaled), isNull, reason: 'a per-base-unit quote is not a price per token');
    expect(p.usdOf(_unscaled, 2500000, 0), isNull);
    final value = holdingsValue(
      ergNano: 1000000000,
      tokens: [(id: _unscaled, amount: 2500000, decimals: 0)],
      result: p.result,
    );
    expect(value.unpriced, 1);
    expect(value.priced, 0);
    expect(value.usd, closeTo(0.5, 1e-12), reason: 'the ERG alone');
  });

  test('a scale learned after the refresh prices the token without another read', () async {
    final pricing = _Pricing();
    final p = TokenPricer(pricing.deps);
    addTearDown(p.dispose);
    await p.refresh();
    expect(p.priceOf(_held), isNull, reason: 'nothing knew its scale yet');

    var notified = 0;
    p.addListener(() => notified++);
    await describeHoldings();
    expect(p.priceOf(_held)?.usd, closeTo(0.002, 1e-12));
    expect(notified, greaterThan(0));
    expect(pricing.poolPriceCalls, 1, reason: 'worked out again from the same quotes');
  });

  test('a holding recorded at another scale is valued at the price\'s own', () async {
    await describeHoldings();
    final p = TokenPricer(_Pricing().deps);
    addTearDown(p.dispose);
    await p.refresh();
    // A holding published before the scale was known, or a locked wallet's
    // older snapshot, says 0 decimals; its base units are still 2.5 tokens.
    expect(p.usdOf(_held, 2500000, 0), closeTo(0.005, 1e-12));
    expect(p.usdOf(_held, 2500000, 6), closeTo(0.005, 1e-12));
    final value = holdingsValue(
      ergNano: 0,
      tokens: [(id: _held, amount: 2500000, decimals: 0)],
      result: p.result,
    );
    expect(value.usd, closeTo(0.005, 1e-12));
  });
}
