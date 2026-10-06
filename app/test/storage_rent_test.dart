import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/storage_rent.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64;
import 'package:flutter_test/flutter_test.dart';

/// What the Rust core answers; figures match `wallet_core::rent` tests (a
/// P2PK box with one NFT is 110 bytes, 0.1375 ERG at 1.25 mERG per byte).
class RentApi extends RustLibApi {
  int parameterReads = 0;
  bool failParameters = false;
  String? lastTokensJson;
  int? lastValue;
  bool failEstimate = false;

  @override
  Future<String> crateApiStorageRentRentParameters({String? nodeUrl}) async {
    parameterReads++;
    if (failParameters) throw 'node unreachable';
    return jsonEncode({
      'height': 1600000,
      'storage_fee_factor': 1250000,
      'factor_from_node': true,
      'storage_period': 1051200,
      'target_block_secs': 120,
    });
  }

  @override
  Future<String> crateApiStorageRentBoxRentReport({
    required List<String> addresses,
    String? nodeUrl,
  }) async => jsonEncode({
    'height': 1600000,
    'storage_fee_factor': 1250000,
    'factor_from_node': true,
    'unmeasured': 2,
    'boxes': [
      row('old', value: 1000000, blocksUntilDue: -5, charge: 'whole_box'),
      row('soon', value: 5000000000, blocksUntilDue: 21600, charge: 'fee'),
      row('later', value: 5000000000, blocksUntilDue: 21601, charge: 'fee'),
      row('huge', value: 1000000, blocksUntilDue: 3, charge: 'none'),
    ],
  });

  @override
  String crateApiStorageRentOutputRentEstimate({
    required String address,
    required PlatformInt64 valueNano,
    required String tokensJson,
    required int height,
    required int storageFeeFactor,
  }) {
    if (failEstimate) throw '{"code":"INVALID_ADDRESS"}';
    lastTokensJson = tokensJson;
    lastValue = valueNano;
    final covered = valueNano > 137500000;
    return jsonEncode({
      'value_nano_erg': valueNano,
      'due_height': height + 1051200,
      'suggested_nano_erg': 140000000,
      'boxes': [
        {
          'value_nano': valueNano,
          'token_count': 1,
          'size_bytes': valueNano >= 2097152 ? 111 : 110,
          'fee_nano': 137500000,
          'charge': covered ? 'fee' : 'whole_box',
          'charge_nano': covered ? 137500000 : valueNano,
          'due_height': height + 1051200,
          'blocks_until_due': 1051200,
          'collectable_now': false,
        },
      ],
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, Object> row(
  String id, {
  required int value,
  required int blocksUntilDue,
  required String charge,
}) => {
  'box_id': id,
  'value_nano_erg': value,
  'creation_height': 1600000 + blocksUntilDue - 1051200,
  'size_bytes': 110,
  'fee_nano': charge == 'none' ? -2104967296 : 137500000,
  'charge': charge,
  'charge_nano': switch (charge) {
    'fee' => 137500000,
    'whole_box' => value,
    _ => 0,
  },
  'due_height': 1600000 + blocksUntilDue,
  'blocks_until_due': blocksUntilDue,
  'collectable_now': blocksUntilDue <= 1,
};

void main() {
  late RentApi api;
  setUpAll(() {
    api = RentApi();
    RustLib.initMock(api: api);
  });
  tearDownAll(RustLib.dispose);
  setUp(() {
    api.parameterReads = 0;
    api.failParameters = false;
    api.failEstimate = false;
  });

  group('rent figures', () {
    test('the soon window is 30 days of 2-minute blocks', () {
      expect(rentSoonBlocks, 21600);
      expect(rentPeriodBlocks, 4 * 365 * 24 * 30);
    });

    test('report rows classify risk and urgency', () async {
      final report = await StorageRentService().report(['a'], nodeUrl: 'n');
      expect(report.parameters.height, 1600000);
      expect(report.parameters.factorFromNode, isTrue);
      final old = report.boxes['old']!;
      expect(old.atRisk, isTrue);
      expect(old.collectableNow, isTrue);
      expect(old.chargeNano, 1000000);
      expect(report.boxes['soon']!.dueSoon, isTrue);
      expect(report.boxes['soon']!.atRisk, isFalse);
      expect(report.boxes['later']!.dueSoon, isFalse);
      // A wrapped fee cannot be charged, so it is never urgent.
      expect(report.boxes['huge']!.charge, RentCharge.none);
      expect(report.boxes['huge']!.flagged, isFalse);
      expect(report.atRiskCount, 1);
      expect(report.dueSoonCount, 2);
      expect(report.unmeasured, 2);
    });

    test('rate and overflow follow the factor', () {
      const node = RentParameters(
        height: 1,
        storageFeeFactor: 1250000,
        factorFromNode: true,
      );
      expect(node.rateLabel, '0.00125 ERG per byte');
      expect(node.overflowBytes, 1717);
      const fallback = RentParameters.fallback(height: 1);
      expect(fallback.storageFeeFactor, fallbackStorageFeeFactor);
      expect(fallback.rateLabel, '0.00125 ERG per byte (default rate)');
    });

    test('due dates read as words', () {
      final now = DateTime(2026, 10, 6);
      expect(rentWhen(1, now: now), 'now');
      expect(rentWhen(-400, now: now), 'now');
      expect(rentWhen(300, now: now), 'within a day');
      expect(rentWhen(rentSoonBlocks, now: now), 'in ~30 days');
      // 1,051,200 blocks of 2 minutes: four 365-day years ahead.
      expect(rentWhen(rentPeriodBlocks, now: now), '~Oct 2030');
    });
  });

  group('service', () {
    test('parameters are cached briefly per node', () async {
      var now = DateTime(2026, 10, 6, 12);
      final service = StorageRentService(clock: () => now);
      await service.parameters(nodeUrl: 'a');
      await service.parameters(nodeUrl: 'a');
      expect(api.parameterReads, 1);
      await service.parameters(nodeUrl: 'b');
      expect(api.parameterReads, 2);
      now = now.add(StorageRentService.parametersTtl);
      await service.parameters(nodeUrl: 'b');
      expect(api.parameterReads, 3);
    });

    test(
      'an unreadable node falls back to the labelled launch factor',
      () async {
        api.failParameters = true;
        final service = StorageRentService();
        final p = await service.parametersOrFallback(knownHeight: 1700000);
        expect(p!.height, 1700000);
        expect(p.storageFeeFactor, 1250000);
        expect(p.factorFromNode, isFalse);
        expect(await service.parametersOrFallback(), isNull);
      },
    );

    test('an output estimate carries the tokens and the suggestion', () {
      const p = RentParameters(
        height: 1600000,
        storageFeeFactor: 1250000,
        factorFromNode: true,
      );
      final e = StorageRentService().estimateOutput(
        address: '9f',
        valueNano: 1000000,
        tokens: {'nft': 1},
        parameters: p,
      )!;
      expect(jsonDecode(api.lastTokensJson!), [
        {'token_id': 'nft', 'amount': 1},
      ]);
      expect(e.first.sizeBytes, 110);
      expect(e.first.feeNano, 137500000);
      expect(e.chargeable, isTrue);
      expect(e.covered, isFalse);
      expect(e.suggestedNano, 140000000);
      expect(e.belowSuggestion, isTrue);
      final enough = StorageRentService().estimateOutput(
        address: '9f',
        valueNano: 140000000,
        tokens: {'nft': 1},
        parameters: p,
      )!;
      expect(enough.covered, isTrue);
      expect(enough.belowSuggestion, isFalse);
      api.failEstimate = true;
      expect(
        StorageRentService().estimateOutput(
          address: 'bad',
          valueNano: 1,
          tokens: {'nft': 1},
          parameters: p,
        ),
        isNull,
      );
    });
  });
}
