import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../format.dart';
import '../services/dapp_connector.dart';
import '../services/ergopay_summary.dart';
import '../services/network_controller.dart';
import '../services/session_lock.dart';
import '../services/wallet_service.dart';
import '../services/wallet_sync_controller.dart';
import 'widgets/error_sheet.dart';
import '../theme/argus_theme.dart';
import 'confirm_transaction_sheet.dart';
import 'widgets/soft_card.dart';

/// A known dApp on the start page.
/// Addresses a page may use as fresh ones: derived addresses without
/// history, the receive address included when it has none.
List<String> unusedAddressesOf({
  required List<Map<String, dynamic>> used,
  required List<String> frontier,
  required String? receive,
}) {
  final withHistory = {for (final u in used) u['address']?.toString()};
  final out = <String>[
    for (final a in frontier)
      if (!withHistory.contains(a)) a,
  ];
  if (receive != null && receive.isNotEmpty && !withHistory.contains(receive) && !out.contains(receive)) out.add(receive);
  return out;
}

class DappEntry {
  const DappEntry(this.name, this.url, this.blurb);
  final String name;
  final String url;
  final String blurb;
}

const knownDapps = [
  DappEntry('SigmaFi', 'https://sigmafi.app', 'Peer-to-peer bonds'),
  DappEntry('Spectrum', 'https://app.spectrum.fi', 'Swaps and liquidity'),
  DappEntry('Duckpools', 'https://app.duckpools.io', 'Lending pools'),
  DappEntry('Rosen Bridge', 'https://app.rosen.tech', 'Bridge to other chains'),
  DappEntry('ErgoAuctions', 'https://ergoauctions.org', 'NFT auctions'),
  DappEntry('SkyHarbor', 'https://skyharbor.io', 'NFT marketplace'),
  DappEntry('Mew Finance', 'https://mewfinance.com', 'Mew Finance dApps'),
];

/// An in-wallet browser that injects the EIP-12 connector every Ergo dApp
/// speaks to Nautilus, backed by this wallet.
class DappBrowserScreen extends StatefulWidget {
  const DappBrowserScreen({super.key, this.initialUrl});
  final String? initialUrl;

  @override
  State<DappBrowserScreen> createState() => _DappBrowserScreenState();
}

class _DappBrowserScreenState extends State<DappBrowserScreen> implements DappHost {
  late final WebViewController _web;
  late final DappConnector _connector = DappConnector(this);
  final _url = TextEditingController();
  String? _current;
  bool _loading = false;
  bool _showStart = true;
  WalletRouteArgs? _args;

  /// The nonce of the current navigation; only the main frame's connector
  /// script knows it, so only that frame's messages are honoured.
  String _nonce = '';
  String? _injectError;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('ArgusBridge', onMessageReceived: (m) => _onMessage(m.message))
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (u) {
          _nonce = _freshNonce();
          if (mounted) {
            setState(() {
              _loading = true;
              _current = u;
              _url.text = u;
              _injectError = null;
            });
          }
          _inject();
        },
        onPageFinished: (u) {
          _inject();
          if (mounted) setState(() => _loading = false);
        },
        onUrlChange: (c) {
          if (mounted && c.url != null) setState(() => _url.text = c.url!);
        },
      ));
    final u = widget.initialUrl;
    if (u != null) WidgetsBinding.instance.addPostFrameCallback((_) => _open(u));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _args = WalletRouteArgs.of(context);
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  static String _freshNonce() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// Inject the connector into the main frame. A failure leaves the page
  /// without `ergoConnector`, so it is shown rather than swallowed.
  Future<void> _inject() async {
    try {
      await _web.runJavaScript(dappInjectedScript(_nonce));
    } catch (e) {
      if (!mounted) return;
      setState(() => _injectError = 'The wallet connector could not be injected into this page: $e');
    }
  }

  void _open(String text) {
    var t = text.trim();
    if (t.isEmpty) return;
    if (!t.contains('://')) t = 'https://$t';
    final uri = Uri.tryParse(t);
    if (uri == null || uri.host.isEmpty) return;
    if (uri.scheme != 'https') {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Only https sites can open here: a plain http page could be rewritten on the way.')));
      return;
    }
    setState(() => _showStart = false);
    _web.loadRequest(uri);
  }

  String get _origin => originOf(_current);

  Future<void> _onMessage(String raw) async {
    // The nonce is checked before anything else: a frame that does not
    // know it (an iframe, a page that navigated away) gets no answer.
    final req = parseBridgeMessage(raw, _nonce);
    if (req == null) return;
    final id = req.id;
    final method = req.method;
    final params = req.params;
    // The navigation this request belongs to: if the page changes while
    // the request is pending, the answer must not reach the new page.
    final nonce = _nonce;
    final origin = _origin;
    if (origin.isEmpty) return;
    bool ok;
    Object? payload;
    try {
      payload = await _connector.handle(_origin, method, params);
      ok = true;
    } on DappError catch (e) {
      ok = false;
      payload = e.toJson();
    } catch (e) {
      ok = false;
      payload = DappError(DappError.internal, e.toString()).toJson();
    }
    if (!mounted || nonce != _nonce || origin != _origin) return;
    await _web.runJavaScript('window.__argusDapp && window.__argusDapp.resolve(${jsonEncode(id)}, $ok, ${jsonEncode(payload)}, ${jsonEncode(nonce)});');
  }

  // ── DappHost ──────────────────────────────────────────────────────

  @override
  Future<bool> askConnect(String origin) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Connect this site?'),
        content: Text('$origin wants to see this wallet\'s addresses, balances and boxes. '
            'It cannot spend anything without a signature you approve here.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Refuse')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Connect')),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Future<bool> confirmSign(String origin, Map<String, dynamic> summary, int preparationId) async {
    if (!mounted) return false;
    if (!walletService.isUnlocked) {
      await showErrorSheet(context, title: 'Wallet locked', message: 'The wallet locked before the page\'s transaction could be signed. Unlock Argus and ask the page again.');
      return false;
    }
    final s = ErgoPaySummary.fromJson(summary);
    final warning = s.warning;
    final choice = await showConfirmTransactionChoice(
      context,
      title: 'Sign for $origin',
      confirmLabel: 'Sign',
      rows: [
        if (warning != null) ConfirmTxRow('Read first', warning, bold: true),
        ...s.confirmRows(tokens: _args?.tokens ?? const []),
      ],
      recipientAddress: s.recipients.isNotEmpty ? s.recipients.first.address : null,
      detail: 'The page built this transaction. Argus signs it and hands it back; the page broadcasts it.',
      preparationId: preparationId,
      broadcasts: false,
    );
    return choice == ConfirmChoice.broadcast;
  }

  @override
  List<String> get usedAddresses => _args?.historyAddresses ?? const [];

  /// Derived addresses with no history yet: the frontier past the used
  /// ones, and the receive address when it has none.
  @override
  List<String> get unusedAddresses => unusedAddressesOf(
        used: walletSyncController.usedAddresses,
        frontier: walletSyncController.frontierAddresses,
        receive: _args?.receiveAddress,
      );
  @override
  String get changeAddress => _args?.changeAddress ?? '';
  @override
  Future<int> currentHeight() async {
    final h = networkController.height;
    if (h == null) throw const DappError(DappError.internal, 'The chain height is not known yet.');
    return h;
  }

  @override
  Future<List<Map<String, dynamic>>> utxos() async {
    final addresses = usedAddresses.isNotEmpty ? usedAddresses : [changeAddress];
    final raw = await walletService.dappUtxos(addresses, nodeUrl: networkController.activeUrl);
    return [for (final b in jsonDecode(raw) as List) (b as Map).cast<String, dynamic>()];
  }

  @override
  Future<Map<String, dynamic>> prepareSign(String txJson) async =>
      (jsonDecode(await walletService.dappPrepareSign(txJson, nodeUrl: networkController.activeUrl)) as Map).cast<String, dynamic>();

  @override
  Future<String> sign(int preparationId) async {
    try {
      return await sessionLock.run(() => walletService.signPreparation(preparationId: preparationId));
    } catch (e) {
      // The user approved a signature: a failure must be seen here, not
      // only by the page.
      if (mounted) {
        await showErrorSheet(context, title: 'Could not sign for the page', message: e is String ? DappConnector.messageOf(e) : '$e');
      }
      rethrow;
    }
  }

  @override
  Future<String> submit(String signedTxJson) => walletService.submitSignedTransaction(signedTxJson, nodeUrl: networkController.activeUrl);

  // ── UI ────────────────────────────────────────────────────────────

  Future<void> _disconnectSite() async {
    final o = _origin;
    if (o.isEmpty) return;
    await _connector.handle(o, 'disconnect', const []);
    await _web.runJavaScript('if (window.ergo) delete window.ergo;');
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$o disconnected')));
  }

  @override
  Widget build(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    final connected = _connector.connected.contains(_origin) && _origin.isNotEmpty;
    return PopScope(
      canPop: _showStart,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _web.canGoBack()) {
          await _web.goBack();
        } else if (mounted) {
          setState(() => _showStart = true);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            autocorrect: false,
            decoration: InputDecoration(
              hintText: 'Site address',
              isDense: true,
              prefixIcon: _injectError != null
                  ? Tooltip(message: _injectError!, child: Icon(Icons.error_outline, size: 18, color: Theme.of(context).colorScheme.error))
                  : connected
                      ? const Icon(Icons.link, size: 18)
                      : const Icon(Icons.public, size: 18),
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
            onSubmitted: _open,
          ),
          actions: [
            PopupMenuButton<String>(
              onSelected: (v) async {
                switch (v) {
                  case 'reload':
                    await _web.reload();
                  case 'forward':
                    await _web.goForward();
                  case 'disconnect':
                    await _disconnectSite();
                  case 'external':
                    final u = Uri.tryParse(_current ?? '');
                    if (u != null) await launchUrl(u, mode: LaunchMode.externalApplication);
                  case 'home':
                    setState(() => _showStart = true);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'reload', child: Text('Reload')),
                const PopupMenuItem(value: 'forward', child: Text('Forward')),
                PopupMenuItem(value: 'disconnect', enabled: connected, child: const Text('Disconnect this site')),
                const PopupMenuItem(value: 'external', child: Text('Open in the system browser')),
                const PopupMenuItem(value: 'home', child: Text('dApp list')),
              ],
            ),
          ],
          bottom: _loading ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2)) : null,
        ),
        body: _showStart
            ? ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  Text(
                    'Ergo dApps open here with this wallet as their Nautilus. A site sees addresses and balances '
                    'only after you connect it, and spends nothing without a signature you approve.',
                    style: TextStyle(color: muted),
                  ),
                  const SizedBox(height: 16),
                  for (final d in knownDapps)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: SoftCard(
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(d.name),
                          subtitle: Text('${d.blurb} · ${Uri.parse(d.url).host}', style: TextStyle(color: muted, fontSize: 12)),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _open(d.url),
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Text('Not on the list? Type its address above.', style: TextStyle(color: muted, fontSize: 12)),
                  if (_current != null)
                    TextButton(onPressed: () => setState(() => _showStart = false), child: Text('Back to ${shorten(_current!, head: 30, tail: 0)}')),
                ],
              )
            : WebViewWidget(controller: _web),
      ),
    );
  }
}
