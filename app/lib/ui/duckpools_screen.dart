import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../format.dart';
import '../services/duckpools_service.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'widgets/empty_state.dart';
import 'widgets/soft_card.dart';

/// Duckpools lending: the pools as they are, and what this wallet lends.
/// Read-only for now; lending and withdrawing are the next step.
class DuckpoolsScreen extends StatefulWidget {
  const DuckpoolsScreen({super.key});

  @override
  State<DuckpoolsScreen> createState() => _DuckpoolsScreenState();
}

class _DuckpoolsScreenState extends State<DuckpoolsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Map<String, int> _holdings(BuildContext context) {
    final args = WalletRouteArgs.of(context);
    return {for (final t in args.tokens) t.id: t.amount};
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    await duckpoolsService.refresh(_holdings(context));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = ArgusColors.of(context).muted;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Duckpools'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: duckpoolsService.busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: duckpoolsService,
        builder: (context, _) {
          final svc = duckpoolsService;
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                Text(
                  'Pool lending on Ergo. Lenders put an asset into a pool and hold '
                  'lend tokens that are worth more of it as borrowers pay interest. '
                  'Borrowers lock ERG as collateral. Argus reads the pools and values '
                  'the lend tokens you already hold; lending from here is the next step.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  svc.lastRefreshedAt == null
                      ? (svc.busy ? 'Reading the pools…' : 'Not read yet')
                      : 'Read ${formatSyncAge(svc.lastRefreshedAt)}',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
                if (svc.lastError != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: SelectableText(
                          'Could not read the pools: ${svc.lastError}',
                          style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copy error',
                        iconSize: 18,
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: svc.lastError!));
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error copied')));
                        },
                        icon: const Icon(Icons.copy),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 20),
                if (svc.positions.isNotEmpty) ...[
                  const SectionLabel('Your positions'),
                  const SizedBox(height: 8),
                  for (final s in svc.positions) ...[
                    _PoolCard(state: s, position: true),
                    const SizedBox(height: 10),
                  ],
                  const SizedBox(height: 12),
                ],
                const SectionLabel('Pools'),
                const SizedBox(height: 8),
                if (svc.states.isEmpty && !svc.busy)
                  const EmptyState(
                    icon: Icons.water_outlined,
                    title: 'No pool data yet',
                    body: 'Pull down to read the eight pools from the chain.',
                    compact: true,
                  )
                else
                  for (final s in svc.states) ...[
                    _PoolCard(state: s, position: false),
                    const SizedBox(height: 10),
                  ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// "27.5%" from basis points.
String utilisationText(int bps) => '${(bps / 100).toStringAsFixed(bps % 100 == 0 ? 0 : 1)}%';

class _PoolCard extends StatelessWidget {
  const _PoolCard({required this.state, required this.position});

  final DuckPoolState state;
  final bool position;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = ArgusColors.of(context).muted;
    final s = state;
    String amt(int units) => formatTokenAmountGrouped(units, s.decimals);
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Expanded(child: Text(label, style: TextStyle(color: muted, fontSize: 12.5))),
              Text(value, style: monoStyle(context, size: 12.5)),
            ],
          ),
        );
    return SoftCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  position ? '${amt(s.walletValue)} ${s.ticker}' : '${s.ticker} pool',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                s.utilisationBps == 0 ? 'nothing borrowed' : '${utilisationText(s.utilisationBps)} lent out',
                style: TextStyle(color: s.utilisationBps == 0 ? muted : accentOf(context), fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (position) ...[
            row('Lend tokens', formatTokenAmountGrouped(s.walletLendTokens, s.decimals)),
            row('Worth today', '${amt(s.walletValue)} ${s.ticker}'),
          ],
          row('In the pool', '${amt(s.pooled)} ${s.ticker}'),
          row('Out on loan', '${amt(s.borrowed)} ${s.ticker}'),
          row('Per lend token', '${s.lendTokenPrice.toStringAsFixed(4)} ${s.ticker}'),
          if (s.utilisationBps == 0) ...[
            const SizedBox(height: 6),
            Text(
              'With nothing borrowed, lenders earn nothing until a borrower appears.',
              style: TextStyle(color: muted, fontSize: 11.5),
            ),
          ],
        ],
      ),
    );
  }
}
