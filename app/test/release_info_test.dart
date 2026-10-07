import 'dart:convert';
import 'dart:io';

import 'package:argus_wallet/services/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> release({
  Object? tag = 'v1.0.0-beta.2',
  Object? body = 'Notes.',
  Object? draft = false,
  Object? prerelease = false,
  Object? assets = const <Object?>[],
  Object? publishedAt = '2026-10-20T10:00:00Z',
}) =>
    {
      'tag_name': tag,
      'body': body,
      'draft': draft,
      'prerelease': prerelease,
      'published_at': publishedAt,
      'assets': assets,
    };

Map<String, Object?> asset({
  Object? name = 'argus-1.0.0-beta.2-universal.apk',
  Object? size = 1000,
  Object? url = 'https://github.com/arkadianet/Argus/releases/download/v1.0.0-beta.2/argus-1.0.0-beta.2-universal.apk',
  Object? digest,
  Object? state = 'uploaded',
}) =>
    {
      'name': name,
      'size': size,
      'browser_download_url': url,
      'digest': digest,
      'state': state,
    };

const hex = 'e64eb689bd9b4c580a40ee6f1621e6cc174f2114bc9da2acb7a7e1967abf9d10';

ReleaseAsset named(String name) =>
    ReleaseAsset(name: name, size: 10, url: Uri.parse('https://github.com/arkadianet/Argus/releases/download/v/$name'));

void main() {
  group('GitHub release JSON', () {
    final fixture = jsonDecode(File('test/fixtures/github_release_latest.json').readAsStringSync());

    test('the real response for beta.1 parses', () {
      final info = ReleaseInfo.fromJson(fixture);
      expect(info.version.toString(), '1.0.0-beta.1');
      expect(info.publishedAt, DateTime.utc(2026, 10, 6, 2, 20, 31));
      expect(info.assets.map((a) => a.name), [
        'argus-1.0.0-beta.1-arm64-v8a.apk',
        'argus-1.0.0-beta.1-universal.apk',
        'argus-1.0.0-beta.1-x86_64.apk',
      ]);
      final arm = info.assets.first;
      expect(arm.size, 50254123);
      expect(arm.sha256, hex);
      expect(arm.url.toString(),
          'https://github.com/arkadianet/Argus/releases/download/v1.0.0-beta.1/argus-1.0.0-beta.1-arm64-v8a.apk');
      expect(info.assets.map((a) => a.sha256), everyElement(isNotNull));
    });

    test('its notes are kept as written, markdown and all', () {
      final notes = ReleaseInfo.fromJson(fixture).notes;
      expect(notes, startsWith('The first beta.'));
      expect(notes, contains('## What changed'));
      expect(notes, contains('**Multi-token sends.**'));
      expect(notes, contains('`E5:8B:18:35:B7:D5:F3:2A:C9:83:08:29:EC:94:9F:8D:D9:C6:2C:20:64:AD:89:E1:97:35:33:17:7D:B4:7F:CC`'));
    });

    test('it is a newer release than the alphas and the same as itself', () {
      final info = ReleaseInfo.fromJson(fixture);
      expect(info.version > AppVersion.tryParse('1.0.0-alpha.59')!, isTrue);
      expect(info.version > AppVersion.tryParse('1.0.0-beta.1')!, isFalse);
    });

    test('what is stored comes back the same', () {
      final info = ReleaseInfo.fromJson(fixture);
      final again = ReleaseInfo.fromJson(jsonDecode(jsonEncode(info.toJson())));
      expect(again.version, info.version);
      expect(again.notes, info.notes);
      expect(again.publishedAt, info.publishedAt);
      expect(again.assets.map((a) => (a.name, a.size, a.url, a.sha256)), info.assets.map((a) => (a.name, a.size, a.url, a.sha256)));
    });
  });

  group('what is not a usable release', () {
    test('anything that is not an object', () {
      for (final bad in <Object?>[null, 'x', 3, <Object?>[]]) {
        expect(() => ReleaseInfo.fromJson(bad), throwsFormatException);
      }
    });

    test('drafts and prereleases', () {
      expect(() => ReleaseInfo.fromJson(release(draft: true)), throwsFormatException);
      expect(() => ReleaseInfo.fromJson(release(prerelease: true)), throwsFormatException);
    });

    test('no version, or one that cannot be ordered', () {
      expect(() => ReleaseInfo.fromJson(release(tag: null)), throwsFormatException);
      expect(() => ReleaseInfo.fromJson(release(tag: 5)), throwsFormatException);
      expect(() => ReleaseInfo.fromJson(release(tag: 'nightly')), throwsFormatException);
      expect(() => ReleaseInfo.fromJson(<String, Object?>{}), throwsFormatException);
    });

    test('a missing body, date or asset list is fine', () {
      final info = ReleaseInfo.fromJson({'tag_name': 'v2.0.0'});
      expect(info.notes, '');
      expect(info.publishedAt, isNull);
      expect(info.assets, isEmpty);
      expect(ReleaseInfo.fromJson(release(publishedAt: 'yesterday', assets: 'none')).publishedAt, isNull);
    });
  });

  group('release notes as plain text', () {
    test('markup, links and addresses are left exactly as written', () {
      const body = '<b>bold</b> <script>alert(1)</script>\n[click](https://evil.example/x) ![img](https://evil.example/i.png)\nhttps://evil.example/bare';
      expect(releaseNotesText(body), body);
    });

    test('control characters are removed, line breaks and tabs kept', () {
      expect(releaseNotesText('a\u0000b\u0007c\u001bd\u007fe\u0085f\tg\nh'), 'abcdef\tg\nh');
    });

    test('line endings are normalised', () {
      expect(releaseNotesText('one\r\ntwo\rthree\nfour'), 'one\ntwo\nthree\nfour');
    });

    test('direction overrides and invisible characters are removed', () {
      // U+202E reverses what follows and U+2066/U+2069 isolate it; the rest
      // are zero-width or separators. Built from code points so that this
      // file holds none of them itself.
      const hidden = [0x202e, 0x2066, 0x2069, 0x200b, 0x200d, 0x200e, 0x2028, 0x2060, 0xfeff];
      final all = String.fromCharCodes(hidden);
      expect(releaseNotesText('safe${all}txt.apk${all}end'), 'safetxt.apkend');
      for (final c in hidden) {
        expect(releaseNotesText('a${String.fromCharCode(c)}b'), 'ab', reason: 'U+${c.toRadixString(16)}');
      }
    });

    test('a lone surrogate does not survive', () {
      expect(releaseNotesText('a\ud800b'), 'ab');
      // A real pair does: this is a whole code point.
      expect(releaseNotesText('ok \u{1F44D}'), 'ok \u{1F44D}');
    });

    test('long notes are cut at a character, with an ellipsis', () {
      final long = 'x' * 6001;
      final cut = releaseNotesText(long);
      expect(cut.length, 6001);
      expect(cut.endsWith('…'), isTrue);
      expect(releaseNotesText('y' * 6000), 'y' * 6000);
      // Emoji are two UTF-16 units; the cut must not split one.
      final emoji = releaseNotesText('\u{1F44D}' * 6001);
      expect(emoji.endsWith('…'), isTrue);
      expect(emoji.runes.length, 6001);
    });

    test('surrounding blank space goes, nothing else', () {
      expect(releaseNotesText('\n\n  hello  \n'), 'hello');
      expect(releaseNotesText(null), '');
      expect(releaseNotesText(''), '');
    });
  });

  group('assets', () {
    test('a good asset keeps its size, address and checksum', () {
      final a = ReleaseAsset.tryParse(asset(digest: 'sha256:$hex'))!;
      expect(a.name, 'argus-1.0.0-beta.2-universal.apk');
      expect(a.size, 1000);
      expect(a.sha256, hex);
    });

    test('an upper-case checksum is normalised', () {
      expect(ReleaseAsset.tryParse(asset(digest: 'SHA256:${hex.toUpperCase()}'))!.sha256, hex);
    });

    test('no checksum, or another algorithm, means none to check', () {
      expect(ReleaseAsset.tryParse(asset())!.sha256, isNull);
      expect(ReleaseAsset.tryParse(asset(digest: 'sha512:${'ab' * 64}'))!.sha256, isNull);
      expect(ReleaseAsset.tryParse(asset(digest: 42))!.sha256, isNull);
    });

    test('a checksum that claims to be SHA-256 and is not makes the asset unusable', () {
      expect(ReleaseAsset.tryParse(asset(digest: 'sha256:abc')), isNull);
      expect(ReleaseAsset.tryParse(asset(digest: 'sha256:${'zz' * 32}')), isNull);
      expect(ReleaseAsset.tryParse(asset(digest: 'sha256:')), isNull);
    });

    test('unfinished, sizeless or malformed assets are skipped', () {
      expect(ReleaseAsset.tryParse(asset(state: 'starter')), isNull);
      expect(ReleaseAsset.tryParse(asset(size: 0)), isNull);
      expect(ReleaseAsset.tryParse(asset(size: -5)), isNull);
      expect(ReleaseAsset.tryParse(asset(size: '1000')), isNull);
      expect(ReleaseAsset.tryParse(asset(name: null)), isNull);
      expect(ReleaseAsset.tryParse(asset(url: null)), isNull);
      expect(ReleaseAsset.tryParse('apk'), isNull);
      expect(ReleaseAsset.tryParse(null), isNull);
    });

    test('an address that is not Argus-on-GitHub material is skipped', () {
      for (final bad in [
        'http://github.com/arkadianet/Argus/releases/download/v1/a.apk',
        'https://evil.example/a.apk',
        'https://github.com.evil.example/a.apk',
        'https://evilgithubusercontent.com/a.apk',
        'https://user:pw@github.com/a.apk',
        'https://github.com:8443/a.apk',
        'ftp://github.com/a.apk',
        '/relative/a.apk',
        'not a url',
      ]) {
        expect(ReleaseAsset.tryParse(asset(url: bad)), isNull, reason: bad);
      }
    });

    test('bad assets do not take the release with them', () {
      final info = ReleaseInfo.fromJson(release(assets: [
        asset(),
        asset(url: 'https://evil.example/a.apk', name: 'evil.apk'),
        'junk',
        asset(name: 'argus-1.0.0-beta.2-x86_64.apk'),
      ]));
      expect(info.assets.map((a) => a.name), ['argus-1.0.0-beta.2-universal.apk', 'argus-1.0.0-beta.2-x86_64.apk']);
    });
  });

  group('trusted release hosts', () {
    test('github.com and the content hosts it hands downloads to', () {
      for (final ok in [
        'https://github.com/arkadianet/Argus/releases/download/v1/a.apk',
        'https://objects.githubusercontent.com/github-production-release-asset/1/a',
        'https://release-assets.githubusercontent.com/github-production-release-asset/1/a?sig=x',
        'https://GITHUB.com/a',
        'https://github.com:443/a',
      ]) {
        expect(isTrustedReleaseUrl(Uri.parse(ok)), isTrue, reason: ok);
      }
    });

    test('nothing else', () {
      for (final bad in [
        'http://github.com/a',
        'https://api.github.com.evil.example/a',
        'https://githubusercontent.com/a',
        'https://notgithub.com/a',
        'https://1.2.3.4/a',
        'https://github.com@evil.example/a',
      ]) {
        expect(isTrustedReleaseUrl(Uri.parse(bad)), isFalse, reason: bad);
      }
    });
  });

  group('which APK a phone gets', () {
    final arm = named('argus-1.0.0-beta.2-arm64-v8a.apk');
    final x86 = named('argus-1.0.0-beta.2-x86_64.apk');
    final universal = named('argus-1.0.0-beta.2-universal.apk');
    final all = [universal, arm, x86];

    test('a 64-bit ARM phone gets the arm64 build', () {
      expect(pickAsset(all, ['arm64-v8a', 'armeabi-v7a', 'armeabi']), arm);
    });

    test('an x86_64 device gets the x86_64 build', () {
      expect(pickAsset(all, ['x86_64', 'x86']), x86);
      expect(pickAsset(all, ['x86', 'x86_64']), x86);
    });

    test('a device that also runs ARM translated still gets its own build first', () {
      expect(pickAsset(all, ['x86_64', 'x86', 'arm64-v8a', 'armeabi-v7a']), x86);
    });

    test('a 32-bit phone, or one that will not say, gets the universal APK', () {
      expect(pickAsset(all, ['armeabi-v7a', 'armeabi']), universal);
      expect(pickAsset(all, ['x86']), universal);
      expect(pickAsset(all, const []), universal);
    });

    test('a release missing the matching build falls back to universal', () {
      expect(pickAsset([universal, x86], ['arm64-v8a', 'armeabi-v7a']), universal);
      expect(pickAsset([universal, arm], ['x86_64', 'arm64-v8a']), universal);
    });

    test('nothing to offer when the release has no suitable APK', () {
      expect(pickAsset([arm], ['x86_64']), isNull);
      expect(pickAsset(const [], ['arm64-v8a']), isNull);
      expect(pickAsset([named('notes.txt'), named('argus-1.0.0-universal.aab')], ['arm64-v8a']), isNull);
    });

    test('a file that only resembles one of ours is not taken', () {
      expect(pickAsset([named('other-1.0.0-arm64-v8a.apk')], ['arm64-v8a']), isNull);
    });
  });

  test('sizes are shown in megabytes', () {
    expect(formatDownloadSize(50254123), '47.9 MB');
    expect(formatDownloadSize(0), '0.0 MB');
  });
}
