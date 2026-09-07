import 'package:argus_wallet/services/mix_service.dart';
import 'package:argus_wallet/services/mix_activity.dart';
import 'package:argus_wallet/ui/mix_screen.dart';
import 'package:flutter_test/flutter_test.dart';

MixRecord _finished(String kind, {String tree = '0008cd00', int done = 6}) => MixRecord(state: {
      'mix_id': 0,
      'ring': {'value': 1000000000, 'token_id': null},
      'rounds_target': 30,
      'rounds_done': done,
      'phase': {'kind': kind},
      'destination_ergo_tree': tree,
      'events': [
        {'action': kind, 'tx_id': 'txw', 'at': 1, 'round': done},
      ],
    });

void main() {
  test('a ring line is one muted fact: who waits, how many boxes, the fee', () {
    // Live figures on 2026-09-05: 0.12 ERG batch plus 0.1% of the amount.
    expect(
      ringSubtitle(value: 1000000000, waiting: 1, depth: 51, operatorFee: 121000000),
      '1 waiting · 51 boxes to hide among · fee 0.121 ERG (12%)',
    );
    expect(
      ringSubtitle(value: 10000000000, waiting: 0, depth: 44, operatorFee: 130000000),
      'Nobody waiting · 44 boxes to hide among · fee 0.13 ERG (1.3%)',
    );
    expect(
      ringSubtitle(value: 1000000000, waiting: 0, depth: 0, operatorFee: null),
      'Nobody waiting · nobody mixing here yet',
      reason: 'no batch chosen yet, empty ring',
    );
  });

  test('a ring note is short, and red only when the fee bites', () {
    expect(
      ringNote(value: 1000000000, waiting: 1, recentRounds: 2, operatorFee: 121000000),
      (text: 'Fee is 12% of this amount · about 1 round a week here', warning: true),
    );
    expect(
      ringNote(value: 100000000000, waiting: 2, recentRounds: 0, operatorFee: 220000000),
      (text: 'A partner is waiting, so your first round could start at once', warning: false),
    );
    expect(
      ringNote(value: 10000000000, waiting: 0, recentRounds: 0, operatorFee: 130000000),
      (text: 'Quiet: no rounds here in the past week', warning: false),
    );
    expect(
      ringNote(value: 100000000000, waiting: 0, recentRounds: 28, operatorFee: 220000000),
      (text: 'About 2 rounds a day here', warning: false),
    );
  });

  test('dead rings are not offered: no partner, no rounds, not a standard amount', () {
    expect(ringOffered(value: 486250000, waiting: 0, recentRounds: 0), isFalse);
    expect(ringOffered(value: 486250000, waiting: 1, recentRounds: 0), isTrue);
    expect(ringOffered(value: 9487500000, waiting: 0, recentRounds: 3), isTrue);
    expect(ringOffered(value: 10000000000, waiting: 0, recentRounds: 0), isTrue, reason: 'standard ring');
  });

  test('a level line prices the tokens and estimates the wait in the chosen ring', () {
    expect(
      levelSubtitle(price: 120000000, rounds: 30, ringValue: 1000000000, recentRounds: 2),
      '0.12 ERG in mixing tokens · about 30 weeks for 30 rounds at the 1 ERG ring\'s pace',
    );
    expect(
      levelSubtitle(price: 240000000, rounds: 60, ringValue: 100000000000, recentRounds: 28),
      '0.24 ERG in mixing tokens · about 30 days for 60 rounds at the 100 ERG ring\'s pace',
    );
    expect(
      levelSubtitle(price: 120000000, rounds: 30, ringValue: 10000000000, recentRounds: 0),
      '0.12 ERG in mixing tokens · no estimate: the 10 ERG ring had no rounds in the past week',
    );
  });

  test('a finished mix says where the money went and what the card means', () {
    expect(
      mixFinishedText(_finished('withdrawn', tree: '1005040004000e2000')),
      '1 ERG went to a stealth address of yours. It counts in this wallet\'s balance '
      'and shows in Activity as "Mix finished". Remove only clears this card.',
    );
    expect(
      mixFinishedText(_finished('withdrawn')),
      '1 ERG went to your public address. It counts in this wallet\'s balance '
      'and shows in Activity as "Mix finished". Remove only clears this card.',
    );
    expect(
      mixFinishedText(_finished('reclaimed', done: 0)),
      '1 ERG went back to your public address, minus the mixing tokens. It counts in '
      'this wallet\'s balance and shows in Activity as "Mix reclaimed". Remove only clears this card.',
    );
    expect(mixDestinationText(_finished('withdrawn')), 'your public address');
    expect(mixDestinationText(_finished('withdrawn', tree: '')), 'the destination you chose');
  });

  test('a level is numbered as ErgoMixer does, with its rounds', () {
    expect(levelTitle(index: 0, rounds: 30), 'Level 1 · 30 rounds');
    expect(levelTitle(index: 3, rounds: 180), 'Level 4 · 180 rounds');
  });


  test('tokens left say how many rounds the box can still pay for', () {
    expect(tokensLeftText(12, 11), '12 mixing tokens on the box · about 11 more rounds affordable');
    expect(tokensLeftText(1, 0), '1 mixing token on the box · no more rounds affordable, it withdraws next');
  });
}
