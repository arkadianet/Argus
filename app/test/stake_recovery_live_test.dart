// Opt-in integration check: real Dart HTTP/cache orchestration plus the actual
// Rust boundary via its test executable. No Android/iOS/shared-library build.
import 'dart:convert';
import 'dart:io';

import 'package:argus_wallet/services/stake_recovery_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RustGateway implements StakeRecoveryGateway {
  _RustGateway(this.executable, this.directory, this.nodeUrl);
  final String executable;
  final Directory directory;
  @override
  final String? nodeUrl;
  @override
  String get explorerBase => 'https://api.ergoplatform.com';
  @override
  String get network => 'mainnet';
  @override
  String get walletId => 'live-verification-candidates';

  String call(Map<String, String> request) {
    final input = File('${directory.path}/request.json')
      ..writeAsStringSync(jsonEncode(request));
    final output = File('${directory.path}/response.json');
    if (output.existsSync()) output.deleteSync();
    final result = Process.runSync(
      executable,
      ['api_stake_recovery_impl::json_bridge_cli', '--exact', '--ignored'],
      environment: {
        'ARGUS_STAKE_BRIDGE_REQUEST': input.path,
        'ARGUS_STAKE_BRIDGE_RESPONSE': output.path,
      },
    );
    if (result.exitCode != 0)
      throw StateError('${result.stdout}\n${result.stderr}');
    return output.readAsStringSync();
  }

  @override
  String contracts() => call({'method': 'contracts'});
  @override
  String state(String pool, String box) =>
      call({'method': 'state', 'pool': pool, 'box': box});
  @override
  String positions(String pool, String boxes, String keys, String stateBox) =>
      call({
        'method': 'positions',
        'pool': pool,
        'boxes': boxes,
        'keys': keys,
        'state': stateBox,
      });
}

void main() {
  final executable = Platform.environment['ARGUS_STAKE_TEST_EXECUTABLE'];
  final evidence = Platform.environment['ARGUS_STAKE_EVIDENCE'];
  test(
    'real mainnet discovery, explorer-only fallback and cache revalidation',
    () async {
      final dir = Directory.systemTemp.createTempSync('argus-stake-live-');
      try {
        // These are chain fixture candidates, not a claim that a real wallet owns
        // the keys. They let every returned position exercise the Rust validators.
        final keys = <String>{
          for (final pool in ['ergopad', 'paideia'])
            ...(jsonDecode(File('$evidence/$pool-keys.json').readAsStringSync())
                    as List)
                .cast<String>(),
        };
        for (final node in [
          'https://ergo-node.eutxo.de',
          'https://ergo-node.zoomout.io',
          null,
        ]) {
          SharedPreferences.setMockInitialValues({});
          final service = StakeRecoveryService(
            gateway: _RustGateway(executable!, dir, node),
          );
          await service.refresh(keys);
          for (final result in service.results) {
            // ignore: avoid_print
            print(
              'LIVE ${node ?? 'explorer-only'} ${result.pool.name}: ${result.status.name}, '
              '${result.scanned} scanned, ${result.positions.length} matched, '
              '${result.positions.where((p) => p.eligible == true).length} eligible, '
              '${result.elapsed.inMilliseconds}ms; source=${result.source}; '
              'state=${result.stateError ?? 'ok'}; message=${result.message}',
            );
            expect(result.status, isNot(StakeScanStatus.scanning));
            if (node != null) {
              expect(result.status, StakeScanStatus.complete);
              expect(result.positions, isNotEmpty);
              expect(result.stateError, isNull);
            }
          }
          // One candidate shared with a completed scan exercises the positive
          // cache via exactly one unspent lookup in the pool owning that key.
          if (node != null) {
            final key = service.results.first.positions.first.keyId;
            await service.refresh({key});
            final result = service.results.first;
            expect(result.scanned, 0);
            expect(result.positions.single.keyId, key);
            expect(result.status, StakeScanStatus.complete);
            // ignore: avoid_print
            print(
              'LIVE $node Ergopad cached key: ${result.scanned} scanned, '
              '${result.positions.length} revalidated, ${result.elapsed.inMilliseconds}ms',
            );
          }
          service.dispose();
        }
      } finally {
        dir.deleteSync(recursive: true);
      }
    },
    skip: executable == null || evidence == null
        ? 'Set ARGUS_STAKE_TEST_EXECUTABLE and ARGUS_STAKE_EVIDENCE to run real HTTP'
        : false,
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
