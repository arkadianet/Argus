import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:argus_wallet/services/update_channel.dart';
import 'package:argus_wallet/services/update_service.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// A phone that answers the update flow's questions from fields.
class FakePlatform implements UpdatePlatform {
  FakePlatform(this.dir);

  Directory? dir;

  @override
  bool supported = true;

  List<Uint8List>? certificates;
  List<String> abis = const ['arm64-v8a', 'armeabi-v7a', 'armeabi'];
  bool allowInstall = true;
  bool installerOpens = true;
  final installed = <String>[];
  int settingsOpened = 0;

  @override
  Future<List<Uint8List>?> signingCertificates() async => certificates;

  @override
  Future<List<String>> supportedAbis() async => abis;

  @override
  Future<Directory?> downloadDirectory() async => dir;

  @override
  Future<bool> canRequestInstall() async => allowInstall;

  @override
  Future<bool> openInstallSettings() async {
    settingsOpened++;
    return true;
  }

  @override
  Future<bool> installApk(String path) async {
    installed.add(path);
    return installerOpens;
  }
}

/// A streamed response that also reports where redirects ended, as the real
/// client's does.
class UrlResponse extends http.StreamedResponse implements http.BaseResponseWithUrl {
  UrlResponse(super.stream, super.statusCode, {required this.url, super.contentLength});

  @override
  final Uri url;
}

/// What the fake serves for one address.
class Served {
  Served(this.body, {this.status = 200, this.finalUrl, this.contentLength});

  /// Called per request, so a test can hand out a stream it controls.
  final Stream<List<int>> Function() body;
  final int status;

  /// Where the "redirects" ended; the requested address when null.
  final Uri? finalUrl;
  final int? contentLength;

  static Served bytes(List<int> data, {int chunk = 97, int status = 200, Uri? finalUrl, int? contentLength}) => Served(
        () => Stream.fromIterable([
          for (var i = 0; i < data.length; i += chunk) data.sublist(i, i + chunk > data.length ? data.length : i + chunk),
        ]),
        status: status,
        finalUrl: finalUrl,
        contentLength: contentLength,
      );
}

/// Stands in for api.github.com and the download host, and records what was
/// asked of it.
class FakeGitHub {
  final requests = <http.BaseRequest>[];
  final files = <String, Served>{};

  Object? releaseBody;
  List<int>? rawReleaseBody;
  int releaseStatus = 200;

  /// Thrown by `send` before anything is answered.
  Object? failure;

  /// Holds the API answer until completed.
  Completer<void>? releaseGate;

  int clientsCreated = 0;
  int clientsClosed = 0;

  http.Client create() {
    clientsCreated++;
    return _Client(this);
  }

  Iterable<http.BaseRequest> get apiRequests => requests.where((r) => r.url == latestReleaseUri);
  Iterable<http.BaseRequest> get fileRequests => requests.where((r) => r.url != latestReleaseUri);
}

class _Client extends http.BaseClient {
  _Client(this.gh);

  final FakeGitHub gh;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (closed) throw http.ClientException('closed', request.url);
    gh.requests.add(request);
    final failure = gh.failure;
    if (failure != null) throw failure;
    if (request.url == latestReleaseUri) {
      await gh.releaseGate?.future;
      final body = gh.rawReleaseBody ?? utf8.encode(jsonEncode(gh.releaseBody));
      return UrlResponse(Stream.value(body), gh.releaseStatus, url: request.url, contentLength: body.length);
    }
    final served = gh.files[request.url.toString()];
    if (served == null) return UrlResponse(const Stream.empty(), 404, url: request.url);
    return UrlResponse(
      served.body(),
      served.status,
      url: served.finalUrl ?? request.url,
      contentLength: served.contentLength,
    );
  }

  @override
  void close() {
    closed = true;
    gh.clientsClosed++;
  }
}

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

String assetUrl(String name) => 'https://github.com/arkadianet/Argus/releases/download/v1.0.0-beta.2/$name';

Map<String, Object?> assetJson(String name, List<int> bytes, {bool digest = true, String? digestOverride, int? size}) => {
      'name': name,
      'size': size ?? bytes.length,
      'state': 'uploaded',
      'digest': digestOverride ?? (digest ? 'sha256:${sha256Hex(bytes)}' : null),
      'browser_download_url': assetUrl(name),
    };

Map<String, Object?> releaseJson(
  String tag, {
  List<Map<String, Object?>> assets = const [],
  String body = 'What is new.',
  bool draft = false,
  bool prerelease = false,
}) =>
    {
      'tag_name': tag,
      'name': tag,
      'body': body,
      'draft': draft,
      'prerelease': prerelease,
      'published_at': '2026-10-20T10:00:00Z',
      'assets': assets,
    };
