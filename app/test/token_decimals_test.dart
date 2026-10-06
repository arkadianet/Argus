import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/amm_service.dart';
import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/oracle_feeds.dart';
import 'package:argus_wallet/services/token_catalog.dart';
import 'package:argus_wallet/services/token_decimals.dart';
import 'package:argus_wallet/services/token_descriptor_store.dart';
import 'package:argus_wallet/services/token_metadata.dart';
import 'package:argus_wallet/services/token_pricer.dart';
import 'package:argus_wallet/services/token_pricing.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// What a token's decimals rest on, read from what the node's issuance lookup
// returns. Only "nothing could be read" and "what the issuer wrote cannot be"
// leave amounts in raw units. A box read with no R6 is a known zero, and an
// R6 written as a plain integer, as some minting tools write it, counts when
// the token record agrees. Seen on node.kadia.io: Carrier Pigeon and four
// more NFTs have R6 = 0400 (Int 0) and a token record saying 0 decimals,
// and showed as "1 raw unit".

const _node = 'https://node.example';
const _wallet = 'decimals-rule';

final _pigeon = '16' * 32;
final _bare = 'b0' * 32;
final _unread = 'e0' * 32;
final _odd = '0d' * 32;

/// Carrier Pigeon's issuance box as node.kadia.io returns it.
const _pigeonRegisters = {
  'R4': '0e0e4361727269657220506967656f6e',
  'R5': '0e314d656e74616c204974656d202d203620506f696e74730a47524541535920524f59414c45204d495353494f4e2043415244',
  'R6': '0400',
  'R7': '0e020101',
  'R8': '0e200835dc089cb1732186c3d26ed29ccb5566588ca7fb36a67d14cec1f65005e059',
  'R9': '0e42697066733a2f2f626166796265696437756f6c35676b71326174706270776872663774667873666871737974716e756f6d656d6e6d32343235357068627575683371',
};

/// An inspection answer shaped as the native parser returns it.
Map<String, dynamic> _answer(
  String id, {
  String name = 'Token',
  int? decimals,
  String evidence = 'valid',
  String state = 'complete',
  Map<String, Object>? registers,
  bool boxRead = true,
}) => {
  'id': id,
  'name': name,
  'decimals': ?decimals,
  'decimalsEvidence': evidence,
  'supplyEvidence': 'originalEmission',
  'emissionAmount': 1,
  'declaredAssetKind': 'picture',
  'metadataState': state,
  'mediaState': 'notLoaded',
  'issuanceTransactionId': boxRead ? 'aa' * 32 : null,
  if (registers != null) 'rawRegisters': jsonEncode(registers),
};

/// The four kinds of token a wallet can hold, as the node describes them.
final _answers = {
  // R6 = Int 0 and a record of 0: the parser calls the box invalid.
  _pigeon: _answer(
    _pigeon,
    name: 'Carrier Pigeon',
    decimals: 0,
    evidence: 'invalid',
    state: 'invalid',
    registers: _pigeonRegisters,
  ),
  // No R6, and a record without decimals: the parser says unknown.
  _bare: _answer(
    _bare,
    name: 'Bare',
    evidence: 'unknown',
    state: 'partial',
    registers: {'R4': '0e0442617265'},
  ),
  // A record without decimals and an issuance box that could not be read.
  _unread: {
    ..._answer(_unread, name: 'Unread', evidence: 'unknown', state: 'partial', boxRead: false),
    'incomplete': true,
  },
  // R6 = "A": no number of decimals at all.
  _odd: _answer(
    _odd,
    name: 'Odd',
    decimals: 0,
    evidence: 'invalid',
    state: 'invalid',
    registers: {'R4': '0e034f6464', 'R6': '0e0141'},
  ),
};

class _NodeApi extends RustLibApi {
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
    final answer = _answers[tokenId];
    if (answer == null) throw '{"code":"NOT_FOUND","message":"404 not found"}';
    return jsonEncode(answer);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DeclaredDecimals _read(Map<String, dynamic> m) => declaredDecimals(m);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    RustLib.initMock(api: _NodeApi());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.argus.wallet/secure_storage'),
      (call) async => null,
    );
  });

  group('the rule', () {
    test('an integer R6 the record agrees with is declared', () {
      final d = _read(_answers[_pigeon]!);
      expect(d.evidence, DecimalsEvidence.valid);
      expect(d.decimals, 0);
      expect(d.metadataState, MetadataState.partial,
          reason: 'R6 was the only thing the parser objected to');

      Map<String, dynamic> withR6(String r6, {int? record}) => _answer(
        _pigeon,
        decimals: record,
        evidence: 'invalid',
        state: 'invalid',
        registers: {..._pigeonRegisters, 'R6': r6},
      );
      expect(_read(withR6('0404', record: 2)).decimals, 2, reason: 'Int 2');
      expect(_read(withR6('0404')).evidence, DecimalsEvidence.valid,
          reason: 'a record silent on decimals does not contradict it');
      expect(_read(withR6('0508', record: 4)).decimals, 4, reason: 'Long 4');
      expect(_read(withR6('0206', record: 6)).decimals, 6, reason: 'Byte 6');
      expect(_read(withR6('0404', record: 0)).evidence, DecimalsEvidence.invalid,
          reason: 'the record contradicts it');
      expect(_read(withR6('04d804', record: 300)).evidence, DecimalsEvidence.invalid,
          reason: '300 is no number of decimals');
      expect(_read(withR6('0401')).evidence, DecimalsEvidence.invalid, reason: '-1');
      expect(_read(withR6('040000')).evidence, DecimalsEvidence.invalid,
          reason: 'trailing bytes');
    });

    test('an R6 that is no number of decimals stays invalid', () {
      for (final r6 in ['0e0141', '0e00', '0e03323536', '0101', '04', 'zz']) {
        final d = _read(_answer(
          _odd,
          decimals: 0,
          evidence: 'invalid',
          state: 'invalid',
          registers: {'R6': r6},
        ));
        expect(d.evidence, DecimalsEvidence.invalid, reason: r6);
        expect(d.metadataState, MetadataState.invalid, reason: r6);
      }
      // Readable decimals do not excuse a malformed name.
      final badName = _read(_answer(
        _pigeon,
        decimals: 0,
        evidence: 'invalid',
        state: 'invalid',
        registers: {..._pigeonRegisters, 'R4': '0e05ff'},
      ));
      expect(badName.evidence, DecimalsEvidence.valid);
      expect(badName.metadataState, MetadataState.invalid);
    });

    test('a box read without an R6 is a known zero; one not read is unknown', () {
      final bare = _read(_answers[_bare]!);
      expect(bare.evidence, DecimalsEvidence.absent);
      expect(bare.decimals, 0);
      // A box with no registers object at all.
      expect(
        _read(_answer(_bare, evidence: 'unknown', state: 'partial')).evidence,
        DecimalsEvidence.absent,
      );
      expect(_read(_answers[_unread]!).evidence, DecimalsEvidence.unknown);
      // A box that contradicts its record says nothing about what it lacks.
      expect(
        _read(_answer(_bare, evidence: 'unknown', state: 'conflict', registers: {})).evidence,
        DecimalsEvidence.unknown,
      );
      // The record's decimals with no R6: the parser's own "valid".
      expect(
        _read(_answer(_bare, decimals: 0, evidence: 'valid', state: 'partial', registers: {})).evidence,
        DecimalsEvidence.valid,
      );
    });

    test('an explorer lists registers as objects', () {
      final d = _read(_answer(
        _pigeon,
        decimals: 0,
        evidence: 'invalid',
        state: 'invalid',
        registers: {
          for (final e in _pigeonRegisters.entries)
            e.key: {'serializedValue': e.value, 'sigmaType': 'x', 'renderedValue': 'y'},
        },
      ));
      expect(d.evidence, DecimalsEvidence.valid);
      expect(d.metadataState, MetadataState.partial);
    });
  });

  group('display', () {
    TokenBalance holding(DecimalsEvidence evidence, {MetadataState state = MetadataState.partial, String? name = 'N'}) =>
        TokenBalance(id: _bare, amount: 1, name: name, decimalsEvidence: evidence, metadataState: state);

    test('declared, absent and listed scales are plain amounts', () {
      for (final e in [DecimalsEvidence.valid, DecimalsEvidence.absent, DecimalsEvidence.listed]) {
        expect(holdingAmountText(holding(e)), '1', reason: '$e');
      }
    });

    test('unread and malformed scales are raw units', () {
      expect(holdingAmountText(holding(DecimalsEvidence.unknown)), '1 raw unit',
          reason: 'an inspection that could not read the decimals does not guess');
      expect(holdingAmountText(holding(DecimalsEvidence.invalid)), '1 raw unit');
      expect(holdingAmountText(holding(DecimalsEvidence.unknown, state: MetadataState.unavailable, name: null)),
          '1 raw unit', reason: 'a holding nothing has described');
      // A holding restored from a snapshot keeps the scale it was shown at.
      expect(holdingAmountText(holding(DecimalsEvidence.unknown, state: MetadataState.unavailable)), '1');
    });

    test('a single-unit NFT with no R6 is still one', () {
      final nft = TokenBalance(
        id: _bare,
        amount: 1,
        emissionAmount: 1,
        supplyEvidence: SupplyEvidence.originalEmission,
        decimalsEvidence: DecimalsEvidence.absent,
        metadataState: MetadataState.partial,
      );
      expect(nft.isCollectible, isTrue);
      expect(nft.classification, 'Single-unit token');
    });
  });

  group('stored tables', () {
    Map<String, dynamic> stored(DecimalsEvidence e, {String? source = _node, bool current = false}) => {
      'name': 'Stored',
      'decimals': 0,
      'decimalsEvidence': e.name,
      'metadataState': 'invalid',
      'source': source,
      if (current) 'decimalsRule': TokenDescriptorStore.decimalsRule,
    };

    test('rows read under the earlier rule are read again', () {
      for (final e in [DecimalsEvidence.invalid, DecimalsEvidence.unknown]) {
        final d = TokenDescriptorStore.decode(_pigeon, stored(e))!;
        expect(d.incomplete, isTrue, reason: '$e is asked again');
        expect(d.decimalsEvidence, e);
      }
      final valid = TokenDescriptorStore.decode(_pigeon, stored(DecimalsEvidence.valid))!;
      expect(valid.incomplete, isFalse);
      // The old pool table recorded no provenance and no evidence.
      final listed = TokenDescriptorStore.decode(_pigeon, stored(DecimalsEvidence.unknown, source: null))!;
      expect(listed.decimalsEvidence, DecimalsEvidence.listed);
      expect(listed.incomplete, isFalse);
      // Rows written under this rule are taken as they are.
      final now = TokenDescriptorStore.decode(_pigeon, stored(DecimalsEvidence.invalid, current: true))!;
      expect(now.incomplete, isFalse);
    });

    test('a written row carries the rule it was read under', () {
      final encoded = TokenDescriptorStore.encode(
        CachedDescriptor.fromInspection(_answers[_pigeon]!, source: _node),
      );
      expect(encoded['decimalsRule'], TokenDescriptorStore.decimalsRule);
      expect(encoded['decimalsEvidence'], 'valid');
    });
  });

  group('a seed wallet', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      publicTokenCatalog.debugReset();
      networkController.activeUrl = _node;
      await walletService.restoreWallet('mock', walletId: _wallet);
      await walletService.prefetchTokenMeta(
        _answers.keys,
        walletId: _wallet,
        servedBy: _node,
        stillCurrent: () => true,
      );
    });

    tearDown(() async {
      networkController.activeUrl = null;
      if (walletService.isUnlocked) await walletService.lock();
    });

    String shown(String id) => holdingAmountText(
      walletService.displayMetadata(TokenBalance(id: id, amount: 1)),
    );

    test('shows an integer R6 and a missing R6 as whole units', () {
      expect(shown(_pigeon), '1');
      expect(tokenName(_pigeon), 'Carrier Pigeon');
      expect(tokenAmountText(BigInt.one, _pigeon), '1 Carrier Pigeon');
      expect(walletService.cachedTokenMeta(_pigeon)!.isCollectible, isTrue,
          reason: 'a picture NFT once its R6 is read');
      expect(shown(_bare), '1');
      expect(walletService.cachedTokenMeta(_bare)!.decimalsEvidence, DecimalsEvidence.absent);
    });

    test('leaves unread and malformed scales in raw units', () {
      expect(shown(_unread), '1 raw unit');
      expect(tokenDecimals(_unread), isNull);
      expect(shown(_odd), '1 raw unit');
      expect(walletService.cachedTokenMeta(_odd)!.decimalsEvidence, DecimalsEvidence.invalid);
    });

    test('names every holding over successive passes, past the per-pass cap', () async {
      final many = [
        for (var i = 0; i < WalletService.maxTokenMetaPerSync + 5; i++)
          'f${i.toRadixString(16).padLeft(3, '0')}' * 16,
      ];
      for (final id in many) {
        _answers[id] = _answer(id, name: 'Many', decimals: 0, registers: {});
      }
      addTearDown(() {
        for (final id in many) {
          _answers.remove(id);
        }
      });
      Future<void> pass() => walletService.prefetchTokenMeta(
        many,
        walletId: _wallet,
        servedBy: _node,
        stillCurrent: () => true,
      );
      await pass();
      expect(many.where((id) => tokenName(id) != null), hasLength(WalletService.maxTokenMetaPerSync));
      // Every sync of the wallet runs a pass, starting where the last stopped.
      await pass();
      expect(many.where((id) => tokenName(id) == null), isEmpty);
    });

    test('prices only what it can scale', () async {
      final pricer = TokenPricer(PricerDeps(
        nodeUrl: () => _node,
        tipHeight: () => 1000,
        fiatCode: () => 'usd',
        oracle: (_) async => null,
        coingecko: (_, _) async => const {},
        pools: () async => const AmmPoolSet(truncated: false, pools: [], tokens: {}),
        poolPrices: (_) async => PoolPriceBook(tokens: {
          for (final id in [_bare, _unread, _odd])
            id: PoolQuote(nanoErgPerUnit: 4, depthNano: 1000000000000, trusted: true, poolId: 'p-$id'),
        }),
        sigRsvPriceNano: () async => null,
        oracleReading: (_, feed) async =>
            feed == OracleFeed.sigmaUsd ? OracleReading(rate: 2000000000, height: 999) : null,
        onRate: (_, _) {},
      ));
      addTearDown(pricer.dispose);
      await pricer.refresh();
      expect(pricer.priceOf(_bare), isNotNull, reason: 'a known zero is a scale');
      expect(pricer.priceOf(_unread), isNull, reason: 'no guessed zero');
      expect(pricer.priceOf(_odd), isNull);
    });
  });

  test('pool lists carry only the scales the public layers know', () {
    publicTokenCatalog.debugReset();
    publicTokenCatalog.debugSeed([
      CachedDescriptor.fromInspection(_answers[_bare]!, source: _node),
      CachedDescriptor.fromInspection(_answers[_unread]!, source: _node),
      CachedDescriptor.fromInspection(_answers[_odd]!, source: _node),
    ]);
    Map<String, dynamic> pool(String id) => {
      'pool_id': 'p-$id',
      'pool_type': 'N2T',
      'erg_reserves': '1',
      'token_y': {'token_id': id, 'amount': '1'},
    };
    final meta = publicPoolTokenMeta([pool(_bare), pool(_unread), pool(_odd)]);
    expect(meta.keys, [_bare]);
    expect(meta[_bare]!.decimals, 0);
    publicTokenCatalog.debugReset();
  });
}
