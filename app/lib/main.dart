import 'package:flutter/material.dart';

import 'services/wallet_service.dart';
import 'theme/argus_theme.dart';
import 'theme/theme_controller.dart';
import 'ui/create_wallet_screen.dart';
import 'ui/dashboard_screen.dart';
import 'ui/receive_screen.dart';
import 'ui/restore_wallet_screen.dart';
import 'ui/send_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/transactions_screen.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await themeController.load();
  runApp(const ArgusApp());
}

class ArgusApp extends StatefulWidget {
  const ArgusApp({super.key});

  @override
  State<ArgusApp> createState() => _ArgusAppState();
}

class _ArgusAppState extends State<ArgusApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    walletService.unlocked.addListener(_onUnlockChanged);
  }

  @override
  void dispose() {
    walletService.unlocked.removeListener(_onUnlockChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      walletService.lock().catchError((Object e, StackTrace st) {
        FlutterError.reportError(FlutterErrorDetails(exception: e, stack: st));
      });
    }
  }

  void _onUnlockChanged() {
    if (!walletService.unlocked.value) {
      navigatorKey.currentState?.popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: themeController,
      builder: (context, _) {
        return MaterialApp(
          title: 'Argus',
          navigatorKey: navigatorKey,
          debugShowCheckedModeBanner: false,
          theme: argusTheme(watchful: false),
          darkTheme: argusTheme(watchful: true),
          themeMode: themeController.themeMode,
          onGenerateRoute: (settings) {
            final page = switch (settings.name) {
              '/receive' => const ReceiveScreen(),
              '/send' => const SendScreen(),
              '/transactions' => const TransactionsScreen(),
              '/create' => const CreateWalletScreen(),
              '/restore' => const RestoreWalletScreen(),
              '/settings' => const SettingsScreen(),
              _ => const DashboardScreen(),
            };
            return fadeRoute(page, settings: settings);
          },
        );
      },
    );
  }
}
