import '../../format.dart';
import '../../services/activity_classifier.dart';
import '../../services/erg_price_history.dart';
import '../../services/network_controller.dart';
import '../../services/token_metadata.dart';
import '../../services/token_pricer.dart';
import '../../services/token_pricing.dart';
import '../../services/verified_tokens.dart';
import '../../services/wallet_service.dart';
import '../widgets/asset_tile.dart' show tokenTicker;
import 'home_format.dart';
import 'home_models.dart';

// What the home screens show, read from the services they show it from.
// Each builder returns the view models of home_models.dart, so the screens
// only lay figures out and the reading lives in one place: prices from the
// pricer and the network controller, names and scales from the one token
// lookup, activity wording from the activity classifier.

typedef Holding = ({String id, int amount, int decimals});

/// The display currency picked in Display settings.
FiatCurrency homeCurrency() => FiatCurrency(
      symbol: networkController.fiatSymbol,
      code: networkController.fiatCode.toUpperCase(),
      decimals: networkController.fiatCode == 'jpy' ? 0 : 2,
    );

/// No node answers, and none is being looked for.
bool networkOffline() => networkController.activeUrl == null && !networkController.probing;

/// What ERG and [tokens] are worth in the display currency, and how many
/// tokens that value leaves out: those nothing prices, those whose scale
/// nothing knows, and those whose price does not count (unverified pools,
/// stopped feeds). Null while ERG itself has no price in this currency.
({double? fiat, int unpriced}) holdingsFiat(int? ergNano, Iterable<Holding> tokens) {
  final result = tokenPricer.result;
  if (ergNano == null || result.ergUsd == null || !tokenPricer.displayRateKnown) return (fiat: null, unpriced: 0);
  final value = holdingsValue(ergNano: ergNano, tokens: tokens, result: result);
  return (fiat: value.usd * tokenPricer.fiatPerUsd, unpriced: value.unpriced + value.excluded);
}

/// Said beside a fiat value while the ERG rate is not current: the age of
/// the stopped feed it came from ("prices 3 h old"), or when the last good
/// read was. Null while prices are current.
String? pricesNote() {
  if (!tokenPricer.stale) return null;
  if (tokenPricer.result.ergStaleAge case final age?) return 'prices $age old';
  final at = tokenPricer.asOf;
  return at == null ? 'prices stale' : 'prices as of ${formatSyncAge(at)}';
}

/// The overview's network line: whether a node answers, and the chain's
/// height when it does.
NetworkStatus overviewNetwork() {
  if (networkController.activeUrl != null) {
    return NetworkStatus(state: SyncState.synced, blockHeight: networkController.height, label: 'Connected');
  }
  if (networkController.probing) return const NetworkStatus(state: SyncState.syncing, label: 'Looking for a node…');
  return const NetworkStatus(state: SyncState.offline, label: 'No reachable nodes');
}

/// The ERG price as the strip and the ERG row show it: today's rate from
/// the pricer, its source as the pricer names it, and the day's history
/// when [history] is for the same currency and current.
ErgPriceView ergPriceView(ErgPriceHistory? history) {
  final result = tokenPricer.result;
  final rate = networkController.fiatPerErg;
  final staleAge = result.ergStaleAge;
  final via = result.ergVia;
  // The pricer appends ", 3 h old" to a stale source; the age is said once,
  // on its own.
  final source = via == null
      ? tokenPricer.source.label
      : staleAge == null
          ? via
          : via.replaceFirst(', $staleAge old', '');
  final staleNote = staleAge != null
      ? '$staleAge old'
      : tokenPricer.pricesAreOld && tokenPricer.asOf != null
          ? 'as of ${formatSyncAge(tokenPricer.asOf)}'
          : null;
  final h = history;
  final current = h != null &&
      h.available &&
      !h.stale &&
      rate != null &&
      h.currency.toLowerCase() == networkController.fiatCode.toLowerCase();
  String? unavailable;
  if (rate == null) {
    unavailable = result.ergUsd != null && !tokenPricer.displayRateKnown
        ? '${networkController.fiatCode.toUpperCase()} rate not known yet'
        : null;
  } else if (h != null && !h.available) {
    unavailable = h.unavailableReason;
  } else if (h != null && h.stale) {
    unavailable = '${h.sourceLabel} history is out of date';
  }
  return ErgPriceView(
    fiatPerErg: rate,
    source: source,
    points: current ? [for (final p in h.points) p.price] : const [],
    changePercent: current ? h.change24hPct : null,
    trendSource: current && !source.startsWith(h.sourceLabel) ? h.sourceLabel : null,
    historyUnavailable: unavailable?.replaceFirst(RegExp(r'\.$'), ''),
    staleNote: staleNote,
  );
}

/// ERG as the first holding: its amount, value, price and 24h change.
AssetRowData ergAssetRow(int nanoErg, ErgPriceView? price) {
  final rate = networkController.fiatPerErg;
  return AssetRowData(
    id: 'ERG',
    ticker: 'ERG',
    name: 'Ergo',
    amount: BigInt.from(nanoErg),
    decimals: 9,
    fiatValue: rate == null ? null : nanoErg / 1e9 * rate,
    unitFiat: rate,
    changePercent: price != null && price.hasTrend && price.staleNote == null ? price.changePercent : null,
    priceNote: price?.staleNote,
    kind: AssetKind.erg,
  );
}

/// One token holding, named and scaled by the one token lookup and valued
/// by the pricer. A token whose scale nothing knows is shown in raw units
/// and left unvalued; a collectible is never valued.
AssetRowData tokenAssetRow(TokenBalance t) {
  final price = tokenPricer.priceOf(t.id);
  final known = hasKnownScale(t);
  double? fiat;
  if (!t.isCollectible && price != null && tokenPricer.displayRateKnown && (known || price.decimals != null)) {
    final usd = tokenPricer.usdOf(t.id, t.amount, t.decimals);
    if (usd != null) fiat = usd * tokenPricer.fiatPerUsd;
  }
  final name = issuerText(t.name).trim();
  return AssetRowData(
    id: t.id,
    ticker: tokenTicker(t),
    name: name.isNotEmpty ? name : shorten(t.id, head: 10, tail: 6),
    amount: BigInt.from(t.amount),
    decimals: known ? t.decimals : null,
    fiatValue: fiat,
    priceNote: fiat == null || price?.staleAge == null ? null : '${price!.staleAge} old',
    kind: t.isCollectible
        ? AssetKind.collectible
        : (price?.via.startsWith('Spectrum LP share') ?? false)
            ? AssetKind.lpShare
            : AssetKind.token,
    verified: isVerifiedToken(t.id),
    caution: cautionedToken(t.id) != null,
  );
}

/// ERG, then fungible tokens, then collectibles: the order the wallet's
/// asset list uses.
List<AssetRowData> assetRows(int nanoErg, List<TokenBalance> tokens, ErgPriceView? price) => [
      ergAssetRow(nanoErg, price),
      for (final t in tokens)
        if (!t.isCollectible) tokenAssetRow(t),
      for (final t in tokens)
        if (t.isCollectible) tokenAssetRow(t),
    ];

/// Whether a history row is still in the mempool.
bool isPendingTx(Map<String, dynamic> tx) => ((tx['height'] as num?)?.toInt() ?? 0) == 0;

/// The id a home row is keyed and opened by.
String activityRowId(Map<String, dynamic> tx, int index) {
  final id = tx['tx_id']?.toString() ?? '';
  return id.isEmpty ? 'row-$index' : id;
}

/// One history row as the home screens list it, worded as the Activity
/// tab's rows are: the same title, the same counterparty, tokens named and
/// scaled by the one token lookup.
ActivityRowData activityRow(Map<String, dynamic> tx, {required String id}) {
  final view = describeActivity(tx, name: (id) => tokenName(id));
  AmountLeg leg(ActivityLeg l) => l.isErg
      ? AmountLeg(amount: l.amount, decimals: 9, unit: 'ERG')
      : AmountLeg(
          amount: l.amount,
          decimals: tokenDecimals(l.tokenId!),
          unit: tokenName(l.tokenId!) ?? shortTokenId(l.tokenId!),
        );
  // A labelled figure ("Fee 0.0011 ERG") is what left the wallet.
  List<AmountLeg> legsOf(ActivityFigure? f) => [
        for (final l in f?.legs ?? const <ActivityLeg>[])
          f!.label == null ? leg(l) : leg(ActivityLeg(l.tokenId, -l.amount.abs())),
      ];
  String? text(ActivityFigure? f) {
    if (f == null || f.legs.isEmpty) return null;
    final first = f.legs.first;
    if (f.label != null) {
      return '${f.label} ${summaryAmount(first.amount.abs(), 9)}${nbsp}ERG';
    }
    final more = f.legs.length - 1;
    return '${legText(leg(first))}${more > 0 ? ' + $more${nbsp}more' : ''}';
  }

  // Rows read from their flows word their own figures; the rest show their
  // legs, most telling first.
  final worded = view.activity != null;
  return ActivityRowData(
    id: id,
    kind: view.kind,
    label: view.title,
    time: shortActivityTime((tx['timestamp'] as num?)?.toInt()),
    legs: [...legsOf(view.primary), ...legsOf(view.secondary)],
    figure: worded ? text(view.primary) : null,
    subfigure: worded ? text(view.secondary) : null,
    counterparty: view.who,
    pending: isPendingTx(tx),
  );
}
