import 'package:argus_wallet/services/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

AppVersion v(String text) {
  final parsed = AppVersion.tryParse(text);
  if (parsed == null) fail('"$text" did not parse');
  return parsed;
}

void main() {
  group('parsing', () {
    test('reads a release, a prerelease and the tag form', () {
      expect(v('1.2.3').toString(), '1.2.3');
      expect(v('1.0.0-beta.1').toString(), '1.0.0-beta.1');
      expect(v('v1.0.0-alpha.59').toString(), '1.0.0-alpha.59');
      expect(v('V2.0.0').toString(), '2.0.0');
      expect(v('1.0.0-beta.1').isPrerelease, isTrue);
      expect(v('1.0.0').isPrerelease, isFalse);
    });

    test('pads a missing minor or patch', () {
      expect(v('2').toString(), '2.0.0');
      expect(v('1.4').toString(), '1.4.0');
    });

    test('ignores build metadata, which the spec says has no precedence', () {
      expect(v('1.0.0-beta.1+4061').toString(), '1.0.0-beta.1');
      expect(v('1.0.0+abc.5').toString(), '1.0.0');
    });

    test('refuses what is not a version', () {
      for (final bad in ['', ' ', 'beta', 'v', '1.0.0-', '1..2', '1.2.3.4', '-1.0.0', '1.0.0-beta..1', '1.0.0 beta', 'latest', '1.0.0-be ta']) {
        expect(AppVersion.tryParse(bad), isNull, reason: '"$bad"');
      }
    });

    test('numbers of any realistic size, none past what an int holds', () {
      expect(v('123456789.0.0').major, 123456789);
      expect(AppVersion.tryParse('1234567890.0.0'), isNull);
    });
  });

  group('ordering', () {
    test('the releases Argus has published, in the order they came out', () {
      final sequence = [
        '1.0.0-alpha.51',
        '1.0.0-alpha.52',
        '1.0.0-alpha.57',
        '1.0.0-alpha.58',
        '1.0.0-alpha.59',
        '1.0.0-beta.1',
        '1.0.0-beta.2',
        '1.0.0-beta.10',
        '1.0.0-rc.1',
        '1.0.0-rc.2',
        '1.0.0',
        '1.0.1',
        '1.1.0',
        '2.0.0',
      ].map(v).toList();
      for (var i = 0; i < sequence.length; i++) {
        for (var j = 0; j < sequence.length; j++) {
          expect(sequence[i].compareTo(sequence[j]).sign, i.compareTo(j).sign, reason: '${sequence[i]} vs ${sequence[j]}');
        }
      }
    });

    test('alpha < beta < rc < final', () {
      expect(v('1.0.0-alpha.59') < v('1.0.0-beta.1'), isTrue);
      expect(v('1.0.0-beta.1') < v('1.0.0-rc.1'), isTrue);
      expect(v('1.0.0-rc.1') < v('1.0.0'), isTrue);
      expect(v('1.0.0') > v('1.0.0-rc.9'), isTrue);
    });

    test('numeric identifiers compare as numbers, not as text', () {
      expect(v('1.0.0-beta.2') < v('1.0.0-beta.10'), isTrue);
      expect(v('1.0.0-alpha.9') < v('1.0.0-alpha.59'), isTrue);
      expect(v('1.0.0-rc.9') < v('1.0.0-rc.10'), isTrue);
    });

    test('the same prerelease of a later version is later', () {
      expect(v('1.0.0-beta.9') < v('1.0.1-alpha.1'), isTrue);
      expect(v('0.9.9') < v('1.0.0-alpha.1'), isTrue);
    });

    test('the example ordering from semver.org holds', () {
      final sequence = [
        '1.0.0-alpha',
        '1.0.0-alpha.1',
        '1.0.0-alpha.beta',
        '1.0.0-beta',
        '1.0.0-beta.2',
        '1.0.0-beta.11',
        '1.0.0-rc.1',
        '1.0.0',
      ].map(v).toList();
      for (var i = 0; i + 1 < sequence.length; i++) {
        expect(sequence[i] < sequence[i + 1], isTrue, reason: '${sequence[i]} < ${sequence[i + 1]}');
        expect(sequence[i + 1] > sequence[i], isTrue);
      }
    });

    test('a number is lower than a word, and a shorter list lower than a longer', () {
      expect(v('1.0.0-1') < v('1.0.0-alpha'), isTrue);
      expect(v('1.0.0-beta') < v('1.0.0-beta.1'), isTrue);
    });

    test('equal versions are equal whatever the build metadata or case', () {
      expect(v('1.0.0-beta.1'), v('v1.0.0-beta.1+4061'));
      expect(v('1.0.0-beta.1').hashCode, v('1.0.0-beta.1+9').hashCode);
      expect(v('1.0.0-RC.1'), v('1.0.0-rc.1'));
      expect(v('1.0.0-beta.1') < v('1.0.0-beta.1'), isFalse);
      expect(v('1.0.0-beta.1') > v('1.0.0-beta.1'), isFalse);
    });

    test('a word run into its number sorts as if separated', () {
      expect(v('1.0.0-rc9') < v('1.0.0-rc10'), isTrue);
      expect(v('1.0.0-beta1'), v('1.0.0-beta.1'));
      expect(v('1.0.0-beta1') < v('1.0.0-beta.2'), isTrue);
      expect(v('1.0.0-alpha59') < v('1.0.0-beta1'), isTrue);
    });
  });
}
