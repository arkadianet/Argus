import '../format.dart';
import 'wallet_database_service.dart';

/// One token's share of a [PendingBalance].
class PendingTokenFlow {
  const PendingTokenFlow({
    required this.id,
    required this.confirmed,
    required this.pendingIn,
    required this.pendingOut,
  });

  final String id;
  final int confirmed;
  final int pendingIn;
  final int pendingOut;

  /// The holding once everything pending confirms.
  int get amount {
    final out = confirmed - pendingOut + pendingIn;
    return out < 0 ? 0 : out;
  }

  factory PendingTokenFlow.fromJson(Map<dynamic, dynamic> json) =>
      PendingTokenFlow(
        id: json['id']?.toString() ?? '',
        confirmed: _int(json['confirmed']),
        pendingIn: _int(json['pending_in']),
        pendingOut: _int(json['pending_out']),
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'confirmed': confirmed,
    'pending_in': pendingIn,
    'pending_out': pendingOut,
    'amount': amount,
  };
}

/// What transactions still in the mempool do to a set of addresses'
/// holdings: a wallet, a locked wallet's known addresses, a watched address
/// or account.
///
/// [pendingOutNano] is what pending transactions take from confirmed boxes;
/// [pendingInNano] is what they pay to the set and nothing pending spends
/// again — incoming payments and the wallet's own change alike. A send of
/// 2.5 ERG from a 10 ERG box is therefore 10 out and 7.5 in, so screens show
/// the net [pendingDeltaNano] beside the [confirmedNano] figure rather than
/// the two sides.
///
/// Valued once across the whole set by the Rust core, so a payment between
/// two of the wallet's addresses, or a chain of spends across them, is not
/// counted twice. See `docs/superpowers/specs/2026-08-23-mempool-awareness-design.md`.
class PendingBalance {
  const PendingBalance({
    required this.confirmedNano,
    this.pendingInNano = 0,
    this.pendingOutNano = 0,
    this.tokens = const [],
    this.transactions = 0,
  });

  final int confirmedNano;
  final int pendingInNano;
  final int pendingOutNano;
  final List<PendingTokenFlow> tokens;

  /// Pending transactions that take from or pay to the set.
  final int transactions;

  /// The balance once everything pending confirms.
  int get netNano {
    final out = confirmedNano - pendingOutNano + pendingInNano;
    return out < 0 ? 0 : out;
  }

  /// How far pending transactions move the balance: negative for a spend.
  int get pendingDeltaNano => pendingInNano - pendingOutNano;

  bool get hasPending =>
      transactions > 0 || pendingInNano != 0 || pendingOutNano != 0;

  /// ERG that has arrived but not confirmed yet: what a wallet that waits
  /// for confirmations cannot spend.
  int get confirmingNano => pendingInNano;

  /// What coin selection can spend right now: confirmed boxes nothing
  /// pending spends, plus — when allowed — what is still confirming.
  int spendableNano({required bool allowUnconfirmed}) {
    final out =
        confirmedNano - pendingOutNano + (allowUnconfirmed ? pendingInNano : 0);
    return out < 0 ? 0 : out;
  }

  PendingTokenFlow? token(String id) {
    for (final t in tokens) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// This app's own broadcasts the node has not listed yet, folded in as
  /// their net balance change: a spend counts as leaving, a receipt as
  /// arriving. Keeps [netNano] equal to the balance the screen shows.
  PendingBalance withUnseenBroadcasts(int deltaNano, int count) {
    if (deltaNano == 0 && count == 0) return this;
    return PendingBalance(
      confirmedNano: confirmedNano,
      pendingInNano: pendingInNano + (deltaNano > 0 ? deltaNano : 0),
      pendingOutNano: pendingOutNano + (deltaNano < 0 ? -deltaNano : 0),
      tokens: tokens,
      transactions: transactions + count,
    );
  }

  /// The same pending movements under a figure that also counts funds this
  /// split never valued — a wallet's stealth and mixing pockets, the other
  /// wallets in a total — all of which are in blocks. [confirmedNano]
  /// becomes [shownNano] less the pending delta, so "+2.5 ERG pending ·
  /// X confirmed" adds up to the figure the line sits under. Unchanged when
  /// [shownNano] is this split's own [netNano].
  PendingBalance under(int shownNano) {
    final confirmed = shownNano - pendingDeltaNano;
    return PendingBalance(
      confirmedNano: confirmed < 0 ? 0 : confirmed,
      pendingInNano: pendingInNano,
      pendingOutNano: pendingOutNano,
      tokens: tokens,
      transactions: transactions,
    );
  }

  /// Two sets added together, for an account read address by address. A
  /// payment between two of its addresses shows on both sides, as it does
  /// within one wallet.
  PendingBalance plus(PendingBalance other) {
    final byId = <String, PendingTokenFlow>{for (final t in tokens) t.id: t};
    for (final t in other.tokens) {
      final prev = byId[t.id];
      byId[t.id] = prev == null
          ? t
          : PendingTokenFlow(
              id: t.id,
              confirmed: prev.confirmed + t.confirmed,
              pendingIn: prev.pendingIn + t.pendingIn,
              pendingOut: prev.pendingOut + t.pendingOut,
            );
    }
    return PendingBalance(
      confirmedNano: confirmedNano + other.confirmedNano,
      pendingInNano: pendingInNano + other.pendingInNano,
      pendingOutNano: pendingOutNano + other.pendingOutNano,
      tokens: byId.values.toList()..sort((a, b) => a.id.compareTo(b.id)),
      transactions: transactions + other.transactions,
    );
  }

  /// The Rust `summary` object (see `PendingSummary::to_json`), or null for
  /// anything else — including a summary the node could not value.
  static PendingBalance? fromJson(Object? json) {
    if (json is! Map || json['confirmed_nano_erg'] is! num) return null;
    return PendingBalance(
      confirmedNano: _int(json['confirmed_nano_erg']),
      pendingInNano: _int(json['pending_in_nano_erg']),
      pendingOutNano: _int(json['pending_out_nano_erg']),
      transactions: _int(json['pending_transactions']),
      tokens: [
        for (final t in (json['tokens'] as List? ?? const []))
          if (t is Map) PendingTokenFlow.fromJson(t),
      ],
    );
  }

  Map<String, dynamic> toJson() => {
    'confirmed_nano_erg': confirmedNano,
    'pending_in_nano_erg': pendingInNano,
    'pending_out_nano_erg': pendingOutNano,
    'balance_nano_erg': netNano,
    'pending_transactions': transactions,
    'tokens': [for (final t in tokens) t.toJson()],
  };
}

int _int(Object? v) => v is num ? v.toInt() : 0;

/// The pending summary a wallet's last snapshot carries, live or public.
/// Null when the snapshot predates pending summaries or none was valued.
Future<PendingBalance?> lastKnownPending(String walletId) async {
  final snapshot = await WalletDatabaseService.loadCachedState(
    expectedWalletId: walletId,
  );
  return PendingBalance.fromJson(snapshot?['pending']);
}

/// "+2.5 ERG pending · 105.21 confirmed" — what the mempool does to the
/// balance shown above it — or null when nothing is pending. With
/// [withTotal] the balance leads: "107.71 ERG · +2.5 pending".
String? pendingBalanceText(
  PendingBalance? pending, {
  bool hidden = false,
  bool withTotal = false,
  int maxFrac = 4,
}) {
  if (pending == null || !pending.hasPending) return null;
  if (hidden) return '•••• ERG pending';
  String erg(int nano) => formatErg(nano, unit: false, maxFrac: maxFrac);
  final delta = pending.pendingDeltaNano;
  // A broadcast whose value is not known yet moves nothing on paper; it is
  // still pending, so the line stays, without a figure.
  final moved = delta == 0
      ? null
      : '${delta > 0 ? '+' : '−'}${erg(delta.abs())}';
  if (withTotal) {
    return '${erg(pending.netNano)} ERG · ${moved == null ? 'pending' : '$moved pending'}';
  }
  final lead = moved == null ? 'Pending' : '$moved ERG pending';
  return '$lead · ${erg(pending.confirmedNano)} confirmed';
}
