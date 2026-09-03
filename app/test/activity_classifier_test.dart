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

  test('token summary names a single token and counts several', () {
    String? name(String id) => id == 'a' ? 'SigUSD' : null;
    int decimals(String id) => id == 'a' ? 2 : 0;
    expect(tokenSummary([{'token_id': 'a', 'amount': 150}], name: name, decimals: decimals), '1.5 SigUSD');
    expect(tokenSummary([{'token_id': 'zz', 'amount': 1}], name: name, decimals: decimals), '1 zz…');
    expect(tokenSummary([{'token_id': 'a', 'amount': 1}, {'token_id': 'b', 'amount': 2}], name: name, decimals: decimals), '2 tokens');
    expect(tokenSummary(const [], name: name, decimals: decimals), isNull);
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
