import 'package:argus_wallet/services/pending_balance.dart';
import 'package:argus_wallet/services/public_wallet_sync.dart';
import 'package:argus_wallet/services/wallet_sync_controller.dart';
import 'package:argus_wallet/services/watch_account_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'batch_a_sync_test.dart' show GatedGateway;
import 'batch_c_sync_test.dart' show MemoryPublic;

const erg = 1000000000;

/// A public gateway that values the mempool across the wallet, as the live
/// one does, on top of the per-address stand-in.
class ValuingPublic extends MemoryPublic {
  @override
  Future<Map<String, dynamic>> inputs(List<String> addresses) async {
    final read = await super.inputs(addresses);
    return {
      ...read,
      'pending': [
        {
          'tx_id': 'in-flight',
          'height': 0,
          'value_nano_erg': erg,
          'confirmed': false,
        },
        // Confirmed since: the confirmed row wins.
        {'tx_id': 'tx7', 'height': 0, 'value_nano_erg': 1, 'confirmed': false},
      ],
      'summary': const PendingBalance(
        confirmedNano: 20,
        pendingInNano: erg,
        pendingOutNano: 6,
        transactions: 1,
        tokens: [
          PendingTokenFlow(
            id: 'shared',
            confirmed: 8,
            pendingIn: 0,
            pendingOut: 8,
          ),
        ],
      ).toJson(),
    };
  }
}

void main() {
  test('a locked wallet\'s refresh keeps its pending rows and split', () async {
    final gw = ValuingPublic();
    final active = GatedGateway();
    final c = WalletSyncController(active)..activateWallet('w1');
    await PublicWalletSync(gw).tick(
      wallets: {'w2': 'b'},
      controller: c,
      activeId: 'w1',
      unlocked: () => true,
      now: DateTime(2026, 10, 6),
    );
    final saved = gw.data['w2']!;
    // The valuation across the wallet wins over the per-address sum.
    expect(saved['balance_nano_erg'], 20 - 6 + erg);
    expect(PendingBalance.fromJson(saved['pending'])!.confirmedNano, 20);
    expect(saved['tokens'], isEmpty, reason: 'all of it is leaving');
    final rows = (saved['transactions'] as List).map((t) => t['tx_id']);
    expect(rows, ['in-flight', 'tx7', 'tx6', 'tx5', 'tx4']);
    expect((saved['transactions'] as List)[1]['height'], isNot(0));
    expect(gw.peak, 1);
  });

  test('a watched account adds its addresses\' splits', () async {
    // The first address has a pending payment; the rest are empty, and
    // answer with or without a split.
    Future<WatchAccountSnapshot> scan({required bool everywhere}) =>
        scanWatchAccount(
          gap: 2,
          derive: (start, count) async => [
            for (var i = start; i < start + count; i++) 'a$i',
          ],
          history: (address) async => address == 'a0'
              ? [
                  {'tx_id': 'x'},
                ]
              : [],
          balance: (address) async => address == 'a0'
              ? {
                  'balance_nano_erg': erg + 5,
                  'tokens': [],
                  'summary': const PendingBalance(
                    confirmedNano: erg,
                    pendingInNano: 5,
                    transactions: 1,
                  ).toJson(),
                }
              : {
                  'balance_nano_erg': 0,
                  'tokens': [],
                  if (everywhere)
                    'summary': const PendingBalance(confirmedNano: 0).toJson(),
                },
        );
    final all = await scan(everywhere: true);
    expect(all.addresses.length, greaterThan(1));
    expect(all.pending!.confirmedNano, erg);
    expect(all.pending!.pendingInNano, 5);
    expect(all.pending!.netNano, all.balance);
    final partial = await scan(everywhere: false);
    expect(
      partial.pending,
      isNull,
      reason: 'a partial sum would understate it',
    );
  });
}
