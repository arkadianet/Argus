import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../build_info.dart';
import '../../format.dart';
import '../../services/app_fee.dart';
import '../../theme/argus_theme.dart';
import 'settings_shared.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
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
    );
  }
}
