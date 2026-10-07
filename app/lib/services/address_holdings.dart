import '../format.dart';

/// What one address of a wallet held in the balance read that produced the
/// wallet's total.
///
/// A wallet is shown as one address — the pinned one, or index 0 — while its
/// balance covers every address it knows. Keeping the per-address split
/// beside the total is what lets the home screen say that part of that
/// balance sits elsewhere, instead of leaving funds on index 0 of a wallet
/// pinned to a vanity address easy to miss.
class AddressHolding {
  const AddressHolding({
    required this.address,
    this.index,
    required this.nanoErg,
    this.tokens = const [],
  });

  final String address;

  /// Derivation index when known: a position on the discovery frontier, a
  /// discovered address, or the pinned index. Null when nothing recorded it.
  final int? index;
  final int nanoErg;
  final List<({String id, int amount})> tokens;

  bool get holdsFunds => nanoErg > 0 || tokens.any((t) => t.amount > 0);

  /// Distinct token ids with a non-zero amount.
  int get tokenCount =>
      tokens.where((t) => t.amount > 0).map((t) => t.id).toSet().length;

  AddressHolding withIndex(int? value) => AddressHolding(
        address: address,
        index: value,
        nanoErg: nanoErg,
        tokens: tokens,
      );

  /// From one address's balance answer (`balance_nano_erg` plus a raw
  /// `tokens` list), as the node returns it.
  factory AddressHolding.fromBalance(
    String address,
    Map<String, dynamic> balance, {
    int? index,
  }) =>
      AddressHolding(
        address: address,
        index: index,
        nanoErg: (balance['balance_nano_erg'] as num?)?.toInt() ?? 0,
        tokens: _tokens(balance['tokens']),
      );

  Map<String, dynamic> toJson() => {
        'address': address,
        'index': index,
        'balance_nano_erg': nanoErg,
        'tokens': [
          for (final t in tokens) {'id': t.id, 'amount': t.amount},
        ],
      };

  /// Null for anything that is not a recorded holding, so a malformed or
  /// older snapshot degrades to "no breakdown" rather than a wrong one.
  static AddressHolding? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final address = raw['address'];
    if (address is! String || address.isEmpty) return null;
    return AddressHolding(
      address: address,
      index: (raw['index'] as num?)?.toInt(),
      nanoErg: (raw['balance_nano_erg'] as num?)?.toInt() ?? 0,
      tokens: _tokens(raw['tokens']),
    );
  }

  static List<AddressHolding> listFrom(Object? raw) => [
        for (final row in (raw is List ? raw : const []))
          if (fromJson(row) case final holding?) holding,
      ];

  static List<({String id, int amount})> _tokens(Object? raw) => [
        for (final t in (raw is List ? raw : const []))
          if (t is Map && t['id'] is String)
            (id: t['id'] as String, amount: (t['amount'] as num?)?.toInt() ?? 0),
      ];
}

/// Derivation index of [address] from what discovery recorded: its place on
/// the frontier (which runs from index 0) or the index a used address was
/// found at. Null when neither knows it.
int? recordedAddressIndex(
  String address, {
  List<String> frontier = const [],
  List<Map<String, dynamic>> used = const [],
}) {
  final position = frontier.indexOf(address);
  if (position >= 0) return position;
  for (final row in used) {
    if (row['address'] == address) return (row['index'] as num?)?.toInt();
  }
  return null;
}

/// Fills in indices the wallet list itself records: index 0 and the pinned
/// address. A pinned address beyond the discovery gap is never on the
/// frontier, so only the wallet's own metadata knows where it sits.
List<AddressHolding> withWalletIndexes(
  List<AddressHolding> holdings, {
  String? address0,
  String? pinnedAddress,
  int? pinnedIndex,
}) => [
      for (final h in holdings)
        h.index != null
            ? h
            : h.address == pinnedAddress && pinnedIndex != null
                ? h.withIndex(pinnedIndex)
                : h.address == address0
                    ? h.withIndex(0)
                    : h,
    ];

/// Funds a wallet holds away from the address it is shown as.
class FundsElsewhere {
  const FundsElsewhere({
    required this.nanoErg,
    required this.tokenCount,
    required this.addressCount,
  });
  final int nanoErg;

  /// Distinct token ids across those addresses.
  final int tokenCount;
  final int addressCount;
}

/// What [holdings] keep on addresses other than [identity], or null when
/// they keep nothing there — the common case, which must stay silent.
FundsElsewhere? fundsElsewhere(
  List<AddressHolding> holdings, {
  required String? identity,
}) {
  var nano = 0;
  var addresses = 0;
  final tokenIds = <String>{};
  for (final h in holdings) {
    if (h.address == identity || !h.holdsFunds) continue;
    addresses++;
    nano += h.nanoErg;
    tokenIds.addAll(h.tokens.where((t) => t.amount > 0).map((t) => t.id));
  }
  if (addresses == 0) return null;
  return FundsElsewhere(
    nanoErg: nano,
    tokenCount: tokenIds.length,
    addressCount: addresses,
  );
}

/// "incl. 3.2 ERG · 4 tokens on 1 other address". With balances hidden it
/// still says that funds sit elsewhere, but not how much.
String fundsElsewhereLine(FundsElsewhere funds, {bool hidden = false}) {
  final where =
      'on ${funds.addressCount} other ${funds.addressCount == 1 ? 'address' : 'addresses'}';
  if (hidden) return 'incl. funds $where';
  final parts = <String>[
    if (funds.nanoErg > 0) formatErg(funds.nanoErg, maxFrac: 4),
    if (funds.tokenCount > 0)
      '${funds.tokenCount} ${funds.tokenCount == 1 ? 'token' : 'tokens'}',
  ];
  return 'incl. ${parts.join(' · ')} $where';
}
