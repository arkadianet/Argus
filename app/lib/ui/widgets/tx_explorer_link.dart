import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/network_controller.dart';

/// Explorer access for stored IDs without an Activity row's amount or direction.
class TxExplorerLink extends StatelessWidget {
  const TxExplorerLink({super.key, required this.txId, required this.label});

  final String txId;
  final String label;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: () => launchUrl(Uri.parse(networkController.explorerTx(txId))),
    icon: const Icon(Icons.open_in_browser, size: 16),
    label: Text(label),
  );
}
