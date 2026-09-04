import 'package:argus_wallet/services/pockets.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:flutter_test/flutter_test.dart';

InputBoxInput box(String id, int nano) => InputBoxInput(
      boxId: id,
      valueNanoErg: BigInt.from(nano),
      creationHeight: 1,
      assets: const [],
    );

void main() {
  _sendPocketTests();
  group('walletPockets', () {
    test('public alone does not read as a split', () {
      final p = walletPockets(publicNano: 1012000000, stealthNano: 0, stealthUnknown: false);
      expect(p.map((e) => e.pocket), [Pocket.public]);
      expect(pocketBreakdown(p), isNull, reason: 'nothing to break down');
    });

    test('stealth funds produce a breakdown that adds up to the total', () {
      final p = walletPockets(publicNano: 1012000000, stealthNano: 1000000000, stealthUnknown: false);
      expect(p.fold<int>(0, (s, e) => s + e.nanoErg), 2012000000);
      expect(pocketBreakdown(p), '1.012 public · 1 stealth');
    });

    test('an unknown stealth balance is shown as unknown, never as zero', () {
      final p = walletPockets(publicNano: 1, stealthNano: 0, stealthUnknown: true);
      expect(p.last.unknown, isTrue);
      expect(pocketBreakdown(p), contains('stealth unknown'));
    });

    test('hidden balances mask the amounts but keep the pocket names', () {
      final p = walletPockets(publicNano: 1012000000, stealthNano: 1000000000, stealthUnknown: false);
      expect(pocketBreakdown(p, hidden: true), '•••• public · •••• stealth');
    });

    test('in-mix money is reported but not spendable', () {
      final p = walletPockets(publicNano: 0, stealthNano: 0, stealthUnknown: false, inMixNano: 5);
      expect(p.any((e) => e.pocket == Pocket.inMix), isTrue);
      expect(Pocket.inMix.spendable, isFalse);
      expect(Pocket.stealth.spendable, isTrue);
    });
  });

  group('spending', () {
    final pub = [box('a', 1000000000)];
    final ste = [box('s1', 1000000000)];

    test('each choice offers exactly its own boxes', () {
      expect(eligibleBoxes(from: SpendFrom.public, publicBoxes: pub, stealthBoxes: ste).single.boxId, 'a');
      expect(eligibleBoxes(from: SpendFrom.stealth, publicBoxes: pub, stealthBoxes: ste).single.boxId, 's1');
      expect(eligibleBoxes(from: SpendFrom.both, publicBoxes: pub, stealthBoxes: ste), hasLength(2));
    });

    test('only mixing pockets warns, because only that links them', () {
      expect(spendFromWarning(SpendFrom.public), isNull);
      // A stealth-only send returns its change to a fresh stealth address
      // of the sender's own, so nothing points back at this wallet.
      expect(spendFromWarning(SpendFrom.stealth), isNull);
      expect(spendFromWarning(SpendFrom.both), contains('links them'));
    });

    test('available reflects the chosen pocket', () {
      expect(availableNano(from: SpendFrom.public, publicNano: 1012000000, stealthNano: 1000000000), 1012000000);
      expect(availableNano(from: SpendFrom.stealth, publicNano: 1012000000, stealthNano: 1000000000), 1000000000);
      expect(availableNano(from: SpendFrom.both, publicNano: 1012000000, stealthNano: 1000000000), 2012000000);
    });

    test('an unknown public balance stays unknown unless spending stealth alone', () {
      expect(availableNano(from: SpendFrom.public, publicNano: null, stealthNano: 5), isNull);
      expect(availableNano(from: SpendFrom.stealth, publicNano: null, stealthNano: 5), 5);
    });

    test('an unknown stealth balance is never added as a number', () {
      // The last figure may predate a spend, so any total including it
      // would be a guess presented as a fact.
      expect(
        availableNano(from: SpendFrom.stealth, publicNano: 10, stealthNano: 7, stealthUnknown: true),
        isNull,
      );
      expect(
        availableNano(from: SpendFrom.both, publicNano: 10, stealthNano: 7, stealthUnknown: true),
        isNull,
      );
      // A public send is unaffected: it never touches those coins.
      expect(
        availableNano(from: SpendFrom.public, publicNano: 10, stealthNano: 7, stealthUnknown: true),
        10,
      );
    });
  });
}

// Send behaviour driven by the pocket choice
void _sendPocketTests() {
  test('a stealth-only send names its boxes, so nothing else can be pulled in', () {
    // The rule the Rust side enforces: an explicit id list is spent exactly,
    // never topped up. Public sends stay on automatic selection.
    expect(SpendFrom.stealth.usesPublic, isFalse);
    expect(SpendFrom.stealth.usesStealth, isTrue);
    expect(SpendFrom.public.usesStealth, isFalse,
        reason: 'stealth coins are never spent unless asked for');
    expect(SpendFrom.both.usesPublic && SpendFrom.both.usesStealth, isTrue);
  });

  test('the default pocket cannot link stealth coins by accident', () {
    // Public is the default in the send screen; assert the property that
    // makes that safe rather than the widget's initial value.
    expect(spendFromWarning(SpendFrom.public), isNull);
    expect(SpendFrom.values.first, SpendFrom.public);
  });
}
