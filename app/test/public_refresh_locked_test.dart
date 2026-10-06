import 'dart:async';

import 'package:argus_wallet/services/public_wallet_sync.dart';
import 'package:argus_wallet/services/wallet_sync_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'batch_a_sync_test.dart' show GatedGateway;
import 'batch_c_sync_test.dart' show MemoryPublic;

// The launch overview shows every wallet's balance before anything is
// unlocked, so the public refresh may run with every wallet locked.

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final at = DateTime(2026, 10, 6);

  test('with every wallet locked it runs only when asked to', () async {
    final gw = MemoryPublic();
    final locked = GatedGateway()..unlocked = false;
    final c = WalletSyncController(locked);
    final sync = PublicWalletSync(gw);
    Future<void> tick({required bool whileLocked}) => sync.tick(
          wallets: {'w1': 'a', 'w2': 'b'},
          controller: c,
          activeId: null,
          unlocked: () => locked.unlocked,
          whileLocked: whileLocked,
          now: at,
        );
    await tick(whileLocked: false);
    expect(gw.calls, isEmpty, reason: 'other callers keep the unlocked-session rule');
    await tick(whileLocked: true);
    expect(gw.calls, ['balance:a', 'history:a', 'balance:b', 'history:b']);
    expect(gw.data.keys, ['w1', 'w2']);
    // Persisted for the overview, but not remembered in a locked session.
    locked.walletId = 'w1';
    c.activateWallet('w1');
    expect(c.publicSnapshotOnly, isFalse);
  });

  test('an unlock part way revokes the pass, and the next check reruns it', () async {
    final gw = MemoryPublic()..gate = Completer<void>();
    final active = GatedGateway()..unlocked = false;
    final c = WalletSyncController(active);
    final sync = PublicWalletSync(gw);
    final pass = sync.tick(
      wallets: {'w1': 'a', 'w2': 'b'},
      controller: c,
      activeId: null,
      unlocked: () => active.unlocked,
      whileLocked: true,
      now: at,
    );
    await Future<void>.delayed(Duration.zero);
    expect(sync.isDue(at.add(const Duration(seconds: 1))), isFalse, reason: 'single flight');
    // The user opens w1 while its public read is in flight.
    active
      ..unlocked = true
      ..walletId = 'w1';
    c.activateWallet('w1');
    gw.gate!.complete();
    await pass;
    expect(gw.data, isEmpty, reason: 'a revoked pass writes nothing');
    expect(
      sync.isDue(at.add(const Duration(seconds: 5))),
      isTrue,
      reason: 'revoked, not failed: no five-minute wait for the other wallet',
    );
    gw.gate = null;
    await sync.tick(
      wallets: {'w1': 'a', 'w2': 'b'},
      controller: c,
      activeId: 'w1',
      unlocked: () => active.unlocked,
      whileLocked: true,
      now: at.add(const Duration(seconds: 5)),
    );
    expect(gw.data.keys, ['w2'], reason: 'the open wallet syncs itself');
  });

  test('failures still wait out the floor', () async {
    final gw = MemoryPublic()..fail = true;
    final active = GatedGateway()..unlocked = false;
    final sync = PublicWalletSync(gw);
    await sync.tick(
      wallets: {'w1': 'a'},
      controller: WalletSyncController(active),
      activeId: null,
      unlocked: () => active.unlocked,
      whileLocked: true,
      now: at,
    );
    expect(gw.calls, ['balance:a']);
    expect(sync.isDue(at.add(const Duration(minutes: 4))), isFalse);
    expect(sync.isDue(at.add(const Duration(minutes: 5))), isTrue);
  });
}
