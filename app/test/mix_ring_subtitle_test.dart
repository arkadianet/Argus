import 'package:argus_wallet/ui/mix_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a ring line names the fee as a share of the amount and flags an expensive one', () {
    // Live figures on 2026-09-05: 0.12 ERG batch plus 0.1% of the amount.
    expect(
      ringSubtitle(value: 1000000000, waiting: 1, operatorFee: 121000000),
      '1 waiting: you could join at once · fees 0.121 ERG (12%), expensive for this amount',
    );
    expect(
      ringSubtitle(value: 10000000000, waiting: 0, operatorFee: 130000000),
      'Nobody waiting: you would post the first box · fees 0.13 ERG (1.3%)',
    );
    expect(
      ringSubtitle(value: 100000000000, waiting: 2, operatorFee: 220000000),
      '2 waiting: you could join at once · fees 0.22 ERG (0.2%)',
    );
    expect(
      ringSubtitle(value: 1000000000, waiting: 0, operatorFee: null),
      'Nobody waiting: you would post the first box',
      reason: 'no batch chosen yet',
    );
  });

  test('a level is numbered as ErgoMixer does, with its rounds', () {
    expect(levelTitle(index: 0, rounds: 30), 'Level 1 · about 30 rounds');
    expect(levelTitle(index: 3, rounds: 180), 'Level 4 · about 180 rounds');
  });

  test('a ring insight says who is there, how fast it moves and how long a level takes', () {
    expect(ringInsight(depth: 0, recentRounds: 0, rounds: 30), 'Nobody mixing here · no rounds here in the past week, so a mix would wait indefinitely');
    expect(ringInsight(depth: 132, recentRounds: 28, rounds: 30), '132 boxes to hide among · about 2 rounds a day here · about 2 weeks for 30 rounds');
    expect(ringInsight(depth: 5, recentRounds: 2, rounds: 30), '5 boxes to hide among · about 1 round a week here · about 30 weeks for 30 rounds');
    expect(ringInsight(depth: 1, recentRounds: 14, rounds: null), '1 box to hide among · about 1 round a day here');
  });

  test('tokens left say how many rounds the box can still pay for', () {
    expect(tokensLeftText(12, 11), '12 mixing tokens on the box · about 11 more rounds affordable');
    expect(tokensLeftText(1, 0), '1 mixing token on the box · no more rounds affordable, it withdraws next');
  });
}
