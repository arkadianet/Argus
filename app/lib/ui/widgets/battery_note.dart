import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/battery_service.dart';
import '../../theme/argus_theme.dart';

/// One line about battery optimisation and a button to fix it. Shown only
/// where background work matters. Reads the setting when built and again
/// after the user comes back from the system dialog.
class BatteryNote extends StatefulWidget {
  const BatteryNote({super.key});

  @override
  State<BatteryNote> createState() => _BatteryNoteState();
}

class _BatteryNoteState extends State<BatteryNote> with WidgetsBindingObserver {
  bool? _unrestricted;
  String _maker = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _read();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _read();
  }

  Future<void> _read() async {
    final u = await BatteryService.isUnrestricted();
    final m = await BatteryService.manufacturer();
    if (mounted) setState(() {
      _unrestricted = u;
      _maker = m;
    });
  }

  Future<void> _fix() async {
    final shown = await BatteryService.requestUnrestricted();
    if (!shown) await BatteryService.openBatterySettings();
  }

  @override
  Widget build(BuildContext context) {
    if (!BatteryService.supported) return const SizedBox.shrink();
    final muted = ArgusColors.of(context).muted;
    final warn = _unrestricted == false;
    final aggressive = aggressiveBatteryMakers.contains(_maker);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          batteryAdvice(unrestricted: _unrestricted, manufacturer: _maker),
          style: TextStyle(color: warn ? rust : muted, fontSize: 12),
        ),
        if (warn || aggressive) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              if (warn)
                OutlinedButton(
                  key: const Key('battery-fix'),
                  onPressed: _fix,
                  child: const Text('Allow unrestricted battery use'),
                ),
              if (aggressive)
                TextButton(
                  onPressed: () => launchUrl(
                    Uri.parse('https://dontkillmyapp.com/$_maker'),
                    mode: LaunchMode.externalApplication,
                  ),
                  child: const Text('Steps for this phone'),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
