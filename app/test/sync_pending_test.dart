import 'package:argus_wallet/services/pending_balance.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/wallet_sync_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'batch_a_sync_test.dart' show GatedGateway;

const erg = 1000000000;

/// A read that values the mempool across the wallet, as the live one does.
class _PendingRead implements WalletSyncRead, WalletSyncPendingRead {
  _PendingRead(this.gw, this.addresses);
  final PendingGateway gw;
  final List<String> addresses;
  @override
  Future<Map<String, dynamic>> balance(String address) =>
      gw.getBalance(address);
  @override
  Future<HistoryResult> history() => gw.loadHistory(addresses);
  @override
  Future<int> count() => gw.countUnspentBoxes(addresses);
  @override
  Future<String?> servedBy() async => gw.servedByUrl;
  @override
  Future<PendingBalance?> pending() async => gw.summary;
  @override
  Future<Set<String>> pendingIds() async => gw.listed;
}

class PendingGateway extends GatedGateway {
  PendingBalance? summary;
  Set<String> listed = {};
  @override
  WalletSyncRead startRead(List<String> addresses) =>
      _PendingRead(this, addresses);
}

/// A wallet whose first address paid its second (pending), and the second
/// paid most of it back (pending too). Address by address, the box in the
/// middle counts as arriving at the second address while the first address
/// already counts what came back: 4 + 1 ERG. Valued once, it is 4.
PendingBalance chained() => const PendingBalance(
  confirmedNano: 5 * erg,
  pendingOutNano: 5 * erg,
  pendingInNano: 4 * erg,
  transactions: 2,
  tokens: [
    PendingTokenFlow(id: 'tok', confirmed: 3, pendingIn: 3, pendingOut: 3),
  ],
);

void main() {
  late PendingGateway gw;
  late WalletSyncController c;

  setUp(() async {
    gw = PendingGateway();
    c = WalletSyncController(gw);
    gw.discovered = [
      {'address': 'addr0', 'balance_nano_erg': 4 * erg},
    ];
    gw.nextUnused = 1;
    gw.balances = {
      'addr0': {
        'balance_nano_erg': 4 * erg,
        'tokens': [
          {'id': 'tok', 'amount': 3},
        ],
      },
      'addr1': {
        'balance_nano_erg': erg,
        'tokens': [
          {'id': 'tok', 'amount': 2},
        ],
      },
    };
    gw.summary = chained();
    await c.hydrateAfterUnlock();
    await c.refresh(discover: true);
  });

  test(
    'the wallet-wide valuation sets the balance, not the per-address sum',
    () {
      expect(c.historyAddresses, containsAll(['addr0', 'addr1']));
      expect(c.balanceNano, 4 * erg);
      expect(c.pending!.confirmedNano, 5 * erg);
      expect(c.pending!.netNano, c.balanceNano);
      expect(c.tokens.single.amount, 3);
      expect(pendingBalanceText(c.pending), '−1 ERG pending · 5 confirmed');
    },
  );

  test('without a valuation there is no split, and the sum stands', () async {
    gw.summary = null;
    await c.refresh(discover: false);
    expect(c.pending, isNull);
    expect(c.balanceNano, 5 * erg);
    expect(c.tokens.single.amount, 5);
  });

  test('an own broadcast folds into the split until the node lists it', () {
    c.noteBroadcast('sent', valueNano: -2 * erg);
    expect(c.balanceNano, 2 * erg);
    expect(c.pending!.netNano, c.balanceNano);
    expect(c.pending!.pendingOutNano, 7 * erg);
    expect(c.pending!.confirmedNano, 5 * erg);
    expect(c.pending!.transactions, 3);
  });

  test('a broadcast the node already lists is not counted twice', () async {
    // The node's next answer includes the send: its figures moved by it.
    gw.summary = const PendingBalance(
      confirmedNano: 5 * erg,
      pendingOutNano: 5 * erg,
      pendingInNano: 2 * erg,
      transactions: 3,
    );
    gw.listed = {'sent'};
    c.noteBroadcast('sent', valueNano: -2 * erg);
    await c.refresh(discover: false, quiet: true);
    expect(c.balanceNano, 2 * erg);
    expect(c.pending!.netNano, 2 * erg);
    expect(c.pending!.transactions, 3);
  });

  test(
    'the split is saved with the snapshot and comes back on unlock',
    () async {
      final saved = gw.savedCache!;
      expect(saved['pending'], chained().toJson());
      expect(saved['balance_nano_erg'], 4 * erg);

      final again = PendingGateway()..cached = saved;
      final restored = WalletSyncController(again);
      await restored.hydrateAfterUnlock();
      expect(restored.pending!.toJson(), chained().toJson());
      expect(restored.balanceNano, 4 * erg);
    },
  );

  test('switching away and back keeps the split', () {
    c.deactivate();
    expect(c.pending, isNull);
    c.activateWallet('w1');
    expect(c.pending!.toJson(), chained().toJson());
  });

  test('a locked wallet shows the split its public refresh found', () {
    final generation = c.publicGeneration;
    final remembered = c.rememberPublic('w2', {
      'wallet_id': 'w2',
      'balance_nano_erg': 7 * erg,
      'pending': const PendingBalance(
        confirmedNano: 6 * erg,
        pendingInNano: erg,
        transactions: 1,
      ).toJson(),
      'transactions': [],
      'tokens': [],
    }, generation);
    expect(remembered, isTrue);
    gw.walletId = 'w2';
    c.activateWallet('w2');
    expect(c.publicSnapshotOnly, isTrue);
    expect(pendingBalanceText(c.pending), '+1 ERG pending · 6 confirmed');
  });
}
