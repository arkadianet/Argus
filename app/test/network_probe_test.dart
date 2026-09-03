import 'package:argus_wallet/services/network_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  _nodeChoiceTests();
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
        'In use  ·  extraIndex, lag 10  ·  #1200',
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

// Node choice and discovery
void _nodeChoiceTests() {
  NodeProbe p(String url, {bool ok = true, bool? extra, int? height, int? indexed}) =>
      NodeProbe(url: url, ok: ok, extraIndex: extra, height: height, indexedHeight: indexed);

  group('chooseActive', () {
    test('a reachable chosen node wins over a better automatic one', () {
      final r = chooseActive([p('https://a', extra: true, height: 100, indexed: 100), p('https://b', extra: false)],
          preferred: 'https://b');
      expect(r!.url, 'https://b');
    });

    test('an unreachable chosen node falls back to the best automatic', () {
      final r = chooseActive([p('https://a', extra: true, height: 100, indexed: 90), p('https://b', ok: false)],
          preferred: 'https://b');
      expect(r!.url, 'https://a');
    });

    test('automatic prefers extraIndex, then the smallest lag, then order', () {
      final r = chooseActive([
        p('https://plain', extra: false, height: 100),
        p('https://lagging', extra: true, height: 100, indexed: 50),
        p('https://fresh', extra: true, height: 100, indexed: 99),
        p('https://fresh2', extra: true, height: 100, indexed: 99),
      ]);
      expect(r!.url, 'https://fresh');
    });

    test('nothing reachable gives null', () {
      expect(chooseActive([p('https://a', ok: false)]), isNull);
    });
  });

  group('restApiUrlsFromPeers', () {
    test('keeps distinct https REST urls not already known', () {
      final urls = restApiUrlsFromPeers([
        {'restApiUrl': 'https://ergo-node.eutxo.de'},
        {'restApiUrl': 'https://ergo-node.eutxo.de/'},
        {'restApiUrl': 'http://1.2.3.4:9053'},
        {'restApiUrl': 'https://ergo1.oette.info'},
        {'name': 'no rest'},
        'junk',
      ], known: ['https://ergo1.oette.info']);
      expect(urls, ['https://ergo-node.eutxo.de']);
    });
  });

  group('describeNode', () {
    test('shows lag only when the index is behind', () {
      final n = NodeEntry(url: 'https://a');
      expect(describeNode(n, p('https://a', extra: true, height: 100, indexed: 100), active: true), 'In use  ·  extraIndex  ·  #100');
      expect(describeNode(n, p('https://a', extra: true, height: 100, indexed: 40), active: false, preferred: true),
          'Standby  ·  chosen  ·  extraIndex, lag 60  ·  #100');
    });
  });
}
