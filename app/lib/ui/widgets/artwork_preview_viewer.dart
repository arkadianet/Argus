import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../services/network_controller.dart';
import '../../services/privacy_service.dart';
import '../../services/preview/preview_service.dart';
import '../../services/wallet_service.dart';

/// A viewer for already checked pixels. It owns [image] and never fetches media.
class ArtworkPreviewViewer extends StatefulWidget {
  const ArtworkPreviewViewer({
    super.key,
    required this.image,
    required this.label,
    required this.integrity,
    required this.walletId,
    required this.settingsRevision,
    required this.generation,
    required this.expectedGeneration,
  });

  final ui.Image image;
  final String label, integrity;
  final String? walletId;
  final int settingsRevision;
  final ValueListenable<int> generation;
  final int expectedGeneration;

  @override
  State<ArtworkPreviewViewer> createState() => _ArtworkPreviewViewerState();
}

class _ArtworkPreviewViewerState extends State<ArtworkPreviewViewer>
    with WidgetsBindingObserver {
  ui.Image? _image;
  final _transformation = TransformationController();

  bool get _allowed =>
      walletService.isUnlocked &&
      widget.walletId == walletService.currentWalletId.value &&
      !privacyService.hideBalances &&
      networkController.activeUrl != null &&
      !previewSettings.never &&
      widget.settingsRevision == previewSettings.revision &&
      widget.generation.value == widget.expectedGeneration;

  @override
  void initState() {
    super.initState();
    _image = widget.image;
    if (!_allowed) _clear();
    WidgetsBinding.instance.addObserver(this);
    walletService.unlocked.addListener(_securityChanged);
    walletService.currentWalletId.addListener(_securityChanged);
    privacyService.addListener(_securityChanged);
    networkController.addListener(_securityChanged);
    previewSettings.addListener(_securityChanged);
    widget.generation.addListener(_securityChanged);
  }

  void _clear() {
    _image?.dispose();
    _image = null;
    _transformation.value = Matrix4.identity();
  }

  void _securityChanged() {
    if (!_allowed && _image != null) {
      _clear();
      // The owner can revoke a preview during its own metadata rebuild.
      // This dialog is a sibling route, so repaint after that frame finishes.
      if (SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() {});
        });
      } else {
        setState(() {});
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) setState(_clear);
  }

  @override
  void dispose() {
    _clear();
    _transformation.dispose();
    WidgetsBinding.instance.removeObserver(this);
    walletService.unlocked.removeListener(_securityChanged);
    walletService.currentWalletId.removeListener(_securityChanged);
    privacyService.removeListener(_securityChanged);
    networkController.removeListener(_securityChanged);
    previewSettings.removeListener(_securityChanged);
    widget.generation.removeListener(_securityChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Close artwork',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close),
        ),
        title: Text(
          _image == null ? 'Artwork' : widget.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_image != null)
            IconButton(
              tooltip: 'Reset zoom',
              onPressed: () => _transformation.value = Matrix4.identity(),
              icon: const Icon(Icons.fit_screen_outlined),
            ),
        ],
      ),
      body: _image == null
          ? const Center(
              child: Text('Preview hidden. Reopen asset details to view it.'),
            )
          : Column(
              children: [
                Expanded(
                  child: SizedBox.expand(
                    child: InteractiveViewer(
                      transformationController: _transformation,
                      minScale: 1,
                      maxScale: 5,
                      child: RawImage(
                        image: _image,
                        fit: BoxFit.contain,
                        width: double.infinity,
                        height: double.infinity,
                      ),
                    ),
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Text(widget.integrity),
                        const SizedBox(height: 4),
                        const Text('Pinch or scroll to zoom. Drag to move.'),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    ),
  );
}
