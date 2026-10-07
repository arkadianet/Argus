import '../../services/activity_classifier.dart';
import '../../services/address_holdings.dart';
import '../../services/pending_balance.dart';
import '../../services/pockets.dart';
import 'overview_model.dart';

export '../../services/activity_classifier.dart' show ActivityKind;
export '../../services/address_holdings.dart' show FundsElsewhere;
export '../../services/pending_balance.dart' show PendingBalance;
export '../../services/pockets.dart' show Pocket, PocketBalance;
export 'overview_model.dart' show WalletKind, WalletRef;

/// View models for the wallets overview and the wallet page.
///
/// Plain immutable values: whoever builds them reads the services, so the
/// screens stay pure and can be rendered from sample data. Amounts stay
/// raw (nanoERG, token base units) and fiat stays a number, so the screens
/// format every figure the same way instead of each caller doing it. Where
/// a service already has a value type for something (what is pending, what
/// sits on other addresses, a pocket), the screens take that type as it is,
/// so the wording and the arithmetic stay the service's own.

/// The display currency for fiat figures.
class FiatCurrency {
  const FiatCurrency({required this.symbol, required this.code, this.decimals = 2});

  /// Shown before the figure, e.g. `A$`.
  final String symbol;

  /// ISO code, e.g. `AUD`, for screen readers and tooltips.
  final String code;

  /// Fraction digits; 0 for yen.
  final int decimals;
}

/// How current the figures on screen are, for the dot beside the status.
enum SyncState {
  synced,
  syncing,

  /// Something to know about rather than act on: history incomplete, only
  /// public data, not synced yet.
  partial,
  stale,
  offline,
}

class NetworkStatus {
  const NetworkStatus({required this.state, this.blockHeight, this.age, this.label});

  final SyncState state;
  final int? blockHeight;

  /// Age of the last successful sync ("4m ago").
  final String? age;

  /// The words for [state] when a service has its own ("History
  /// incomplete", "Public data · known addresses only").
  final String? label;
}

/// The ERG price and, when there is history, its 24-hour trend.
///
/// This is the price of one ERG from the source picked in Display
/// settings, not the history of the balance above it, and it is labelled
/// that way wherever it appears.
class ErgPriceView {
  const ErgPriceView({
    required this.fiatPerErg,
    required this.source,
    this.points = const [],
    this.changePercent,
    this.window = '24h',
    this.trendSource,
    this.historyUnavailable,
    this.staleNote,
  });

  /// Current price of one ERG in the display currency; null when no
  /// source could price it.
  final double? fiatPerErg;

  /// Where the price comes from, e.g. `SigmaUSD oracle`, `CoinGecko`.
  final String source;

  /// Prices over [window], oldest first. Fewer than two points means no
  /// sparkline.
  final List<double> points;

  /// Change over [window] in percent, e.g. 2.4 for +2.4%.
  final double? changePercent;

  /// The span [points] and [changePercent] cover.
  final String window;

  /// Where the history comes from, when that is not [source]: the price
  /// can come from a fallback feed while the chart is the oracle's.
  final String? trendSource;

  /// Why there is no history, in a few words. Null when history is
  /// available or nobody said why.
  final String? historyUnavailable;

  /// How old the price is when it is not current ("3 h old"): a stale
  /// price is shown with its age, never as if it were today's.
  final String? staleNote;

  bool get hasTrend => points.length >= 2 && changePercent != null;
}

/// One wallet as the overview lists it, and as the wallet page heads it.
class WalletSummary {
  const WalletSummary({
    required this.ref,
    required this.name,
    this.nanoErg,
    this.loading = false,
    this.unavailable,
    this.fiatValue,
    this.tokenCount,
    this.publicTokensOnly = false,
    this.pockets = const [],
    this.pocketsAsOf,
    this.pending,
    this.otherAddresses,
    this.unlocked = false,
    this.asOf,
    this.address,
    this.pinnedIndex,
  });

  final WalletRef ref;
  final String name;

  /// Display balance (public, stealth and mixing pockets, every known
  /// address); null while unknown, which must never read as zero.
  final int? nanoErg;

  /// No balance yet and one on its way.
  final bool loading;

  /// Why [nanoErg] is null, when there is something to say ("Not loaded
  /// yet", "Balance unavailable").
  final String? unavailable;

  /// Value of ERG plus priced tokens in the display currency.
  final double? fiatValue;

  /// Distinct token IDs held, NFTs included; null when the source cannot
  /// say, which is shown as no count rather than "0 tokens".
  final int? tokenCount;

  /// The count covers public addresses only: a locked wallet cannot see
  /// its stealth tokens.
  final bool publicTokensOnly;

  /// The parts of [nanoErg] that are not on public addresses: stealth,
  /// mixed, in a mix. Empty when it is all public.
  final List<PocketBalance> pockets;

  /// Age of the pockets' figures when they are older than the balance: a
  /// locked wallet cannot rescan for stealth funds.
  final String? pocketsAsOf;

  /// What the mempool does to [nanoErg], already split against it
  /// ([PendingBalance.under]); null when nothing valued it.
  final PendingBalance? pending;
  final FundsElsewhere? otherAddresses;

  /// Open in this session: entering it again asks for nothing.
  final bool unlocked;

  /// Age of a snapshot balance ("3h ago"). Locked and watched wallets show
  /// the last public read.
  final String? asOf;

  /// The address the wallet is shown as: the pinned address, index 0, the
  /// watched address or a watched account's first address.
  final String? address;

  /// Set when [address] is a pinned address, shown as "#275".
  final int? pinnedIndex;

  String get id => ref.id;
  WalletKind get kind => ref.kind;
  bool get watchOnly => ref.watched;
}

/// Everything the wallets overview shows.
class OverviewData {
  const OverviewData({
    required this.wallets,
    required this.currency,
    required this.network,
    this.watched = const [],
    this.totalNano,
    this.loading = false,
    this.notLoaded = 0,
    this.totalFiat,
    this.unpricedCount = 0,
    this.pricesNote,
    this.pending,
    this.price,
    this.hidden = false,
  });

  /// Wallets with keys on this phone, in the order the user dragged them.
  final List<WalletSummary> wallets;

  /// Watched addresses and accounts.
  final List<WalletSummary> watched;
  final FiatCurrency currency;
  final NetworkStatus network;

  /// Sum across the wallets whose balance is known; null when none is.
  final int? totalNano;

  /// Nothing known yet and something on its way.
  final bool loading;

  /// Wallets left out of [totalNano] because their balance is unknown.
  final int notLoaded;
  final double? totalFiat;

  /// Tokens the fiat total leaves out because nothing prices them.
  final int unpricedCount;

  /// Said beside the fiat total when the prices are not current.
  final String? pricesNote;
  final PendingBalance? pending;
  final ErgPriceView? price;

  /// Hidden-balances mode: every amount is masked.
  final bool hidden;

  bool get isEmpty => wallets.isEmpty && watched.isEmpty;
}

/// What an asset row is, for its badge and its mark.
enum AssetKind { erg, token, lpShare, collectible }

/// One holding on the wallet page.
class AssetRowData {
  const AssetRowData({
    required this.id,
    required this.ticker,
    required this.amount,
    this.name,
    this.decimals = 0,
    this.fiatValue,
    this.unitFiat,
    this.changePercent,
    this.priceNote,
    this.kind = AssetKind.token,
    this.verified = false,
    this.caution = false,
  });

  /// Token id; `ERG` for ERG.
  final String id;
  final String ticker;

  /// Full name or a short description ("Spectrum pool share").
  final String? name;

  /// Base units (nanoERG for ERG).
  final BigInt amount;

  /// Null when nothing knows the token's scale: the amount is then shown
  /// as the raw units it is, never as whole tokens.
  final int? decimals;

  /// Null when nothing prices the holding.
  final double? fiatValue;

  /// Price of one unit, shown in place of the name. Set for ERG, whose
  /// row carries its price and 24h change.
  final double? unitFiat;

  /// 24h change in percent of [unitFiat].
  final double? changePercent;

  /// How old the price is when it is not current ("3 h old").
  final String? priceNote;
  final AssetKind kind;

  /// On-chain-verified registry entry.
  final bool verified;

  /// Named like a verified token without being one.
  final bool caution;
}

/// One leg of a transaction: a signed amount of one asset.
class AmountLeg {
  const AmountLeg({required this.amount, required this.decimals, required this.unit});

  /// Signed base units: negative left the wallet.
  final BigInt amount;

  /// Null when nothing knows the token's scale (raw units).
  final int? decimals;
  final String unit;
}

/// One transaction in the short Recent activity list.
class ActivityRowData {
  const ActivityRowData({
    required this.id,
    required this.kind,
    required this.time,
    required this.legs,
    this.counterparty,
    this.pending = false,
  });

  final String id;
  final ActivityKind kind;

  /// "10:08 pm", "Yesterday", "Oct 2"; empty when the time is not known.
  final String time;

  /// Amounts that moved, most telling first; the row shows the first and
  /// summarises the rest.
  final List<AmountLeg> legs;

  /// Already phrased: "to 9fRx…3kQe", "contract 5vSU…SCqM", "stealth
  /// payment".
  final String? counterparty;
  final bool pending;

  String get title => activityTitle(kind);
}

/// The wallet page's primary actions.
enum WalletAction { send, sendOffline, receive, swap, more }

/// What the More sheet offers.
enum WalletTool { mix, tokens, utxos, addresses, lock }

/// A More sheet row with its live status, if any.
class WalletToolEntry {
  const WalletToolEntry(this.tool, {this.status, this.warn = false});

  final WalletTool tool;

  /// Short state shown as a badge: "Fragmented", "1 running".
  final String? status;

  /// Draw [status] as something to deal with.
  final bool warn;
}

/// The one line about mixes, while any is running or has just finished.
class MixLine {
  const MixLine({required this.text, this.finished = false});

  final String text;

  /// A finished mix is announced until dismissed.
  final bool finished;
}

/// What a watched wallet's page adds: how it is read, what it cannot do,
/// and the address it is shown as.
class WatchedDetails {
  const WatchedDetails({
    required this.status,
    this.error,
    this.notes = const [],
    this.addressTitle = 'Address',
    this.addressNote,
    this.canSend = true,
    this.canReceive = true,
  });

  /// "Watch-only · cannot sign here", "Updated 2m ago".
  final List<String> status;
  final String? error;

  /// What this wallet can and cannot do, one sentence each.
  final List<String> notes;
  final String addressTitle;
  final String? addressNote;

  /// False while the action cannot work, e.g. before an account's first
  /// scan.
  final bool canSend;
  final bool canReceive;
}

/// Everything the wallet page shows.
class WalletPageData {
  const WalletPageData({
    required this.wallet,
    required this.currency,
    this.status,
    this.offline = false,
    this.assets = const [],
    this.assetCount = 0,
    this.activity = const [],
    this.activityLoading = false,
    this.activityError,
    this.activityEmpty = 'No activity yet',
    this.activityEmptyAction = 'Show my address',
    this.utxoCount,
    this.fragmented = false,
    this.unpricedCount = 0,
    this.pricesNote,
    this.hidden = false,
    this.pendingCount = 0,
    this.pinIssue,
    this.mix,
    this.watched,
    List<WalletAction>? actions,
    List<WalletToolEntry>? tools,
  })  : _actions = actions,
        _tools = tools;

  final WalletSummary wallet;
  final FiatCurrency currency;

  /// The wallet's sync state, with its block and UTXO count; null for a
  /// watched wallet, which says how it is read instead ([watched]).
  final NetworkStatus? status;

  /// No node answers: said once, with a way to look again.
  final bool offline;

  /// The holdings worth a glance, ERG first; [assetCount] is all of them,
  /// NFTs included.
  final List<AssetRowData> assets;
  final int assetCount;

  /// Newest first; the page shows three.
  final List<ActivityRowData> activity;

  /// Nothing read yet, and a read on its way.
  final bool activityLoading;
  final String? activityError;

  /// What an empty activity list says, and the link that goes with it
  /// (the wallet's Receive), if any.
  final String activityEmpty;
  final String? activityEmptyAction;

  final int? utxoCount;

  /// Enough small boxes to slow sends down; the page offers a tidy-up.
  final bool fragmented;
  final int unpricedCount;
  final String? pricesNote;
  final bool hidden;

  /// Unconfirmed transactions, for the Activity tab's badge.
  final int pendingCount;

  /// The pinned address cannot be derived; settings can fix it.
  final String? pinIssue;
  final MixLine? mix;

  /// Set for a watched address or account.
  final WatchedDetails? watched;

  final List<WalletAction>? _actions;
  final List<WalletToolEntry>? _tools;

  /// A watched wallet signs elsewhere, so it trades Send for the offline
  /// signer and drops what needs keys here.
  List<WalletAction> get actions =>
      _actions ??
      (wallet.watchOnly
          ? const [WalletAction.sendOffline, WalletAction.receive]
          : const [WalletAction.send, WalletAction.receive, WalletAction.swap, WalletAction.more]);

  /// Actions drawn but not offered right now.
  Set<WalletAction> get disabled => {
        if (watched case final w?) ...{
          if (!w.canSend) WalletAction.sendOffline,
          if (!w.canReceive) WalletAction.receive,
        },
      };

  List<WalletToolEntry> get tools =>
      _tools ??
      (wallet.watchOnly
          ? const [WalletToolEntry(WalletTool.addresses)]
          : [
              const WalletToolEntry(WalletTool.mix),
              const WalletToolEntry(WalletTool.tokens),
              WalletToolEntry(WalletTool.utxos, status: fragmented ? 'Fragmented' : null, warn: fragmented),
              const WalletToolEntry(WalletTool.addresses),
              const WalletToolEntry(WalletTool.lock),
            ]);
}

/// Tabs of the wallet page's bottom navigation.
enum WalletTab { wallet, activity, discover, settings }
