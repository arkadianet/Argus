import 'package:flutter/material.dart';
import '../../services/preview/preview_service.dart';

class PreviewSettingsPage extends StatefulWidget {
  const PreviewSettingsPage({super.key});
  @override
  State<PreviewSettingsPage> createState() => _PreviewSettingsPageState();
}

class _PreviewSettingsPageState extends State<PreviewSettingsPage> {
  late final _gateway = TextEditingController(
    text: previewSettings.gateway ?? '',
  );
  String? _message;
  bool _saving = false;
  @override
  void dispose() {
    _gateway.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      await previewSettings.setGateway(_gateway.text);
      if (mounted)
        setState(
          () => _message = previewSettings.gateway == null
              ? 'No gateway configured. Previews are unavailable.'
              : 'Gateway saved. Each artwork still requires consent.',
        );
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Remote previews')),
    body: ListenableBuilder(
      listenable: previewSettings,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Never load remote previews'),
            subtitle: const Text(
              'Disables loading and clears open previews. Image decoding has no enforceable total allocation ceiling and an active native decode cannot be interrupted. Use this switch to avoid decoder memory or security risks.',
            ),
            value: previewSettings.never,
            onChanged: (value) async {
              try {
                await previewSettings.setNever(value);
              } catch (e) {
                if (mounted) setState(() => _message = '$e');
              }
            },
          ),
          const SizedBox(height: 24),
          const Text(
            'Only IPFS artwork can be displayed. Issuer-selected hosts are refused because the issuer would choose who learns you looked. There is no default gateway or fallback.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _gateway,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Your HTTPS IPFS gateway',
              helperText: 'Origin only, port 443. Leave empty to remove.',
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Saving resolves the gateway hostname to check that its addresses are public. Loading checks again and connects only to that address. The gateway can see your IP and which artwork you request.',
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Checking gateway…' : 'Save gateway'),
          ),
          if (_message != null) Text(_message!),
        ],
      ),
    ),
  );
}
