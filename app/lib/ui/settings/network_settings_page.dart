import 'package:flutter/material.dart';

import '../../services/network_controller.dart';
import '../../theme/argus_theme.dart';
import '../widgets/soft_card.dart';
import 'settings_shared.dart';

class NetworkSettingsPage extends StatefulWidget {
  const NetworkSettingsPage({super.key});

  @override
  State<NetworkSettingsPage> createState() => _NetworkSettingsPageState();
}

class _NetworkSettingsPageState extends State<NetworkSettingsPage> {
  final _nodeCtrl = TextEditingController();
  final _explorerCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _explorerCtrl.text = networkController.explorer;
  }

  @override
  void dispose() {
    _nodeCtrl.dispose();
    _explorerCtrl.dispose();
    super.dispose();
  }

  Future<void> _addNode() async {
    final err = await networkController.addNode(_nodeCtrl.text);
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    _nodeCtrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: networkController,
      builder: (context, _) {
        final colors = ArgusColors.of(context);
        final nodes = networkController.nodes;
        return SettingsPage(
          title: 'Network',
          children: [
            SoftCard(
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Connected node', style: TextStyle(fontSize: 12.5, color: colors.muted)),
                        const SizedBox(height: 4),
                        Text(networkController.statusLabel, style: Theme.of(context).textTheme.titleMedium),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: networkController.probing ? null : networkController.probe,
                    child: Text(networkController.probing ? 'Checking…' : 'Check nodes'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const SectionLabel('Nodes', scope: 'App-wide'),
            const SizedBox(height: 10),
            SoftCard(
              padding: EdgeInsets.zero,
              child: DividedColumn(
                indent: 16,
                children: [
                  _autoRow(context),
                  for (var i = 0; i < nodes.length; i++) _nodeRow(context, i, nodes[i]),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                    child: TextField(
                      controller: _nodeCtrl,
                      decoration: InputDecoration(
                        labelText: 'Add node URL',
                        hintText: 'https://host  or  1.2.3.4:9053',
                        suffixIcon: IconButton(tooltip: 'Add', onPressed: _addNode, icon: const Icon(Icons.add)),
                      ),
                      onSubmitted: (_) => _addNode(),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const SettingsNote(
              'Tap a node to use it. Automatic picks the reachable node with extraIndex and the smallest index lag. Built-in nodes are HTTPS; you can add http://ip:port for a node you run or trust, unencrypted.',
            ),
            const SectionLabel('Find more nodes', scope: 'App-wide'),
            const SizedBox(height: 10),
            SoftCard(
              padding: EdgeInsets.zero,
              child: DividedColumn(
                indent: 16,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            networkController.discovering
                                ? 'Asking every node for its peers and checking each…'
                                : networkController.lastSearch != null
                                    ? nodeSearchSummary(networkController.lastSearch!)
                                    : 'Peers of your nodes that publish an HTTPS API.',
                            style: TextStyle(fontSize: 12.5, color: colors.muted),
                          ),
                        ),
                        TextButton(
                          onPressed: networkController.discovering
                              ? null
                              : networkController.discoverNodes,
                          child: Text(networkController.discovering ? 'Searching…' : 'Search'),
                        ),
                      ],
                    ),
                  ),
                  for (final p in networkController.discovered) _discoveredRow(context, p),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const SectionLabel('Explorer', scope: 'App-wide'),
            const SizedBox(height: 10),
            SoftCard(
              child: TextField(
                controller: _explorerCtrl,
                decoration: InputDecoration(
                  labelText: 'Explorer API URL',
                  hintText: 'https://api.sigmaspace.io',
                  suffixIcon: IconButton(
                    tooltip: 'Save',
                    onPressed: () => networkController.setExplorer(_explorerCtrl.text),
                    icon: const Icon(Icons.check),
                  ),
                ),
                onSubmitted: networkController.setExplorer,
              ),
            ),
            const SizedBox(height: 8),
            const SettingsNote(
              'Token names and decimals come from extraIndex nodes first, then this explorer as a fallback. It is also used for Open in explorer.',
            ),
          ],
        );
      },
    );
  }

  Widget _radio(BuildContext context, bool on) => Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: on ? accentOf(context) : Colors.transparent,
          border: Border.all(color: accentOf(context), width: 1.2),
        ),
      );

  Widget _autoRow(BuildContext context) {
    final auto = networkController.preferredUrl == null;
    final active = networkController.activeUrl;
    final host = active == null ? null : Uri.tryParse(active)?.host;
    return InkWell(
      onTap: auto ? null : () => networkController.setPreferredNode(null),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            _radio(context, auto),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Automatic', style: Theme.of(context).textTheme.titleMedium),
                  Text(
                    auto
                        ? (host == null ? 'Best reachable extraIndex node' : 'Using $host')
                        : 'Best reachable extraIndex node',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _discoveredRow(BuildContext context, NodeProbe p) {
    final host = Uri.tryParse(p.url)?.host ?? p.url;
    final lag = p.indexLag;
    final detail = [
      if (p.extraIndex == true) (lag != null && lag > 2 ? 'extraIndex, lag $lag' : 'extraIndex') else 'no extraIndex',
      if (p.height != null) '#${p.height}',
    ].join('  ·  ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(host, style: Theme.of(context).textTheme.titleMedium),
                Text(detail, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          TextButton(onPressed: () => networkController.addNode(p.url), child: const Text('Add')),
        ],
      ),
    );
  }

  Widget _nodeRow(BuildContext context, int i, NodeEntry n) {
    final active = n.url == networkController.activeUrl;
    final preferred = n.url == networkController.preferredUrl;
    final isLastEnabled = n.enabled && networkController.enabledUrls.length <= 1;
    return InkWell(
      onTap: !n.enabled || preferred ? null : () => networkController.setPreferredNode(n.url),
      child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
      child: Row(
        children: [
          _radio(context, preferred),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(Uri.tryParse(n.url)?.host ?? n.url,
                          style: Theme.of(context).textTheme.titleMedium, overflow: TextOverflow.ellipsis),
                    ),
                    if (active) ...[
                      const SizedBox(width: 8),
                      Container(width: 8, height: 8, decoration: const BoxDecoration(shape: BoxShape.circle, color: moss)),
                    ],
                  ],
                ),
                Text(
                  describeNode(n, networkController.probes[n.url], active: active, preferred: preferred),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: n.enabled ? 'Disable' : 'Enable',
            onPressed: isLastEnabled ? null : () => networkController.toggleNode(i),
            icon: Icon(n.enabled ? Icons.visibility : Icons.visibility_off, size: 20),
          ),
          IconButton(
            tooltip: 'Remove',
            onPressed: isLastEnabled ? null : () => networkController.removeNode(i),
            icon: const Icon(Icons.close, size: 20),
          ),
        ],
      ),
      ),
    );
  }
}
