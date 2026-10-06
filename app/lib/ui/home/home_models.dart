import '../../services/activity_classifier.dart';

export '../../services/activity_classifier.dart' show ActivityKind;

/// View models for the wallets overview and the wallet page.
///
/// Plain immutable values: whoever builds them reads the services, so the
/// screens stay pure and can be rendered from sample data. Amounts stay
/// raw (nanoERG, token base units) and fiat stays a number, so the screens
/// format every figure the same way instead of each caller doing it.

/// Whether this phone holds the wallet's keys or only watches it.
enum WalletKind {
  /// Seed on this phone; can sign.
  seed,

  /// Address or account watched without keys; sends are signed elsewhere.
  watchOnly,
}

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

/// ERG not yet confirmed, signed from the wallet's side: positive is on
/// its way in, negative on its way out.
class PendingFunds {
  const PendingFunds({required this.nanoErg, this.tokenCount = 0});

  final int nanoErg;

  /// Token IDs moving in the same unconfirmed transactions.
  final int tokenCount;

  bool get isEmpty => nanoErg == 0 && tokenCount == 0;
}

/// Funds the wallet holds on addresses other than its pinned primary one.
/// The balance includes them; this says where they are.
class OtherAddressFunds {
  const OtherAddressFunds({
    required this.nanoErg,
    required this.tokenCount,
    required this.addressCount,
  });

  final int nanoErg;
  final int tokenCount;
  final int addressCount;
}

/// How current the figures on screen are.
enum SyncState { synced, syncing, stale, offline }

class NetworkStatus {
  const NetworkStatus({required this.state, this.blockHeight, this.age});

  final SyncState state;
  final int? blockHeight;

  /// Age of the last successful sync ("4m ago"); shown only once the
  /// figures are no longer fresh, since "Synced" already says they are.
  final String? age;
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
    this.historyUnavailable,
    this.stale = false,
  });

  /// Current price of one ERG in the display currency; null when no
  /// source could price it.
  final double? fiatPerErg;

  /// Where the price comes from, e.g. `Oracle pool`, `CoinGecko`.
  final String source;

  /// Prices over [window], oldest first. Fewer than two points means no
  /// sparkline.
  final List<double> points;

  /// Change over [window] in percent, e.g. 2.4 for +2.4%.
  final double? changePercent;

  /// The span [points] and [changePercent] cover.
  final String window;

  /// Why there is no history, in a few words ("No history on this
  /// node"). Null when history is available or nobody said why.
  final String? historyUnavailable;

  /// The last refresh failed and [fiatPerErg] is an older figure.
  final bool stale;

  bool get hasTrend => points.length >= 2 && changePercent != null;
}

/// One wallet as the overview lists it, and as the wallet page heads it.
class WalletSummary {
  const WalletSummary({
    required this.id,
    required this.name,
    this.kind = WalletKind.seed,
    this.nanoErg,
    this.fiatValue,
    this.tokenCount = 0,
    this.stealthNano = 0,
    this.pending,
    this.otherAddresses,
    this.unlocked = false,
    this.asOf,
  });

  final String id;
  final String name;
  final WalletKind kind;

  /// Display balance (spendable plus stealth plus other addresses); null
  /// while unknown, which must never read as zero.
  final int? nanoErg;

  /// Value of ERG plus priced tokens in the display currency.
  final double? fiatValue;

  /// Distinct token IDs held, NFTs included.
  final int tokenCount;

  /// Part of [nanoErg] received privately to stealth addresses.
  final int stealthNano;

  final PendingFunds? pending;
  final OtherAddressFunds? otherAddresses;

  /// Open in this session: entering it again asks for nothing.
  final bool unlocked;

  /// Age of a snapshot balance ("3h ago"), set only when it is old enough
  /// to matter. Locked wallets show the last public snapshot.
  final String? asOf;

  bool get watchOnly => kind == WalletKind.watchOnly;
}

/// Everything the wallets overview shows.
class OverviewData {
  const OverviewData({
    required this.wallets,
    required this.currency,
    required this.network,
    this.totalNano,
    this.totalFiat,
    this.unpricedCount = 0,
    this.pending,
    this.price,
    this.hidden = false,
  });

  final List<WalletSummary> wallets;
  final FiatCurrency currency;
  final NetworkStatus network;

  /// Sum across wallets; null when no wallet's balance is known yet.
  final int? totalNano;
  final double? totalFiat;

  /// Tokens the fiat total leaves out because nothing prices them.
  final int unpricedCount;
  final PendingFunds? pending;
  final ErgPriceView? price;

  /// Hidden-balances mode: every amount is masked.
  final bool hidden;
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
  final int decimals;
  final double? fiatValue;
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
  final int decimals;
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

  /// "Today, 10:08 pm".
  final String time;

  /// Amounts that moved, most telling first; the row shows the first and
  /// summarises the rest.
  final List<AmountLeg> legs;

  /// Already phrased: "to 9fRx…3kQe", "contract 5vSU…SCqM", "Spectrum".
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

/// Everything the wallet page shows.
class WalletPageData {
  const WalletPageData({
    required this.wallet,
    required this.currency,
    required this.network,
    this.price,
    this.assets = const [],
    this.assetCount = 0,
    this.activity = const [],
    this.utxoCount,
    this.fragmented = false,
    this.unpricedCount = 0,
    this.hidden = false,
    this.pendingCount = 0,
    List<WalletAction>? actions,
    List<WalletToolEntry>? tools,
  })  : _actions = actions,
        _tools = tools;

  final WalletSummary wallet;
  final FiatCurrency currency;
  final NetworkStatus network;
  final ErgPriceView? price;

  /// The few holdings worth a glance, ERG first; [assetCount] is all of
  /// them, NFTs included.
  final List<AssetRowData> assets;
  final int assetCount;

  /// Newest first; the page shows three.
  final List<ActivityRowData> activity;

  final int? utxoCount;

  /// Enough small boxes to slow sends down; the card offers a tidy-up.
  final bool fragmented;
  final int unpricedCount;
  final bool hidden;

  /// Unconfirmed transactions, for the Activity tab's badge.
  final int pendingCount;

  final List<WalletAction>? _actions;
  final List<WalletToolEntry>? _tools;

  /// A watched wallet signs elsewhere, so it trades Send for the offline
  /// signer and drops what needs keys here.
  List<WalletAction> get actions =>
      _actions ??
      (wallet.watchOnly
          ? const [WalletAction.sendOffline, WalletAction.receive]
          : const [WalletAction.send, WalletAction.receive, WalletAction.swap, WalletAction.more]);

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
