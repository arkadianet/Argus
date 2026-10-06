import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/amm_service.dart';
import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/oracle_feeds.dart';
import 'package:argus_wallet/services/token_catalog.dart';
import 'package:argus_wallet/services/token_metadata.dart';
import 'package:argus_wallet/services/token_pricer.dart';
import 'package:argus_wallet/services/token_pricing.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/watch_account_service.dart';
import 'package:argus_wallet/services/watch_only_service.dart';
import 'package:argus_wallet/services/watched_token_meta.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Watched addresses and watched accounts are first-class wallets: what they
// hold is named and scaled automatically, as a seed wallet's holdings are,
// only by the node that served their balances, and stored per wallet.

const _preferred = 'https://preferred.example';
const _served = 'https://answered.example';
const _watched = '9watchedAddressHoldingTokensxxxxxxxxxxxxxxxxxxxxxxxxx';
const _accountKey = '0488b21e-watched-account';
final _alpha = 'a1' * 32;
final _beta = 'b2' * 32;

String _tableKey(String key) => 'argus_token_descriptors_v1_watched:$key';

/// The user's node, as far as watched wallets reach it: balances, the
/// public sync read that names the node that answered, issuance lookups,
/// and what an account scan derives and reads.
class WatchedApi extends RustLibApi {
  final balances = <String, Map<String, dynamic>>{};

  /// What the public sync read says answered; null when it cannot say.
  String? servedBy = _served;
  final asked = <({String id, String provider})>[];
  final syncReads = <List<String>>[];

  static final _described = {
    _alpha: ('Alpha', 6),
    _beta: ('Beta', 3),
  };

  Map<String, dynamic> _balance(String address) =>
      balances[address] ?? {'balance_nano_erg': 0, 'tokens': []};

  @override
  Future<String> crateApiGetBalance({
    required String address,
    String? nodeUrl,
  }) async => jsonEncode(_balance(address));

  @override
  Future<String> crateApiMempoolGetPublicSyncInputs({
    required List<String> addresses,
    String? nodeUrl,
  }) async {
    syncReads.add(addresses);
    return jsonEncode({
      'balances': {for (final a in addresses) a: _balance(a)},
      'pending': [],
      'served_by': servedBy,
    });
  }

  @override
  Future<String> crateApiInspectTokenMetadata({
    required String tokenId,
    required String providerUrl,
    required bool providerIsNode,
  }) async {
    asked.add((id: tokenId, provider: providerUrl));
    final known = _described[tokenId];
    if (known == null) throw '{"code":"NOT_FOUND","message":"404 not found"}';
    return jsonEncode({
      'id': tokenId,
      'name': known.$1,
      'decimals': known.$2,
      'decimalsEvidence': 'valid',
      'supplyEvidence': 'originalEmission',
      'emissionAmount': 1000000000000,
      'declaredAssetKind': 'none',
      'metadataState': 'complete',
      'mediaState': 'unknown',
    });
  }

  @override
  void crateApiCancelTokenMetadata() {}

  @override
  Future<List<String>> crateApiDeriveWatchAddresses({
    required String input,
    required int start,
    required int count,
  }) async => [for (var i = start; i < start + count; i++) 'acct$i'];

  @override
  Future<String> crateApiGetTransactionHistory({
    required String address,
    String? nodeUrl,
    required BigInt limit,
    required BigInt offset,
  }) async => '[]';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 2000 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(done(), isTrue, reason: 'condition never became true');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = WatchedApi();
  setUpAll(() {
    RustLib.initMock(api: api);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.argus.wallet/secure_storage'),
      (call) async => null,
    );
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'argus_watch_only_addresses': jsonEncode([_watched]),
    });
    publicTokenCatalog.debugReset();
    networkController.activeUrl = _preferred;
    api
      ..balances.clear()
      ..asked.clear()
      ..syncReads.clear()
      ..servedBy = _served;
    await watchOnlyService.load();
    watchAccountService.accounts.clear();
    watchedTokenMeta.attach();
  });

  tearDown(() async {
    watchedTokenMeta.detach();
    await walletService.forgetWatchedTokenTable(WalletService.watchedAddressKey(_watched));
    await walletService.forgetWatchedTokenTable(WalletService.watchedAccountKey(_accountKey));
    watchAccountService.accounts.clear();
    networkController.activeUrl = null;
  });

  test('a watched address names and scales its tokens without an explicit load', () async {
    api.balances[_watched] = {
      'balance_nano_erg': 1000000000,
      'tokens': [
        {'id': _alpha, 'amount': 2500000},
      ],
    };
    expect(tokenName(_alpha), isNull);

    // The overview and the watched page read the balance this way.
    await walletService.getBalance(_watched, nodeUrl: _preferred);
    await _until(() => tokenDecimals(_alpha) != null);

    // Assets: the page shows holdings through displayMetadata.
    final shown = walletService.displayMetadata(TokenBalance(id: _alpha, amount: 2500000));
    expect(shown.name, 'Alpha');
    expect(shown.decimals, 6);
    expect(holdingAmountText(shown), '2.5');
    // Activity rows and transaction details name tokens the same way.
    expect(tokenAmountText(BigInt.from(2500000), _alpha), '2.5 Alpha');

    // Only the node that answered the balance read was asked, and only
    // about what it served; not the preferred URL, not an explorer.
    expect(api.syncReads, [
      [_watched],
    ]);
    expect(api.asked, [(id: _alpha, provider: _served)]);

    // Stored for this wallet alone, never where seed wallets' holdings or
    // an app-wide table would carry it.
    final prefs = await SharedPreferences.getInstance();
    await _until(() => prefs.getString(_tableKey('address:$_watched')) != null);
    expect(prefs.getString(_tableKey('address:$_watched')), contains(_alpha));
    expect(prefs.getString('argus_token_meta_v2'), isNull);
    expect(walletService.cachedTokenMeta(_alpha), isNull);

    // A second read asks nothing again.
    await walletService.getBalance(_watched, nodeUrl: _preferred);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(api.asked, hasLength(1));
  });

  test('a watched address\'s tokens are priced at the scale they were resolved to', () async {
    api.balances[_watched] = {
      'balance_nano_erg': 0,
      'tokens': [
        {'id': _alpha, 'amount': 2500000},
      ],
    };
    final pricer = TokenPricer(PricerDeps(
      nodeUrl: () => _preferred,
      tipHeight: () => 1000,
      fiatCode: () => 'usd',
      oracle: (_) async => null,
      coingecko: (_, _) async => const {},
      pools: () async => const AmmPoolSet(truncated: false, pools: [], tokens: {}),
      poolPrices: (_) async => PoolPriceBook(tokens: {
        _alpha: const PoolQuote(nanoErgPerUnit: 4, depthNano: 1000000000000, trusted: true, poolId: 'p'),
      }),
      sigRsvPriceNano: () async => null,
      oracleReading: (_, feed) async =>
          feed == OracleFeed.sigmaUsd ? OracleReading(rate: 2000000000, height: 999) : null,
      onRate: (_, _) {},
    ));
    addTearDown(pricer.dispose);
    await pricer.refresh();
    expect(pricer.priceOf(_alpha), isNull, reason: 'its scale is not known yet');

    await walletService.getBalance(_watched, nodeUrl: _preferred);
    await _until(() => pricer.priceOf(_alpha) != null);
    // 4 nanoERG a base unit at 6 decimals and $0.50: $0.002 a token.
    expect(pricer.priceOf(_alpha)!.usd, closeTo(0.002, 1e-12));
    expect(pricer.usdOf(_alpha, 2500000, 6), closeTo(0.005, 1e-12));
  });

  test('a watched account names its tokens after a scan, in its own table', () async {
    api.balances['acct0'] = {
      'balance_nano_erg': 1000000000,
      'tokens': [
        {'id': _beta, 'amount': 1500},
      ],
    };
    final account = WatchAccount(_accountKey);
    watchAccountService.accounts.add(account);
    expect(tokenName(_beta), isNull);

    await watchAccountService.refresh(account);
    expect(account.snapshot, isNotNull);
    expect(account.snapshot!.tokenAddresses, ['acct0']);
    await _until(() => tokenDecimals(_beta) != null);

    expect(tokenName(_beta), 'Beta');
    expect(tokenAmountText(BigInt.from(1500), _beta), '1.5 Beta');
    // Only the address holding tokens is read again, and only the node
    // that answered that read is asked.
    expect(api.syncReads.last, ['acct0']);
    expect(api.asked, [(id: _beta, provider: _served)]);

    final prefs = await SharedPreferences.getInstance();
    await _until(() => prefs.getString(_tableKey('account:$_accountKey')) != null);
    final accountTable = prefs.getString(_tableKey('account:$_accountKey'))!;
    expect(accountTable, contains(_beta));
    expect(accountTable, isNot(contains(_alpha)));
    expect(prefs.getString(_tableKey('address:$_watched')), isNull, reason: 'one table per wallet');
    expect(prefs.getString('argus_token_meta_v2'), isNull);
  });

  test('each watched wallet keeps its own table, and loses it when unwatched', () async {
    api.balances[_watched] = {
      'balance_nano_erg': 0,
      'tokens': [
        {'id': _alpha, 'amount': 1},
      ],
    };
    api.balances['acct0'] = {
      'balance_nano_erg': 0,
      'tokens': [
        {'id': _beta, 'amount': 1},
      ],
    };
    final account = WatchAccount(_accountKey);
    watchAccountService.accounts.add(account);
    await walletService.getBalance(_watched, nodeUrl: _preferred);
    await watchAccountService.refresh(account);
    final prefs = await SharedPreferences.getInstance();
    await _until(
      () =>
          prefs.getString(_tableKey('address:$_watched')) != null &&
          prefs.getString(_tableKey('account:$_accountKey')) != null,
    );
    expect(prefs.getString(_tableKey('address:$_watched')), isNot(contains(_beta)));
    expect(prefs.getString(_tableKey('account:$_accountKey')), isNot(contains(_alpha)));

    await watchOnlyService.remove(_watched);
    await _until(() => prefs.getString(_tableKey('address:$_watched')) == null);
    expect(tokenName(_alpha), isNull, reason: 'gone with the wallet');
    expect(tokenName(_beta), 'Beta', reason: 'the account keeps its own');
  });

  test('a token the node says does not exist is not read for again', () async {
    final unknown = 'cc' * 32;
    api.balances[_watched] = {
      'balance_nano_erg': 0,
      'tokens': [
        {'id': unknown, 'amount': 1},
      ],
    };
    await walletService.getBalance(_watched, nodeUrl: _preferred);
    await _until(() => api.asked.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(api.syncReads, hasLength(1));
    // The overview reads the address again: nothing new to learn, so no
    // second read and no second question.
    await walletService.getBalance(_watched, nodeUrl: _preferred);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(api.syncReads, hasLength(1));
    expect(api.asked, hasLength(1));
  });

  test('nothing is asked when the node that answered cannot be told', () async {
    api.servedBy = null;
    api.balances[_watched] = {
      'balance_nano_erg': 0,
      'tokens': [
        {'id': _alpha, 'amount': 1},
      ],
    };
    await walletService.getBalance(_watched, nodeUrl: _preferred);
    await _until(() => api.syncReads.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(api.asked, isEmpty);
    expect(tokenName(_alpha), isNull);
  });
}
