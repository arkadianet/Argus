import 'package:flutter/material.dart';

import 'services/address_label_service.dart';
import 'services/contacts_service.dart';
import 'services/deep_link_channel.dart';
import 'services/notification_service.dart';
import 'services/network_controller.dart';
import 'services/privacy_service.dart';
import 'services/token_pricer.dart';
import 'services/session_lock.dart';
import 'services/stealth_service.dart';
import 'services/watch_only_service.dart';
import 'services/wallet_service.dart';
import 'services/wallet_sync_controller.dart';
import 'theme/argus_theme.dart';
import 'theme/theme_controller.dart';
import 'ui/ageusd_screen.dart';
import 'ui/contacts_screen.dart';
import 'ui/create_wallet_screen.dart';
import 'ui/dashboard_screen.dart';
import 'ui/dexy_screen.dart';
import 'ui/receive_screen.dart';
import 'ui/restore_wallet_screen.dart';
import 'ui/send_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/swap_hub_screen.dart';
import 'ui/transaction_detail_screen.dart';
import 'ui/transactions_screen.dart';
import 'ui/utxo_management_screen.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  themeController.load().catchError((_) {});
  // Independent preference loads; run them together so the first frame
  // waits on the slowest one instead of the sum.
  await Future.wait<void>([
    sessionLock.loadGrace().catchError((_) {}),
    contactsService.load().catchError((_) {}),
    addressLabelService.load().catchError((_) {}),
    watchOnlyService.load().catchError((_) {}),
    privacyService.load().catchError((_) {}),
    stealthService.load().catchError((_) {}),
    tokenPricer.load().catchError((_) {}),
    stealthService.loadSelfChangeTrees().catchError((_) {}),
  ]);
  networkController.priceRefresher = tokenPricer.refresh;
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
    DeepLinkChannel.start();
    notificationService.init();
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
          theme: themeController.lightTheme,
          darkTheme: themeController.darkTheme,
          themeMode: themeController.themeMode,
          // Densities in the wallet card assume at most ~1.6x text; larger
          // system font scales would overflow fixed rows.
          // Every route sees live wallet context through WalletArgsScope, so
          // a pushed screen's balances update instead of freezing at push
          // time. Route arguments still carry per-route data (a transaction).
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler:
                  MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.6),
            ),
            child: ListenableBuilder(
              listenable: walletSyncController,
              builder: (context, _) => WalletArgsScope(
                args: walletSyncController.routeArgs,
                child: child!,
              ),
            ),
          ),
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
              '/ageusd' => const AgeUsdScreen(),
              '/swap' => const SwapHubScreen(),
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
