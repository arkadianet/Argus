import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../bridge/api.dart' as api;

/// The native session owns the collector, immutable review and verification gate.
/// Keeping this controller alive preserves progress while the camera is closed.
abstract class ColdBackend {
  Future<Map<String, dynamic>> add(String session, String page);
  Future<void> reset(String session);
  Future<Map<String, dynamic>> review(String session, BigInt handle);
  Future<void> sign(String session, BigInt handle);
  Future<List<String>> pages(String session);
  Future<String> verify(String session);
  Future<String> broadcast(String session);
  Future<void> discard(String session);
}

class NativeColdBackend implements ColdBackend {
  const NativeColdBackend();
  @override
  Future<Map<String, dynamic>> add(String session, String page) async =>
      jsonDecode(await api.coldAddPage(session: session, page: page))
          as Map<String, dynamic>;
  @override
  Future<void> reset(String session) => api.coldReset(session: session);
  @override
  Future<Map<String, dynamic>> review(String session, BigInt handle) async =>
      jsonDecode(await api.coldReview(session: session, handleId: handle))
          as Map<String, dynamic>;
  @override
  Future<void> sign(String session, BigInt handle) =>
      api.coldSign(session: session, handleId: handle);
  @override
  Future<List<String>> pages(String session) =>
      api.coldQrPages(session: session, lowDensity: false);
  @override
  Future<String> verify(String session) => api.coldVerify(session: session);
  @override
  Future<String> broadcast(String session) =>
      api.coldBroadcast(session: session);
  @override
  Future<void> discard(String session) => api.coldDiscard(session: session);
}

enum ColdStage { requestQr, scan, review, responseQr, verified, broadcast }

class ColdSigningController extends ChangeNotifier {
  ColdSigningController({
    required this.session,
    required this.hot,
    this.backend = const NativeColdBackend(),
    this.reviewData,
  }) : stage = hot ? ColdStage.requestQr : ColdStage.scan;
  final String session;
  final bool hot;
  final ColdBackend backend;
  ColdStage stage;
  Map<String, dynamic>? reviewData;
  List<String> qrPages = [];
  int received = 0;
  int? total;
  List<int> missing = [];
  String? error;
  String? transactionId;
  BigInt? reviewedHandle;
  bool busy = false;
  bool refused = false;

  Future<void> _run(Future<void> Function() body) async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await body();
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> loadPages() => _run(() async {
    qrPages = await backend.pages(session);
  });
  void scanResponse() {
    if (busy || !hot) return;
    stage = ColdStage.scan;
    notifyListeners();
  }

  void showRequest() {
    if (busy || !hot || stage != ColdStage.scan) return;
    stage = ColdStage.requestQr;
    notifyListeners();
  }

  Future<void> addPage(String page) => _run(() async {
    if (stage != ColdStage.scan || refused) return;
    transactionId = null;
    try {
      final result = await backend.add(session, page);
      received = result['received'] as int;
      total = result['total'] as int?;
      missing = (result['missing'] as List).cast<int>();
    } catch (_) {
      refused = true;
      rethrow;
    }
  });
  bool get complete =>
      total != null && received == total && missing.isEmpty && !refused;
  Future<void> reset() => _run(() async {
    await backend.reset(session);
    received = 0;
    total = null;
    missing = [];
    refused = false;
    transactionId = null;
    reviewedHandle = null;
    if (!hot) {
      reviewData = null;
      qrPages = [];
    }
    stage = ColdStage.scan;
  });
  Future<void> finish(BigInt? handle) => _run(() async {
    if (!complete || stage != ColdStage.scan) return;
    if (!hot && handle == null)
      throw StateError('Unlock the seed wallet before reviewing.');
    try {
      if (hot) {
        transactionId = await backend.verify(session);
        stage = ColdStage.verified;
      } else {
        reviewData = await backend.review(session, handle!);
        reviewedHandle = handle;
        stage = ColdStage.review;
      }
    } catch (_) {
      transactionId = null;
      refused = true;
      rethrow;
    }
  });
  Future<void> sign(BigInt? currentHandle) => _run(() async {
    if (hot || stage != ColdStage.review) return;
    if (currentHandle == null || currentHandle != reviewedHandle) {
      throw StateError(
        'Wallet locked or changed. Reset and review with the selected wallet.',
      );
    }
    await backend.sign(session, currentHandle);
    qrPages = await backend.pages(session);
    stage = ColdStage.responseQr;
  });
  Future<void> broadcast() => _run(() async {
    if (!hot ||
        stage != ColdStage.verified ||
        transactionId == null ||
        refused) {
      throw StateError('Refusing broadcast: no verified response.');
    }
    final id = await backend.broadcast(session);
    if (id != transactionId) throw StateError('Node transaction ID mismatch.');
    stage = ColdStage.broadcast;
  });
}

// In-memory drafts only: no private financial payloads written to preferences.
// Rust expires each session after 30 minutes. Explicit discard starts afresh.
ColdSigningController? pendingColdSigner;
final pendingColdSends = <String, ColdSigningController>{};
