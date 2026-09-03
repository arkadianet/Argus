import 'package:flutter/material.dart';

import '../services/contacts_service.dart';
import '../services/network_controller.dart';
import '../services/wallet_service.dart';
import '../services/watch_only_service.dart';
import '../theme/argus_theme.dart';
import '../theme/theme_controller.dart';
import 'settings/about_page.dart';
import 'settings/address_book_page.dart';
import 'settings/display_settings_page.dart';
import 'settings/network_settings_page.dart';
import 'settings/security_settings_page.dart';
import 'settings/settings_shared.dart';
import 'settings/wallet_settings_page.dart';
import 'settings/wallets_page.dart';
import 'settings/watch_only_page.dart';
import 'widgets/soft_card.dart';

/// Settings hub: the active wallet on top, then short groups whose rows open
/// their own page. Per-wallet and app-wide scopes are labelled.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.walletId,
    this.embedded = false,
    this.onWalletSwitched,
  });

  final String? walletId;

  /// Hosted as a home tab: no app bar, and wallet switches are reported via
  /// [onWalletSwitched] instead of popping the route. An empty id means the
  /// wallet this screen showed was deleted.
  final bool embedded;
  final ValueChanged<String>? onWalletSwitched;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late Future<List<WalletInfo>> _walletsFuture = walletService.listWallets();

  String? get _walletId => widget.walletId ?? walletService.activeWalletId;

  Future<void> _open(Widget page) async {
    await Navigator.push(context, fadeRoute(page));
    if (mounted) setState(() => _walletsFuture = walletService.listWallets());
  }

  void _onWalletSwitched(String id) {
    final cb = widget.onWalletSwitched;
    if (cb != null) {
      cb(id);
    } else {
      Navigator.pop(context, id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.embedded ? null : AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          themeController,
          networkController,
          walletService.unlocked,
          watchOnlyService,
          contactsService,
        ]),
        builder: (context, _) {
          return FutureBuilder<List<WalletInfo>>(
            future: _walletsFuture,
            builder: (context, snapshot) {
              final wallets = snapshot.data ?? const <WalletInfo>[];
              WalletInfo? current;
              for (final w in wallets) {
                if (w.walletId == _walletId) current = w;
              }
              final name = current?.name ?? 'No wallet selected';
              return ListView(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
                children: [
                  _walletHeader(context, name, wallets.length, current),
                  const SizedBox(height: 24),
                  SettingsGroup(
                    title: 'This wallet',
                    scope: name,
                    children: [
                      SettingsRow(
                        icon: Icons.account_balance_wallet_outlined,
                        title: 'Addresses, tools and backup',
                        subtitle: 'Primary address, change policy, UTXO management',
                        onTap: current == null
                            ? null
                            : () => _open(WalletSettingsPage(walletId: _walletId, walletName: name)),
                      ),
                      SettingsRow(
                        icon: Icons.lock_outline,
                        title: 'Security',
                        subtitle: 'PIN, biometric unlock, auto-lock',
                        onTap: () => _open(SecuritySettingsPage(walletId: _walletId)),
                      ),
                    ],
                  ),
                  SettingsGroup(
                    title: 'App',
                    scope: 'App-wide',
                    children: [
                      SettingsRow(
                        icon: Icons.hub_outlined,
                        title: 'Network',
                        subtitle: networkController.statusLabel,
                        onTap: () => _open(const NetworkSettingsPage()),
                      ),
                      SettingsRow(
                        icon: Icons.palette_outlined,
                        title: 'Display',
                        subtitle: '${_paletteName(themeController.palette)} · ${networkController.fiatCode.toUpperCase()}',
                        onTap: () => _open(const DisplaySettingsPage()),
                      ),
                      SettingsRow(
                        icon: Icons.contacts_outlined,
                        title: 'Address book',
                        subtitle: '${contactsService.contacts.length} contacts',
                        onTap: () => _open(const AddressBookPage()),
                      ),
                      SettingsRow(
                        icon: Icons.visibility_outlined,
                        title: 'Watch-only',
                        subtitle: watchOnlyService.addresses.isEmpty
                            ? 'Follow an address without its keys'
                            : '${watchOnlyService.addresses.length} watched',
                        onTap: () => _open(const WatchOnlyPage()),
                      ),
                    ],
                  ),
                  SettingsGroup(
                    title: 'About',
                    children: [
                      SettingsRow(
                        icon: Icons.info_outline,
                        title: 'About Argus',
                        subtitle: 'Version, release notes, licenses',
                        onTap: () => _open(const AboutPage()),
                      ),
                    ],
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  static String _paletteName(ArgusPalette p) => switch (p) {
        ArgusPalette.system => 'System palette',
        ArgusPalette.watchful => 'Watchful',
        ArgusPalette.ledger => 'Ledger',
      };

  Widget _walletHeader(BuildContext context, String name, int count, WalletInfo? current) {
    final colors = ArgusColors.of(context);
    final unlocked = current != null && walletService.isUnlocked && walletService.activeWalletId == current.walletId;
    return SoftCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 12, 16),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: iris.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.account_balance_wallet_outlined, color: iris),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'Newsreader', fontWeight: FontWeight.w600, fontSize: 19),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    unlocked ? 'Unlocked' : 'Locked',
                    '$count ${count == 1 ? 'wallet' : 'wallets'} on this device',
                  ].join(' · '),
                  style: TextStyle(fontSize: 12.5, color: colors.muted),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => _open(WalletsPage(walletId: _walletId, onWalletSwitched: _onWalletSwitched)),
            child: const Text('Manage'),
          ),
        ],
      ),
    );
  }
}
