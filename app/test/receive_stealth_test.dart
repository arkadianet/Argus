import 'package:argus_wallet/services/privacy_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:argus_wallet/services/stealth_identities.dart';
import 'package:argus_wallet/services/stealth_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/ui/receive_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _stealth =
    'stealth2Zc5nJHNTZmnKSyfnCsQrkVW42s9dhoNUmm5bxLrDBnwuGSaSQ';
const _stealthB =
    'stealth7pKv2xPsEjeNd2v68sbKxjxP2p63A8MwcrXhh6LAq945wfPo5Z';
const _receive = '9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8';

Widget _wrap() => MaterialApp(
      home: WalletArgsScope(
        args: const WalletRouteArgs(
          senderAddress: _receive,
          receiveAddress: _receive,
          changeAddress: _receive,
          historyAddresses: [_receive],
        ),
        child: const ReceiveScreen(),
      ),
    );

/// Scrolls the Receive list until [finder] is on screen.
Future<void> _scrollTo(WidgetTester tester, Finder finder) =>
    tester.scrollUntilVisible(finder, 300,
        scrollable: find.byType(Scrollable).first);

/// Opens the stealth identity picker and chooses the entry labelled [label].
///
/// `scrollUntilVisible` stops as soon as the widget enters the viewport, which
/// can leave its centre past the bottom edge and make a tap miss, so the
/// picker is centred with `ensureVisible` first.
Future<void> _pickIdentity(WidgetTester tester, String label) async {
  final picker = find.byKey(const Key('stealth-identity-picker'));
  await _scrollTo(tester, picker);
  await tester.ensureVisible(picker);
  await tester.pumpAndSettle();
  await tester.tap(picker);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    stealthService.reset();
    stealthService.scanEnabled = true;
  });

  tearDown(() => stealthService.reset());

  testWidgets('Receive explains reuse and fresh-address settings accurately', (tester) async {
    SharedPreferences.setMockInitialValues({'argus_privacy_unused_change': false});
    await privacyService.load();
    await tester.pumpWidget(_wrap());
    await tester.pump();
    expect(find.text('RECEIVE ADDRESS'), findsOneWidget);
    expect(find.textContaining('This address stays the same'), findsOneWidget);
    SharedPreferences.setMockInitialValues({'argus_privacy_unused_change': true});
    await privacyService.load();
    await tester.pump();
    expect(find.text('UNUSED ADDRESS'), findsOneWidget);
    expect(find.text('A new address is shown after this one is used.'), findsOneWidget);
    SharedPreferences.setMockInitialValues({'argus_privacy_unused_change': false});
    await privacyService.load();
  });

  test('a receive request carries the amount, and says why one is rejected', () {
    expect(receiveRequest(address: _receive, amount: '').payload, _receive);
    expect(receiveRequest(address: _receive, amount: '1.25').payload, 'ergo:$_receive?amount=1.25');
    expect(receiveRequest(address: _receive, amount: ' 1.25 ').payload, 'ergo:$_receive?amount=1.25');
    final bad = receiveRequest(address: _receive, amount: 'abc');
    expect(bad.payload, _receive, reason: 'an unusable amount must not be shared as a request');
    expect(bad.error, contains('decimal number'));
    expect(receiveRequest(address: _receive, amount: '0').error, contains('greater than zero'));
    expect(receiveRequest(address: _receive, amount: '-1').error, contains('decimal number'));
  });

  testWidgets('Share is refused while the amount is invalid', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pump();
    await _scrollTo(tester, find.byKey(const Key('receive-amount')));
    await tester.enterText(find.byKey(const Key('receive-amount')), '-1');
    await tester.pump();
    await _scrollTo(tester, find.text('Share'));
    final button = tester.widget<OutlinedButton>(find.ancestor(
      of: find.text('Share'), matching: find.byType(OutlinedButton)));
    expect(button.onPressed, isNull);
  });

  testWidgets('no stealth section until the address is known', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pump();
    expect(find.text('STEALTH ADDRESS'), findsNothing);
  });

  testWidgets('shows the string, a QR, copy and the explainer', (tester) async {
    stealthService.address = _stealth;
    await tester.pumpWidget(_wrap());
    await tester.pump();

    await _scrollTo(tester, find.byKey(const Key('stealth-address-text')));
    expect(find.text('STEALTH ADDRESS'), findsOneWidget);
    expect(find.text(_stealth), findsOneWidget);
    expect(find.byKey(const Key('stealth-qr')), findsOneWidget);
    expect(find.byKey(const Key('stealth-copy')), findsOneWidget);
    expect(
      find.textContaining('nothing on chain links two payments'),
      findsOneWidget,
    );
    expect(find.textContaining('needs the explorer'), findsOneWidget);
  });

  testWidgets('an unscanned wallet says the balance is unknown',
      (tester) async {
    stealthService.address = _stealth;
    await tester.pumpWidget(_wrap());
    await tester.pump();

    await _scrollTo(tester, find.byKey(const Key('stealth-copy')));
    expect(find.textContaining('Stealth balance unknown'), findsOneWidget);
    expect(find.byKey(const Key('stealth-sweep')), findsNothing);
  });

  testWidgets('a scan with no matches says so and offers no sweep',
      (tester) async {
    stealthService.address = _stealth;
    stealthService.lastScan = StealthScanResult.empty;
    await tester.pumpWidget(_wrap());
    await tester.pump();

    await _scrollTo(tester, find.byKey(const Key('stealth-copy')));
    expect(find.text('No stealth payments found.'), findsOneWidget);
    expect(find.byKey(const Key('stealth-sweep')), findsNothing);
  });

  testWidgets('found funds are summarised and a sweep is offered',
      (tester) async {
    stealthService.address = _stealth;
    stealthService.lastScan = const StealthScanResult(
      scanned: 20,
      ownedCount: 2,
      totalNanoErg: 1500000000,
      tokens: [],
      boxIds: ['b1', 'b2'],
    );
    await tester.pumpWidget(_wrap());
    await tester.pump();

    await _scrollTo(tester, find.byKey(const Key('stealth-sweep')));
    expect(find.textContaining('1.5 ERG in 2 stealth boxes'), findsOneWidget);
    expect(find.text('Sweep stealth funds'), findsOneWidget);
  });

  testWidgets('one box is singular', (tester) async {
    stealthService.address = _stealth;
    stealthService.lastScan = const StealthScanResult(
      scanned: 20,
      ownedCount: 1,
      totalNanoErg: 1000000,
      tokens: [],
      boxIds: ['b1'],
    );
    await tester.pumpWidget(_wrap());
    await tester.pump();

    await _scrollTo(tester, find.byKey(const Key('stealth-sweep')));
    expect(find.textContaining('1 stealth box.'), findsOneWidget);
  });

  testWidgets('with scanning off the section points at Settings',
      (tester) async {
    stealthService.address = _stealth;
    stealthService.scanEnabled = false;
    await tester.pumpWidget(_wrap());
    await tester.pump();

    await _scrollTo(tester, find.byKey(const Key('stealth-copy')));
    expect(
      find.textContaining('Stealth scanning is off'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('stealth-sweep')), findsNothing);
  });

  _multipleIdentityTests();
}

/// A wallet that has only ever had one stealth address must look exactly as
/// it did; a picker appears only once there is something to pick.
void _multipleIdentityTests() {
  testWidgets('one identity shows no picker', (tester) async {
    stealthService.address = _stealth;
    await tester.pumpWidget(_wrap());
    await tester.pump();

    await _scrollTo(tester, find.byKey(const Key('stealth-address-text')));
    expect(find.byKey(const Key('stealth-identity-picker')), findsNothing);
    expect(find.text('STEALTH ADDRESS'), findsOneWidget);
    // Adding one is still offered.
    expect(find.byKey(const Key('stealth-identity-add')), findsOneWidget);
  });

  testWidgets('several identities are picked by label, and the shown '
      'address and balance follow the choice', (tester) async {
    stealthService.address = _stealth;
    stealthService.debugSetIdentities(
      const [
        StealthIdentity(index: 0, label: ''),
        StealthIdentity(index: 1, label: 'Donations'),
      ],
      const {0: _stealth, 1: _stealthB},
    );
    stealthService.lastScan = const StealthScanResult(
      scanned: 20,
      ownedCount: 3,
      totalNanoErg: 4500000000,
      tokens: [],
      boxIds: ['a', 'b', 'c'],
      identities: [
        StealthIdentityBalance(
            index: 0, ownedCount: 1, totalNanoErg: 1000000000, tokens: []),
        StealthIdentityBalance(
            index: 1, ownedCount: 2, totalNanoErg: 3500000000, tokens: []),
      ],
    );
    await tester.pumpWidget(_wrap());
    await tester.pump();

    await _scrollTo(tester, find.byKey(const Key('stealth-identity-picker')));
    expect(find.text('STEALTH ADDRESSES'), findsOneWidget);
    // Identity 0 first: its own balance, not the wallet-wide 4.5 ERG.
    expect(find.text(_stealth), findsOneWidget);
    expect(find.textContaining('1 ERG in 1 stealth box on this address.'),
        findsOneWidget);
    expect(find.textContaining('4.5'), findsNothing);

    await _pickIdentity(tester, 'Donations');

    await _scrollTo(tester, find.byKey(const Key('stealth-address-text')));
    expect(find.text(_stealthB), findsOneWidget);
    expect(find.textContaining('3.5 ERG in 2 stealth boxes on this address.'),
        findsOneWidget);
  });

  testWidgets('an identity with no payments says so and offers no sweep',
      (tester) async {
    stealthService.address = _stealth;
    stealthService.debugSetIdentities(
      const [
        StealthIdentity(index: 0, label: ''),
        StealthIdentity(index: 1, label: 'Donations'),
      ],
      const {0: _stealth, 1: _stealthB},
    );
    // Identity 1 is empty even though the wallet as a whole holds funds.
    stealthService.lastScan = const StealthScanResult(
      scanned: 20,
      ownedCount: 1,
      totalNanoErg: 1000000000,
      tokens: [],
      boxIds: ['a'],
      identities: [
        StealthIdentityBalance(
            index: 0, ownedCount: 1, totalNanoErg: 1000000000, tokens: []),
        StealthIdentityBalance(
            index: 1, ownedCount: 0, totalNanoErg: 0, tokens: []),
      ],
    );
    await tester.pumpWidget(_wrap());
    await tester.pump();

    await _pickIdentity(tester, 'Donations');

    await _scrollTo(tester, find.byKey(const Key('stealth-address-text')));
    expect(find.text('No payments to this stealth address.'), findsOneWidget);
    expect(find.byKey(const Key('stealth-sweep')), findsNothing);
  });

  testWidgets('an unlabelled identity is still named in the picker',
      (tester) async {
    stealthService.address = _stealth;
    stealthService.debugSetIdentities(
      const [
        StealthIdentity(index: 0, label: ''),
        StealthIdentity(index: 3, label: ''),
      ],
      const {0: _stealth, 3: _stealthB},
    );
    await tester.pumpWidget(_wrap());
    await tester.pump();

    // A gap in the indices is normal after a restore found identity 3 but
    // not 1 or 2, and neither row may render blank.
    await _pickIdentity(tester, 'Identity 3');
    await _scrollTo(tester, find.byKey(const Key('stealth-address-text')));
    expect(find.text(_stealthB), findsOneWidget);
    expect(find.text('Identity 3'), findsOneWidget);
  });
}
