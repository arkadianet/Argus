import 'package:argus_wallet/format.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseErgToNano', () {
    test('returns 0 for zero representations', () {
      expect(parseErgToNano('0'), 0);
      expect(parseErgToNano('0.0'), 0);
      expect(parseErgToNano('0.000'), 0);
      expect(parseErgToNano('0.000000000'), 0);
      expect(parseErgToNano('00'), 0);
      expect(parseErgToNano('00.0000'), 0);
    });

    test('returns >0 for positive amounts', () {
      expect(parseErgToNano('0.001'), minBoxNano);
      expect(parseErgToNano('1'), 1000000000);
      expect(parseErgToNano('0.000000001'), 1);
    });

    test('returns null for invalid inputs', () {
      expect(parseErgToNano(''), isNull);
      expect(parseErgToNano('abc'), isNull);
      expect(parseErgToNano('-1'), isNull);
      expect(parseErgToNano('1.2.3'), isNull);
    });
  });

  group('formatErg', () {
    test('trims trailing zeros and keeps needed precision', () {
      expect(formatErg(1000000000), '1 ERG');
      expect(formatErg(1500000000), '1.5 ERG');
      expect(formatErg(1000000), '0.001 ERG');
      expect(formatErg(1), '0.000000001 ERG');
      expect(formatErg(0), '0 ERG');
      expect(formatErg(null), '—');
    });

    test('can omit the unit', () {
      expect(formatErg(2500000000, unit: false), '2.5');
    });
  });

  group('formatTokenAmount', () {
    test('respects decimals and trims zeros', () {
      expect(formatTokenAmount(150, 2), '1.5');
      expect(formatTokenAmount(1, 0), '1');
      expect(formatTokenAmount(1000, 3), '1');
    });
  });

  group('shorten', () {
    test('keeps short values whole', () {
      expect(shorten('abc'), 'abc');
    });

    test('ellipsizes long values', () {
      expect(shorten('1234567890abcdef', head: 4, tail: 4), '1234…cdef');
    });
  });

  group('parseErgoUri', () {
    const addr = '9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8';

    test('accepts a raw P2PK address', () {
      expect(parseErgoUri(addr)?.address, addr);
    });

    test('accepts ergo: and amount', () {
      final pay = parseErgoUri('ergo:$addr?amount=1.5');
      expect(pay?.address, addr);
      expect(pay?.amountErg, '1.5');
    });

    test('rejects junk', () {
      expect(parseErgoUri('bitcoin:abc'), isNull);
      expect(parseErgoUri(''), isNull);
    });

    test('rejects a malformed query string', () {
      expect(parseErgoUri('$addr?amount=%'), isNull);
    });
  });

  group('formatHeight', () {
    test('marks missing height as unconfirmed', () {
      expect(formatHeight(null), 'Unconfirmed');
      expect(formatHeight(0), 'Unconfirmed');
      expect(formatHeight(1200), '#1200');
    });
  });

  group('formatNanoErg', () {
    test('matches formatErg for in-range values', () {
      expect(formatNanoErg(BigInt.parse('1000000000')), '1 ERG');
      expect(formatNanoErg(BigInt.parse('1500000000')), '1.5 ERG');
      expect(formatNanoErg(BigInt.parse('1000000')), '0.001 ERG');
      expect(formatNanoErg(BigInt.parse('1')), '0.000000001 ERG');
      expect(formatNanoErg(BigInt.zero), '0 ERG');
    });

    test('omits the unit and supports maxFrac', () {
      expect(formatNanoErg(BigInt.parse('2500000000'), unit: false), '2.5');
      expect(formatNanoErg(BigInt.parse('1000000000'), maxFrac: 2), '1 ERG');
      expect(formatNanoErg(BigInt.parse('1234567890')), '1.23456789 ERG');
    });

    test('handles values beyond 64-bit', () {
      final bigValue = BigInt.parse('10000000000000000000000000000');
      expect(formatNanoErg(bigValue), '10000000000000000000 ERG');
      expect(
        formatNanoErg(bigValue, unit: false),
        '10000000000000000000',
      );
    });
  });

  group('formatRelativeTime', () {
    test('null returns empty', () {
      expect(formatRelativeTime(null), '');
    });

    test('within a few seconds is just now', () {
      final now = DateTime(2025, 6, 15, 12, 0, 0);
      expect(formatRelativeTime(now, now: now), 'Just now');
      expect(formatRelativeTime(now.subtract(const Duration(seconds: 3)), now: now), 'Just now');
    });

    test('seconds are reported individually', () {
      final now = DateTime(2025, 6, 15, 12, 0, 0);
      expect(formatRelativeTime(now.subtract(const Duration(seconds: 10)), now: now), '10s ago');
      expect(formatRelativeTime(now.subtract(const Duration(seconds: 59)), now: now), '59s ago');
    });

    test('minutes and hours', () {
      final now = DateTime(2025, 6, 15, 12, 0, 0);
      expect(formatRelativeTime(now.subtract(const Duration(minutes: 5)), now: now), '5 min ago');
      expect(formatRelativeTime(now.subtract(const Duration(minutes: 45)), now: now), '45 min ago');
      expect(formatRelativeTime(now.subtract(const Duration(hours: 2)), now: now), '2h ago');
    });

    test('days', () {
      final now = DateTime(2025, 6, 15, 12, 0, 0);
      expect(formatRelativeTime(now.subtract(const Duration(days: 1)), now: now), 'Yesterday');
      expect(formatRelativeTime(now.subtract(const Duration(days: 3)), now: now), '3 days ago');
    });

    test('future timestamps are not reported as ago', () {
      final now = DateTime(2025, 6, 15, 12, 0, 0);
      expect(formatRelativeTime(now.add(const Duration(seconds: 30)), now: now), 'Just now');
      expect(formatRelativeTime(now.add(const Duration(seconds: 59)), now: now), 'Just now');
    });

    test('day labels use calendar days across midnight', () {
      final now = DateTime(2025, 6, 15, 0, 30, 0);
      expect(formatRelativeTime(DateTime(2025, 6, 13, 23, 0, 0), now: now), '2 days ago');
      expect(formatRelativeTime(DateTime(2025, 6, 14, 23, 30, 0), now: now), '1h ago');
      expect(formatRelativeTime(DateTime(2025, 6, 13, 12, 0, 0), now: now), '2 days ago');
    });

    test('day labels survive a spring-forward DST transition', () {
      final now = DateTime(2026, 3, 10, 0, 30, 0);
      expect(formatRelativeTime(DateTime(2026, 3, 8, 0, 30, 0), now: now), '2 days ago');
      expect(formatRelativeTime(DateTime(2026, 3, 9, 0, 30, 0), now: now), 'Yesterday');
    });

    test('old dates fall back to date format', () {
      final now = DateTime(2025, 6, 15, 12, 0, 0);
      expect(formatRelativeTime(now.subtract(const Duration(days: 30)), now: now), '5/16/2025');
    });
  });
}
