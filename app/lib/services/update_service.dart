import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../build_info.dart';
import 'apk_signature.dart';
import 'update_channel.dart';

// Opt-in update check against Argus's GitHub releases, and a download that is
// checked before Android is asked to install it.
//
// What leaves the phone, and when:
//  * With the setting on, once a day when the app starts, and whenever
//    "Check now" is tapped (that works with the setting off, because the tap
//    is the request): one HTTPS GET of [latestReleaseUri]. It carries a
//    generic User-Agent and nothing else of ours: no token, no app version,
//    no device or install identifier. GitHub sees the phone's IP address.
//  * When the user taps "Download and verify": one HTTPS GET of the APK, to
//    github.com and the GitHub CDN it redirects to. Same headers.
// Nothing is sent at any other time, and nothing about the wallet is ever
// part of either request.

/// GitHub's "latest release" for Argus: the newest release that is neither a
/// draft nor a prerelease, which is how Argus publishes.
final latestReleaseUri = Uri.https('api.github.com', '/repos/arkadianet/Argus/releases/latest');

/// GitHub rejects a request with no User-Agent. This is the whole identity.
const updateUserAgent = 'Argus';

/// How often the start-up check may contact GitHub.
const updateCheckInterval = Duration(hours: 24);

/// The release JSON is a few KiB. Notes are capped at 125,000 characters by
/// GitHub, so this bound only stops a server from streaming us something else.
const maxReleaseJsonBytes = 1024 * 1024;

/// Release APKs are 50 to 100 MB. Anything past this is not one of ours.
const maxApkBytes = 300 * 1024 * 1024;

const _apiTimeout = Duration(seconds: 15);
const _connectTimeout = Duration(seconds: 20);

/// No bytes for this long ends a download instead of hanging it.
const _stallTimeout = Duration(seconds: 30);

// ── Versions ─────────────────────────────────────────────────────────

/// A semantic version (semver.org) as Argus tags its releases. Ordering
/// follows the spec: major, minor, patch, then a release outranks any
/// prerelease of it, and prerelease identifiers compare one by one, numbers
/// numerically and words alphabetically, numbers below words. So
/// `1.0.0-alpha.59 < 1.0.0-beta.2 < 1.0.0-beta.10 < 1.0.0-rc.1 < 1.0.0`.
///
/// Two leniencies, because the cost of a mis-ordered tag is a missed update:
/// a leading `v`, and a word run straight into its number (`rc10`) is read
/// as `rc.10`, which otherwise would sort `rc10` before `rc9`.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion._(this.major, this.minor, this.patch, this._pre);

  final int major;
  final int minor;
  final int patch;

  /// Prerelease identifiers: ints, and lower-case words.
  final List<Object> _pre;

  static final _syntax = RegExp(
    r'^[vV]?(\d{1,9})(?:\.(\d{1,9}))?(?:\.(\d{1,9}))?'
    r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
    r'(?:\+[0-9A-Za-z.-]+)?$',
  );
  static final _digits = RegExp(r'^\d{1,9}$');
  static final _wordThenNumber = RegExp(r'^([A-Za-z]+)(\d{1,9})$');

  /// Null when [text] is not a version. Build metadata (`+4061`) is accepted
  /// and ignored, as the spec says to.
  static AppVersion? tryParse(String text) {
    final m = _syntax.firstMatch(text.trim());
    if (m == null) return null;
    final pre = <Object>[];
    final raw = m.group(4);
    if (raw != null) {
      for (final part in raw.split('.')) {
        if (_digits.hasMatch(part)) {
          pre.add(int.parse(part));
          continue;
        }
        final split = _wordThenNumber.firstMatch(part);
        if (split != null) {
          pre
            ..add(split.group(1)!.toLowerCase())
            ..add(int.parse(split.group(2)!));
          continue;
        }
        pre.add(part.toLowerCase());
      }
    }
    return AppVersion._(
      int.parse(m.group(1)!),
      int.parse(m.group(2) ?? '0'),
      int.parse(m.group(3) ?? '0'),
      pre,
    );
  }

  bool get isPrerelease => _pre.isNotEmpty;

  @override
  int compareTo(AppVersion other) {
    var c = major.compareTo(other.major);
    if (c != 0) return c;
    c = minor.compareTo(other.minor);
    if (c != 0) return c;
    c = patch.compareTo(other.patch);
    if (c != 0) return c;
    if (_pre.isEmpty && other._pre.isEmpty) return 0;
    if (_pre.isEmpty) return 1;
    if (other._pre.isEmpty) return -1;
    final shared = math.min(_pre.length, other._pre.length);
    for (var i = 0; i < shared; i++) {
      c = _compareIdentifier(_pre[i], other._pre[i]);
      if (c != 0) return c;
    }
    return _pre.length.compareTo(other._pre.length);
  }

  static int _compareIdentifier(Object a, Object b) {
    if (a is int && b is int) return a.compareTo(b);
    if (a is int) return -1;
    if (b is int) return 1;
    return (a as String).compareTo(b as String).sign;
  }

  bool operator <(AppVersion other) => compareTo(other) < 0;
  bool operator >(AppVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) => other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, Object.hashAll(_pre));

  @override
  String toString() => '$major.$minor.$patch${_pre.isEmpty ? '' : '-${_pre.join('.')}'}';
}

// ── Release JSON ─────────────────────────────────────────────────────

/// Whether [url] is somewhere Argus's own release assets are served from:
/// github.com, or the GitHub content hosts it redirects downloads to. HTTPS
/// only, no credentials, no odd port. The signature check is what protects
/// the install; this keeps the app from being sent to fetch from elsewhere.
bool isTrustedReleaseUrl(Uri url) {
  if (url.scheme != 'https' || url.userInfo.isNotEmpty) return false;
  if (url.hasPort && url.port != 443) return false;
  final host = url.host;
  return host == 'github.com' || host.endsWith('.githubusercontent.com');
}

/// Release notes as the plain text they are shown as. GitHub serves
/// markdown, and Argus shows it as written: no formatting, no links. This
/// also removes what a release body should not carry into a text widget:
/// control characters, and the invisible and direction-changing characters
/// that let a line read differently from what it says. Capped at [maxChars]
/// characters; the releases page has the rest.
String releaseNotesText(String? raw, {int maxChars = 6000}) {
  if (raw == null) return '';
  final out = <int>[];
  for (final c in raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').runes) {
    if (c == 0x0a || c == 0x09 || !_isHiddenOrControl(c)) out.add(c);
  }
  final truncated = out.length > maxChars;
  final text = String.fromCharCodes(truncated ? out.sublist(0, maxChars) : out).trim();
  return truncated ? '$text…' : text;
}

bool _isHiddenOrControl(int c) =>
    c < 0x20 ||
    (c >= 0x7f && c <= 0x9f) ||
    c == 0x061c ||
    (c >= 0x200b && c <= 0x200f) ||
    (c >= 0x2028 && c <= 0x202e) ||
    (c >= 0x2060 && c <= 0x2069) ||
    (c >= 0xd800 && c <= 0xdfff) ||
    c == 0xfeff ||
    (c >= 0xfff9 && c <= 0xfffb) ||
    (c >= 0xe0000 && c <= 0xe007f);

/// One downloadable file of a release.
class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.size, required this.url, this.sha256});

  final String name;
  final int size;
  final Uri url;

  /// Lower-case hex SHA-256 from GitHub's `digest` field, when it lists one.
  /// Releases published before GitHub began computing digests have none.
  final String? sha256;

  /// Null for an asset Argus will not fetch: unfinished, no size, an address
  /// off GitHub, or a digest that is not the SHA-256 it claims to be.
  static ReleaseAsset? tryParse(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final size = json['size'];
    final url = json['browser_download_url'];
    final state = json['state'];
    if (name is! String || size is! int || size <= 0 || url is! String) return null;
    if (state != null && state != 'uploaded') return null;
    final uri = Uri.tryParse(url);
    if (uri == null || !isTrustedReleaseUrl(uri)) return null;
    String? digest;
    final claimed = json['digest'];
    if (claimed is String && claimed.toLowerCase().startsWith('sha256:')) {
      digest = normalizeSha256(claimed.substring(7));
      if (digest == null) return null;
    }
    return ReleaseAsset(name: name, size: size, url: uri, sha256: digest);
  }

  Map<String, Object?> toJson() => {
        'name': name,
        'size': size,
        'digest': sha256 == null ? null : 'sha256:$sha256',
        'browser_download_url': url.toString(),
        'state': 'uploaded',
      };
}

/// A published release, reduced to what the update flow uses.
class ReleaseInfo {
  const ReleaseInfo({required this.version, required this.notes, required this.assets, this.publishedAt});

  final AppVersion version;

  /// Plain text; see [releaseNotesText].
  final String notes;
  final DateTime? publishedAt;
  final List<ReleaseAsset> assets;

  /// From GitHub's release JSON, or the copy [toJson] stores. Throws
  /// [FormatException] for anything that is not a published release with a
  /// version Argus can order.
  factory ReleaseInfo.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('Not a release object.');
    if (json['draft'] == true || json['prerelease'] == true) {
      throw const FormatException('Not a published release.');
    }
    final tag = json['tag_name'];
    final version = tag is String ? AppVersion.tryParse(tag) : null;
    if (version == null) throw const FormatException('No usable version.');
    final body = json['body'];
    final published = json['published_at'];
    final assets = json['assets'];
    return ReleaseInfo(
      version: version,
      notes: releaseNotesText(body is String ? body : null),
      publishedAt: published is String ? DateTime.tryParse(published)?.toUtc() : null,
      assets: [
        if (assets is List)
          for (final a in assets) ?ReleaseAsset.tryParse(a),
      ],
    );
  }

  Map<String, Object?> toJson() => {
        'tag_name': version.toString(),
        'body': notes,
        'published_at': publishedAt?.toIso8601String(),
        'assets': [for (final a in assets) a.toJson()],
      };
}

/// The APK for this phone: the build made for its CPU when the release has
/// one, otherwise the universal APK. Split builds carry a higher versionCode
/// than the universal one, so a phone that installed a split must keep
/// getting splits; Android refuses to go back down.
ReleaseAsset? pickAsset(List<ReleaseAsset> assets, List<String> supportedAbis) {
  ReleaseAsset? named(String variant) {
    for (final a in assets) {
      final name = a.name.toLowerCase();
      if (name.startsWith('argus-') && name.endsWith('-$variant.apk')) return a;
    }
    return null;
  }

  // The first of the phone's ABIs that Argus ships a build for. If the
  // release lacks that build, fall back to universal rather than to a build
  // for a lesser ABI that would run under translation.
  for (final abi in supportedAbis) {
    if (abi == 'arm64-v8a' || abi == 'x86_64') {
      final split = named(abi);
      if (split != null) return split;
      break;
    }
  }
  return named('universal');
}

String formatDownloadSize(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

// ── Network ──────────────────────────────────────────────────────────

/// A failure with something the user can be told.
class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _Cancelled implements Exception {
  const _Cancelled();
}

UpdateException _networkFailure(Object e) => e is TimeoutException
    ? const UpdateException('GitHub did not answer in time.')
    : const UpdateException('Could not reach GitHub. Check your connection.');

/// The latest release. The caller owns [client] and closes it.
Future<ReleaseInfo> fetchLatestRelease(http.Client client, {Uri? endpoint}) async {
  final request = http.Request('GET', endpoint ?? latestReleaseUri)..headers['user-agent'] = updateUserAgent;
  final Uint8List body;
  try {
    final response = await client.send(request).timeout(_apiTimeout);
    if (response.statusCode == 403 || response.statusCode == 429) {
      throw const UpdateException('GitHub is limiting requests from this network. Try again later.');
    }
    if (response.statusCode == 404) throw const UpdateException('GitHub has no release to offer.');
    if (response.statusCode != 200) {
      throw UpdateException('GitHub answered with an error (${response.statusCode}).');
    }
    body = await _readCapped(response.stream, maxReleaseJsonBytes).timeout(_apiTimeout);
  } on UpdateException {
    rethrow;
  } catch (e) {
    throw _networkFailure(e);
  }
  try {
    return ReleaseInfo.fromJson(jsonDecode(utf8.decode(body)));
  } on FormatException {
    throw const UpdateException('GitHub\'s answer was not understood.');
  }
}

Future<Uint8List> _readCapped(Stream<List<int>> stream, int cap) async {
  final out = BytesBuilder();
  await for (final chunk in stream) {
    out.add(chunk);
    if (out.length > cap) throw const UpdateException('GitHub\'s answer was larger than expected.');
  }
  return out.takeBytes();
}

class DownloadedApk {
  const DownloadedApk({required this.sha256, required this.bytes});

  /// Lower-case hex SHA-256 of what was written, computed as it arrived.
  final String sha256;
  final int bytes;
}

/// Streams [asset] into [into], hashing as it goes. Stops, and leaves no file
/// behind, when the server sends more than the size GitHub lists (or
/// [maxBytes]), sends less, stalls, redirects off GitHub, or [isCancelled]
/// turns true. The caller owns [client]; closing it is how a cancel reaches
/// a request that is waiting on the network.
Future<DownloadedApk> downloadApk({
  required http.Client client,
  required ReleaseAsset asset,
  required File into,
  required bool Function() isCancelled,
  void Function(int received)? onProgress,
  int maxBytes = maxApkBytes,
  Duration stallTimeout = _stallTimeout,
}) async {
  if (!isTrustedReleaseUrl(asset.url)) throw const UpdateException('The download address is not on GitHub.');
  if (asset.size > maxBytes) throw const UpdateException('The download is larger than Argus will accept.');
  final limit = asset.size;

  final request = http.Request('GET', asset.url)..headers['user-agent'] = updateUserAgent;
  final http.StreamedResponse response;
  try {
    response = await client.send(request).timeout(_connectTimeout);
  } catch (e) {
    if (isCancelled()) throw const _Cancelled();
    throw _networkFailure(e);
  }
  if (response.statusCode != 200) {
    throw UpdateException('GitHub answered with an error (${response.statusCode}).');
  }
  // Where the redirects ended up. IOClient reports it; a client that does not
  // is no worse off than before this check.
  if (response case http.BaseResponseWithUrl(:final url) when !isTrustedReleaseUrl(url)) {
    throw const UpdateException('The download was redirected away from GitHub.');
  }

  // The size is judged on what arrives, not on a Content-Length header:
  // that one describes the compressed body if a server gzips it.
  final digest = _DigestCapture();
  final hasher = sha256.startChunkedConversion(digest);
  final RandomAccessFile file;
  try {
    file = await into.open(mode: FileMode.write);
  } on FileSystemException {
    throw const UpdateException('Argus could not save the download. Is the phone out of storage?');
  }
  var received = 0;
  try {
    await for (final chunk in response.stream.timeout(stallTimeout)) {
      if (isCancelled()) throw const _Cancelled();
      received += chunk.length;
      if (received > limit) throw const UpdateException('The download is larger than GitHub lists it, so it was stopped.');
      hasher.add(chunk);
      await file.writeFrom(chunk);
      onProgress?.call(received);
    }
    if (isCancelled()) throw const _Cancelled();
    if (received != limit) throw const UpdateException('The download ended early.');
    hasher.close();
    await file.flush();
    await file.close();
  } on _Cancelled {
    await _discard(file, into);
    rethrow;
  } on UpdateException {
    await _discard(file, into);
    rethrow;
  } catch (e) {
    await _discard(file, into);
    if (isCancelled()) throw const _Cancelled();
    if (e is FileSystemException) throw const UpdateException('Argus could not save the download. Is the phone out of storage?');
    throw _networkFailure(e);
  }
  return DownloadedApk(sha256: digest.value.toString(), bytes: received);
}

/// Receives the one digest a chunked hash produces.
class _DigestCapture implements Sink<Digest> {
  late final Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

Future<void> _discard(RandomAccessFile open, File file) async {
  try {
    await open.close();
  } catch (_) {}
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {}
}

// ── Verification ─────────────────────────────────────────────────────

enum ApkVerdict {
  /// Signed by the key this app is signed with, and (when GitHub lists one)
  /// matching its checksum.
  verified,

  /// The bytes are not what GitHub says it published.
  checksumMismatch,

  /// Signed with a different key than this app. The case to refuse loudly.
  wrongSigner,

  /// No readable v2 or v3 signature, so there is nothing to compare.
  unreadable,

  /// This app's own signing key could not be read, so there is nothing to
  /// compare against.
  appKeyUnknown,
}

class ApkVerification {
  const ApkVerification(this.verdict, {this.signerSha256});

  final ApkVerdict verdict;

  /// Hex SHA-256 of the certificate the APK is signed with, when it was read.
  final String? signerSha256;

  bool get ok => verdict == ApkVerdict.verified;
}

/// Checks a downloaded APK. [expectedSha256] is GitHub's checksum for the
/// file (null when it lists none) and [fileSha256] what arrived. A mismatch
/// on either is a rejection. The APK's declared signer must be one of
/// [appCertificates], this app's own signing certificates as Android reports
/// them.
///
/// The comparison is with the key the running app has now. A release signed
/// with a rotated key (a v3 proof-of-rotation chain from the current one)
/// differs from it and is refused here, with the same words as a foreign key;
/// the releases page still has the file for someone who knows the rotation
/// is real. Supporting it would mean walking the lineage in the v3 block.
Future<ApkVerification> verifyApk({
  required File file,
  required String? fileSha256,
  required String? expectedSha256,
  required List<Uint8List>? appCertificates,
}) async {
  if (expectedSha256 != null && expectedSha256 != fileSha256) {
    return const ApkVerification(ApkVerdict.checksumMismatch);
  }
  if (appCertificates == null || appCertificates.isEmpty) {
    return const ApkVerification(ApkVerdict.appKeyUnknown);
  }
  final ApkSigners signers;
  try {
    signers = await readApkSignersFromFile(file);
  } catch (_) {
    return const ApkVerification(ApkVerdict.unreadable);
  }
  final signer = certificateSha256(signers.first);
  final own = {for (final c in appCertificates) certificateSha256(c)};
  return ApkVerification(
    own.contains(signer) ? ApkVerdict.verified : ApkVerdict.wrongSigner,
    signerSha256: signer,
  );
}

String _rejection(ApkVerdict verdict) => switch (verdict) {
      ApkVerdict.wrongSigner =>
        'This download is not signed by the same key as this app, so it must not be installed. It has been deleted.',
      ApkVerdict.checksumMismatch =>
        'This download does not match the SHA-256 checksum GitHub lists for it, so it may be damaged or tampered with. It has been deleted.',
      ApkVerdict.unreadable =>
        'The signing key of this download could not be read, so it was not offered for install. It has been deleted.',
      ApkVerdict.appKeyUnknown =>
        'Argus could not read its own signing key, so it cannot check this download. It has been deleted.',
      ApkVerdict.verified => '',
    };

// ── Service ──────────────────────────────────────────────────────────

enum UpdateStage {
  idle,
  downloading,
  verifying,

  /// A file whose signer is this app's key is in the cache, ready to install.
  verified,

  /// The file failed a check and was deleted. [UpdateService.stageMessage]
  /// says which.
  rejected,

  /// The download did not complete (network, size, storage). Nothing to fear.
  failed,
}

/// The update check and the verified download, with their settings.
class UpdateService extends ChangeNotifier {
  UpdateService({
    UpdatePlatform? platform,
    http.Client Function()? clientFactory,
    DateTime Function()? clock,
    AppVersion? current,
    Uri? endpoint,
  })  : _platform = platform ?? const AndroidUpdatePlatform(),
        _newClient = clientFactory ?? http.Client.new,
        _now = clock ?? DateTime.now,
        _current = current ?? AppVersion.tryParse(appVersion),
        _endpoint = endpoint ?? latestReleaseUri;

  static const _enabledKey = 'argus_update_check';
  static const _lastCheckKey = 'argus_update_last_check';
  static const _latestKey = 'argus_update_latest';
  static const _dismissedKey = 'argus_update_dismissed';

  final UpdatePlatform _platform;
  final http.Client Function() _newClient;
  final DateTime Function() _now;
  final AppVersion? _current;
  final Uri _endpoint;

  /// App-wide: ask GitHub for the latest release once a day at start-up.
  /// Off until the user turns it on.
  bool enabled = false;

  /// A release newer than the running app, as of the last check.
  ReleaseInfo? available;

  /// When GitHub was last asked, by either kind of check.
  DateTime? lastChecked;
  bool checking = false;

  /// Why the last check failed; null when it succeeded.
  String? checkError;

  UpdateStage stage = UpdateStage.idle;
  int downloadedBytes = 0;
  int? totalBytes;

  /// What went wrong, or what to do next, for [stage].
  String? stageMessage;

  /// Hex SHA-256 of the signing certificate of the verified download.
  String? verifiedSigner;

  bool loaded = false;

  Future<void>? _loading;
  Future<void>? _checking;
  String? _dismissed;
  List<String> _abis = const [];
  http.Client? _client;
  bool _cancelled = false;
  File? _verifiedFile;
  int _verifiedBytes = 0;
  bool _installing = false;
  final _progress = Stopwatch();

  bool get busy => stage == UpdateStage.downloading || stage == UpdateStage.verifying;

  /// The settings banner shows while there is an update the user has not
  /// waved away. About shows it regardless.
  bool get noticeVisible => available != null && _dismissed != available!.version.toString();

  /// The APK this phone would download, or null when the release has none.
  ReleaseAsset? get assetForDevice => available == null ? null : pickAsset(available!.assets, _abis);

  /// False on hosts that cannot install an APK; the UI then only reports the
  /// release and points at the releases page.
  bool get installSupported => _platform.supported;

  bool get _dueForAutomaticCheck {
    final last = lastChecked;
    if (last == null) return true;
    final now = _now();
    // A clock that moved backwards must not hold the check off for days.
    return now.isBefore(last) || now.difference(last) >= updateCheckInterval;
  }

  /// Reads the saved settings. Safe to call from anywhere, any number of
  /// times; unreadable preferences leave the defaults, which are off.
  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool(_enabledKey) ?? false;
      final at = prefs.getInt(_lastCheckKey);
      lastChecked = at == null ? null : DateTime.fromMillisecondsSinceEpoch(at);
      _dismissed = prefs.getString(_dismissedKey);
      final stored = prefs.getString(_latestKey);
      if (stored != null) {
        try {
          final release = ReleaseInfo.fromJson(jsonDecode(stored));
          if (_isNewer(release.version)) {
            available = release;
          } else {
            // The app has caught up since: the saved notice is stale.
            await prefs.remove(_latestKey);
          }
        } catch (_) {
          await prefs.remove(_latestKey);
        }
      }
    } catch (_) {}
    // The saved settings are enough to show a notice; the questions for the
    // phone below go through a channel and may take a moment.
    notifyListeners();
    _abis = await _platform.supportedAbis();
    // A download does not outlive the process. If an installer is still
    // reading one, Android already holds it open.
    await _removeDownloads();
    loaded = true;
    notifyListeners();
  }

  bool _isNewer(AppVersion v) => _current != null && v > _current;

  Future<void> _store(Future<Object?> Function(SharedPreferences prefs) write) async {
    try {
      await write(await SharedPreferences.getInstance());
    } catch (_) {}
  }

  /// Turns the start-up check on or off. Saved before it takes effect, so a
  /// failed write cannot leave the app checking after it was switched off;
  /// false means the setting did not change.
  Future<bool> setEnabled(bool value) async {
    await ensureLoaded();
    if (value == enabled) return true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setBool(_enabledKey, value)) return false;
    } catch (_) {
      return false;
    }
    enabled = value;
    notifyListeners();
    return true;
  }

  /// The start-up check: does nothing unless the setting is on and the last
  /// check was more than a day ago.
  Future<void> checkOnStart() async {
    await ensureLoaded();
    if (!enabled || !_dueForAutomaticCheck) return;
    await _check();
  }

  /// An explicit check. Works with the setting off and ignores the daily
  /// limit: the tap is the request.
  Future<void> checkNow() async {
    await ensureLoaded();
    await _check();
  }

  Future<void> _check() => _checking ??= _runCheck().whenComplete(() => _checking = null);

  Future<void> _runCheck() async {
    if (busy) return;
    checking = true;
    checkError = null;
    notifyListeners();
    // Stamped before the request: one that fails or times out may still have
    // reached GitHub, and "at most once a day" counts attempts.
    final at = _now();
    lastChecked = at;
    await _store((p) => p.setInt(_lastCheckKey, at.millisecondsSinceEpoch));
    http.Client? client;
    try {
      client = _newClient();
      await _adopt(await fetchLatestRelease(client, endpoint: _endpoint));
    } on UpdateException catch (e) {
      checkError = e.message;
    } catch (_) {
      checkError = 'The update check failed.';
    } finally {
      client?.close();
      checking = false;
      notifyListeners();
    }
  }

  Future<void> _adopt(ReleaseInfo release) async {
    // A download under way belongs to the release it started with; the next
    // check will pick up anything newer.
    if (busy) return;
    if (!_isNewer(release.version)) {
      available = null;
      await _store((p) => p.remove(_latestKey));
      if (stage != UpdateStage.idle) await _resetDownload();
      return;
    }
    // A file checked for an older release is of no use for this one.
    if (available?.version != release.version && stage != UpdateStage.idle) await _resetDownload();
    available = release;
    await _store((p) => p.setString(_latestKey, jsonEncode(release.toJson())));
  }

  /// Hides the settings banner for this version. A newer release shows it
  /// again.
  Future<void> dismissNotice() async {
    final release = available;
    if (release == null) return;
    _dismissed = release.version.toString();
    notifyListeners();
    await _store((p) => p.setString(_dismissedKey, _dismissed!));
  }

  /// Hex SHA-256 of each certificate this app is signed with, for display;
  /// null when Android will not say.
  Future<List<String>?> ownSigningFingerprints() async {
    final certs = await _platform.signingCertificates();
    if (certs == null || certs.isEmpty) return null;
    return [for (final c in certs) certificateSha256(c)];
  }

  // ── Download ─────────────────────────────────────────────────────────

  /// Downloads the APK for this phone, then checks it against GitHub's
  /// checksum and against this app's own signing key. Only a file that passes
  /// becomes [UpdateStage.verified]; any other is deleted.
  Future<void> downloadAndVerify() async {
    // The phone's ABIs decide which file this is.
    await ensureLoaded();
    final release = available;
    final asset = assetForDevice;
    if (busy) return;
    if (release == null || asset == null) {
      _setStage(UpdateStage.failed, 'This release has no APK for your phone. The releases page has the files.');
      return;
    }
    await _resetDownload();
    _cancelled = false;
    downloadedBytes = 0;
    totalBytes = asset.size;
    _progress
      ..reset()
      ..start();
    _setStage(UpdateStage.downloading, null);

    http.Client? client;
    File? part;
    try {
      client = _client = _newClient();
      final dir = await _platform.downloadDirectory();
      if (dir == null) throw const UpdateException('This device cannot keep a download.');
      await dir.create(recursive: true);
      // A name of ours, never one from the response: the file is written
      // as `.part` and only a verified one gets the `.apk` name the installer
      // hand-off accepts.
      part = File('${dir.path}/argus-update.apk.part');
      final result = await downloadApk(
        client: client,
        asset: asset,
        into: part,
        isCancelled: () => _cancelled,
        onProgress: _onProgress,
      );
      downloadedBytes = result.bytes;
      _setStage(UpdateStage.verifying, null);
      final verdict = await verifyApk(
        file: part,
        fileSha256: result.sha256,
        expectedSha256: asset.sha256,
        appCertificates: await _platform.signingCertificates(),
      );
      if (!verdict.ok) {
        await _delete(part);
        _setStage(UpdateStage.rejected, _rejection(verdict.verdict));
        return;
      }
      final ready = await part.rename('${dir.path}/argus-update.apk');
      _verifiedFile = ready;
      _verifiedBytes = result.bytes;
      verifiedSigner = verdict.signerSha256;
      _setStage(UpdateStage.verified, null);
    } on _Cancelled {
      await _delete(part);
      _setStage(UpdateStage.idle, 'Download cancelled.');
    } on UpdateException catch (e) {
      await _delete(part);
      _setStage(UpdateStage.failed, e.message);
    } catch (_) {
      await _delete(part);
      _setStage(UpdateStage.failed, 'The download failed.');
    } finally {
      client?.close();
      _client = null;
    }
  }

  void _onProgress(int received) {
    downloadedBytes = received;
    // A chunk arrives every few milliseconds; a repaint per chunk buys nothing.
    if (_progress.elapsedMilliseconds >= 100) {
      _progress.reset();
      notifyListeners();
    }
  }

  /// Stops a download in progress and removes what it wrote.
  void cancelDownload() {
    if (stage != UpdateStage.downloading) return;
    _cancelled = true;
    _client?.close();
  }

  /// Hands the verified APK to Android's installer. The signer is read once
  /// more first: the file has sat in the cache since it was checked.
  Future<void> install() async {
    final file = _verifiedFile;
    if (stage != UpdateStage.verified || file == null || _installing) return;
    _installing = true;
    try {
      await _install(file);
    } finally {
      _installing = false;
    }
  }

  Future<void> _install(File file) async {
    final again = await _stillVerified(file);
    if (!again.ok) {
      await _resetDownload();
      _setStage(UpdateStage.rejected, _rejection(again.verdict));
      return;
    }
    if (!await _platform.canRequestInstall()) {
      stageMessage = 'Android needs your permission first. Allow Argus to install apps on the next screen, then tap Install again.';
      notifyListeners();
      await _platform.openInstallSettings();
      return;
    }
    if (!await _platform.installApk(file.path)) {
      stageMessage = 'Android could not open its installer. The releases page has the file.';
      notifyListeners();
    }
  }

  Future<ApkVerification> _stillVerified(File file) async {
    try {
      if (await file.length() != _verifiedBytes) return const ApkVerification(ApkVerdict.unreadable);
    } catch (_) {
      return const ApkVerification(ApkVerdict.unreadable);
    }
    return verifyApk(
      file: file,
      fileSha256: null,
      expectedSha256: null,
      appCertificates: await _platform.signingCertificates(),
    );
  }

  void _setStage(UpdateStage next, String? message) {
    stage = next;
    stageMessage = message;
    notifyListeners();
  }

  /// Deletes any download and returns to [UpdateStage.idle].
  Future<void> _resetDownload() async {
    final dir = await _platform.downloadDirectory();
    await _removeFiles(dir);
    _verifiedFile = null;
    _verifiedBytes = 0;
    verifiedSigner = null;
    if (stage != UpdateStage.idle) _setStage(UpdateStage.idle, null);
  }

  Future<void> _removeDownloads() async => _removeFiles(await _platform.downloadDirectory());

  Future<void> _removeFiles(Directory? dir) async {
    try {
      if (dir != null && await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> _delete(File? file) async {
    try {
      if (file != null && await file.exists()) await file.delete();
    } catch (_) {}
  }
}

final updateService = UpdateService();
