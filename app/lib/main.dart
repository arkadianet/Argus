import 'package:flutter/material.dart';

import 'ui/create_wallet_screen.dart';
import 'ui/dashboard_screen.dart';
import 'ui/receive_screen.dart';
import 'ui/restore_wallet_screen.dart';
import 'ui/send_screen.dart';
import 'ui/transactions_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ArgusApp());
}

class ArgusApp extends StatelessWidget {
  const ArgusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Argus Wallet',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF00BFA5),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const DashboardScreen(),
        '/receive': (context) => const ReceiveScreen(),
        '/send': (context) => const SendScreen(),
        '/transactions': (context) => const TransactionsScreen(),
        '/create': (context) => const CreateWalletScreen(),
        '/restore': (context) => const RestoreWalletScreen(),
      },
    );
  }
}