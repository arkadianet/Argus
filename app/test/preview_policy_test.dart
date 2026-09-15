import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:argus_wallet/services/preview/policy.dart';
import 'package:argus_wallet/services/preview/preview_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'support/failing_preferences.dart';

const cid = 'QmYwAPJzv5CZsnAzt8auVZRnG6FMmQLGzsh6coP7u8MLhM';
final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
);
final fails = throwsA(isA<PreviewFailure>());

class FixtureTransport extends PreviewTransport {
  FixtureTransport({
    Uint8List? bytes,
    this.mime = 'image/png',
    this.status = 200,
    this.encoding,
    this.length = -1,
    this.stream,
  }) : bytes = bytes ?? png;
  final Uint8List bytes;
  final String mime;
  final int status, length;
  final String? encoding;
  final Stream<List<int>>? stream;
  int calls = 0;
  @override
  Future<(Uint8List, String)> fetch(Uri origin, List<String> path) {
    calls++;
    return readPreviewResponse(
      status,
      mime,
      encoding,
      length,
      stream ?? Stream.value(bytes),
    );
  }
}

void main() {
  for (final initial in [false, true]) {
    test('failed opt-out write preserves $initial without publishing', () async {
      SharedPreferences.setMockInitialValues({});
      SharedPreferencesStorePlatform.instance = FailingPreferences({
        'flutter.preview_never': initial,
      });
      final settings = PreviewSettings();
      addTearDown(settings.dispose);
      addTearDown(() => SharedPreferences.setMockInitialValues({}));
      await settings.load();
      final revision = settings.revision;
      var notifications = 0;
      settings.addListener(() => notifications++);
      await expectLater(settings.setNever(!initial), fails);
      expect(settings.never, initial);
      expect(settings.revision, revision);
      expect(notifications, 0);
      // Reload disk rather than the legacy SharedPreferences optimistic cache.
      await (await SharedPreferences.getInstance()).reload();
      await settings.load();
      expect(settings.never, initial);
    });
  }

  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('PNG MIME with non-PNG bytes refuses before decode', () async {
    final job = PreviewJob(
      allowed: () => true,
      transport: FixtureTransport(
        bytes: Uint8List.fromList(utf8.encode('<html>beacon</html>')),
      ),
    );
    await expectLater(
      job.fetch('https://gateway.example', 'ipfs://$cid', null),
      fails,
    );
  });
  test('dimension bombs refuse at IHDR before pixel allocation', () {
    for (final dims in [(4097, 1), (4096, 4096), (0, 1)]) {
      final bomb = Uint8List.fromList(png);
      ByteData.sublistView(bomb)
        ..setUint32(16, dims.$1)
        ..setUint32(20, dims.$2);
      expect(
        () => inspectImage(bomb, 'image/png', null),
        throwsA(
          isA<PreviewFailure>().having(
            (e) => e.message,
            'reason',
            contains('dimensions'),
          ),
        ),
      );
    }
  });
  test('R8 mismatch refuses before a renderable result exists', () async {
    final job = PreviewJob(allowed: () => true, transport: FixtureTransport());
    await expectLater(
      job.fetch('https://gateway.example', 'ipfs://$cid', '00' * 32),
      throwsA(
        isA<PreviewFailure>().having(
          (e) => e.message,
          'reason',
          'Content differs from issuance hash.',
        ),
      ),
    );
    final info = inspectImage(png, 'image/png', sha256.convert(png).toString());
    expect(info.matchesHash, isTrue);
  });
  test('missing or invalid R8 needs a further explicit action', () async {
    for (final hash in [null, 'invalid']) {
      final job = PreviewJob(
        allowed: () => true,
        transport: FixtureTransport(),
      );
      final source = await job.fetch(
        'https://gateway.example',
        'ipfs://$cid',
        hash,
      );
      expect(source.info.matchesHash, isFalse);
      await expectLater(job.decode(source), fails);
    }
  });
  test(
    'streamed oversized body stops at cap and cancels subscription',
    () async {
      var yielded = 0;
      var cancelled = false;
      Stream<List<int>> chunks() async* {
        try {
          for (var i = 0; i < 10; i++) {
            yielded++;
            yield Uint8List(1024 * 1024);
          }
        } finally {
          cancelled = true;
        }
      }

      final transport = FixtureTransport(stream: chunks());
      await expectLater(
        transport.fetch(Uri.parse('https://gateway.example'), ['ipfs', cid]),
        fails,
      );
      expect(yielded, 6); // Fifth MiB accepted; next chunk never appended.
      expect(cancelled, isTrue);
    },
  );
  test(
    'redirect and transport compression refuse without reading body',
    () async {
      var reads = 0;
      Stream<List<int>> body() async* {
        reads++;
        yield png;
      }

      for (final status in [301, 302, 303, 307, 308]) {
        await expectLater(
          readPreviewResponse(status, 'image/png', null, -1, body()),
          fails,
        );
      }
      await expectLater(
        readPreviewResponse(200, 'image/png', 'gzip', -1, body()),
        fails,
      );
      await expectLater(
        readPreviewResponse(
          200,
          'image/png',
          null,
          maxPreviewBytes + 1,
          body(),
        ),
        fails,
      );
      expect(reads, 0);
    },
  );
  test(
    'private loopback special-use mapped and reserved gateway addresses refused',
    () async {
      for (final address in [
        '0.0.0.0',
        '10.1.2.3',
        '127.0.0.1',
        '100.64.0.1',
        '169.254.1.2',
        '172.16.0.1',
        '192.168.0.1',
        '192.0.2.1',
        '198.18.0.1',
        '198.51.100.1',
        '203.0.113.1',
        '224.0.0.1',
        '240.0.0.1',
        '::',
        '::1',
        '::ffff:8.8.8.8',
        'fc00::1',
        'fe80::1',
        'ff02::1',
        '2001:db8::1',
        '2002:808:808::1',
        '3fff::1',
      ]) {
        expect(
          publicAddress(InternetAddress(address)),
          isFalse,
          reason: address,
        );
        final url = address.contains(':')
            ? 'https://[$address]'
            : 'https://$address';
        await expectLater(
          PreviewSettings().setGateway(url),
          fails,
          reason: address,
        );
      }
      await expectLater(
        PreviewSettings().setGateway(
          'https://gateway.example',
          lookup: (_) async => [
            InternetAddress('8.8.8.8'),
            InternetAddress('127.0.0.1'),
          ],
        ),
        fails,
      );
    },
  );
  test('gateway changes revalidate and retain host for pinned TLS', () async {
    final settings = PreviewSettings();
    var lookups = 0;
    Future<List<InternetAddress>> lookup(String host) async {
      lookups++;
      return [InternetAddress('8.8.8.8')];
    }

    await settings.setGateway('https://gateway.example', lookup: lookup);
    await settings.setGateway('https://second.example', lookup: lookup);
    expect(lookups, 2);
    final address = await resolveGateway(
      gatewayOrigin(settings.gateway!),
      lookup: lookup,
    );
    expect(address.address, '8.8.8.8');
    expect(settings.gateway, 'https://second.example');
    await expectLater(
      settings.setGateway(
        'https://private.example',
        lookup: (_) async => [InternetAddress('10.0.0.1')],
      ),
      fails,
    );
    expect(settings.gateway, 'https://second.example');
    for (final url in [
      'http://gateway.example',
      'https://user:pass@gateway.example',
      'https://gateway.example:444',
      'https://gateway.example/ipfs',
      'https://gateway.example?x=1',
    ]) {
      expect(() => gatewayOrigin(url), fails);
    }
  });
  test(
    'issuer HTTPS is refused even with consent and a configured gateway',
    () async {
      final transport = FixtureTransport();
      final job = PreviewJob(allowed: () => true, transport: transport);
      for (var i = 0; i < 3; i++) {
        await expectLater(
          job.fetch(
            'https://gateway.example',
            'https://issuer.example/beacon',
            null,
          ),
          fails,
        );
      }
      expect(transport.calls, 0);
    },
  );
  test('CID path is constructed from validated segments only', () {
    expect(ipfsPath('ipfs://$cid/art.png'), ['ipfs', cid, 'art.png']);
    expect(
      ipfsPath(
        'ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3pt5zsp4q2qjdx47zhw27q7by',
      ).length,
      2,
    );
    for (final raw in [
      'ipfs://garbage',
      'ipfs://$cid/../secret',
      'ipfs://$cid/%2e%2e',
      'ipfs://$cid?beacon=1',
      'ipfs://$cid/a?x=1',
      'ipfs://$cid/#x',
      'ipfs://$cid//x',
      'ipfs://user@$cid',
      'ipfs://bafyb',
    ]) {
      expect(() => ipfsPath(raw), fails, reason: raw);
    }
  });
  test('no gateway default; kill switch persists and blocks jobs', () async {
    final settings = PreviewSettings();
    await settings.load();
    expect(settings.gateway, isNull);
    await settings.setNever(true);
    final loaded = PreviewSettings();
    await loaded.load();
    expect(loaded.never, isTrue);
    final transport = FixtureTransport();
    final job = PreviewJob(allowed: () => !loaded.never, transport: transport);
    await expectLater(
      job.fetch('https://gateway.example', 'ipfs://$cid', null),
      fails,
    );
    expect(transport.calls, 0);
  });
  test('locked and cancelled jobs cannot request or decode', () async {
    final transport = FixtureTransport();
    final locked = PreviewJob(allowed: () => false, transport: transport);
    await expectLater(
      locked.fetch('https://gateway.example', 'ipfs://$cid', null),
      fails,
    );
    final cancelled = PreviewJob(allowed: () => true, transport: transport)
      ..cancel();
    await expectLater(
      cancelled.fetch('https://gateway.example', 'ipfs://$cid', null),
      fails,
    );
    expect(transport.calls, 0);
  });
  test(
    'resolver retains original hostname on numeric addresses for TLS',
    () async {
      final addresses = await InternetAddress.lookup('localhost');
      expect(addresses, isNotEmpty);
      expect(addresses.every((a) => a.host == 'localhost'), isTrue);
    },
  );
  for (final fixture in ['wide.png', 'wide.jpg', 'progressive.jpg']) {
    testWidgets('$fixture decodes at detail and thumbnail caps', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final bytes = await File(
          'test/fixtures/previews/$fixture',
        ).readAsBytes();
        final mime = fixture.endsWith('png') ? 'image/png' : 'image/jpeg';
        final info = inspectImage(
          bytes,
          mime,
          sha256.convert(bytes).toString(),
        );
        expect(info.width, 2048);
        final job = PreviewJob(allowed: () => true);
        for (final thumbnail in [false, true]) {
          final image = await job.decode(
            PreviewBytes(bytes, info),
            thumbnail: thumbnail,
          );
          expect(image.width, thumbnail ? 256 : 1024);
          expect(image.height, lessThanOrEqualTo(thumbnail ? 256 : 1024));
          image.dispose();
        }
      });
    });
  }
  test('APNG and other media signatures refused', () {
    final animated = Uint8List.fromList([
      ...png.sublist(0, 33),
      0,
      0,
      0,
      8,
      ...ascii.encode('acTL'),
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      ...png.sublist(33),
    ]);
    expect(() => inspectImage(animated, 'image/png', null), fails);
    for (final content in [
      'GIF89a',
      '<svg/>',
      '%PDF',
      'RIFF0000WEBP',
      '<html/>',
    ]) {
      expect(
        () => inspectImage(
          Uint8List.fromList(ascii.encode(content)),
          'image/png',
          null,
        ),
        fails,
      );
    }
    expect(() => inspectImage(png, 'image/jpeg', null), fails);
  });
}
