import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/argus_error.dart';
import '../services/secure_storage.dart';
import '../services/wallet_service.dart';
import 'create_wallet_screen.dart';
import 'restore_wallet_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _loading = true;
  String _status = 'Initializing...';
  String? _address;
  int? _balanceNano;
  List<Map<String, dynamic>> _recentTxs = [];
  bool _walletUnlocked = false;
  bool _hasSeed = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await walletService.init();
      _hasSeed = await SecureStorageService.hasEncryptedSeed();
      _status = _hasSeed ? 'Wallet found. Unlock to continue.' : 'No wallet. Create or restore one.';
    } on ArgusException catch (e) {
      _status = '${e.code}: ${e.message}';
    } catch (e) {
      _status = 'Error: $e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _afterUnlock() async {
    final address = await walletService.deriveAddress(0);
    setState(() {
      _walletUnlocked = true;
      _address = address;
      _status = 'Unlocked';
    });
    await _refresh();
  }

  Future<void> _unlockFromKeystore() async {
    try {
      final json = await SecureStorageService.loadEncryptedSeed();
      if (json == null) {
        setState(() => _status = 'No wallet found. Create or restore.');
        return;
      }
      await walletService.restoreWallet(json);
      await _afterUnlock();
    } on ArgusException catch (e) {
      _snack('${e.code}: ${e.message}');
    } on SecureStorageException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _openCreate() async {
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const CreateWalletScreen()),
    );
    if (ok == true) {
      _hasSeed = true;
      await _afterUnlock();
    }
  }

  Future<void> _openRestore() async {
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const RestoreWalletScreen()),
    );
    if (ok == true) {
      _hasSeed = true;
      await _afterUnlock();
    }
  }

  Future<void> _refresh() async {
    if (_address == null) return;
    try {
      final balance = await walletService.getBalanceNano(_address!);
      final txsJson = await walletService.getTransactionHistory(_address!, limit: 5);
      final decoded = jsonDecode(txsJson) as List;
      if (!mounted) return;
      setState(() {
        _balanceNano = balance;
        _recentTxs = decoded.cast<Map<String, dynamic>>();
      });
    } catch (_) {}
  }

  Future<void> _lock() async {
    await walletService.lock();
    setState(() {
      _walletUnlocked = false;
      _address = null;
      _balanceNano = null;
      _recentTxs = [];
      _status = _hasSeed ? 'Locked' : 'No wallet. Create or restore one.';
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _go(String route) {
    if (!_walletUnlocked || _address == null) {
      _snack('Unlock the wallet first');
      return;
    }
    Navigator.pushNamed(context, route, arguments: _address);
  }

  String _erg(int? nano) {
    if (nano == null) return '—';
    return '${(nano / 1e9).toStringAsFixed(4)} ERG';
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
              onPressed: _lock,
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_status, style: theme.textTheme.titleMedium),
                    if (_address != null) ...[
                      const SizedBox(height: 8),
                      Text('Address', style: theme.textTheme.labelSmall),
                      SelectableText(_address!, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                      const SizedBox(height: 8),
                      Text(_erg(_balanceNano), style: theme.textTheme.headlineSmall),
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.copy, size: 18),
                            onPressed: () => Clipboard.setData(ClipboardData(text: _address!)),
                          ),
                          IconButton(
                            icon: const Icon(Icons.qr_code, size: 18),
                            onPressed: () => _go('/receive'),
                          ),
                        ],
                      ),
                    ],
                    if (!_walletUnlocked) ...[
                      const SizedBox(height: 12),
                      if (_hasSeed)
                        FilledButton(onPressed: _unlockFromKeystore, child: const Text('Unlock')),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.tonal(
                              onPressed: _openCreate,
                              child: const Text('Create'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.tonal(
                              onPressed: _openRestore,
                              child: const Text('Restore'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (_walletUnlocked) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _go('/send'),
                      icon: const Icon(Icons.send),
                      label: const Text('Send'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: () => _go('/receive'),
                      icon: const Icon(Icons.qr_code),
                      label: const Text('Receive'),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Text('Recent Transactions', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            if (_recentTxs.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('No transactions yet')),
                ),
              )
            else
              ..._recentTxs.map((tx) {
                final nano = (tx['value_nano_erg'] as num?)?.toInt();
                final txId = tx['tx_id']?.toString() ?? '';
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.swap_horiz),
                    title: Text(_erg(nano), style: const TextStyle(fontFamily: 'monospace')),
                    subtitle: Text(
                      txId.length > 16 ? txId.substring(0, 16) : txId,
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: Text('#${tx['height'] ?? '?'}'),
                    onTap: () => _go('/transactions'),
                  ),
                );
              }),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: 0,
        onDestinationSelected: (i) {
          if (i == 1) _go('/send');
          if (i == 2) _go('/receive');
          if (i == 3) _go('/transactions');
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
