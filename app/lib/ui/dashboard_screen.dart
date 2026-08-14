import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/wallet_service.dart';
import '../services/secure_storage.dart';
import '../bridge/argus_error.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _loading = true;
  String _status = 'Initializing...';
  String? _address;
  String? _balance;
  List<Map<String, dynamic>> _recentTxs = [];
  bool _walletUnlocked = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await walletService.init();

      // Check if encrypted seed exists in Keystore
      final hasSeed = await SecureStorageService.hasEncryptedSeed();
      if (hasSeed) {
        _status = 'Wallet found. Unlock to continue.';
      } else {
        _status = 'No wallet. Create or restore one.';
        final testAddr = await walletService.testDeriveDisplay();
        _address = testAddr;
      }

      setState(() => _loading = false);
    } on ArgusException catch (e) {
      setState(() {
        _status = '${e.code}: ${e.message}';
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
        _loading = false;
      });
    }
  }

  Future<void> _quickCreate() async {
    try {
      final mnemonic = await walletService.generateMnemonic(strength: 128);
      await walletService.createWallet(mnemonic);

      final address = await walletService.deriveAddress(0);
      final encryptedJson = await walletService.createEncryptedSeed(mnemonic);
      await SecureStorageService.saveEncryptedSeed(encryptedJson);

      setState(() {
        _walletUnlocked = true;
        _address = address;
        _balance = null;
      });
      _refresh();
    } on ArgusException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${e.code}: ${e.message}')),
      );
    }
  }

  Future<void> _unlockFromKeystore() async {
    try {
      final json = await SecureStorageService.loadEncryptedSeed();
      if (json == null) {
        _status = 'No wallet found. Create or restore.';
        return;
      }
      // keyMaterial is derived inside Rust from the stored blob.
      // For now, use a placeholder that triggers Rust-side key derivation.
      await walletService.restoreWallet(json, []);
      final address = await walletService.deriveAddress(0);
      setState(() {
        _walletUnlocked = true;
        _address = address;
      });
      _refresh();
    } on ArgusException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${e.code}: ${e.message}')),
      );
    }
  }

  Future<void> _refresh() async {
    if (_address == null) return;
    try {
      final txsJson = await walletService.getTransactionHistory(_address!, limit: 5);
      final decoded = jsonDecode(txsJson) as List;
      setState(() {
        _recentTxs = decoded.cast<Map<String, dynamic>>();
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Argus'),
        actions: [
          if (_walletUnlocked)
            IconButton(
              icon: const Icon(Icons.lock_open),
              tooltip: 'Lock wallet',
              onPressed: () {
                walletService.lock();
                setState(() => _walletUnlocked = false);
              },
            ),
          if (!_walletUnlocked)
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: 'Quick create wallet',
              onPressed: _quickCreate,
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Status card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_status, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    if (_address != null) ...[
                      Text('Address', style: theme.textTheme.labelSmall),
                      SelectableText(_address!, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.copy, size: 18),
                            onPressed: () => Clipboard.setData(ClipboardData(text: _address!)),
                            tooltip: 'Copy address',
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.qr_code, size: 18),
                            onPressed: () => Navigator.pushNamed(context, '/receive', arguments: _address),
                            tooltip: 'Show QR code',
                          ),
                          const Spacer(),
                          if (!_walletUnlocked)
                            FilledButton.tonal(
                              onPressed: _unlockFromKeystore,
                              child: const Text('Unlock'),
                            ),
                        ],
                      ),
                    ],
                    if (_balance != null) ...[
                      const SizedBox(height: 8),
                      Text('Balance', style: theme.textTheme.labelSmall),
                      Text('$_balance nanoERG', style: theme.textTheme.headlineSmall),
                    ],
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Action buttons
            if (_walletUnlocked) ...[
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => Navigator.pushNamed(context, '/send', arguments: _address),
                      icon: const Icon(Icons.send),
                      label: const Text('Send'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: () => Navigator.pushNamed(context, '/receive', arguments: _address),
                      icon: const Icon(Icons.qr_code),
                      label: const Text('Receive'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],

            // Recent transactions
            Text('Recent Transactions', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            if (_recentTxs.isEmpty)
              const Card(child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('No transactions yet')),
              ))
            else
              ..._recentTxs.map((tx) => Card(
                child: ListTile(
                  leading: const Icon(Icons.swap_horiz),
                  title: Text('${tx['value_nano_erg'] ?? '?'} nanoERG',
                    style: const TextStyle(fontFamily: 'monospace')),
                  subtitle: Text(tx['tx_id']?.toString().substring(0, 16) ?? '...',
                    style: const TextStyle(fontSize: 11)),
                  trailing: Text('#${tx['height'] ?? '?'}'),
                  onTap: () => Navigator.pushNamed(context, '/transactions'),
                ),
              )),
            if (_recentTxs.isNotEmpty)
              TextButton(
                onPressed: () => Navigator.pushNamed(context, '/transactions',
                    arguments: _address),
                child: const Text('View all'),
              ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: 0,
        onDestinationSelected: (i) {
          if (i == 1) Navigator.pushNamed(context, '/send', arguments: _address);
          if (i == 2) Navigator.pushNamed(context, '/receive', arguments: _address);
          if (i == 3) Navigator.pushNamed(context, '/transactions', arguments: _address);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home), label: 'Wallet'),
          NavigationDestination(icon: Icon(Icons.send), label: 'Send'),
          NavigationDestination(icon: Icon(Icons.qr_code), label: 'Receive'),
          NavigationDestination(icon: Icon(Icons.list), label: 'History'),
        ],
      ),
    );
  }
}