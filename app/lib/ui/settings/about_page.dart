import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../build_info.dart';
import '../../format.dart';
import '../../services/apk_signature.dart';
import '../../services/app_fee.dart';
import '../../services/update_service.dart';
import '../../theme/argus_theme.dart';
import 'settings_shared.dart';
import 'update_card.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key, this.updates});

  /// Defaults to the app-wide [updateService]; tests pass their own.
  final UpdateService? updates;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  late final UpdateService _updates = widget.updates ?? updateService;

  /// Read once: the key this build is signed with does not change while the
  /// page is open.
  late final Future<List<String>?> _signingKey = _updates.ownSigningFingerprints();

  @override
  void initState() {
    super.initState();
    // Saved settings only; nothing is fetched by opening this page.
    _updates.ensureLoaded();
  }

  Future<void> _setChecking(bool value) async {
    final saved = await _updates.setEnabled(value);
    if (!saved && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not save the setting.')));
    }
  }

  /// One line on where the last check stands.
  String _checkStatus() {
    final u = _updates;
    if (u.checking) return 'Asking GitHub…';
    if (u.checkError != null) return u.checkError!;
    final at = u.lastChecked;
    if (at == null) return 'Not checked yet';
    final when = formatRelativeTime(at);
    final lower = when.isEmpty ? when : '${when[0].toLowerCase()}${when.substring(1)}';
    return '${u.available == null ? 'Up to date' : 'Version ${u.available!.version} is available'} · checked $lower';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _updates,
      builder: (context, _) => SettingsPage(
        title: 'About',
        children: [
          const SizedBox(height: 16),
          const Center(child: IrisMark(size: 64)),
          const SizedBox(height: 14),
          Text('Argus', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 6),
          Text(
            '$appVersion · build $appBuildNumber',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 28),
          UpdateCard(updates: _updates),
          SettingsGroup(
            title: 'Updates',
            scope: 'App-wide',
            children: [
              SettingsRow(
                icon: Icons.update,
                title: 'Check for updates',
                subtitle: 'Asks GitHub once a day. GitHub sees your IP address.',
                trailing: Switch(
                  key: const Key('update-check-toggle'),
                  value: _updates.enabled,
                  onChanged: _setChecking,
                ),
                onTap: () => _setChecking(!_updates.enabled),
              ),
              SettingsRow(
                icon: Icons.refresh,
                title: 'Check now',
                subtitle: _checkStatus(),
                trailing: _updates.checking
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const SizedBox.shrink(),
                onTap: _updates.checking || _updates.busy ? null : _updates.checkNow,
              ),
            ],
          ),
          const SettingsNote(
            'Off by default. When on, Argus asks api.github.com for the latest release once a day as it starts. '
            '"Check now" does the same on request, even with this off. Nothing else is sent: no account, token, '
            'app version or device identifier. A download comes from github.com and is checked against this '
            'app\'s signing key before Android is asked to install it.',
          ),
          SettingsGroup(
            title: 'This build',
            children: [
              const SettingsRow(
                icon: Icons.shield_outlined,
                title: 'Unaudited prototype',
                subtitle: 'Transactions on Ergo are irreversible. Use only funds you can afford to lose.',
              ),
              SettingsRow(
                icon: Icons.toll_outlined,
                title: 'App fee ${formatErg(argusFeeNano)} per transaction',
                subtitle: 'Paid to ${argusFeeAddress.substring(0, 12)}… on every transaction Argus builds. ErgoPay requests from dApps are not charged.',
              ),
              _SigningKeyRow(fingerprints: _signingKey),
              SettingsRow(
                icon: Icons.new_releases_outlined,
                title: 'Releases and notes',
                subtitle: 'What changed in each alpha, and the latest APK.',
                onTap: () => launchUrl(Uri.parse(releasesUrl), mode: LaunchMode.externalApplication),
              ),
              SettingsRow(
                icon: Icons.description_outlined,
                title: 'Open-source licenses',
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'Argus',
                  applicationVersion: appVersion,
                ),
              ),
            ],
          ),
          const SettingsNote(
            'Argus is a light client: it talks to public Ergo nodes over HTTPS and never sends your keys anywhere.',
          ),
        ],
      ),
    );
  }
}

/// The SHA-256 of the certificate this build is signed with, in the form
/// release notes publish it, so it can be compared by eye. Read from Android
/// at run time, never a constant.
class _SigningKeyRow extends StatelessWidget {
  const _SigningKeyRow({required this.fingerprints});

  final Future<List<String>?> fingerprints;

  /// Eight bytes to a line so the fingerprint fits a narrow phone.
  static String _lines(String hex) {
    final pairs = formatFingerprint(hex).split(':');
    return [
      for (var i = 0; i < pairs.length; i += 8) pairs.sublist(i, i + 8 > pairs.length ? pairs.length : i + 8).join(':'),
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    return FutureBuilder<List<String>?>(
      future: fingerprints,
      builder: (context, snapshot) {
        final done = snapshot.connectionState == ConnectionState.done;
        final prints = snapshot.data;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: colors.chip, borderRadius: BorderRadius.circular(10)),
                child: Icon(Icons.verified_user_outlined, size: 19, color: accentOf(context)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Signing certificate', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(
                      'SHA-256 of the key this build is signed with. An update must be signed with the same one.',
                      style: TextStyle(fontSize: 12.5, color: colors.muted),
                    ),
                    const SizedBox(height: 8),
                    if (!done)
                      Text('Reading…', style: TextStyle(fontSize: 12.5, color: colors.muted))
                    else if (prints == null)
                      Text('Not available on this device.', style: TextStyle(fontSize: 12.5, color: colors.muted))
                    else
                      for (final hex in prints)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            _lines(hex),
                            key: const Key('signing-fingerprint'),
                            style: monoStyle(context, size: 12),
                          ),
                        ),
                  ],
                ),
              ),
              if (prints != null)
                IconButton(
                  tooltip: 'Copy',
                  icon: const Icon(Icons.copy_outlined, size: 18),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: prints.map(formatFingerprint).join('\n')));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Fingerprint copied')));
                    }
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}
