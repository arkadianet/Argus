import 'dart:convert';
import 'dart:io';

import 'package:argus_wallet/services/activity_classifier.dart';
import 'package:argus_wallet/services/stealth_service.dart';
import 'package:argus_wallet/services/token_metadata.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/ui/home/home_data.dart';
import 'package:argus_wallet/ui/home/home_format.dart';
import 'package:argus_wallet/ui/transaction_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Activity read from the whole wallet's point of view, on real mainnet
// transactions. `fixtures/activity_rows.json` is what the Rust history
// path emits for them (rust/crates/wallet-ffi/src/activity_fixture_tests.rs
// keeps the two in step), so these tests classify exactly what the app
// receives from the node.
//
// The wallet of the user report: index 0 and the pinned #275.

const pinned = '9iArkadiaZAPVxbUp2XQ8SVA1zGA29rCPhbpVuUaaKW6fWspUZA';
const index0 = '9hQTG5EspKUxjhmnFRdzhethHaFmnW4PvjobckSrTSNRYhQLhCZ';

/// Names and scales as the node's token index records them.
const _tokens = <String, (String, int)>{
  '003bd19d0187117f130b62e1bcab0939929ff5c7709f843c5c4dd158949285d0': ('SigRSV', 0),
  '118905fbf54899b7ffe765f59adfe9f4dcd1571909f07ddde50f5c5547bf6ed1': ('XIXA2', 0),
  '1fd6e032e8476c4aa54c18c1a308dce83940e8f4a28f576440513ed7326ad489': ('Paideia', 4),
  '2f9c8b660da2104504771e5be54953966a93ad47f8cdc66ca275d3d9cf254b6a': ('Test Asset 3', 0),
  '6122f7289e7bb2df2de273e09d4b2756cda6aeb0f40438dc9d257688f45183ad': ('DexyGold', 0),
  '8675f7857698e6028ec4cce953693356e61ae4e6e5e10dae3a6ff8e4086fd2fb': ('XIXA', 9),
  '8920b19596b810ddd716587d7d6d9b03e3e382ac480da9e9e4058b8db05b2f99': ('Test Asset 3', 0),
  'ac698c7198f409229c52f3aaf5d4591da3eea8e548d677497b3385b0dc4da97d': ('Test Asset 3', 0),
  'cf74432b2d3ab8a1a934b6326a1004e1a19aec7b357c57209018c4aa35226246': ('DexyLP', 0),
  'e8b20745ee9d18817305f32eb21015831a48f02d40980de6e849f886dca7f807': ('Flux', 8),
  'fa698cc19b05e40c637ba9ec04f28e9e60683cc2e873b266968fc4afa0b23ad5': ('TST', 0),
};

String? _name(String id) => _tokens[id]?.$1;
int? _decimals(String id) => _tokens[id]?.$2;

final _rows = {
  for (final r in (jsonDecode(File('test/fixtures/activity_rows.json').readAsStringSync())['rows'] as List)
      .cast<Map>())
    r['name'] as String: Map<String, dynamic>.from(r['row'] as Map),
};

Map<String, dynamic> row(String name) => Map<String, dynamic>.from(_rows[name]!);

/// The home row as the screen shows it, spaces plain.
({String title, String? who, String? figure, String? subfigure}) home(Map<String, dynamic> tx) {
  final r = activityRow(tx, id: 'x');
  String? plain(String? s) => s == null ? null : spoken(s);
  return (title: r.title, who: r.counterparty, figure: plain(r.figure), subfigure: plain(r.subfigure));
}

/// What the classifier before this change made of the same row: it read
/// only the summary fields.
ActivityKind legacyKind(Map<String, dynamic> tx) => classifyActivity({...tx}..remove('io'));

void main() {
  setUpAll(() {
    for (final MapEntry(key: id, value: (name, decimals)) in _tokens.entries) {
      walletService.rememberTokenMeta(TokenBalance(
        id: id,
        amount: 0,
        name: name,
        decimals: decimals,
        decimalsEvidence: DecimalsEvidence.valid,
      ));
    }
  });

  test('the fixture rows are the node history path\'s own output', () {
    expect(_rows.length, greaterThanOrEqualTo(20));
    for (final r in _rows.values) {
      expect(r['io'], isA<Map>(), reason: r['tx_id']);
    }
  });

  group('the reported burn (index 0 tokens burned, change to #275)', () {
    test('is a burn of six tokens, the fee on the line below', () {
      final h = home(row('burn'));
      expect(h.title, 'Burned tokens');
      expect(h.figure, '−100 Test Asset 3 + 5 more');
      expect(h.subfigure, 'Fee 0.0011 ERG');
      expect(h.who, isNull, reason: 'no counterparty: nothing went to anyone');
      // Before: "Sent · to 9iArka…pUZA · −2.09 ERG". The old reading cannot
      // say burned at all.
      expect(legacyKind(row('burn_seen_from_index0_only')), ActivityKind.sent);
      expect(row('burn_seen_from_index0_only')['counterparty'], pinned);
    });

    test('names none of the wallet\'s own addresses', () {
      final a = walletActivity(row('burn'))!;
      expect(a.category, ActivityCategory.burned);
      expect(a.recipients, isEmpty);
      expect(a.erg, BigInt.from(-1100000));
      expect(a.minerFee, BigInt.from(1100000));
      expect(a.appFee, BigInt.zero, reason: 'the app fee went to #275, the wallet itself');
      expect(a.burned.map((t) => t.amount.toInt()), [100, 100, 100, 3, 8181, 999000000000]);
      expect(a.internalNano, BigInt.from(2092515058 + 1100000));
    });

    test('in the Activity tab: what was burned, then the fee', () {
      expect(
        spoken(activityLine(row('burn'), name: _name, decimals: _decimals)),
        '100 Test Asset 3 + 5 more · fee 0.0011 ERG',
      );
    });

    test('pending, it reads the same', () {
      final pending = {...row('burn'), 'height': 0, 'timestamp': 0, 'confirmed': false};
      final h = activityRow(pending, id: 'p');
      expect(h.pending, isTrue);
      expect(h.title, 'Burned tokens');
      expect(spoken(h.figure!), '−100 Test Asset 3 + 5 more');
    });

    test('a watched account re-read with its later addresses sees the burn', () {
      // Index 0 alone: it paid 2.09 ERG to #275, which this read did not
      // know as its own yet.
      final early = row('burn_seen_from_index0_only');
      expect(home(early).title, 'Sent');
      expect(home(early).who, 'to 9iArka…pUZA');
      final full = reownActivity(early, {index0, pinned});
      expect(home(full).title, 'Burned tokens');
      expect(home(full).who, isNull);
      expect(full['value_nano_erg'], -1100000);
      expect(full['counterparty'], isNull);
      expect(home(full).figure, home(row('burn')).figure);
    });
  });

  group('swaps net both legs over every address', () {
    test('a token sold for ERG on Spectrum', () {
      final h = home(row('swap_token_for_erg'));
      // Before: "Sent · contract 5vSUZR…SCqM · −0.0001 ERG · −2,000 …".
      expect(h.title, 'Swapped');
      expect(h.who, 'Spectrum');
      expect(h.figure, '+0.0349 ERG');
      expect(h.subfigure, '−2,000 raw units of 185e217d…');
      expect(
        spoken(activityLine(row('swap_token_for_erg'), name: _name, decimals: _decimals)),
        '2,000 raw units of 185e217d… → 0.0349 ERG',
      );
    });

    test('Flux sold for ERG', () {
      // Before: "−0.1087 ERG · −57.32 Flux", the view of one address.
      final h = home(row('swap_flux_for_erg'));
      expect(h.title, 'Swapped');
      expect(h.figure, '+0.316 ERG');
      expect(h.subfigure, '−57.32 Flux');
    });

    test('ERG spent on Flux', () {
      final h = home(row('swap_erg_for_flux'));
      expect(h.title, 'Swapped');
      expect(h.figure, '+33.92 Flux');
      expect(h.subfigure, '−0.8254 ERG');
    });

    test('an order a bot filled shows what the order paid in', () {
      final h = home(row('swap_order_filled'));
      expect(legacyKind(row('swap_order_filled')), ActivityKind.received);
      expect(h.title, 'Swapped');
      expect(h.who, 'Spectrum');
      expect(h.figure, '+23.95 ERG');
      expect(h.subfigure, '−3,312.36 Flux');
    });

    test('Dexy LP swap', () {
      final h = home(row('dexy_lp_swap'));
      expect(h.title, 'Swapped');
      expect(h.who, 'Dexy');
      expect(h.figure, '+1 DexyGold');
      expect(h.subfigure, '−0.542 ERG');
    });
  });

  group('liquidity', () {
    test('Dexy LP deposit', () {
      final h = home(row('dexy_lp_add'));
      expect(legacyKind(row('dexy_lp_add')), ActivityKind.swap);
      expect(h.title, 'Added liquidity');
      expect(h.figure, '+470 DexyLP');
      expect(h.subfigure, '−2 DexyGold + 1 more');
    });

    test('Spectrum redeem order filled', () {
      final h = home(row('lp_remove_order_filled'));
      expect(h.title, 'Removed liquidity');
      expect(h.who, 'Spectrum');
      expect(h.figure, startsWith('+131.03 Flux'));
    });
  });

  group('moves inside the wallet change only the fee', () {
    test('a self-transfer from #275 to index 0', () {
      final h = home(row('self_transfer'));
      expect(h.title, 'Moved');
      expect(h.figure, 'Fee 0.0011 ERG');
      expect(h.subfigure, isNull);
      expect(h.who, 'between your addresses');
    });

    test('eight boxes on two addresses merged into one', () {
      final h = home(row('consolidation'));
      expect(h.title, 'Consolidated');
      expect(h.figure, 'Fee 0.0011 ERG');
    });
  });

  group('payments', () {
    test('a send names the outside recipient', () {
      final h = home(row('send'));
      expect(h.title, 'Sent');
      expect(h.who, 'to 9hUMAN…o9go');
      expect(h.figure, '−300 ERG');
    });

    test('a receipt names the sender', () {
      final h = home(row('receive'));
      expect(h.title, 'Received');
      expect(h.figure, '+0.1 ERG');
      expect(h.who, startsWith('from 9eew3x'));
    });

    test('the app fee another wallet paid to #275', () {
      final h = home(row('app_fee_income'));
      expect(h.title, 'Received');
      expect(h.who, 'Argus app fee');
      expect(h.figure, '+0.0011 ERG');
    });

    test('a 26-party transaction paying the wallet', () {
      final h = home(row('multi_party_receive'));
      expect(h.title, 'Received');
      expect(h.who, startsWith('from 9gX9db'));
      expect(h.who, endsWith('more'));
    });
  });

  test('a token issued by the wallet', () {
    final h = home(row('mint'));
    expect(legacyKind(row('mint')), ActivityKind.selfTransfer, reason: 'the old reading called it a move');
    expect(h.title, 'Issued token');
    expect(h.figure, startsWith('+100,000,000'));
    expect(h.subfigure, 'Fee 0.0011 ERG');
  });

  group('stablecoins', () {
    test('SigmaUSD bank mints SigRSV', () {
      final h = home(row('sigmausd_mint'));
      expect(h.title, 'Minted SigRSV');
      expect(h.who, 'SigmaUSD');
      expect(h.figure, '+160,119 SigRSV');
      expect(h.subfigure, '−33.67 ERG');
    });

    test('Dexy bank mints DexyGold', () {
      final h = home(row('dexy_mint'));
      expect(h.title, 'Minted DexyGold');
      expect(h.who, 'Dexy');
      expect(h.figure, '+59 DexyGold');
    });
  });

  group('staking', () {
    test('a Paideia unstake request', () {
      final h = home(row('stake_unstake_request'));
      expect(legacyKind(row('stake_unstake_request')), ActivityKind.sent);
      expect(h.title, 'Unstake requested');
      expect(h.who, 'Paideia');
    });

    test('the unstake filled', () {
      final h = home(row('stake_unstake_filled'));
      expect(h.title, 'Unstaked');
      expect(h.figure, '+356.04 Paideia');
    });
  });

  group('stealth', () {
    test('paying a stealth address', () {
      final h = home(row('stealth_send'));
      expect(legacyKind(row('stealth_send')), ActivityKind.contract);
      expect(h.title, 'Stealth payment');
      expect(h.who, 'to stealth address');
      expect(h.figure, startsWith('−286.4'));
    });

    test('a stealth receipt from the scan', () {
      // The box d957a1f2 paid to a stealth script, as the scan reports it.
      final rows = stealthActivityRows([
        const StealthOwnedBox(
          boxId: 'b',
          transactionId: 'd957a1f2b5944a59465d69729cb3844a94182b61a845434e60c8e2b3553b7e14',
          valueNanoErg: 286403783656,
          creationHeight: 1888800,
          tokens: [],
        ),
      ]);
      final h = home(rows.single);
      expect(h.title, 'Stealth payment');
      expect(h.who, 'to your stealth address');
    });
  });

  testWidgets('the transaction screen breaks the burn down', (tester) async {
    final tx = row('burn');
    await tester.pumpWidget(
      MaterialApp(
        home: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute(
            settings: RouteSettings(
              arguments: WalletRouteArgs(
                senderAddress: pinned,
                receiveAddress: pinned,
                changeAddress: pinned,
                transaction: tx,
              ),
            ),
            builder: (_) => const TransactionDetailScreen(),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Burned tokens'), findsOneWidget);
    expect(find.text('BURNED'), findsOneWidget);
    expect(find.text('100 Test Asset 3'), findsNWidgets(3));
    expect(find.text('Miner fee 0.0011 ERG'), findsOneWidget);
    expect(find.text('MOVED BETWEEN YOUR ADDRESSES'), findsOneWidget);
    expect(find.text('LEFT YOUR WALLET'), findsNothing, reason: 'nothing went to anyone');
    expect(find.text('TO'), findsNothing);
  });

  test('token names come from the one lookup', () {
    expect(tokenName('e8b20745ee9d18817305f32eb21015831a48f02d40980de6e849f886dca7f807'), 'Flux');
  });
}
