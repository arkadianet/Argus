import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../format.dart';
import '../../services/address_holdings.dart';
import '../../theme/argus_theme.dart';

/// The quiet "incl. 3.2 ERG · 4 tokens on 1 other address" line under a
/// wallet's identity. Only built when other addresses hold something.
class FundsElsewhereLink extends StatelessWidget {
  const FundsElsewhereLink({
    super.key,
    required this.funds,
    required this.hidden,
    this.onTap,
    this.fontSize = 12.5,
  });

  final FundsElsewhere funds;
  final bool hidden;
  final VoidCallback? onTap;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    final text = Text(
      fundsElsewhereLine(funds, hidden: hidden),
      key: const Key('funds-elsewhere'),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: fontSize, color: muted),
    );
    if (onTap == null) return text;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: text),
            Icon(Icons.chevron_right, size: 16, color: muted),
          ],
        ),
      ),
    );
  }
}

/// Holdings in the order the breakdown lists them: the address the wallet
/// is shown as first, then every other funded address by index. Empty
/// addresses are counted, not listed: a wallet can know dozens.
({List<AddressHolding> listed, int emptyOthers}) breakdownRows(
  List<AddressHolding> holdings, {
  required String? identity,
}) {
  final listed = <AddressHolding>[];
  var empty = 0;
  AddressHolding? shownAs;
  for (final h in holdings) {
    if (h.address == identity) {
      shownAs = h;
    } else if (h.holdsFunds) {
      listed.add(h);
    } else {
      empty++;
    }
  }
  listed.sort((a, b) {
    final ia = a.index, ib = b.index;
    if (ia == null && ib == null) return a.address.compareTo(b.address);
    if (ia == null) return 1;
    if (ib == null) return -1;
    return ia.compareTo(ib);
  });
  return (listed: [?shownAs, ...listed], emptyOthers: empty);
}

/// Per-address split of a wallet's balance: index, address, ERG, tokens,
/// with the address the wallet is shown as marked.
Future<void> showAddressBreakdownSheet(
  BuildContext context, {
  required String walletName,
  required List<AddressHolding> holdings,
  required String? identity,
  required bool hidden,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => AddressBreakdownSheet(
      walletName: walletName,
      holdings: holdings,
      identity: identity,
      hidden: hidden,
    ),
  );
}

class AddressBreakdownSheet extends StatelessWidget {
  const AddressBreakdownSheet({
    super.key,
    required this.walletName,
    required this.holdings,
    required this.identity,
    required this.hidden,
  });

  final String walletName;
  final List<AddressHolding> holdings;
  final String? identity;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    final rows = breakdownRows(holdings, identity: identity);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.92,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          24 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          Text(
            'Where $walletName holds funds',
            style: const TextStyle(
              fontFamily: 'Newsreader',
              fontWeight: FontWeight.w600,
              fontSize: 20,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'The wallet is shown as one address, but its balance covers every '
            'address it knows. Any of them can spend from this wallet.',
            style: TextStyle(fontSize: 13, color: muted),
          ),
          const SizedBox(height: 14),
          for (final h in rows.listed)
            _AddressHoldingRow(
              holding: h,
              shownAs: h.address == identity,
              hidden: hidden,
            ),
          if (rows.emptyOthers > 0) ...[
            const SizedBox(height: 8),
            Text(
              '${rows.emptyOthers} other known '
              '${rows.emptyOthers == 1 ? 'address holds' : 'addresses hold'} nothing.',
              style: TextStyle(fontSize: 12.5, color: muted),
            ),
          ],
        ],
      ),
    );
  }
}

class _AddressHoldingRow extends StatelessWidget {
  const _AddressHoldingRow({
    required this.holding,
    required this.shownAs,
    required this.hidden,
  });

  final AddressHolding holding;
  final bool shownAs;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    final tokens = holding.tokenCount;
    return InkWell(
      key: ValueKey('holding-${holding.address}'),
      borderRadius: BorderRadius.circular(12),
      onLongPress: () async {
        await Clipboard.setData(ClipboardData(text: holding.address));
        if (context.mounted) {
          ScaffoldMessenger.maybeOf(
            context,
          )?.showSnackBar(const SnackBar(content: Text('Address copied')));
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 52,
              child: Text(
                holding.index == null ? '#?' : '#${holding.index}',
                style: monoStyle(context, size: 12.5).copyWith(color: muted),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    shorten(holding.address, head: 9, tail: 7),
                    style: monoStyle(context, size: 12.5),
                  ),
                  if (shownAs)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.push_pin_outlined,
                            size: 12,
                            color: accentOf(context),
                          ),
                          const SizedBox(width: 3),
                          Flexible(
                            child: Text(
                              'Shown as this wallet',
                              style: TextStyle(
                                fontSize: 12,
                                color: accentOf(context),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  hidden ? '•••• ERG' : formatErg(holding.nanoErg, maxFrac: 4),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (tokens > 0 && !hidden)
                  Text(
                    '$tokens ${tokens == 1 ? 'token' : 'tokens'}',
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
