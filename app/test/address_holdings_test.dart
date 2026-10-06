import 'package:argus_wallet/services/address_holdings.dart';
import 'package:argus_wallet/services/public_wallet_sync.dart';
import 'package:argus_wallet/services/wallet_database_service.dart';
import 'package:argus_wallet/services/wallet_sync_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'batch_a_sync_test.dart' show GatedGateway;
import 'batch_c_sync_test.dart' show MemoryPublic;
import 'wallet_sync_controller_test.dart' show FakeGateway;

// A4: a wallet pinned to one address still counts, and shows, what its
// other addresses hold.

AddressHolding h(String address, int nano, {int? index, List<(String, int)> tokens = const []}) =>
    AddressHolding(
      address: address,
      index: index,
      nanoErg: nano,
      tokens: [for (final (id, amount) in tokens) (id: id, amount: amount)],
    );

/// Discovery that fails outright, as a node error mid-scan does.
class FailingDiscovery extends FakeGateway {
  @override
  Future<String> discoverAddresses() async {
    discoverCalls++;
    throw Exception('node error during discovery');
  }
}

void main() {
  group('funds elsewhere', () {
    test('counts only funded addresses other than the identity', () {
      final funds = fundsElsewhere([
        h('pinned', 9314000000, tokens: [('a', 25)]),
        h('zero', 3200000000, index: 0, tokens: [('a', 150), ('b', 2), ('c', 1), ('d', 9)]),
        h('empty', 0, index: 1),
      ], identity: 'pinned');
      expect(funds!.nanoErg, 3200000000);
      expect(funds.addressCount, 1);
      expect(funds.tokenCount, 4, reason: 'distinct ids on the other addresses');
      expect(fundsElsewhereLine(funds), 'incl. 3.2 ERG · 4 tokens on 1 other address');
      expect(fundsElsewhereLine(funds, hidden: true), 'incl. funds on 1 other address');
    });

    test('says nothing when every other address is empty', () {
      expect(fundsElsewhere([h('pinned', 5), h('zero', 0)], identity: 'pinned'), isNull);
      expect(fundsElsewhere(const [], identity: 'pinned'), isNull);
    });

    test('words ERG-only, token-only and several addresses', () {
      expect(
        fundsElsewhereLine(fundsElsewhere([h('a', 1000000000), h('b', 500000000)], identity: 'x')!),
        'incl. 1.5 ERG on 2 other addresses',
      );
      expect(
        fundsElsewhereLine(fundsElsewhere([h('a', 0, tokens: [('t', 1)])], identity: 'x')!),
        'incl. 1 token on 1 other address',
      );
      // A token on two addresses is still one token.
      expect(
        fundsElsewhere([h('a', 0, tokens: [('t', 1)]), h('b', 0, tokens: [('t', 4)])], identity: 'x')!
            .tokenCount,
        1,
      );
    });

    test('wallet metadata supplies the indices discovery cannot', () {
      final filled = withWalletIndexes(
        [h('vanity', 1), h('zero', 1), h('other', 1), h('known', 1, index: 7)],
        address0: 'zero',
        pinnedAddress: 'vanity',
        pinnedIndex: 275,
      );
      expect([for (final x in filled) x.index], [275, 0, null, 7]);
    });

    test('recorded indices come from the frontier and from discovery', () {
      expect(recordedAddressIndex('b', frontier: ['a', 'b']), 1);
      expect(
        recordedAddressIndex('far', used: [
          {'address': 'far', 'index': 40},
        ]),
        40,
      );
      expect(recordedAddressIndex('unknown', frontier: ['a']), isNull);
    });

    test('holdings survive JSON, and junk degrades to no breakdown', () {
      final original = h('zero', 3200000000, index: 0, tokens: [('a', 150)]);
      final back = AddressHolding.fromJson(original.toJson())!;
      expect(back.address, 'zero');
      expect(back.index, 0);
      expect(back.nanoErg, 3200000000);
      expect(back.tokens.single, (id: 'a', amount: 150));
      expect(AddressHolding.listFrom([null, 'x', {'address': ''}, original.toJson()]).length, 1);
      expect(AddressHolding.listFrom('not a list'), isEmpty);
    });

  });

  group('unlocked wallet pinned away from index 0', () {
    late FakeGateway gw;
    late WalletSyncController c;

    setUp(() {
      gw = FakeGateway()
        ..pinnedIndex = 275
        ..maxIndex = 300
        ..balances['addr0'] = {
          'balance_nano_erg': 3200000000,
          'tokens': [
            {'id': 'a', 'amount': 150},
          ],
        }
        ..balances['addr1'] = {'balance_nano_erg': 0, 'tokens': []}
        ..balances['addr275'] = {'balance_nano_erg': 9314000000, 'tokens': []}
        ..discovered = [
          {'index': 0, 'address': 'addr0', 'balance_nano_erg': 3200000000},
        ]
        ..nextUnused = 1
        ..stealthEnabled = false;
      c = WalletSyncController(gw);
    });

    test('the total counts index 0 as well as the pinned address', () async {
      await c.hydrateAfterUnlock();
      await c.refresh(discover: true);
      expect(c.receiveAddress, 'addr275', reason: 'the pinned address stays the identity');
      expect(c.balanceNano, 3200000000 + 9314000000);
      final byAddress = {for (final x in c.addressHoldings) x.address: x};
      expect(byAddress['addr0']!.nanoErg, 3200000000);
      expect(byAddress['addr0']!.index, 0);
      expect(byAddress['addr275']!.nanoErg, 9314000000);
      expect(byAddress['addr1']!.holdsFunds, isFalse);
      // Persisted, so the wallet's overview row can say it once locked.
      final saved = AddressHolding.listFrom(gw.savedCache!['address_holdings']);
      expect(saved.map((x) => x.address), containsAll(['addr0', 'addr275']));
    });

    test('before or without discovery, index 0 is still counted', () async {
      // First unlock on this device, and discovery fails: only the pinned
      // address was known, so index 0 used to be left out of the total.
      final failing = FailingDiscovery()
        ..pinnedIndex = 275
        ..maxIndex = 300
        ..balances.addAll(gw.balances)
        ..stealthEnabled = false;
      final controller = WalletSyncController(failing);
      await controller.hydrateAfterUnlock();
      expect(controller.historyAddresses, containsAll(['addr0', 'addr275']));
      await controller.refresh(discover: true);
      expect(failing.discoverCalls, 1);
      expect(controller.balanceNano, 3200000000 + 9314000000);
    });

    test('a partial read keeps the previous split rather than misplace funds', () async {
      await c.hydrateAfterUnlock();
      await c.refresh(discover: true);
      final before = c.addressHoldings;
      gw.balances.remove('addr0');
      await c.refresh(discover: false);
      expect(c.addressHoldings, same(before));
    });
  });

  group('locked wallet snapshots', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('a pinned wallet without a snapshot is read at index 0 too', () async {
      final gw = MemoryPublic();
      final active = GatedGateway()..walletId = 'other';
      final c = WalletSyncController(active)..activateWallet('other');
      await PublicWalletSync(gw).tick(
        wallets: {'w2': 'vanity'},
        recordedAddresses: {
          'w2': ['zero', 'vanity'],
        },
        controller: c,
        activeId: active.walletId,
        unlocked: () => true,
      );
      expect(gw.calls.where((x) => x.startsWith('balance:')), ['balance:vanity', 'balance:zero']);
      expect(gw.data['w2']!['balance_nano_erg'], 14, reason: 'MemoryPublic answers 7 per address');
      final holdings = AddressHolding.listFrom(gw.data['w2']!['address_holdings']);
      expect(holdings.map((x) => x.address), ['vanity', 'zero']);
    });

    test('recorded indices travel with a public refresh', () async {
      final gw = MemoryPublic()
        ..data['w2'] = {
          'wallet_id': 'w2',
          'frontier_addresses': ['zero', 'one'],
          'used_addresses': [
            {'index': 0, 'address': 'zero'},
          ],
        };
      final active = GatedGateway()..walletId = 'other';
      final c = WalletSyncController(active)..activateWallet('other');
      await PublicWalletSync(gw).tick(
        wallets: {'w2': 'vanity'},
        controller: c,
        activeId: active.walletId,
        unlocked: () => true,
      );
      final byAddress = {
        for (final x in AddressHolding.listFrom(gw.data['w2']!['address_holdings'])) x.address: x,
      };
      expect(byAddress['zero']!.index, 0);
      expect(byAddress['one']!.index, 1);
      expect(byAddress['vanity']!.index, isNull, reason: 'the overview fills it from the wallet list');
    });

    test('the split is persisted and read back with the last known balance', () async {
      await WalletDatabaseService.saveCachedState(
        walletId: 'w9',
        primaryAddress: 'vanity',
        usedAddresses: const [],
        balanceNano: 12,
        tokens: const [],
        transactions: const [],
        utxoCount: 2,
        addressHoldings: [h('vanity', 9).toJson(), h('zero', 3, index: 0).toJson()],
      );
      final known = await WalletDatabaseService.lastKnownBalance('w9');
      expect(known!.addressHoldings.map((x) => (x.address, x.nanoErg)), [('vanity', 9), ('zero', 3)]);
    });

  });
}
