import 'package:flutter/material.dart';
import 'cold_signing_screen.dart';

import '../format.dart';
import '../services/address_label_service.dart';
import '../services/contacts_service.dart';
import '../services/network_controller.dart';
import '../services/wallet_service.dart';
import '../services/watch_account_service.dart';
import '../services/watch_only_service.dart';
import '../theme/argus_theme.dart';
import '../theme/theme_controller.dart';
import 'home/name_dialog.dart';
import 'home/overview_model.dart';
import 'settings/about_page.dart';
import 'settings/address_book_page.dart';
import 'settings/display_settings_page.dart';
import 'settings/network_settings_page.dart';
import 'settings/preview_settings_page.dart';
import 'settings/security_settings_page.dart';
import 'settings/settings_shared.dart';
import 'settings/update_notice.dart';
import 'settings/wallet_settings_page.dart';
import 'widgets/soft_card.dart';

/// Settings hub: the open wallet on top, then short groups whose rows open
/// their own page. Per-wallet and app-wide scopes are labelled.
///
/// Wallets themselves — switching, creating, restoring, watching — live on
/// the overview. Renaming and removing a wallet live in its own settings.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.walletId,
    this.watched,
    this.embedded = false,
    this.onShowAllWallets,
    this.onWalletChanged,
    this.onWalletRemoved,
  });

  /// The seed wallet whose page hosts these settings.
  final String? walletId;

  /// The watched address or account whose page hosts these settings.
  final WalletRef? watched;

  /// Hosted as a wallet page's tab: no app bar of its own.
  final bool embedded;

  /// Back to the overview, from the header.
  final VoidCallback? onShowAllWallets;

  /// The wallet was renamed or its pinned address changed.
  final VoidCallback? onWalletChanged;

  /// The wallet was removed, or stopped being watched; carries its id.
  final ValueChanged<String>? onWalletRemoved;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late Future<List<WalletInfo>> _walletsFuture = walletService.listWallets();

  /// Only a seed wallet's page has a seed wallet; the overview's settings
  /// and a watched wallet's page have none.
  String? get _walletId => widget.watched != null ? null : widget.walletId;

  Future<void> _open(Widget page) async {
    await Navigator.push(context, fadeRoute(page));
    if (mounted) setState(() => _walletsFuture = walletService.listWallets());
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
          watchAccountService,
          addressLabelService,
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
              final watched = widget.watched;
              return ListView(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
                children: [
                  const UpdateNotice(),
                  if (current != null) ...[
                    _walletHeader(context, current, wallets.length),
                    const SizedBox(height: 24),
                    _seedGroup(current),
                  ] else if (watched != null) ...[
                    _watchedHeader(context, watched),
                    const SizedBox(height: 24),
                    _watchedGroup(watched),
                  ],
                  _appGroup(includeSecurity: current == null),
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

  Widget _seedGroup(WalletInfo current) {
    return SettingsGroup(
      title: 'This wallet',
      // The header above names the wallet; a long name as the scope tag
      // would run off the label row.
      scope: 'Seed wallet',
      children: [
        SettingsRow(
          icon: Icons.account_balance_wallet_outlined,
          title: 'Name, addresses and backup',
          subtitle: 'Rename, primary address, change policy, remove',
          onTap: () => _open(
            WalletSettingsPage(
              walletId: current.walletId,
              walletName: current.name,
              onChanged: widget.onWalletChanged,
              onRemoved: widget.onWalletRemoved,
            ),
          ),
        ),
        SettingsRow(
          icon: Icons.lock_outline,
          title: 'Security',
          subtitle: 'PIN, biometric unlock, auto-lock',
          onTap: () => _open(SecuritySettingsPage(walletId: current.walletId)),
        ),
      ],
    );
  }

  Widget _appGroup({required bool includeSecurity}) {
    return SettingsGroup(
      title: 'App',
      scope: 'App-wide',
      children: [
        if (includeSecurity)
          SettingsRow(
            icon: Icons.lock_outline,
            title: 'Security',
            subtitle: 'Auto-lock, screenshots, stealth scan, mixing',
            onTap: () => _open(const SecuritySettingsPage()),
          ),
        SettingsRow(
          icon: Icons.qr_code_scanner,
          title: 'Offline signing',
          subtitle: 'Scan, review and sign with this seed wallet',
          onTap: () => openColdSigner(context),
        ),
        SettingsRow(
          icon: Icons.image_outlined,
          title: 'Remote previews',
          subtitle: 'IPFS gateway and Never load remote previews',
          onTap: () => _open(const PreviewSettingsPage()),
        ),
        SettingsRow(
          icon: Icons.hub_outlined,
          title: 'Network',
          subtitle: networkController.statusLabel,
          onTap: () => _open(const NetworkSettingsPage()),
        ),
        SettingsRow(
          icon: Icons.palette_outlined,
          title: 'Display',
          subtitle: '${_appearanceName()} · ${networkController.fiatCode.toUpperCase()}',
          onTap: () => _open(const DisplaySettingsPage()),
        ),
        SettingsRow(
          icon: Icons.contacts_outlined,
          title: 'Address book',
          subtitle: '${contactsService.contacts.length} contacts',
          onTap: () => _open(const AddressBookPage()),
        ),
      ],
    );
  }

  static String _appearanceName() => switch (themeController.mode) {
        ArgusThemeMode.system => '${themeController.darkPalette.name} / ${themeController.lightPalette.name}',
        ArgusThemeMode.dark => themeController.darkPalette.name,
        ArgusThemeMode.light => themeController.lightPalette.name,
      };

  Widget _header(BuildContext context, {required IconData icon, required String name, required String detail}) {
    final colors = ArgusColors.of(context);
    return SoftCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 12, 16),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: accentOf(context).withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: accentOf(context)),
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
                Text(detail, style: TextStyle(fontSize: 12.5, color: colors.muted)),
              ],
            ),
          ),
          if (widget.onShowAllWallets != null)
            TextButton(
              onPressed: widget.onShowAllWallets,
              child: const Text('All wallets'),
            ),
        ],
      ),
    );
  }

  Widget _walletHeader(BuildContext context, WalletInfo current, int count) {
    final unlocked = walletService.isUnlocked && walletService.activeWalletId == current.walletId;
    return _header(
      context,
      icon: Icons.account_balance_wallet_outlined,
      name: current.name,
      detail: [
        unlocked ? 'Unlocked' : 'Locked',
        '$count ${count == 1 ? 'wallet' : 'wallets'} on this device',
      ].join(' · '),
    );
  }

  // ── Watched wallets ────────────────────────────────────────────────────

  WatchAccount? _account(WalletRef ref) {
    for (final a in watchAccountService.accounts) {
      if (a.key == ref.id) return a;
    }
    return null;
  }

  String _watchedName(WalletRef ref) => ref.kind == WalletKind.watchedAccount
      ? (_account(ref)?.label ?? 'Watched account')
      : (addressLabelService.labelFor(ref.id) ?? 'Watched address');

  Widget _watchedHeader(BuildContext context, WalletRef ref) {
    return _header(
      context,
      icon: Icons.visibility_outlined,
      name: _watchedName(ref),
      detail: ref.kind == WalletKind.watchedAccount
          ? 'Watch-only account · ${shorten(ref.id, head: 8, tail: 6)}'
          : 'Watch-only address · ${shorten(ref.id, head: 6, tail: 6)}',
    );
  }

  Widget _watchedGroup(WalletRef ref) {
    final account = ref.kind == WalletKind.watchedAccount;
    return SettingsGroup(
      title: account ? 'This account' : 'This address',
      scope: 'Watch-only',
      children: [
        SettingsRow(
          icon: Icons.edit_outlined,
          title: 'Name',
          subtitle: _watchedName(ref),
          onTap: () => _renameWatched(ref),
        ),
        SettingsRow(
          icon: Icons.visibility_off_outlined,
          title: 'Stop watching',
          subtitle: 'Removes it from this device. Nothing on chain changes.',
          danger: true,
          onTap: () => _unwatch(ref),
        ),
      ],
    );
  }

  Future<void> _renameWatched(WalletRef ref) async {
    final account = _account(ref);
    final name = await showNameDialog(
      context,
      title: 'Name',
      label: 'Name (optional)',
      initial: ref.kind == WalletKind.watchedAccount
          ? (account?.label ?? '')
          : (addressLabelService.labelFor(ref.id) ?? ''),
    );
    if (name == null) return;
    try {
      if (ref.kind == WalletKind.watchedAccount) {
        if (account != null) await watchAccountService.setLabel(account, name);
      } else {
        await addressLabelService.setLabel(ref.id, name);
      }
      widget.onWalletChanged?.call();
    } catch (e) {
      _snack('Could not save the name: $e');
    }
  }

  Future<void> _unwatch(WalletRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stop watching?'),
        content: Text(
          ref.kind == WalletKind.watchedAccount
              ? 'The extended key is removed from this device. Re-import it to watch the account again.'
              : shorten(ref.id, head: 12, tail: 10),
          style: ref.kind == WalletKind.watchedAccount ? null : monoStyle(ctx, size: 12),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: rust, foregroundColor: bone),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Stop watching'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      if (ref.kind == WalletKind.watchedAccount) {
        final account = _account(ref);
        if (account != null) await watchAccountService.remove(account);
      } else {
        await watchOnlyService.remove(ref.id);
      }
    } catch (e) {
      _snack('Could not stop watching: $e');
      return;
    }
    widget.onWalletRemoved?.call(ref.id);
  }
}
