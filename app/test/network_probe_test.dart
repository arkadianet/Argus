import 'package:argus_wallet/services/network_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('chainHeightFromInfo', () {
    test('prefers fullHeight', () {
      expect(chainHeightFromInfo({'fullHeight': 10, 'headersHeight': 9}), 10);
    });

    test('falls back to headersHeight', () {
      expect(chainHeightFromInfo({'headersHeight': 9}), 9);
    });
  });

  group('indexedHeightFromJson', () {
    test('reads indexedHeight', () {
      expect(indexedHeightFromJson({'indexedHeight': 42}), 42);
    });

    test('reads snake_case', () {
      expect(indexedHeightFromJson({'indexed_height': 7}), 7);
    });
  });

  group('NodeProbe.fromJson', () {
    test('keeps extraIndex', () {
      final p = NodeProbe.fromJson({
        'url': 'https://n.example',
        'ok': true,
        'height': 100,
        'extra_index': true,
        'indexed_height': 99,
      });
      expect(p.extraIndex, isTrue);
      expect(p.indexedHeight, 99);
      expect(p.ok, isTrue);
    });
  });

  group('probeOrder', () {
    test('puts last-good first without dropping the rest', () {
      expect(
        probeOrder(['https://a', 'https://b', 'https://c'], 'https://b'),
        ['https://b', 'https://a', 'https://c'],
      );
    });

    test('keeps the list when last-good is missing', () {
      expect(
        probeOrder(['https://a', 'https://b'], 'https://z'),
        ['https://a', 'https://b'],
      );
    });
  });

  group('describeNode', () {
    test('shows extraIndex when the probe found it', () {
      final node = NodeEntry(url: 'https://n.example');
      final probe = NodeProbe(
        url: node.url,
        ok: true,
        height: 1200,
        extraIndex: true,
        indexedHeight: 1190,
      );
      expect(
        describeNode(node, probe, active: true),
        'In use  ·  extraIndex  ·  #1200',
      );
    });

    test('shows no extraIndex when the probe did not find it', () {
      final node = NodeEntry(url: 'https://n.example');
      final probe = NodeProbe(
        url: node.url,
        ok: true,
        height: 50,
        extraIndex: false,
      );
      expect(
        describeNode(node, probe, active: false),
        'Standby  ·  no extraIndex  ·  #50',
      );
    });

    test('omits extraIndex when the probe is unknown', () {
      final node = NodeEntry(url: 'https://n.example');
      final probe = NodeProbe(
        url: node.url,
        ok: true,
        height: 50,
      );
      expect(
        describeNode(node, probe, active: false),
        'Standby  ·  #50',
      );
    });
  });
}
