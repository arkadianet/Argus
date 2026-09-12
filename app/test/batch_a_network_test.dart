import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/network_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TestNetwork extends NetworkController {
  TestNetwork({required super.configure});
  int requests = 0;
  @override
  Future<NodeProbe> probeNodeDetails(String url) async {
    requests += 2;
    return NodeProbe(
      url: url,
      ok: true,
      height: 100,
      extraIndex: true,
      indexedHeight: 100,
    );
  }
}

class ProbeApi extends RustLibApi {
  int probeCalls = 0;
  @override
  Future<String> crateApiProbeNetwork() async {
    probeCalls++;
    return '{}';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final api = ProbeApi();
  setUpAll(() => RustLib.initMock(api: api));

  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'BATCH A: repeated probes configure only on a change and publish price',
    () async {
      final configurations = <List<String>>[];
      final c = TestNetwork(
        configure: (urls, explorer) async => configurations.add(urls),
      );
      var prices = 0;
      c.priceRefresher = ({bool force = false}) async {
        prices++;
      };
      await c.probe();
      expect(c.requests, c.nodes.length * 2);
      expect(configurations, hasLength(1));
      await c.probe();
      expect(configurations, hasLength(1));
      expect(prices, 2);
      c.explorer = 'https://another.example';
      await c.apply();
      expect(configurations, hasLength(2));
    },
  );
  test('BATCH A: Dart probing does not trigger a second native tour', () async {
    api.probeCalls = 0;
    final c = TestNetwork(configure: (_, _) async {});
    await c.probe();
    expect(api.probeCalls, 0);
  });
  test('BATCH A: failed configuration is retried', () async {
    var calls = 0;
    final c = NetworkController(
      configure: (_, _) async {
        if (++calls == 1) throw StateError('unavailable');
      },
    );
    await expectLater(c.apply(), throwsStateError);
    await c.apply();
    expect(calls, 2);
  });
}
