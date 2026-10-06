import 'package:argus_wallet/services/pending_balance.dart';
import 'package:argus_wallet/ui/widgets/pending_balance_line.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const erg = 1000000000;

/// What the Rust core returns for a wallet that sent 0.3 ERG from a 1 ERG
/// box: the box leaves, 0.6989 ERG of change arrives.
Map<String, dynamic> sentSummary() => {
  'confirmed_nano_erg': erg + 50000000,
  'pending_in_nano_erg': 698900000,
  'pending_out_nano_erg': erg,
  'balance_nano_erg': 748900000,
  'pending_transactions': 1,
  'tokens': [
    {
      'id': 'tok',
      'confirmed': 10,
      'pending_in': 4,
      'pending_out': 10,
      'amount': 4,
    },
  ],
};

void main() {
  group('PendingBalance', () {
    test('reads the core summary and splits the balance', () {
      final p = PendingBalance.fromJson(sentSummary())!;
      expect(p.confirmedNano, erg + 50000000);
      expect(p.netNano, 748900000);
      expect(p.pendingDeltaNano, 698900000 - erg);
      expect(p.hasPending, isTrue);
      expect(p.token('tok')!.amount, 4);
      expect(p.toJson(), sentSummary());
    });

    test('anything but a summary reads as none', () {
      expect(PendingBalance.fromJson(null), isNull);
      expect(PendingBalance.fromJson('x'), isNull);
      expect(PendingBalance.fromJson({'balance_nano_erg': 1}), isNull);
    });

    test(
      'what can be spent now depends on the setting, never on spent boxes',
      () {
        final p = PendingBalance.fromJson(sentSummary())!;
        // The spent 1 ERG box is out under both settings; the change counts
        // only while unconfirmed funds may be spent.
        expect(p.spendableNano(allowUnconfirmed: true), 748900000);
        expect(p.spendableNano(allowUnconfirmed: false), 50000000);
        expect(p.confirmingNano, 698900000);
        expect(
          p.spendableNano(allowUnconfirmed: false) + p.confirmingNano,
          p.spendableNano(allowUnconfirmed: true),
        );
      },
    );

    test('unseen broadcasts move the split the way they moved the balance', () {
      const node = PendingBalance(confirmedNano: 5 * erg);
      final sent = node.withUnseenBroadcasts(-2 * erg, 1);
      expect(sent.netNano, 3 * erg);
      expect(sent.pendingOutNano, 2 * erg);
      expect(sent.transactions, 1);
      final received = node.withUnseenBroadcasts(erg, 1);
      expect(received.pendingInNano, erg);
      expect(identical(node.withUnseenBroadcasts(0, 0), node), isTrue);
    });

    test('accounts add address by address', () {
      final a = PendingBalance.fromJson(sentSummary())!;
      const b = PendingBalance(
        confirmedNano: erg,
        pendingInNano: 5,
        transactions: 1,
        tokens: [
          PendingTokenFlow(
            id: 'tok',
            confirmed: 1,
            pendingIn: 0,
            pendingOut: 0,
          ),
        ],
      );
      final sum = a.plus(b);
      expect(sum.confirmedNano, 2 * erg + 50000000);
      expect(sum.pendingInNano, 698900005);
      expect(sum.pendingOutNano, erg);
      expect(sum.transactions, 2);
      expect(sum.token('tok')!.confirmed, 11);
      expect(sum.netNano, a.netNano + b.netNano);
    });
  });

  group('pendingBalanceText', () {
    test('an outgoing send shows what leaves and what is confirmed', () {
      expect(
        pendingBalanceText(PendingBalance.fromJson(sentSummary())),
        '−0.3011 ERG pending · 1.05 confirmed',
      );
    });

    test('an incoming payment, alone or leading with the balance', () {
      const p = PendingBalance(
        confirmedNano: 105210000000,
        pendingInNano: 2500000000,
        transactions: 1,
      );
      expect(pendingBalanceText(p), '+2.5 ERG pending · 105.21 confirmed');
      expect(
        pendingBalanceText(p, withTotal: true),
        '107.71 ERG · +2.5 pending',
      );
    });

    test('nothing pending, nothing known, or hidden amounts', () {
      expect(pendingBalanceText(null), isNull);
      expect(
        pendingBalanceText(const PendingBalance(confirmedNano: erg)),
        isNull,
      );
      const p = PendingBalance(
        confirmedNano: erg,
        pendingInNano: 1,
        transactions: 1,
      );
      expect(pendingBalanceText(p, hidden: true), '•••• ERG pending');
      // A broadcast whose value is unknown still says something is pending.
      const unknown = PendingBalance(confirmedNano: erg, transactions: 1);
      expect(pendingBalanceText(unknown), 'Pending · 1 confirmed');
    });
  });

  testWidgets('the line shows only while something is pending', (tester) async {
    Future<void> pump(PendingBalance? p) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PendingBalanceLine(pending: p)),
      ),
    );
    await pump(const PendingBalance(confirmedNano: erg));
    expect(find.byType(Text), findsNothing);
    await pump(
      const PendingBalance(
        confirmedNano: erg,
        pendingInNano: erg ~/ 2,
        transactions: 1,
      ),
    );
    expect(find.text('+0.5 ERG pending · 1 confirmed'), findsOneWidget);
  });
}
