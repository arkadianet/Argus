import 'package:flutter/material.dart';

import 'services/address_label_service.dart';
import 'services/contacts_service.dart';
import 'services/privacy_service.dart';
import 'services/session_lock.dart';
import 'services/watch_only_service.dart';
import 'services/wallet_service.dart';
import 'theme/argus_theme.dart';
import 'theme/theme_controller.dart';
import 'ui/contacts_screen.dart';
import 'ui/create_wallet_screen.dart';
import 'ui/dashboard_screen.dart';
import 'ui/dexy_screen.dart';
import 'ui/receive_screen.dart';
import 'ui/restore_wallet_screen.dart';
import 'ui/send_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/transaction_detail_screen.dart';
import 'ui/transactions_screen.dart';
import 'ui/utxo_management_screen.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  themeController.load().catchError((_) {});
  await sessionLock.loadGrace().catchError((_) {});
  await contactsService.load().catchError((_) {});
  await addressLabelService.load().catchError((_) {});
  await watchOnlyService.load().catchError((_) {});
  await privacyService.load().catchError((_) {});
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
    sessionLock.onLifecycle(state);
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
              '/' || null => const DashboardScreen(),
              '/receive' => const ReceiveScreen(),
              '/send' => const SendScreen(),
              '/transactions' => const TransactionsScreen(),
              '/create' => const CreateWalletScreen(),
              '/restore' => const RestoreWalletScreen(),
              '/settings' => const SettingsScreen(),
              '/contacts' => const ContactsScreen(),
              '/tx' => const TransactionDetailScreen(),
              '/utxos' => const UtxoManagementScreen(),
              '/dexy' => const DexyScreen(),
              _ => null,
            };
            if (page == null) return null;
            return fadeRoute(page, settings: settings);
          },
          onUnknownRoute: (settings) =>
              fadeRoute(const DashboardScreen(), settings: settings),
        );
      },
    );
  }
}
