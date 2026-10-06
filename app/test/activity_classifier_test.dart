import 'package:argus_wallet/services/activity_classifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const p2pk = '9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8';
  const contract = '5vSUZRZbdVbnk4sJWjg2uhL94VZWRg4iatK9VgMChufzUgdihgvhR8yWSUEJKszzV7Vmi6K8hCyKTNhUaiP8p5ko6YEU9yfHpjVuXdQ4i5p1YMhmvBBUbEEWqgrx1Ah5R9mdS4B7ENzfGjWn9hzpDdZDp6nffA6fkT6zfSpRaeBTaM7KH6Hjfq5rrFbz8x2bmfVPPYmRvvSsmhzETb7c9zVnC4jH2Mx4YbKDX8MTYAUVbmhX5ARDTr4FXJ3Fv9SsK1ohnVfUxQspkjP2oMPU5ZoXWKBv6q9Ek4EKM4Xu1Cph3E2rbTG7HFaPEYRp4pVHY3xFsSkBapAa9EuZHdGjcKKGVJjB4dKvjdYNPpHdZS5rZ7dxgFsXLEgHAkAqJ';

  test('plain receive from a person', () {
    final k = classifyActivity({'value_nano_erg': 1000, 'counterparty': p2pk});
    expect(k, ActivityKind.received);
    expect(activityTitle(k), 'Received');
  });

  test('plain send to a person', () {
    expect(classifyActivity({'value_nano_erg': -1000, 'counterparty': p2pk}), ActivityKind.sent);
  });

  test('ERG out and tokens in from a contract is a swap', () {
    final k = classifyActivity({
      'value_nano_erg': -750000000,
      'counterparty': contract,
      'tokens_received': [{'token_id': 'a', 'amount': 5}],
    });
    expect(k, ActivityKind.swap);
    expect(activityTitle(k), 'Swapped');
  });

  test('tokens out and ERG in from a contract is a swap too', () {
    final k = classifyActivity({
      'value_nano_erg': 500000000,
      'counterparty': contract,
      'tokens_sent': [{'token_id': 'a', 'amount': 5}],
    });
    expect(k, ActivityKind.swap);
  });

  test('a contract interaction with no clear direction is labelled as such', () {
    final k = classifyActivity({'value_nano_erg': -1100000, 'counterparty': contract});
    expect(k, ActivityKind.contract);
    expect(activityTitle(k), 'Contract');
  });

  test('no counterparty and no value is a self transfer', () {
    expect(classifyActivity({'value_nano_erg': -1100000}), ActivityKind.selfTransfer);
  });

  test('token summary names a single token', () {
    String? name(String id) => id == 'a' ? 'SigUSD' : null;
    int decimals(String id) => id == 'a' ? 2 : 0;
    expect(tokenSummary([{'token_id': 'a', 'amount': 150}], name: name, decimals: decimals), '1.5 SigUSD');
    expect(tokenSummary(const [], name: name, decimals: decimals), isNull);
  });

  group('tokens in a row are named, not counted', () {
    const comet = '0cd8c9f416e5b1ca9f986a7f10a84191dfb85941619e49e53c0dc30ebf83324b';
    const sigUsd = '03faf2cb329f2e90d6d23b58d91bbb6c046aa143261cc21f52fbe2824bfcbf04';
    const unknown = 'e91cbc48aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    String? name(String id) => switch (id) {
          comet => 'COMET',
          sigUsd => 'SigUSD',
          _ => null,
        };
    int? decimals(String id) => switch (id) {
          comet => 0,
          sigUsd => 2,
          _ => null,
        };
    Map<String, Object> t(String id, int amount) => {'token_id': id, 'amount': amount};

    test('two tokens are both named', () {
      expect(
        tokenSummary([t(comet, 69), t(sigUsd, 150)], name: name, decimals: decimals),
        '69 COMET + 1.5 SigUSD',
      );
    });

    test('past two, the rest are summed up', () {
      expect(
        tokenSummary(
          [t(comet, 69), t(sigUsd, 150), t(unknown, 7), t('f' * 64, 1)],
          name: name,
          decimals: decimals,
        ),
        '69 COMET + 1.5 SigUSD + 2 more tokens',
      );
      expect(
        tokenSummary([t(comet, 69), t(sigUsd, 150), t(unknown, 7)], name: name, decimals: decimals),
        '69 COMET + 1.5 SigUSD + 1 more token',
      );
    });

    test('named tokens are the ones a row keeps', () {
      expect(
        tokenSummary([t(unknown, 7), t(comet, 69), t(sigUsd, 150)], name: name, decimals: decimals),
        '69 COMET + 1.5 SigUSD + 1 more token',
      );
    });

    test('an unknown token is its short id, in raw units said as such', () {
      expect(
        tokenSummary([t(unknown, 5000)], name: name, decimals: decimals),
        '5,000 raw units of e91cbc48…',
      );
    });

    test('a known name with an unknown scale is still raw units', () {
      expect(
        tokenSummary([t(comet, 1)], name: name, decimals: (_) => null),
        '1 raw unit of COMET',
      );
    });

    test('the reported row: Sent 69 COMET + ERG to a contract', () {
      final tx = {
        'value_nano_erg': -1816200000,
        'counterparty': contract,
        'tokens_sent': [t(comet, 69)],
      };
      expect(classifyActivity(tx), ActivityKind.sent);
      expect(activityLine(tx, name: name, decimals: decimals), '69 COMET + 1.8162 ERG');
    });

    test('a swap shows what went out and what came back', () {
      final tx = {
        'value_nano_erg': -750000000,
        'counterparty': contract,
        'tokens_received': [t(comet, 69)],
      };
      expect(classifyActivity(tx), ActivityKind.swap);
      expect(activityLine(tx, name: name, decimals: decimals), '0.75 ERG for 69 COMET');
    });

    test('hidden balances hide names too', () {
      final tx = {'value_nano_erg': -1, 'tokens_sent': [t(comet, 69)]};
      expect(activityLine(tx, name: name, decimals: decimals, hidden: true), '••••');
    });
  });

  test('activity line joins ERG and tokens and drops a zero ERG leg', () {
    String? name(String id) => 'Tok';
    int decimals(String id) => 0;
    expect(
      activityLine({'value_nano_erg': 0, 'tokens_received': [{'token_id': 'a', 'amount': 1}]}, name: name, decimals: decimals),
      '1 Tok',
    );
    expect(
      activityLine({'value_nano_erg': -749600000, 'tokens_sent': [{'token_id': 'a', 'amount': 1}]}, name: name, decimals: decimals),
      '1 Tok + 0.7496 ERG',
    );
    expect(activityLine({'value_nano_erg': 2000000000}, name: name, decimals: decimals), '2 ERG');
  });
}
