import 'widgets/tx_result_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../format.dart';
import '../services/network_controller.dart';
import '../services/token_issuance.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'confirm_transaction_sheet.dart';
import 'widgets/error_sheet.dart';
import 'widgets/soft_card.dart';

/// Issue a token or NFT, or burn tokens: two things a wallet does rarely
/// and one of them cannot be undone, so they live apart from Send.
class TokenToolsScreen extends StatefulWidget {
  const TokenToolsScreen({super.key});

  @override
  State<TokenToolsScreen> createState() => _TokenToolsScreenState();
}

class _TokenToolsScreenState extends State<TokenToolsScreen> {
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Tokens'),
          bottom: const TabBar(tabs: [Tab(text: 'Issue'), Tab(text: 'Burn')]),
        ),
        body: const TabBarView(children: [_IssueTab(), _BurnTab()]),
      ),
    );
  }
}

// ── Issue ───────────────────────────────────────────────────────────────

class _IssueTab extends StatefulWidget {
  const _IssueTab();

  @override
  State<_IssueTab> createState() => _IssueTabState();
}

class _IssueTabState extends State<_IssueTab> with AutomaticKeepAliveClientMixin {
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _amount = TextEditingController();
  final _decimals = TextEditingController(text: '0');
  final _hash = TextEditingController();
  final _url = TextEditingController();
  bool _nft = false;
  String _kind = 'picture';
  bool _working = false;
  String? _issuedId;
  String? _issuedTxId;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    for (final c in [_name, _description, _amount, _decimals, _hash, _url]) {
      c.dispose();
    }
    super.dispose();
  }

  int get _decimalsValue => _nft ? 0 : (int.tryParse(_decimals.text.trim()) ?? -1);

  String? get _error => issuanceError(
        name: _name.text,
        amountText: _nft ? '1' : _amount.text,
        decimals: _decimalsValue,
        nft: _nft,
        contentHashHex: _hash.text,
        url: _url.text,
      );

  Future<void> _issue() async {
    if (_working) return;
    final problem = _error;
    if (problem != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    final args = WalletRouteArgs.of(context);
    final amount = _nft ? BigInt.one : parseIssuanceAmount(_amount.text, _decimalsValue)!;
    setState(() => _working = true);
    try {
      final prepared = await walletService.prepareMint(
        senderAddress: args.senderAddress,
        spendAddresses: args.historyAddresses,
        changeAddress: args.changeAddress,
        name: _name.text.trim(),
        description: _description.text.trim(),
        decimals: _decimalsValue,
        amount: amount,
        nftKind: _nft ? _kind : null,
        nftContentHashHex: _nft && _hash.text.trim().isNotEmpty ? _hash.text.trim().toLowerCase() : null,
        nftUrl: _nft ? _url.text.trim() : null,
        nodeUrl: networkController.activeUrl,
      );
      if (!mounted) return;
      final tokenId = prepared['token_id'] as String;
      final ok = await showConfirmTransactionSheet(
        context,
        title: _nft ? 'Issue an NFT' : 'Issue a token',
        confirmLabel: 'Issue',
        detail: 'The new token lands in this wallet. Its name, description and '
            'decimals are written on chain and cannot be changed afterwards.',
        rows: [
          ConfirmTxRow('Name', _name.text.trim(), bold: true),
          ConfirmTxRow('Supply', _nft ? '1 (NFT)' : '${formatTokenAmountGrouped(amount.toInt(), _decimalsValue)} · ${_decimalsValue} decimals'),
          if (_description.text.trim().isNotEmpty) ConfirmTxRow('Description', _description.text.trim()),
          if (_nft) ConfirmTxRow('Kind', _kind),
          if (_nft && _url.text.trim().isNotEmpty) ConfirmTxRow('Link', _url.text.trim()),
          ConfirmTxRow('Token id', shorten(tokenId, head: 10, tail: 8)),
          ConfirmTxRow('Box value', formatErg((prepared['box_value'] as num).toInt())),
          ConfirmTxRow('Argus fee', formatErg((prepared['app_fee_nano'] as num?)?.toInt() ?? 0)),
          ConfirmTxRow('Miner fee', formatErg((prepared['miner_fee'] as num).toInt())),
        ],
        preparationId: (prepared['preparation_id'] as num).toInt(),
      );
      if (!ok || !mounted) return;
      final txId = await walletService.sendErg(
        preparationId: (prepared['preparation_id'] as num).toInt(),
      );
      if (!mounted) return;
      setState(() {
        _issuedId = tokenId;
        _issuedTxId = txId;
      });
      showTxResultSheet(
        context,
        txId: txId,
        headline: 'Token issuance submitted',
        note:
            'The token ID remains on the issuance screen. The token appears in your assets after confirmation.',
      );
    } catch (e) {
      if (mounted) showTxFailureSheet(context, e);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final muted = ArgusColors.of(context).muted;
    final issued = _issuedId;
    if (issued != null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              Icons.check_circle_outline,
              size: 48,
              color: accentOf(context),
            ),
            const SizedBox(height: 12),
            Text(
              '${_name.text.trim()} issuance submitted',
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'It appears in your assets once the transaction confirms. The token id is what other wallets and sites know it by.',
              style: TextStyle(color: muted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            const Text('Token ID', textAlign: TextAlign.center),
            SoftCard(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Expanded(child: SelectableText(issued, style: monoStyle(context, size: 11))),
                  IconButton(
                    tooltip: 'Copy token id',
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: issued));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Token id copied')));
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => showTxResultSheet(
                context,
                txId: _issuedTxId!,
                headline: 'Token issuance submitted',
                note:
                    'The token ID remains on the issuance screen. The token appears in your assets after confirmation.',
              ),
              child: const Text('View transaction receipt'),
            ),
            const Text('Transaction ID'),
            SelectableText(_issuedTxId!, style: monoStyle(context, size: 11)),
            OutlinedButton(
              onPressed: () => setState(() {
                _issuedId = null;
                _issuedTxId = null;
                for (final c in [_name, _description, _amount, _hash, _url]) {
                  c.clear();
                }
              }),
              child: const Text('Issue another'),
            ),
          ],
        ),
      );
    }
    final problem = _error;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        Text(
          'A token is created by a transaction from this wallet. Its id is fixed by that '
          'transaction, and its name, description and decimals are written once, on chain.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('NFT'),
          subtitle: const Text('A single unit with a content hash and a link'),
          value: _nft,
          onChanged: (v) => setState(() {
            _nft = v;
            if (v) {
              _amount.text = '1';
              _decimals.text = '0';
            }
          }),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('issue-name'),
          controller: _name,
          decoration: const InputDecoration(labelText: 'Name'),
          textCapitalization: TextCapitalization.words,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('issue-description'),
          controller: _description,
          decoration: const InputDecoration(labelText: 'Description (optional)'),
          maxLines: 2,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        if (!_nft)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  key: const Key('issue-amount'),
                  controller: _amount,
                  decoration: const InputDecoration(labelText: 'Supply', helperText: 'Whole units, decimals allowed'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: TextField(
                  key: const Key('issue-decimals'),
                  controller: _decimals,
                  decoration: const InputDecoration(labelText: 'Decimals', helperText: '0 to 18'),
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
        if (_nft) ...[
          DropdownButtonFormField<String>(
            initialValue: _kind,
            decoration: const InputDecoration(labelText: 'Kind'),
            items: const [
              DropdownMenuItem(value: 'picture', child: Text('Picture')),
              DropdownMenuItem(value: 'audio', child: Text('Audio')),
              DropdownMenuItem(value: 'video', child: Text('Video')),
            ],
            onChanged: (v) => setState(() => _kind = v ?? 'picture'),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('issue-hash'),
            controller: _hash,
            decoration: const InputDecoration(labelText: 'Content SHA-256 (hex, optional)', helperText: '64 hex characters'),
            style: monoStyle(context, size: 12),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('issue-url'),
            controller: _url,
            decoration: const InputDecoration(labelText: 'Link (optional)', helperText: 'https:// or ipfs://'),
            keyboardType: TextInputType.url,
            onChanged: (_) => setState(() {}),
          ),
        ],
        const SizedBox(height: 8),
        if (problem != null && _name.text.isNotEmpty)
          Text(problem, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
        const SizedBox(height: 16),
        Text('Costs 0.001 ERG for the token box plus the Argus and miner fees.', style: TextStyle(color: muted, fontSize: 12)),
        const SizedBox(height: 12),
        FilledButton(
          key: const Key('issue-continue'),
          onPressed: _working || problem != null ? null : _issue,
          child: Text(_working ? 'Preparing…' : 'Issue'),
        ),
      ],
    );
  }
}

// ── Burn ────────────────────────────────────────────────────────────────

class _BurnTab extends StatefulWidget {
  const _BurnTab();

  @override
  State<_BurnTab> createState() => _BurnTabState();
}

class _BurnTabState extends State<_BurnTab> with AutomaticKeepAliveClientMixin {
  /// Token id to the amount field, for the tokens picked to burn.
  final Map<String, TextEditingController> _picked = {};
  final _confirmWord = TextEditingController();
  bool _working = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    for (final c in _picked.values) {
      c.dispose();
    }
    _confirmWord.dispose();
    super.dispose();
  }

  /// Amounts in base units per token, or the first problem.
  (Map<String, int>?, String?) _burns(List<TokenBalance> held) {
    final out = <String, int>{};
    for (final e in _picked.entries) {
      final t = held.where((t) => t.id == e.key).firstOrNull;
      if (t == null) continue;
      final int? n;
      if (t.isNft) {
        n = 1;
      } else {
        n = parseDecimalToBase(e.value.text, t.decimals);
      }
      if (n == null || n <= 0) return (null, 'Enter how much ${t.label} to burn');
      if (n > t.amount) return (null, 'You hold ${formatTokenAmount(t.amount, t.decimals)} ${t.label}');
      out[e.key] = n;
    }
    if (out.isEmpty) return (null, 'Pick a token to burn');
    return (out, null);
  }

  Future<void> _burn(List<TokenBalance> held) async {
    if (_working) return;
    final (burns, problem) = _burns(held);
    if (burns == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem!)));
      return;
    }
    if (_confirmWord.text.trim() != burnConfirmWord) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Type $burnConfirmWord to go on')));
      return;
    }
    final args = WalletRouteArgs.of(context);
    setState(() => _working = true);
    try {
      final prepared = await walletService.prepareBurn(
        senderAddress: args.senderAddress,
        spendAddresses: args.historyAddresses,
        changeAddress: args.changeAddress,
        burns: burns,
        nodeUrl: networkController.activeUrl,
      );
      if (!mounted) return;
      String label(String id, int n) {
        final t = held.firstWhere((t) => t.id == id);
        return '${formatTokenAmountGrouped(n, t.decimals)} ${t.label}';
      }
      final ok = await showConfirmTransactionSheet(
        context,
        title: 'Burn tokens',
        confirmLabel: 'Burn for good',
        detail: 'These units are left out of every output of the transaction and stop '
            'existing. Nobody, including Argus, can bring them back.',
        rows: [
          for (final b in (prepared['burned'] as List).cast<Map>())
            ConfirmTxRow('Burn', label(b['token_id'] as String, (b['amount'] as num).toInt()), bold: true),
          ConfirmTxRow('Argus fee', formatErg((prepared['app_fee_nano'] as num?)?.toInt() ?? 0)),
          ConfirmTxRow('Miner fee', formatErg((prepared['miner_fee'] as num).toInt())),
          ConfirmTxRow('Back to you', formatErg((prepared['change_nano_erg'] as num).toInt())),
        ],
        preparationId: (prepared['preparation_id'] as num).toInt(),
      );
      if (!ok || !mounted) return;
      final txId = await walletService.sendErg(preparationId: (prepared['preparation_id'] as num).toInt());
      if (!mounted) return;
      setState(() {
        for (final c in _picked.values) {
          c.dispose();
        }
        _picked.clear();
        _confirmWord.clear();
      });
      showTxResultSheet(context, txId: txId, headline: 'Token burn submitted');
    } catch (e) {
      if (mounted) showTxFailureSheet(context, e);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final muted = ArgusColors.of(context).muted;
    final held = WalletRouteArgs.of(context).tokens.where((t) => t.amount > 0).toList();
    final (burns, problem) = _burns(held);
    final ready = burns != null && _confirmWord.text.trim() == burnConfirmWord;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        SoftCard(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.local_fire_department_outlined, color: theme.colorScheme.error),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Burning destroys tokens permanently. It is not a send: the units leave '
                  'the chain rather than move to anyone. Use it for tokens you are sure you '
                  'never want back, such as spam or a supply you mean to cut.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (held.isEmpty)
          Text('This wallet holds no tokens.', style: TextStyle(color: muted))
        else ...[
          Text('Tokens in this wallet', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          for (final t in held)
            CheckboxListTile(
              key: ValueKey('burn-${t.id}'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(t.label),
              subtitle: Text('${formatTokenAmountGrouped(t.amount, t.decimals)} held · ${shorten(t.id, head: 8, tail: 6)}',
                  style: TextStyle(color: muted, fontSize: 12)),
              value: _picked.containsKey(t.id),
              onChanged: (v) => setState(() {
                if (v == true) {
                  _picked[t.id] = TextEditingController(text: t.isNft ? '1' : '');
                } else {
                  _picked.remove(t.id)?.dispose();
                }
              }),
            ),
          for (final t in held)
            if (_picked[t.id] case final ctl?)
              Padding(
                padding: const EdgeInsets.only(left: 40, bottom: 12),
                child: TextField(
                  key: ValueKey('burn-amount-${t.id}'),
                  controller: ctl,
                  enabled: !t.isNft,
                  decoration: InputDecoration(
                    labelText: t.isNft ? '${t.label}: the one unit' : '${t.label} to burn',
                    helperText: t.isNft ? null : 'Of ${formatTokenAmount(t.amount, t.decimals)}',
                    suffixIcon: t.isNft
                        ? null
                        : TextButton(
                            onPressed: () => setState(() => ctl.text = formatTokenAmount(t.amount, t.decimals)),
                            child: const Text('ALL'),
                          ),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                ),
              ),
          if (problem != null && _picked.isNotEmpty)
            Text(problem, style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
          const SizedBox(height: 16),
          TextField(
            key: const Key('burn-confirm-word'),
            controller: _confirmWord,
            decoration: InputDecoration(labelText: 'Type $burnConfirmWord to confirm'),
            textCapitalization: TextCapitalization.characters,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('burn-continue'),
            style: FilledButton.styleFrom(backgroundColor: theme.colorScheme.error, foregroundColor: theme.colorScheme.onError),
            onPressed: _working || !ready ? null : () => _burn(held),
            child: Text(_working ? 'Preparing…' : 'Burn'),
          ),
        ],
      ],
    );
  }
}
