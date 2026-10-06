import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the update flow needs from the phone. Android answers through
/// [AndroidUpdatePlatform]; tests substitute their own.
abstract class UpdatePlatform {
  /// False on hosts that cannot install an APK, where the flow stops at
  /// telling the user a release exists.
  bool get supported;

  /// DER certificates this app is signed with, or null when they cannot be
  /// read. Compared with the signer of a download, never with a constant, so
  /// a rotated key needs no code change.
  Future<List<Uint8List>?> signingCertificates();

  /// The phone's CPU ABIs, most preferred first.
  Future<List<String>> supportedAbis();

  /// App-private folder for downloads, or null when there is none. Not
  /// created; the caller does that when it has something to put there.
  Future<Directory?> downloadDirectory();

  /// Whether Android lets Argus start the installer ("Install unknown apps").
  Future<bool> canRequestInstall();

  /// Opens the system page where the user grants the above, for Argus only.
  Future<bool> openInstallSettings();

  /// Hands [path], a file in [downloadDirectory], to the system installer.
  Future<bool> installApk(String path);
}

/// The Android half lives in `UpdateHandler.kt`.
class AndroidUpdatePlatform implements UpdatePlatform {
  const AndroidUpdatePlatform();

  static const _channel = MethodChannel('com.argus.wallet/update');

  @override
  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<List<Uint8List>?> signingCertificates() async {
    if (!supported) return null;
    try {
      return await _channel.invokeListMethod<Uint8List>('signingCertificates');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<String>> supportedAbis() async {
    if (!supported) return const [];
    try {
      return await _channel.invokeListMethod<String>('supportedAbis') ?? const [];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<Directory?> downloadDirectory() async {
    if (!supported) return null;
    try {
      final path = await _channel.invokeMethod<String>('downloadDirectory');
      return path == null || path.isEmpty ? null : Directory(path);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> canRequestInstall() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('canRequestInstall') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> openInstallSettings() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('openInstallSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> installApk(String path) async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('installApk', {'path': path}) ?? false;
    } catch (_) {
      return false;
    }
  }
}
