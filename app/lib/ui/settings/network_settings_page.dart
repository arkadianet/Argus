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
              'Built-in nodes are HTTPS. You can add http://ip:port for a node you run or trust; that traffic is not encrypted. The first healthy node in this order is used.',
            ),
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

  Widget _nodeRow(BuildContext context, int i, NodeEntry n) {
    final colors = ArgusColors.of(context);
    final active = n.url == networkController.activeUrl;
    final last = i == networkController.nodes.length - 1;
    final isLastEnabled = n.enabled && networkController.enabledUrls.length <= 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? moss : (n.enabled ? colors.muted : Colors.transparent),
              border: n.enabled ? null : Border.all(color: colors.muted),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(Uri.tryParse(n.url)?.host ?? n.url, style: Theme.of(context).textTheme.titleMedium),
                Text(
                  describeNode(n, networkController.probes[n.url], active: active),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Up',
            onPressed: i == 0 ? null : () => networkController.moveNode(i, -1),
            icon: const Icon(Icons.keyboard_arrow_up, size: 20),
          ),
          IconButton(
            tooltip: 'Down',
            onPressed: last ? null : () => networkController.moveNode(i, 1),
            icon: const Icon(Icons.keyboard_arrow_down, size: 20),
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
    );
  }
}
