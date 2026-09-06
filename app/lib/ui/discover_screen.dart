import 'package:flutter/material.dart';

import '../theme/argus_theme.dart';
import 'widgets/discover_sheet.dart';
import 'widgets/soft_card.dart';

/// Every feature with a line on what it is. A row opens the explainer,
/// whose button hands the feature back to the home screen to open.
class DiscoverScreen extends StatelessWidget {
  const DiscoverScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    return Scaffold(
      appBar: AppBar(title: const Text('Discover')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Text(
            'What Argus can do beyond sending and receiving. Each one says what it is, '
            'what you can do with it, and what to watch for before it opens.',
            style: TextStyle(color: muted, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 16),
          for (final (label, features) in const [
            (
              'Protocols',
              [
                DiscoverFeature.dexy,
                DiscoverFeature.ageusd,
                DiscoverFeature.spectrum,
                DiscoverFeature.liquidity,
                DiscoverFeature.duckpools,
                DiscoverFeature.sigmafi,
                DiscoverFeature.rosen,
                DiscoverFeature.dapps,
              ],
            ),
            ('Tools', [DiscoverFeature.mix, DiscoverFeature.tokens, DiscoverFeature.utxos]),
          ]) ...[
            Text(
              label.toUpperCase(),
              style: Theme.of(context).textTheme.titleSmall?.copyWith(color: muted, letterSpacing: 1.2),
            ),
            const SizedBox(height: 8),
            _list(context, features),
            const SizedBox(height: 20),
          ],
        ],
      ),
    );
  }

  Widget _list(BuildContext context, List<DiscoverFeature> features) {
    final muted = ArgusColors.of(context).muted;
    return SoftCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (final (i, f) in features.indexed) ...[
            if (i > 0) const Divider(height: 1, indent: 16),
            ListTile(
              key: Key('discover-${f.name}'),
              leading: Icon(discoverExplainers[f]!.icon, color: accentOf(context)),
              title: Text(discoverExplainers[f]!.title),
              subtitle: Text(discoverExplainers[f]!.blurb, style: TextStyle(color: muted, fontSize: 12.5)),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => showDiscoverSheet(context, feature: f, onGo: () => Navigator.pop(context, f)),
            ),
          ],
        ],
      ),
    );
  }
}
