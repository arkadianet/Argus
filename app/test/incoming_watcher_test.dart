import 'package:argus_wallet/services/incoming_payment_watcher.dart';
import 'package:argus_wallet/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  _stealthNotificationTests();
  final a = {'tx_id': 'a', 'value_nano_erg': 1000000000, 'height': 0};
  final b = {'tx_id': 'b', 'value_nano_erg': -500, 'height': 0};
  final c = {'tx_id': 'c', 'value_nano_erg': 2000000000, 'height': 10};

  test('the first observation only primes the watcher', () {
    final w = IncomingPaymentWatcher();
    expect(w.observe([a, b]), isEmpty);
    expect(w.observe([a, b]), isEmpty);
  });

  test('a new incoming transaction is reported once', () {
    final w = IncomingPaymentWatcher()..observe([b]);
    final fresh = w.observe([a, b]);
    expect(fresh.map((t) => t['tx_id']), ['a']);
    expect(w.observe([a, b]), isEmpty);
  });

  test('outgoing transactions and reset are not reported', () {
    final w = IncomingPaymentWatcher()..observe([a]);
    expect(w.observe([a, b]), isEmpty);
    w.reset();
    expect(w.observe([a, b, c]), isEmpty);
  });

  test('confirmation of an already-seen pending tx is not a new payment', () {
    final w = IncomingPaymentWatcher()..observe([a]);
    expect(w.observe([{...a, 'height': 12}]), isEmpty);
  });
}

// Stealth receipts must be announced too (they are not in address history)
void _stealthNotificationTests() {
  Map<String, dynamic> row(String id, int nano, {bool stealth = false, int height = 100}) => {
        'tx_id': id,
        'value_nano_erg': nano,
        'height': height,
        if (stealth) 'stealth': true,
      };

  test('a stealth receipt appearing after priming is announced', () {
    final w = IncomingPaymentWatcher();
    w.observe([row('old', 1000)]);
    final fresh = w.observe([row('old', 1000), row('s1', 1000000000, stealth: true)]);
    expect(fresh.single['tx_id'], 's1');
    expect(fresh.single['stealth'], isTrue);
  });

  test('it is announced once, not on every poll', () {
    final w = IncomingPaymentWatcher();
    w.observe([row('old', 1)]);
    final list = [row('old', 1), row('s1', 5, stealth: true)];
    expect(w.observe(list), hasLength(1));
    expect(w.observe(list), isEmpty);
  });

  test('a stealth receipt is titled as such and never as pending', () {
    expect(incomingTitle(pending: false, stealth: true), 'Stealth payment received');
    // Detection reads the unspent set, so height 0 cannot mean "in flight".
    expect(incomingTitle(pending: true, stealth: true), 'Stealth payment received');
    expect(incomingTitle(pending: true, stealth: false), 'Payment on the way');
    expect(incomingTitle(pending: false, stealth: false), 'Payment received');
  });
}
