import 'dart:convert';

import 'package:argus_wallet/services/stealth_identities.dart';
import 'package:argus_wallet/services/stealth_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _wallet = 'wallet-a';
const _other = 'wallet-b';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the identity list', () {
    test('a fresh wallet already has identity 0', () async {
      final list = await StealthIdentityStore.load(_wallet);
      expect(list.map((i) => i.index), [0]);
      expect(list.single.displayLabel, 'Main');
      expect(StealthIdentityStore.frontierOf(list), 1);
    });

    test('adding appends the next index and keeps the label', () async {
      final donations = await StealthIdentityStore.add(_wallet, 'Donations');
      final projectB = await StealthIdentityStore.add(_wallet, 'Project B');

      expect(donations.index, 1);
      expect(projectB.index, 2);

      final list = await StealthIdentityStore.load(_wallet);
      expect(list.map((i) => i.index), [0, 1, 2]);
      expect(list.map((i) => i.displayLabel), ['Main', 'Donations', 'Project B']);
      expect(StealthIdentityStore.frontierOf(list), 3);
      expect(donations.publishedAt, isNotNull);
    });

    test('labels are trimmed and an empty one still names the row', () async {
      await StealthIdentityStore.add(_wallet, '  Donations  ');
      await StealthIdentityStore.add(_wallet, '   ');
      final list = await StealthIdentityStore.load(_wallet);
      expect(list[1].label, 'Donations');
      expect(list[2].label, '');
      expect(list[2].displayLabel, 'Identity 2');
    });

    test('identities are per wallet', () async {
      await StealthIdentityStore.add(_wallet, 'Donations');
      expect((await StealthIdentityStore.load(_other)).map((i) => i.index), [0]);
      expect((await StealthIdentityStore.load(_wallet)).length, 2);
    });

    test('renaming leaves the index alone', () async {
      await StealthIdentityStore.add(_wallet, 'Donations');
      await StealthIdentityStore.rename(_wallet, 1, 'Tips');
      final list = await StealthIdentityStore.load(_wallet);
      expect(list[1].index, 1);
      expect(list[1].label, 'Tips');

      // An index nobody has is a no-op, not a new row.
      await StealthIdentityStore.rename(_wallet, 9, 'Ghost');
      expect((await StealthIdentityStore.load(_wallet)).length, 2);
    });

    /// Deleting is deliberately absent: an index that came back would hand
    /// out a string that may already be published under another label. This
    /// pins the append-only property.
    test('indices are never reused', () async {
      await StealthIdentityStore.add(_wallet, 'One');
      await StealthIdentityStore.add(_wallet, 'Two');
      final third = await StealthIdentityStore.add(_wallet, 'Three');
      expect(third.index, 3);
    });

    test('a corrupted list still yields the default identity', () async {
      SharedPreferences.setMockInitialValues({
        'argus_stealth_identities_v1_$_wallet': 'not json',
      });
      expect((await StealthIdentityStore.load(_wallet)).map((i) => i.index), [0]);
    });

    test('junk rows are dropped, valid ones survive', () async {
      SharedPreferences.setMockInitialValues({
        'argus_stealth_identities_v1_$_wallet': jsonEncode([
          {'index': 1, 'label': 'Good'},
          {'index': -1, 'label': 'Negative'},
          {'index': 9999, 'label': 'Too high'},
          {'label': 'No index'},
          'not a map',
        ]),
      });
      final list = await StealthIdentityStore.load(_wallet);
      expect(list.map((i) => i.index), [0, 1]);
      expect(list[1].label, 'Good');
    });

    test('the maximum is enforced before the FFI sees it', () async {
      SharedPreferences.setMockInitialValues({
        'argus_stealth_identities_v1_$_wallet': jsonEncode([
          {'index': maxStealthIdentity, 'label': 'Last'},
        ]),
      });
      await expectLater(
        StealthIdentityStore.add(_wallet, 'One too many'),
        throwsStateError,
      );
    });
  });

  group('restore discovery', () {
    test('adopts funded indices and leaves existing labels alone', () async {
      await StealthIdentityStore.add(_wallet, 'Donations'); // index 1

      final merged = await StealthIdentityStore.merge(_wallet, [1, 4, 4, 2]);
      expect(merged.map((i) => i.index), [0, 1, 2, 4]);
      // The label we still have is not overwritten by a discovered blank.
      expect(merged[1].label, 'Donations');
      // A discovered identity has no label; the index is what spends it.
      expect(merged[2].label, '');
      expect(StealthIdentityStore.frontierOf(merged), 5);
    });

    test('finding nothing new writes nothing', () async {
      await StealthIdentityStore.add(_wallet, 'Donations');
      final merged = await StealthIdentityStore.merge(_wallet, [0, 1]);
      expect(merged.map((i) => i.index), [0, 1]);
      expect(merged[1].label, 'Donations');
    });

    test('out-of-range indices are ignored', () async {
      final merged =
          await StealthIdentityStore.merge(_wallet, [-3, maxStealthIdentity + 1]);
      expect(merged.map((i) => i.index), [0]);
    });
  });

  group('per-identity balances', () {
    StealthScanResult parse(Map<String, dynamic> json) =>
        StealthScanResult.fromJson(json);

    test('a scan splits its totals by identity', () {
      final scan = parse({
        'scanned': 9,
        'owned_count': 3,
        'total_nano_erg': 4500000,
        'tokens': [],
        'boxes': [
          {'box_id': 'a', 'value_nano_erg': 1000000, 'identity': 0},
          {'box_id': 'b', 'value_nano_erg': 3000000, 'identity': 2},
          {'box_id': 'c', 'value_nano_erg': 500000, 'identity': 2},
        ],
        'identities': [
          {'index': 0, 'owned_count': 1, 'total_nano_erg': 1000000, 'tokens': []},
          {'index': 1, 'owned_count': 0, 'total_nano_erg': 0, 'tokens': []},
          {'index': 2, 'owned_count': 2, 'total_nano_erg': 3500000, 'tokens': []},
        ],
      });

      expect(scan.totalNanoErg, 4500000);
      expect(scan.boxes.map((b) => b.identity), [0, 2, 2]);
      expect(scan.balanceOf(0).totalNanoErg, 1000000);
      expect(scan.balanceOf(1).ownedCount, 0);
      expect(scan.balanceOf(2).totalNanoErg, 3500000);
      expect(scan.balanceOf(2).ownedCount, 2);
      // An identity the scan never covered reads as empty, not as the total.
      expect(scan.balanceOf(7).totalNanoErg, 0);
    });

    /// A result with no per-identity rows came from a single-identity scan,
    /// so its wallet-wide total is identity 0's. Reading it as zero would
    /// hide real funds and remove the sweep button.
    test('a result without identity rows credits identity 0', () {
      const scan = StealthScanResult(
        scanned: 20,
        ownedCount: 2,
        totalNanoErg: 1500000000,
        tokens: [],
        boxIds: ['b1', 'b2'],
      );
      expect(scan.balanceOf(0).totalNanoErg, 1500000000);
      expect(scan.balanceOf(0).ownedCount, 2);
      expect(scan.balanceOf(1).totalNanoErg, 0);
    });

    test('boxes default to identity 0 when the field is absent', () {
      final scan = parse({
        'owned_count': 1,
        'boxes': [
          {'box_id': 'a', 'value_nano_erg': 1000000},
        ],
      });
      expect(scan.boxes.single.identity, 0);
    });
  });
}
