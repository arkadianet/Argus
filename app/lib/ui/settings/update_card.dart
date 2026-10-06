import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../build_info.dart';
import '../../services/apk_signature.dart';
import '../../services/update_service.dart';
import '../../theme/argus_theme.dart';
import '../widgets/soft_card.dart';

/// The update notice on the About page: which version is out, its notes as
/// plain text, and the download with its checks. Everything happens inline;
/// nothing pops up, and nothing is fetched until a button is tapped.
class UpdateCard extends StatefulWidget {
  const UpdateCard({super.key, required this.updates});

  final UpdateService updates;

  @override
  State<UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<UpdateCard> {
  bool _notesOpen = false;

  UpdateService get _u => widget.updates;

  @override
  Widget build(BuildContext context) {
    final release = _u.available;
    if (release == null) return const SizedBox.shrink();
    final colors = ArgusColors.of(context);
    final published = release.publishedAt;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: SoftCard(
        key: const Key('update-card'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(color: colors.chip, borderRadius: BorderRadius.circular(10)),
                  child: Icon(Icons.system_update_outlined, size: 19, color: accentOf(context)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Update available',
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Argus ${release.version}'
                        '${published == null ? '' : ' · ${_date(published)}'}',
                        style: TextStyle(fontSize: 12.5, color: colors.muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (release.notes.isNotEmpty) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('update-notes-toggle'),
                  onPressed: () => setState(() => _notesOpen = !_notesOpen),
                  icon: Icon(_notesOpen ? Icons.expand_less : Icons.expand_more, size: 18),
                  label: Text(_notesOpen ? 'Hide release notes' : 'Release notes'),
                ),
              ),
              // Plain text on purpose: GitHub serves markdown, which is shown
              // as written, with no formatting, links or images.
              if (_notesOpen)
                Container(
                  key: const Key('update-notes'),
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colors.inset,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: colors.cardBorder),
                  ),
                  child: Text(release.notes, style: const TextStyle(fontSize: 12.5, height: 1.4)),
                ),
            ],
            const SizedBox(height: 12),
            _actions(context),
          ],
        ),
      ),
    );
  }

  Widget _actions(BuildContext context) {
    final colors = ArgusColors.of(context);
    final small = TextStyle(fontSize: 12.5, color: colors.muted);
    switch (_u.stage) {
      case UpdateStage.downloading:
        final total = _u.totalBytes;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(
              key: const Key('update-progress'),
              value: total == null || total == 0 ? null : (_u.downloadedBytes / total).clamp(0.0, 1.0),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    total == null
                        ? 'Downloading…'
                        : 'Downloading ${formatDownloadSize(_u.downloadedBytes)} of ${formatDownloadSize(total)}',
                    style: small,
                  ),
                ),
                TextButton(
                  key: const Key('update-cancel'),
                  onPressed: _u.cancelDownload,
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        );
      case UpdateStage.verifying:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LinearProgressIndicator(key: Key('update-progress')),
            const SizedBox(height: 8),
            Text('Checking the download against this app\'s signing key…', style: small),
          ],
        );
      case UpdateStage.verified:
        final signer = _u.verifiedSigner;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.verified_user_outlined, size: 18, color: moss),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Signed by the same key as this app'
                    '${signer == null ? '' : ' (SHA-256 ${formatFingerprint(signer).substring(0, 11)}…)'}.',
                    key: const Key('update-verified'),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
            if (_u.stageMessage != null) ...[
              const SizedBox(height: 8),
              Text(_u.stageMessage!, style: small),
            ],
            const SizedBox(height: 12),
            FilledButton(
              key: const Key('update-install'),
              onPressed: _u.install,
              child: const Text('Install'),
            ),
          ],
        );
      case UpdateStage.idle:
      case UpdateStage.rejected:
      case UpdateStage.failed:
        return _startOrRetry(context, small);
    }
  }

  Widget _startOrRetry(BuildContext context, TextStyle small) {
    final asset = _u.assetForDevice;
    final rejected = _u.stage == UpdateStage.rejected;
    final message = _u.stageMessage;
    final canDownload = _u.installSupported && asset != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (message != null) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (rejected) ...[
                Icon(Icons.gpp_bad_outlined, size: 18, color: rustFor(context)),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  message,
                  key: const Key('update-message'),
                  style: rejected
                      ? TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: rustFor(context))
                      : small,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        if (canDownload) ...[
          FilledButton(
            key: const Key('update-download'),
            onPressed: _u.downloadAndVerify,
            child: Text(rejected || _u.stage == UpdateStage.failed ? 'Try again' : 'Download and verify'),
          ),
          const SizedBox(height: 8),
          Text(
            '${asset.name} · ${formatDownloadSize(asset.size)}. Before anything is installed, Argus checks the file '
            'against the checksum GitHub lists and against the key this app is signed with.',
            style: small,
          ),
        ] else ...[
          OutlinedButton(
            key: const Key('update-open-releases'),
            onPressed: () => launchUrl(Uri.parse(releasesUrl), mode: LaunchMode.externalApplication),
            child: const Text('Open the releases page'),
          ),
          if (_u.installSupported && asset == null) ...[
            const SizedBox(height: 8),
            Text('This release has no APK for your phone.', style: small),
          ],
        ],
      ],
    );
  }

  static String _date(DateTime at) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${at.day} ${months[at.month - 1]} ${at.year}';
  }
}
