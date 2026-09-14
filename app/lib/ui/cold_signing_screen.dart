import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../bridge/api.dart' as api;
import '../services/cold_signing_service.dart';
import '../services/network_controller.dart';
import '../services/watch_account_service.dart';
import '../services/wallet_service.dart';
import 'scan_screen.dart';

class ColdSigningScreen extends StatefulWidget {
  const ColdSigningScreen({
    super.key,
    required this.controller,
    required this.onDiscard,
    this.scan,
    this.handle,
  });
  final ColdSigningController controller;
  final VoidCallback onDiscard;
  final Future<String?> Function(BuildContext)? scan;
  final BigInt? Function()? handle;
  @override
  State<ColdSigningScreen> createState() => _ColdSigningScreenState();
}

class _ColdSigningScreenState extends State<ColdSigningScreen> {
  bool approved = false;
  ColdSigningController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    if (c.stage == ColdStage.requestQr && c.qrPages.isEmpty)
      unawaited(c.loadPages());
  }

  BigInt? get handle =>
      widget.handle != null ? widget.handle!() : walletService.handleId;
  Future<void> scan() async {
    final value =
        await (widget.scan?.call(context) ??
            Navigator.push<String>(
              context,
              MaterialPageRoute(builder: (_) => const ScanScreen()),
            ));
    if (value != null) await c.addPage(value);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: Text(c.hot ? 'Cold-wallet send' : 'Offline signing'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Unsigned sessions expire after 30 minutes. Back pauses; return here to resume. Verified returns remain available for retry. Closing the app discards all sessions.',
          ),
          if (c.busy) const LinearProgressIndicator(),
          if (c.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Refused: ${c.error}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (c.stage == ColdStage.requestQr ||
              c.stage == ColdStage.responseQr) ...[
            Text(
              c.stage == ColdStage.requestQr
                  ? 'Scan every request code with the offline signer.'
                  : 'Signed. Scan every response code with the online wallet.',
            ),
            if (c.qrPages.isNotEmpty) ColdQrSequence(pages: c.qrPages),
            if (c.qrPages.isEmpty && !c.busy)
              OutlinedButton(
                onPressed: c.loadPages,
                child: const Text('Load QR codes'),
              ),
            if (c.hot)
              FilledButton(
                onPressed: c.busy ? null : c.scanResponse,
                child: const Text('Scan signed response'),
              ),
          ],
          if (c.stage == ColdStage.scan) ...[
            if (c.hot)
              TextButton(
                onPressed: c.busy ? null : c.showRequest,
                child: const Text('Show request codes again'),
              ),
            Text(
              c.hot
                  ? 'Collect signed response (CSTX)'
                  : 'Collect signing request (CSR)',
            ),
            Text(
              '${c.received} of ${c.total ?? '?'} scanned',
              key: const Key('page-progress'),
            ),
            if (c.missing.isNotEmpty)
              Text('Missing pages: ${c.missing.join(', ')}'),
            if (c.refused)
              const Text(
                'This scan was refused. Discard the collected pages and restart.',
              ),
            FilledButton.icon(
              onPressed: c.busy || c.refused || c.complete ? null : scan,
              icon: const Icon(Icons.qr_code_scanner),
              label: Text(c.received == 0 ? 'Scan a code' : 'Scan next code'),
            ),
            OutlinedButton(
              onPressed: c.busy
                  ? null
                  : () {
                      approved = false;
                      c.reset();
                    },
              child: const Text('Reset collected pages'),
            ),
            FilledButton(
              onPressed: c.busy || !c.complete ? null : () => c.finish(handle),
              child: Text(
                c.hot ? 'Verify signed transaction' : 'Review transaction',
              ),
            ),
          ],
          if (c.stage == ColdStage.review ||
              c.stage == ColdStage.verified ||
              c.stage == ColdStage.requestQr) ...[
            if (c.reviewData != null)
              ColdTransactionReview(data: c.reviewData!),
          ],
          if (c.stage == ColdStage.review) ...[
            const Text(
              'Independently check the full recipient addresses and quantities. Keep this device offline. Labels from the online wallet are not used.',
            ),
            CheckboxListTile(
              value: approved,
              onChanged: c.busy
                  ? null
                  : (v) => setState(() => approved = v ?? false),
              title: const Text(
                'I checked every output, token and fee on this device',
              ),
            ),
            FilledButton(
              onPressed: approved && !c.busy ? () => c.sign(handle) : null,
              child: const Text('Confirm and sign offline'),
            ),
            OutlinedButton(
              onPressed: c.busy
                  ? null
                  : () {
                      approved = false;
                      c.reset();
                    },
              child: const Text('Reject and reset'),
            ),
          ],
          if (c.stage == ColdStage.verified) ...[
            const Text(
              'Every signature verifies and the transaction exactly matches the prepared payment.',
            ),
            SelectableText('Transaction ID: ${c.transactionId}'),
            FilledButton(
              onPressed: c.busy ? null : c.broadcast,
              child: const Text('Broadcast verified transaction'),
            ),
            const Text(
              'If the network fails, retry sends the same verified transaction. Do not rebuild while its status is uncertain.',
            ),
          ],
          if (c.stage == ColdStage.broadcast) ...[
            const Text('Transaction submitted'),
            SelectableText(c.transactionId!),
          ],
          const SizedBox(height: 24),
          TextButton(
            onPressed: c.busy
                ? null
                : () async {
                    await c.backend.discard(c.session);
                    widget.onDiscard();
                    if (context.mounted) Navigator.pop(context);
                  },
            child: const Text('Discard session'),
          ),
        ],
      ),
    ),
  );
}

class ColdTransactionReview extends StatelessWidget {
  const ColdTransactionReview({super.key, required this.data});
  final Map<String, dynamic> data;
  static String erg(String nano) {
    final n = BigInt.parse(nano);
    return '${n ~/ BigInt.from(1000000000)}.${(n % BigInt.from(1000000000)).toString().padLeft(9, '0')} ERG';
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 16),
      Text(
        'Review · ${data['network']}',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      Text('Miner fee: ${erg(data['fee_nano'] as String)}'),
      const Text(
        'Every output is listed below, including application fees. “Your address” is verified from local keys; it may be change or a self-payment.',
      ),
      for (final output in data['outputs'] as List)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  output['is_fee'] == true
                      ? 'Miner fee'
                      : output['application_fee'] == true
                      ? 'Argus application fee'
                      : output['owned'] == true
                      ? 'Your address'
                      : 'External recipient / application payment',
                ),
                if (output['address'] != null)
                  SelectableText(output['address'] as String),
                Text(erg(output['nano_erg'] as String)),
                for (final token in output['tokens'] as List) ...[
                  SelectableText('Token ID: ${token['id']}'),
                  Text('Quantity: ${token['amount']} base units'),
                ],
              ],
            ),
          ),
        ),
      for (final kind in ['burns', 'mints']) ...[
        Text(
          '${kind == 'burns' ? 'Token burns' : 'Token creation'}: ${(data[kind] as List).isEmpty ? 'None' : ''}',
        ),
        for (final token in data[kind] as List)
          SelectableText('${token['id']} · ${token['amount']} base units'),
      ],
    ],
  );
}

class ColdQrSequence extends StatefulWidget {
  const ColdQrSequence({super.key, required this.pages});
  final List<String> pages;
  @override
  State<ColdQrSequence> createState() => _ColdQrSequenceState();
}

class _ColdQrSequenceState extends State<ColdQrSequence> {
  int page = 0;
  Timer? timer;
  void toggle() {
    if (timer != null) {
      timer!.cancel();
      setState(() => timer = null);
    } else {
      setState(
        () => timer = Timer.periodic(const Duration(seconds: 2), (_) {
          if (mounted) setState(() => page = (page + 1) % widget.pages.length);
        }),
      );
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text('Code ${page + 1} of ${widget.pages.length}'),
      Container(
        color: Colors.white,
        padding: const EdgeInsets.all(12),
        child: QrImageView(
          data: widget.pages[page],
          size: 280,
          errorCorrectionLevel: QrErrorCorrectLevel.L,
        ),
      ),
      Wrap(
        alignment: WrapAlignment.center,
        children: [
          TextButton(
            onPressed: () => setState(
              () =>
                  page = (page - 1 + widget.pages.length) % widget.pages.length,
            ),
            child: const Text('Previous'),
          ),
          TextButton(
            onPressed: toggle,
            child: Text(timer == null ? 'Auto-repeat' : 'Pause'),
          ),
          TextButton(
            onPressed: () =>
                setState(() => page = (page + 1) % widget.pages.length),
            child: const Text('Next'),
          ),
        ],
      ),
    ],
  );
}

Future<void> openColdSigner(BuildContext context) async {
  try {
    pendingColdSigner ??= ColdSigningController(
      session: await api.coldStart(),
      hot: false,
    );
    if (!context.mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ColdSigningScreen(
          controller: pendingColdSigner!,
          onDiscard: () => pendingColdSigner = null,
        ),
      ),
    );
  } catch (e) {
    if (context.mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
  }
}

class ColdWatchSendScreen extends StatefulWidget {
  const ColdWatchSendScreen({super.key, required this.account});
  final WatchAccount account;
  @override
  State<ColdWatchSendScreen> createState() => _ColdWatchSendScreenState();
}

class _ColdWatchSendScreenState extends State<ColdWatchSendScreen> {
  final recipient = TextEditingController();
  final amount = TextEditingController();
  final token = TextEditingController();
  final quantity = TextEditingController();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    recipient.dispose();
    amount.dispose();
    token.dispose();
    quantity.dispose();
    super.dispose();
  }

  Future<void> prepare() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final snapshot = widget.account.snapshot;
      if (snapshot == null)
        throw StateError('Refresh the watched account first.');
      final node = networkController.activeUrl;
      if (node == null) throw StateError('Choose an online node first.');
      final amountNano = int.tryParse(amount.text.trim());
      if (amountNano == null || amountNano <= 0) {
        setState(
          () => error = 'Enter a positive whole number for Amount (nanoERG).',
        );
        return;
      }
      final tokenId = token.text.trim();
      final tokenAmount = BigInt.tryParse(quantity.text.trim());
      if ((tokenId.isNotEmpty || quantity.text.trim().isNotEmpty) &&
          (tokenAmount == null || tokenAmount <= BigInt.zero)) {
        setState(
          () => error = 'Enter a positive whole number for Token quantity.',
        );
        return;
      }
      final raw =
          jsonDecode(
                await api.coldPrepareWatch(
                  key: widget.account.key,
                  addressCount: snapshot.addresses.length,
                  changeIndex: snapshot.highestUsed + 1,
                  recipient: recipient.text.trim(),
                  amountNano: amountNano,
                  tokenId: tokenId.isEmpty ? null : tokenId,
                  tokenAmount: tokenAmount,
                  nodeUrl: node,
                ),
              )
              as Map<String, dynamic>;
      if (networkController.activeUrl != node) {
        await api.coldDiscard(session: raw['session'] as String);
        throw StateError('Node changed during preparation. Try again.');
      }
      pendingColdSends[widget.account.key] = ColdSigningController(
        session: raw['session'] as String,
        hot: true,
        reviewData: raw['review'] as Map<String, dynamic>,
      );
      if (mounted) await resume();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> resume() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ColdSigningScreen(
          controller: pendingColdSends[widget.account.key]!,
          onDiscard: () => pendingColdSends.remove(widget.account.key),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Send with offline signer')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Mainnet P2PK payments. This watched account has no keys. An offline seed wallet must review and sign the request.',
        ),
        if (pendingColdSends.containsKey(widget.account.key))
          FilledButton(
            onPressed: busy ? null : resume,
            child: const Text('Resume cold send'),
          )
        else ...[
          TextField(
            controller: recipient,
            decoration: const InputDecoration(
              labelText: 'Full recipient address',
            ),
          ),
          TextField(
            controller: amount,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Amount in nanoERG (1 ERG = 1000000000)',
            ),
          ),
          TextField(
            controller: token,
            decoration: const InputDecoration(labelText: 'Token ID (optional)'),
          ),
          TextField(
            controller: quantity,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Token quantity in base units (optional)',
            ),
          ),
          FilledButton(
            onPressed: busy ? null : prepare,
            child: const Text('Prepare cold request'),
          ),
        ],
        if (busy) const LinearProgressIndicator(),
        if (error != null) Text('Refused: $error'),
      ],
    ),
  );
}
