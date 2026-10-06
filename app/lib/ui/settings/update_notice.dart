import 'package:flutter/material.dart';

import '../../services/update_service.dart';
import '../../theme/argus_theme.dart';
import 'about_page.dart';

/// A slim, dismissible line at the top of Settings when a newer release is
/// known: the version, a way into About where the notes and the download
/// live, and a close button. Dismissing hides it for that version only, so
/// the next release shows it again. Hidden when there is nothing to say, and
/// it never fetches anything itself.
class UpdateNotice extends StatefulWidget {
  const UpdateNotice({super.key, this.updates});

  /// Defaults to the app-wide [updateService]; tests pass their own.
  final UpdateService? updates;

  @override
  State<UpdateNotice> createState() => _UpdateNoticeState();
}

class _UpdateNoticeState extends State<UpdateNotice> {
  UpdateService get _updates => widget.updates ?? updateService;

  @override
  void initState() {
    super.initState();
    // Reads what was saved by an earlier check; no network.
    _updates.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _updates,
      builder: (context, _) {
        final release = _updates.available;
        if (release == null || !_updates.noticeVisible) return const SizedBox.shrink();
        final dark = Theme.of(context).brightness == Brightness.dark;
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Container(
            key: const Key('update-notice'),
            padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
            decoration: BoxDecoration(
              color: dark ? watchfulSurface : bannerTint,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                const Icon(Icons.system_update_outlined, size: 18, color: iris),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Argus ${release.version} is available.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.push(context, fadeRoute(AboutPage(updates: widget.updates))),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                  ),
                  child: const Text('View'),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Dismiss',
                  onPressed: _updates.dismissNotice,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
