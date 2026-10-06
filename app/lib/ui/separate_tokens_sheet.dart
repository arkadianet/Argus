import 'package:flutter/material.dart';

import '../format.dart';
import '../services/app_fee.dart';
import '../services/utxo_plans.dart';
import '../services/utxo_tools_controller.dart';
import '../services/wallet_service.dart';

/// Configure one transaction that moves every token type into its own box.
/// This sheet only returns an allocation; the caller prepares and reviews it.
class SeparateTokensSheet extends StatefulWidget {
  const SeparateTokensSheet({
    super.key,
    required this.boxes,
    this.initialSourceId,
  });

  final List<InputBoxInput> boxes;
  final String? initialSourceId;

  @override
  State<SeparateTokensSheet> createState() => _SeparateTokensSheetState();
}

class _SeparateTokensSheetState extends State<SeparateTokensSheet> {
  late final List<InputBoxInput> _sources;
  InputBoxInput? _source;
  final _fundingIds = <String>{};

  @override
  void initState() {
    super.initState();
    _sources =
        widget.boxes
            .where((b) => b.assets.map((a) => a.tokenId).toSet().length >= 2)
            .toList()
          ..sort(compareUtxoAge);
    for (final box in _sources) {
      if (box.boxId == widget.initialSourceId) _source = box;
    }
    _source ??= _sources.isEmpty ? null : _sources.first;
  }

  List<InputBoxInput> get _fundingChoices =>
      widget.boxes
          .where(
            (b) =>
                b.boxId != _source?.boxId &&
                b.assets.isEmpty &&
                b.address != null &&
                b.address == _source?.address,
          )
          .toList()
        ..sort(compareUtxoAge);

  @override
  Widget build(BuildContext context) {
    final source = _source;
    final funding = _fundingChoices;
    SeparateTokensPlan? plan;
    String? issue;
    if (source != null) {
      try {
        plan = planSeparateTokens(
          source: source,
          funding: funding.where((b) => _fundingIds.contains(b.boxId)).toList(),
          feesNano: minerFeeNano + argusFeeNano,
        );
      } on FormatException catch (e) {
        issue = e.message;
      }
    }
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          24,
          20,
          24,
          MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Separate tokens',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Move each token type, with its full balance, into a separate box in your wallet. This uses one transaction.',
            ),
            const SizedBox(height: 16),
            if (source == null)
              const Text('No boxes contain multiple token types.')
            else ...[
              DropdownButtonFormField<String>(
                initialValue: source.boxId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Source box'),
                items: [
                  for (final box in _sources)
                    DropdownMenuItem(
                      value: box.boxId,
                      child: Text(
                        '${shorten(box.boxId, head: 8, tail: 6)} · ${box.assets.length} tokens · ${formatNanoErg(box.valueNanoErg)}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (id) => setState(() {
                  _source = _sources.firstWhere((b) => b.boxId == id);
                  _fundingIds.clear();
                }),
              ),
              const SizedBox(height: 12),
              Text(
                'Each token box holds at least ${formatErg(minBoxNano)}. Miner fee ${formatErg(minerFeeNano)} + Argus fee ${formatErg(argusFeeNano)}.',
              ),
              const SizedBox(height: 8),
              Text(
                'Minimum ERG needed: ${formatErg(source.assets.map((a) => a.tokenId).toSet().length * minBoxNano + minerFeeNano + argusFeeNano)}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Text(
                'Tokens to separate',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final asset in plan?.assets ?? source.assets)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          walletService.cachedTokenMeta(asset.tokenId)?.label ??
                              shorten(asset.tokenId, head: 8, tail: 6),
                        ),
                        subtitle: Text(
                          '${asset.tokenId}\n${asset.amount} raw units',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                  ],
                ),
              ),
              if (funding.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'Add ERG funding',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Text(
                  'Only ERG-only boxes at the source address are listed, oldest first. Select any you want to spend.',
                ),
                const SizedBox(height: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final box in funding)
                        CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: _fundingIds.contains(box.boxId),
                          title: Text(formatNanoErg(box.valueNanoErg)),
                          subtitle: Text(
                            '${shorten(box.boxId, head: 8, tail: 6)} · Height ${box.creationHeight > 0 ? box.creationHeight : "unknown"}',
                          ),
                          onChanged: (checked) => setState(() {
                            if (checked == true) {
                              _fundingIds.add(box.boxId);
                            } else {
                              _fundingIds.remove(box.boxId);
                            }
                          }),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              if (issue != null)
                Text(
                  issue,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                )
              else if (plan != null) ...[
                Text(
                  '${plan.inputs.length} input ${plan.inputs.length == 1 ? "box" : "boxes"} → ${plan.assets.length} token boxes${plan.changeNano > BigInt.zero ? " + ERG change" : ""}',
                ),
                Text(
                  'ERG returned as change: ${formatNanoErg(plan.changeNano)}',
                ),
                const Text(
                  'Every token and all remaining ERG stay in your wallet. A remainder below 0.001 ERG is kept in the first token box.',
                ),
              ],
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: plan == null
                    ? null
                    : () => Navigator.pop(context, plan),
                child: const Text('Review separation'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
