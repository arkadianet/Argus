import 'package:flutter/material.dart';
import '../../services/watch_account_service.dart';
import '../../services/wallet_service.dart';
import '../../format.dart';
import '../transactions_screen.dart';
import '../cold_signing_screen.dart';

Future<void> addWatchAccount(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _ImportAccountDialog(),
);

class _ImportAccountDialog extends StatefulWidget {
  const _ImportAccountDialog();
  @override
  State<_ImportAccountDialog> createState() => _ImportAccountDialogState();
}

class _ImportAccountDialogState extends State<_ImportAccountDialog> {
  final controller = TextEditingController();
  String? error;
  var busy = false;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Watch an extended public key'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(watchAccountDisclosure),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Ergo Wallet App extended public key',
              helperText:
                  '156 hex characters, mainnet. No checksum: verify the first address with the source wallet.',
              helperMaxLines: 3,
            ),
          ),
          if (error != null) Text(error!),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: busy
            ? null
            : () async {
                setState(() => busy = true);
                try {
                  final saved = await watchAccountService.add(controller.text);
                  if (!context.mounted) return;
                  if (saved) {
                    Navigator.pop(context);
                  } else {
                    setState(() {
                      error = 'This extended key is already watched.';
                      busy = false;
                    });
                  }
                } catch (e) {
                  if (context.mounted)
                    setState(() {
                      error = e is StateError
                          ? e.message.toString()
                          : watchAccountExpected;
                      busy = false;
                    });
                }
              },
        child: const Text('Watch account'),
      ),
    ],
  );
}

class WatchAccountList extends StatelessWidget {
  const WatchAccountList({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: watchAccountService,
    builder: (context, _) => Column(
      children: [
        for (final account in watchAccountService.accounts)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Watch-only account',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(shorten(account.key, head: 16, tail: 8)),
                  const Text(watchAccountLimitations),
                  const Text(
                    'Discovery stops after 20 unused addresses. Payments beyond a larger gap can be missed.',
                  ),
                  if (account.snapshot case final snapshot?) ...[
                    Text(formatErg(snapshot.balance)),
                    Text('First address: ${snapshot.addresses.first}'),
                    for (final token in snapshot.tokens.entries)
                      Text('${token.value} base units · ${token.key}'),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: account.busy
                              ? null
                              : () async {
                                  await watchAccountService.refresh(account);
                                  if (!context.mounted ||
                                      account.snapshot == null)
                                    return;
                                  final current = account.snapshot!;
                                  Navigator.pushNamed(
                                    context,
                                    '/receive',
                                    arguments: WalletRouteArgs(
                                      watchOnly: true,
                                      watchAccount: true,
                                      senderAddress: current.addresses.first,
                                      receiveAddress: current.receiveAddress,
                                      changeAddress: current.receiveAddress,
                                      historyAddresses: current.addresses,
                                    ),
                                  );
                                },
                          child: const Text('Receive'),
                        ),
                        OutlinedButton(
                          onPressed: account.busy
                              ? null
                              : () => Navigator.push(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) => TransactionsScreen(
                                      args: WalletRouteArgs(
                                        watchOnly: true,
                                        watchAccount: true,
                                        senderAddress: snapshot.addresses.first,
                                        receiveAddress: snapshot.receiveAddress,
                                        changeAddress: snapshot.receiveAddress,
                                        historyAddresses: snapshot.addresses,
                                      ),
                                    ),
                                  ),
                                ),
                          child: const Text('History'),
                        ),
                        OutlinedButton(
                          onPressed: account.busy
                              ? null
                              : () => Navigator.push(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) =>
                                        ColdWatchSendScreen(account: account),
                                  ),
                                ),
                          child: const Text('Send with offline signer'),
                        ),
                      ],
                    ),
                  ],
                  if (account.error != null) Text(account.error!),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: account.busy
                            ? null
                            : () => watchAccountService.refresh(account),
                        child: Text(
                          account.busy ? 'Scanning…' : 'Refresh account',
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          try {
                            await watchAccountService.remove(account);
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Could not stop watching: $e'),
                                ),
                              );
                            }
                          }
                        },
                        child: const Text('Stop watching'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        OutlinedButton.icon(
          onPressed: () => addWatchAccount(context),
          icon: const Icon(Icons.account_tree_outlined),
          label: const Text('Watch an extended public key'),
        ),
      ],
    ),
  );
}
