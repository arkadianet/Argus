import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../services/network_controller.dart';
import '../../services/privacy_service.dart';
import '../../services/preview/policy.dart';
import '../../services/preview/preview_service.dart';
import '../../services/wallet_service.dart';
import '../../theme/argus_theme.dart';
import '../settings/preview_settings_page.dart';
import 'artwork_preview_viewer.dart';

/// Created only in token details. Building this widget never loads media.
class RemotePreview extends StatefulWidget {
  const RemotePreview({super.key, required this.token});
  final TokenBalance token;
  @override
  State<RemotePreview> createState() => _RemotePreviewState();
}

class _RemotePreviewState extends State<RemotePreview>
    with WidgetsBindingObserver {
  late final _wallet = walletService.currentWalletId.value;
  PreviewJob? _job;
  ui.Image? _image;
  final _generation = ValueNotifier<int>(0);
  String? _message;
  bool _loading = false, _concealed = false;
  bool get _allowed =>
      mounted &&
      !_concealed &&
      !privacyService.hideBalances &&
      walletService.isUnlocked &&
      _wallet == walletService.currentWalletId.value &&
      networkController.activeUrl != null &&
      !previewSettings.never &&
      widget.token.declaredAssetKind == DeclaredAssetKind.picture &&
      widget.token.metadataState != MetadataState.invalid &&
      widget.token.metadataState != MetadataState.conflict;

  @override
  void didUpdateWidget(RemotePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Consent belongs to the exact holding and media commitment presented.
    // A rebuild must not turn approval for one artwork into a different fetch.
    final old = oldWidget.token, token = widget.token;
    if (old.id != token.id ||
        old.iconUrl != token.iconUrl ||
        old.issuanceHash != token.issuanceHash ||
        old.declaredAssetKind != token.declaredAssetKind ||
        old.metadataState != token.metadataState ||
        old.hasStealth != token.hasStealth) {
      _clear();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    walletService.unlocked.addListener(_securityChanged);
    walletService.currentWalletId.addListener(_securityChanged);
    privacyService.addListener(_securityChanged);
    networkController.addListener(_securityChanged);
    previewSettings.addListener(_settingsChanged);
  }

  void _clear() {
    _generation.value++;
    _job?.cancel();
    _job = null;
    _image?.dispose();
    _image = null;
    _loading = false;
    _message = null;
  }

  void _settingsChanged() {
    _clear();
    if (mounted) setState(() {});
  }

  void _securityChanged() {
    // Security transitions latch until details are reopened.
    if (privacyService.hideBalances ||
        !walletService.isUnlocked ||
        _wallet != walletService.currentWalletId.value) {
      _concealed = true;
    }
    // Offline cancels current work but permits fresh consent after reconnecting.
    if (!_allowed) _clear();
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _clear();
      if (mounted) setState(() => _concealed = true);
    }
  }

  @override
  void dispose() {
    _clear();
    WidgetsBinding.instance.removeObserver(this);
    walletService.unlocked.removeListener(_securityChanged);
    walletService.currentWalletId.removeListener(_securityChanged);
    privacyService.removeListener(_securityChanged);
    networkController.removeListener(_securityChanged);
    previewSettings.removeListener(_settingsChanged);
    _generation.dispose();
    super.dispose();
  }

  Future<bool> _consent(String title, String text, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;
  Future<void> _load() async {
    if (!_allowed || _loading) return;
    final token = widget.token;
    final gateway = previewSettings.gateway;
    if (gateway == null) return;
    final revision = previewSettings.revision;
    try {
      ipfsPath(token.iconUrl ?? '');
    } catch (_) {
      return;
    }
    setState(() => _loading = true);
    final job = _job = PreviewJob(
      allowed: () => _allowed && revision == previewSettings.revision,
    );
    try {
      final yes = await _consent(
        'Load preview through ${Uri.parse(gateway).host}?',
        'This gateway can see your IP address and which artwork was requested. '
            '${token.hasStealth ? 'Loading may link this private holding to this connection. ' : ''}'
            'Up to 5 MiB will be downloaded. Artwork may contain unsolicited or misleading content.',
        'Load preview',
      );
      job.check();
      if (!yes) return;
      final source = await job.fetch(
        gateway,
        token.iconUrl!,
        token.issuanceHash,
      );
      var withoutIntegrity = false;
      if (!source.info.matchesHash) {
        if (!mounted) return;
        withoutIntegrity = await _consent(
          'Issuance hash missing or invalid',
          'The format and dimensions passed the preview checks, but these bytes cannot be compared with an issuance hash.',
          'View without integrity check',
        );
        job.check();
        if (!withoutIntegrity) return;
      }
      final image = await job.decode(
        source,
        withoutIntegrity: withoutIntegrity,
      );
      if (!mounted || !identical(_job, job) || !_allowed) {
        image.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = image;
        _message = source.info.matchesHash
            ? 'Matches issuance hash'
            : 'Viewed without integrity check';
      });
    } catch (e) {
      if (mounted && identical(_job, job) && _allowed)
        setState(
          () => _message = e is PreviewFailure
              ? e.message
              : 'Preview could not be loaded.',
        );
    } finally {
      if (mounted && identical(_job, job)) setState(() => _loading = false);
    }
  }

  Future<void> _expand() async {
    if (!_allowed || _image == null) return;
    // A clone shares the already bounded pixels; zoom never reloads the URI.
    final image = _image!.clone();
    final label = widget.token.label;
    final integrity = _message ?? '';
    final revision = previewSettings.revision;
    final generation = _generation.value;
    await showDialog<void>(
      context: context,
      useSafeArea: false,
      builder: (_) => ArtworkPreviewViewer(
        image: image,
        label: label,
        integrity: integrity,
        walletId: _wallet,
        settingsRevision: revision,
        generation: _generation,
        expectedGeneration: generation,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final token = widget.token;
    String? unavailable;
    try {
      ipfsPath(token.iconUrl ?? '');
    } on PreviewFailure catch (e) {
      unavailable = e.message;
    }
    if (token.declaredAssetKind != DeclaredAssetKind.picture ||
        token.metadataState == MetadataState.invalid ||
        token.metadataState == MetadataState.conflict) {
      unavailable ??= 'Preview not supported for this metadata.';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (unavailable != null)
          Text(unavailable)
        else if (previewSettings.never)
          const Text('Remote previews disabled.')
        else if (previewSettings.gateway == null)
          const Text('No gateway configured. Previews are unavailable.')
        else if (!_allowed)
          const Text(
            'Previews unavailable while locked, hidden, offline or outside this session.',
          )
        else ...[
          if (_image != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Container(
                width: double.infinity,
                height: 280,
                color: ArgusColors.of(context).inset,
                child: RawImage(image: _image, fit: BoxFit.contain),
              ),
            ),
          if (_message != null) ...[const SizedBox(height: 8), Text(_message!)],
          if (_image != null)
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: _expand,
                  icon: const Icon(Icons.fullscreen, size: 20),
                  label: const Text('View artwork'),
                ),
                TextButton.icon(
                  onPressed: () => setState(_clear),
                  icon: const Icon(Icons.visibility_off_outlined, size: 18),
                  label: const Text('Hide preview'),
                ),
              ],
            ),
          if (_image == null)
            OutlinedButton.icon(
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.image_outlined, size: 18),
              label: Text(_loading ? 'Loading preview…' : 'Load preview'),
            ),
          if (_loading)
            TextButton(
              onPressed: () {
                _clear();
                setState(() {});
              },
              child: const Text('Cancel preview'),
            ),
        ],
        TextButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => const PreviewSettingsPage(),
            ),
          ),
          child: const Text('Remote preview settings'),
        ),
      ],
    );
  }
}
