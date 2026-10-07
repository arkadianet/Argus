import 'dart:convert';
import 'dart:io';

import 'package:argus_wallet/services/update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/update_fakes.dart';

/// What actually crosses the wire, seen by a real server on the loopback
/// interface through the real HTTP client. The other tests stop at the
/// request object; this one checks what dart:io adds underneath it, because
/// "nothing identifying is sent" has to hold for the bytes, not the intent.
void main() {
  test('the update check is one plain GET that names only "Argus"', () async {
    SharedPreferences.setMockInitialValues({});
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = <HttpRequest>[];
    final headers = <String, List<String>>{};
    server.listen((request) {
      seen.add(request);
      request.headers.forEach((name, values) => headers[name] = values);
      request.response
        ..statusCode = 200
        ..write(jsonEncode(releaseJson('v1.0.0-beta.2')))
        ..close();
    });

    final svc = UpdateService(
      platform: FakePlatform(null),
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/repos/arkadianet/Argus/releases/latest'),
      current: AppVersion.tryParse('1.0.0-beta.1'),
    );
    await svc.checkNow();

    expect(svc.checkError, isNull);
    expect(svc.available?.version.toString(), '1.0.0-beta.2');
    expect(seen, hasLength(1));
    expect(seen.single.method, 'GET');
    expect(seen.single.uri.toString(), '/repos/arkadianet/Argus/releases/latest');
    expect(headers['user-agent'], ['Argus']);

    // Every header on the wire, by name. These are the transport's own: the
    // address asked for, and willingness to take gzip. Anything else added
    // later (a token, an install id, a version, a language) fails here.
    expect(headers.keys.toSet().difference({'host', 'user-agent', 'accept-encoding'}), isEmpty, reason: 'unexpected headers: ${headers.keys}');
    expect(headers.containsKey('cookie'), isFalse);
    expect(headers.containsKey('authorization'), isFalse);
    expect(headers.containsKey('referer'), isFalse);
    expect(seen.single.contentLength, anyOf(0, -1), reason: 'no body');
  });

  test('a GitHub that answers with an error is reported without leaking the body into the message', () async {
    SharedPreferences.setMockInitialValues({});
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response
        ..statusCode = 403
        ..write('{"message":"API rate limit exceeded for 203.0.113.9."}')
        ..close();
    });
    final svc = UpdateService(
      platform: FakePlatform(null),
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/x'),
    );
    await svc.checkNow();
    expect(svc.checkError, contains('limiting'));
    expect(svc.checkError, isNot(contains('203.0.113.9')));
  });
}
