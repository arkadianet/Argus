import '../format.dart';
import 'token_amounts.dart';

// What a history entry did, read from the whole wallet's point of view.
//
// Each history row carries `io` (see `wallet_net::activity::TxIo`): the
// transaction's inputs and outputs grouped by owner, each marked `mine`
// when the address is one of the wallet's own, and tagged when a box
// belongs to a protocol the wallet knows (`spectrum:pool`,
// `sigmausd:bank`, `argus_fee`, …). From that the wallet's net change per
// asset is exact: a box moving between two of its addresses changes
// nothing, a fee is a fee, a token in its inputs that no output holds was
// burned. Rows without `io` (mix and stealth records, a just-broadcast
// transaction, a snapshot saved by an older version) fall back to the
// legacy per-row reading.

/// The icon family of a history entry: which way value went.
enum ActivityKind { received, sent, swap, selfTransfer, contract, mix }

/// What happened, from the wallet's point of view.
enum ActivityCategory {
  received,
  sent,

  /// Between the wallet's own addresses; only fees left.
  moved,

  /// Many of the wallet's boxes merged into few.
  consolidated,

  /// Tokens the wallet held that no output holds any more.
  burned,

  /// A token created here (its id is the first input's).
  minted,
  swap,

  /// A swap or liquidity order handed to a protocol's bots.
  order,
  liquidityAdded,
  liquidityRemoved,

  /// AgeUSD (SigmaUSD) or Dexy minted by the bank.
  stableMint,
  stableRedeem,
  lending,
  loan,
  bridge,
  staking,
  stealth,
  mix,
  contract,
}

/// Mainnet P2PK addresses are 51 base58 characters starting with 9; anything
/// longer is a script (pool, bank, dApp contract).
bool isContractAddress(String? address) {
  if (address == null || address.isEmpty) return false;
  return !(address.startsWith('9') && address.length == 51);
}

BigInt _big(Object? v) => switch (v) {
      final int i => BigInt.from(i),
      final BigInt b => b,
      final double d => BigInt.from(d),
      final String s => BigInt.tryParse(s) ?? BigInt.zero,
      _ => BigInt.zero,
    };

/// Every box of one owner on one side of a transaction.
class TxParty {
  const TxParty({
    required this.address,
    required this.value,
    required this.assets,
    this.boxes = 1,
    this.tag,
    this.mine = false,
  });

  factory TxParty.fromJson(Map m) => TxParty(
        address: m['address']?.toString() ?? '',
        value: _big(m['value']),
        assets: {
          for (final a in (m['assets'] as List? ?? const []).whereType<Map>())
            a['token_id']?.toString() ?? '': _big(a['amount']),
        },
        boxes: (m['boxes'] as num?)?.toInt() ?? 1,
        tag: m['tag']?.toString(),
        mine: m['mine'] == true,
      );

  Map<String, dynamic> toJson() => {
        'address': address,
        'value': value.isValidInt ? value.toInt() : value.toString(),
        'assets': [
          for (final e in assets.entries)
            {'token_id': e.key, 'amount': e.value.isValidInt ? e.value.toInt() : e.value.toString()},
        ],
        'boxes': boxes,
        'tag': ?tag,
        if (mine) 'mine': true,
      };

  /// Empty for the folded remainder of many foreign owners.
  final String address;
  final BigInt value;

  /// Token id to amount, in the order the boxes list them (a pool's NFT
  /// first, then its LP token).
  final Map<String, BigInt> assets;
  final int boxes;
  final String? tag;
  final bool mine;

  /// `spectrum` of `spectrum:pool`.
  String? get protocol => tag?.split(':').first;
  String? get role => tag == null || !tag!.contains(':') ? null : tag!.split(':')[1];

  TxParty owned(bool mine) =>
      TxParty(address: address, value: value, assets: assets, boxes: boxes, tag: tag, mine: mine);
}

/// A transaction's inputs and outputs, grouped by owner.
class TxFlows {
  const TxFlows({
    required this.inputs,
    required this.outputs,
    required this.minerFee,
    required this.firstInput,
    this.complete = true,
  });

  static TxFlows? of(Map tx) {
    final io = tx['io'];
    if (io is! Map) return null;
    List<TxParty> side(String key) =>
        [for (final p in (io[key] as List? ?? const []).whereType<Map>()) TxParty.fromJson(p)];
    return TxFlows(
      inputs: side('inputs'),
      outputs: side('outputs'),
      minerFee: _big(io['miner_fee']),
      firstInput: io['first_input']?.toString() ?? '',
      complete: io['complete'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
        'inputs': [for (final p in inputs) p.toJson()],
        'outputs': [for (final p in outputs) p.toJson()],
        'miner_fee': minerFee.toInt(),
        'first_input': firstInput,
        'complete': complete,
      };

  final List<TxParty> inputs;
  final List<TxParty> outputs;
  final BigInt minerFee;
  final String firstInput;

  /// False when some inputs could not be read (a pending transaction
  /// spending a foreign box).
  final bool complete;
}

/// One amount that moved: ERG when [tokenId] is null. Signed: positive
/// arrived, negative left.
class ActivityLeg {
  const ActivityLeg(this.tokenId, this.amount);
  final String? tokenId;
  final BigInt amount;
  bool get isErg => tokenId == null;
  ActivityLeg get abs => ActivityLeg(tokenId, amount.abs());
  @override
  String toString() => '${tokenId ?? 'ERG'}:$amount';
}

/// What a row's amount column shows on one line: legs, or a label and one
/// unsigned figure ("Fee 0.0011 ERG").
class ActivityFigure {
  const ActivityFigure(this.legs, {this.label});
  final List<ActivityLeg> legs;
  final String? label;
}

/// A transaction as the wallet saw it.
class WalletActivity {
  const WalletActivity({
    required this.category,
    required this.flows,
    required this.erg,
    required this.received,
    required this.sent,
    required this.burned,
    required this.minted,
    required this.minerFee,
    required this.appFee,
    required this.internalNano,
    required this.recipients,
    required this.senders,
    this.protocol,
    this.role,
    this.contract,
    this.counterLegs = const [],
  });

  final ActivityCategory category;
  final TxFlows flows;

  /// The wallet's net nanoERG change, fees included.
  final BigInt erg;

  /// Tokens that arrived (net, minted ones excluded) and that left (net,
  /// burned ones excluded), as positive amounts.
  final List<ActivityLeg> received;
  final List<ActivityLeg> sent;
  final List<ActivityLeg> burned;
  final List<ActivityLeg> minted;

  /// What the wallet paid: zero when someone else built the transaction.
  final BigInt minerFee;
  final BigInt appFee;

  /// nanoERG that left one of the wallet's addresses for another (change
  /// included).
  final BigInt internalNano;

  /// Outside addresses paid (P2PK and stealth scripts; never the wallet's).
  final List<String> recipients;

  /// Outside addresses that funded an arrival.
  final List<String> senders;

  /// `spectrum`, `sigmausd`, `dexy`, … when a known protocol took part.
  final String? protocol;

  /// The protocol box's role (`pool`, `swap_order`, `lend`, …), or for
  /// staking the pool's name.
  final String? role;

  /// An unrecognised script the wallet dealt with.
  final String? contract;

  /// What an order the wallet's arrival came from had paid in (a bot-filled
  /// swap), so the row can show both sides.
  final List<ActivityLeg> counterLegs;

  BigInt get feesPaid => minerFee + appFee;

  bool get funded => flows.inputs.any((p) => p.mine);

  ActivityKind get kind => switch (category) {
        ActivityCategory.received || ActivityCategory.minted => ActivityKind.received,
        ActivityCategory.sent || ActivityCategory.burned => ActivityKind.sent,
        ActivityCategory.moved || ActivityCategory.consolidated => ActivityKind.selfTransfer,
        ActivityCategory.swap ||
        ActivityCategory.liquidityAdded ||
        ActivityCategory.liquidityRemoved ||
        ActivityCategory.stableMint ||
        ActivityCategory.stableRedeem =>
          ActivityKind.swap,
        ActivityCategory.mix => ActivityKind.mix,
        ActivityCategory.stealth || ActivityCategory.bridge =>
          erg.isNegative || sent.isNotEmpty ? ActivityKind.sent : ActivityKind.received,
        _ => ActivityKind.contract,
      };

  /// Everything that arrived, ERG first when it is the point.
  List<ActivityLeg> get inLegs => [
        for (final t in minted) t,
        for (final t in received) t,
        if (erg > BigInt.zero) ActivityLeg(null, erg),
      ];

  /// Everything that left, fees included in the ERG leg.
  List<ActivityLeg> get outLegs => [
        for (final t in sent) ActivityLeg(t.tokenId, -t.amount),
        for (final t in burned) ActivityLeg(t.tokenId, -t.amount),
        if (erg < BigInt.zero) ActivityLeg(null, erg),
      ];
}

/// Display names of the protocols the tags name.
String protocolName(String protocol, {String? role}) => switch (protocol) {
      'spectrum' => 'Spectrum',
      'sigmausd' => 'SigmaUSD',
      'dexy' => 'Dexy',
      'duckpools' => 'Duckpools',
      'sigmafi' => 'SigmaFi',
      'mixer' => 'ErgoMixer',
      'rosen' => 'Rosen Bridge',
      'stake' => switch (role) {
          'ergopad' => 'Ergopad',
          'egio' => 'EGIO',
          _ => 'Paideia',
        },
      'stealth' => 'stealth address',
      _ => protocol,
    };

/// Tags that say nothing about what the wallet did.
const _incidentalTags = {'argus_fee', 'oracle', 'babel'};

Map<String, BigInt> _sum(Iterable<TxParty> parties) {
  final out = <String, BigInt>{};
  for (final p in parties) {
    p.assets.forEach((id, n) => out[id] = (out[id] ?? BigInt.zero) + n);
  }
  return out;
}

BigInt _value(Iterable<TxParty> parties) => parties.fold(BigInt.zero, (a, p) => a + p.value);

/// The wallet's reading of [tx], or null for a row without `io`.
WalletActivity? walletActivity(Map tx) {
  final flows = TxFlows.of(tx);
  return flows == null ? null : readFlows(flows);
}

/// Classifies one transaction's flows.
WalletActivity readFlows(TxFlows f) {
  final selfIn = f.inputs.where((p) => p.mine).toList();
  final selfOut = f.outputs.where((p) => p.mine).toList();
  final foreignIn = f.inputs.where((p) => !p.mine).toList();
  final foreignOut = f.outputs.where((p) => !p.mine).toList();
  final funded = selfIn.isNotEmpty;

  final inSelf = _sum(selfIn), outSelf = _sum(selfOut);
  final inAll = _sum(f.inputs), outAll = _sum(f.outputs);
  final erg = _value(selfOut) - _value(selfIn);

  final ids = <String>{...inSelf.keys, ...outSelf.keys};
  final received = <ActivityLeg>[], sent = <ActivityLeg>[];
  final burned = <ActivityLeg>[], minted = <ActivityLeg>[];
  for (final id in ids) {
    final net = (outSelf[id] ?? BigInt.zero) - (inSelf[id] ?? BigInt.zero);
    // Burned: what the wallet put in and no output holds. Only a whole
    // input side can tell; a pending transaction's foreign inputs are
    // unread, which can only make this smaller.
    final destroyed = (inAll[id] ?? BigInt.zero) - (outAll[id] ?? BigInt.zero);
    var burnt = BigInt.zero;
    if (funded && destroyed > BigInt.zero) {
      final mineIn = inSelf[id] ?? BigInt.zero;
      burnt = destroyed < mineIn ? destroyed : mineIn;
    }
    if (burnt > BigInt.zero) burned.add(ActivityLeg(id, burnt));
    if (net > BigInt.zero) {
      final issued = id == f.firstInput && (inAll[id] ?? BigInt.zero) == BigInt.zero;
      (issued ? minted : received).add(ActivityLeg(id, net));
    } else if (net < BigInt.zero && -net > burnt) {
      sent.add(ActivityLeg(id, -net - burnt));
    }
  }

  final appFeeParties = foreignOut.where((p) => p.tag == 'argus_fee');
  final appFee = funded ? _value(appFeeParties) : BigInt.zero;
  final minerFee = funded ? f.minerFee : BigInt.zero;
  final internal = funded ? _value(selfOut) : BigInt.zero;
  final paid = foreignOut.where((p) => p.tag != 'argus_fee').toList();
  final recipients = [
    for (final p in paid)
      if (p.tag == null || p.tag == 'stealth')
        if (p.address.isNotEmpty) p.address,
  ];
  final senders = [
    for (final p in foreignIn)
      if (p.tag == null && p.address.isNotEmpty) p.address,
  ];

  // The protocol that took part, by the parties that are not the wallet's.
  final tagged = [
    for (final p in [...foreignIn, ...foreignOut])
      if (p.tag != null && !_incidentalTags.contains(p.tag)) p,
  ];
  bool has(String tag, {bool? input}) => [
        if (input != true) ...foreignOut,
        if (input != false) ...foreignIn,
      ].any((p) => p.tag == tag);
  bool hasProtocol(String protocol) => tagged.any((p) => p.protocol == protocol);

  WalletActivity make(
    ActivityCategory c, {
    String? protocol,
    String? role,
    String? contract,
    List<ActivityLeg> counter = const [],
  }) =>
      WalletActivity(
        category: c,
        flows: f,
        erg: erg,
        received: received,
        sent: sent,
        burned: burned,
        minted: minted,
        minerFee: minerFee,
        appFee: appFee,
        internalNano: internal,
        recipients: recipients,
        senders: senders,
        protocol: protocol,
        role: role,
        contract: contract,
        counterLegs: counter,
      );

  final gains = erg > BigInt.zero || received.isNotEmpty || minted.isNotEmpty;
  final losses = erg < BigInt.zero || sent.isNotEmpty || burned.isNotEmpty;

  // Arrivals that are only the app fee another wallet paid.
  if (!funded && selfOut.isNotEmpty && selfOut.every((p) => p.tag == 'argus_fee')) {
    return make(ActivityCategory.received, protocol: 'argus_fee');
  }

  if (hasProtocol('mixer')) return make(ActivityCategory.mix, protocol: 'mixer');

  // AMMs: Spectrum pools and orders, and the Dexy LP that mirrors them.
  final pools = tagged.where((p) => p.tag == 'spectrum:pool' || p.tag == 'dexy:lp').toList();
  final lpTokens = {
    for (final p in pools)
      if (p.assets.length >= 2) p.assets.keys.elementAt(1),
  };
  final amm = hasProtocol('spectrum') || tagged.any((p) => p.tag!.startsWith('dexy:lp'));
  if (amm) {
    final protocol = hasProtocol('spectrum') ? 'spectrum' : 'dexy';
    final gotLp = received.any((t) => lpTokens.contains(t.tokenId));
    final gaveLp = sent.any((t) => lpTokens.contains(t.tokenId));
    final order = tagged.where((p) => p.tag!.startsWith('spectrum:') && p.tag!.endsWith('_order')).firstOrNull;
    if (order != null && funded && foreignOut.contains(order)) {
      return make(ActivityCategory.order, protocol: protocol, role: order.role);
    }
    // A bot filled the wallet's order: what the wallet paid sits in the
    // order box, the one foreign input that is neither a pool nor the bot.
    // Older order contracts carry no tag, so any lone script input counts.
    final counter = <ActivityLeg>[];
    if (!funded) {
      final orders = [
        ?order,
        ...foreignIn.where((p) => p.tag == null && isContractAddress(p.address)),
      ];
      if (orders.length == 1) {
        final o = orders.single;
        o.assets.forEach((id, n) {
          if (!received.any((t) => t.tokenId == id)) counter.add(ActivityLeg(id, -n));
        });
        final back = erg > BigInt.zero ? erg : BigInt.zero;
        final spentErg = o.value - back;
        if (counter.isEmpty && spentErg > BigInt.zero) counter.add(ActivityLeg(null, -spentErg));
      }
    }
    if (gotLp || has('spectrum:deposit_order', input: true) || has('dexy:lp_mint')) {
      return make(ActivityCategory.liquidityAdded, protocol: protocol, counter: counter);
    }
    if (gaveLp || has('spectrum:redeem_order', input: true) || has('dexy:lp_redeem')) {
      return make(ActivityCategory.liquidityRemoved, protocol: protocol, counter: counter);
    }
    if (pools.isNotEmpty || order != null) {
      if ((gains && (losses || counter.isNotEmpty)) || funded) {
        return make(ActivityCategory.swap, protocol: protocol, counter: counter);
      }
    }
  }

  if (hasProtocol('sigmausd') || tagged.any((p) => p.tag == 'dexy:bank' || p.tag == 'dexy:mint')) {
    final protocol = hasProtocol('sigmausd') ? 'sigmausd' : 'dexy';
    return make(
      received.isNotEmpty ? ActivityCategory.stableMint : ActivityCategory.stableRedeem,
      protocol: protocol,
    );
  }
  if (hasProtocol('duckpools')) {
    final proxy = tagged.where((p) => p.protocol == 'duckpools' && p.role != 'pool' && p.role != 'collateral');
    return make(ActivityCategory.lending, protocol: 'duckpools', role: proxy.isEmpty ? null : proxy.first.role);
  }
  if (hasProtocol('sigmafi')) {
    final role = has('sigmafi:order', input: false) && funded
        ? 'request'
        : has('sigmafi:bond', input: false)
            ? 'loan'
            : has('sigmafi:bond', input: true)
                ? 'repayment'
                : null;
    return make(ActivityCategory.loan, protocol: 'sigmafi', role: role);
  }
  if (hasProtocol('rosen')) {
    return make(ActivityCategory.bridge, protocol: 'rosen', role: has('rosen:lock', input: false) && funded ? 'out' : 'in');
  }
  if (hasProtocol('stake')) {
    final pool = tagged.firstWhere((p) => p.protocol == 'stake' && p.role != 'proxy', orElse: () => tagged.first);
    final role = has('stake:proxy', input: false) && funded
        ? 'request'
        : has('stake:proxy', input: true)
            ? 'unstake'
            : null;
    return make(ActivityCategory.staking, protocol: 'stake', role: '${pool.role == 'proxy' ? 'paideia' : pool.role}:${role ?? ''}');
  }
  if (tagged.any((p) => p.tag == 'stealth')) {
    if ((funded && foreignOut.any((p) => p.tag == 'stealth')) || (!funded && gains)) {
      return make(ActivityCategory.stealth, protocol: 'stealth');
    }
  }

  if (!funded) {
    return make(gains ? ActivityCategory.received : ActivityCategory.contract);
  }
  if (minted.isNotEmpty) return make(ActivityCategory.minted);

  final scripts = paid.where((p) => p.tag == null && isContractAddress(p.address)).toList();
  if (paid.isEmpty) {
    if (burned.isNotEmpty) return make(ActivityCategory.burned);
    // A script's box claimed back into the wallet (a refunded order): an
    // arrival, though the wallet paid the fee.
    if (foreignIn.isNotEmpty && gains) return make(ActivityCategory.received);
    final inBoxes = selfIn.fold(0, (a, p) => a + p.boxes);
    final outBoxes = selfOut.where((p) => p.tag != 'argus_fee').fold(0, (a, p) => a + p.boxes);
    return make(inBoxes >= 3 && outBoxes < inBoxes ? ActivityCategory.consolidated : ActivityCategory.moved);
  }
  if (scripts.isNotEmpty || (received.isNotEmpty && losses)) {
    return make(ActivityCategory.contract, contract: scripts.isEmpty ? null : scripts.first.address);
  }
  if (tagged.isNotEmpty) {
    return make(ActivityCategory.contract, protocol: tagged.first.protocol);
  }
  return make(ActivityCategory.sent);
}

/// [tx] re-read for a wallet that owns [owned] as well: a watched account
/// whose later addresses were derived after its first history reads, or
/// the wallet's stealth scripts. The wallet-wide summary fields
/// (`value_nano_erg`, `tokens_*`, `counterparty`) are recomputed with the
/// flows. Rows without `io` come back unchanged.
Map<String, dynamic> reownActivity(Map<String, dynamic> tx, Set<String> owned) {
  final flows = TxFlows.of(tx);
  if (flows == null || owned.isEmpty) return tx;
  TxParty mark(TxParty p) => p.mine || !owned.contains(p.address) ? p : p.owned(true);
  final next = TxFlows(
    inputs: [for (final p in flows.inputs) mark(p)],
    outputs: [for (final p in flows.outputs) mark(p)],
    minerFee: flows.minerFee,
    firstInput: flows.firstInput,
    complete: flows.complete,
  );
  final a = readFlows(next);
  List<Map<String, dynamic>> tokens(Iterable<ActivityLeg> legs) => [
        for (final l in legs) {'token_id': l.tokenId, 'amount': l.amount.toInt()},
      ];
  final out = a.erg < BigInt.zero || a.sent.isNotEmpty || a.burned.isNotEmpty;
  return {
    ...tx,
    'io': next.toJson(),
    'value_nano_erg': a.erg.toInt(),
    'tokens_received': tokens([...a.minted, ...a.received]),
    'tokens_sent': tokens([...a.sent, ...a.burned]),
    'counterparty': out
        ? (a.recipients.isEmpty ? null : a.recipients.first)
        : (a.senders.isEmpty ? null : a.senders.first),
  };
}

// ─── Wording ──────────────────────────────────────────────────────────────

typedef TokenNamer = String? Function(String id);
typedef TokenScaler = int? Function(String id);

/// A row's words and figures.
class ActivityView {
  const ActivityView({
    required this.kind,
    required this.title,
    required this.primary,
    this.secondary,
    this.who,
    this.activity,
  });

  final ActivityKind kind;
  final String title;

  /// "to 9fRx…3kQe", "Spectrum", "between your addresses"; null for none.
  final String? who;

  /// The amount column: the figure, and the line under it.
  final ActivityFigure primary;
  final ActivityFigure? secondary;

  /// Null for a row read the legacy way.
  final WalletActivity? activity;
}

String _short(String a) => shorten(a, head: 6, tail: 4);

String _name(TokenNamer name, String? id) {
  if (id == null) return 'ERG';
  final n = name(id)?.trim();
  return n == null || n.isEmpty ? shortTokenId(id) : n;
}

String activityTitleFor(WalletActivity a, {required TokenNamer name}) {
  String plural(int n, String one, String many) => n == 1 ? one : many;
  return switch (a.category) {
    ActivityCategory.received => 'Received',
    ActivityCategory.sent => 'Sent',
    ActivityCategory.moved => 'Moved',
    ActivityCategory.consolidated => 'Consolidated',
    ActivityCategory.burned => plural(a.burned.length, 'Burned token', 'Burned tokens'),
    ActivityCategory.minted => plural(a.minted.length, 'Issued token', 'Issued tokens'),
    ActivityCategory.swap => 'Swapped',
    ActivityCategory.order => switch (a.role) {
        'swap_order' => 'Swap order',
        'deposit_order' => 'Liquidity order',
        'redeem_order' => 'Withdrawal order',
        _ => 'Order placed',
      },
    ActivityCategory.liquidityAdded => 'Added liquidity',
    ActivityCategory.liquidityRemoved => 'Removed liquidity',
    ActivityCategory.stableMint =>
      a.received.isEmpty ? 'Minted' : 'Minted ${_name(name, a.received.first.tokenId)}',
    ActivityCategory.stableRedeem =>
      a.sent.isEmpty ? 'Redeemed' : 'Redeemed ${_name(name, a.sent.first.tokenId)}',
    ActivityCategory.lending => switch (a.role) {
        'lend' => 'Lent',
        'withdraw' => 'Withdrew lending',
        'borrow' => 'Borrowed',
        'repay' || 'partial_repay' => 'Repaid loan',
        _ => 'Lending',
      },
    ActivityCategory.loan => switch (a.role) {
        'request' => 'Loan requested',
        'loan' => 'Loan',
        'repayment' => 'Loan repaid',
        _ => 'Loan',
      },
    ActivityCategory.bridge => a.role == 'out' ? 'Bridged out' : 'Bridged in',
    ActivityCategory.staking => switch (a.role?.split(':').last) {
        'request' => 'Unstake requested',
        'unstake' => 'Unstaked',
        _ => 'Staking',
      },
    ActivityCategory.stealth => 'Stealth payment',
    ActivityCategory.mix => 'Mix',
    ActivityCategory.contract => 'Contract interaction',
  };
}

String? _who(WalletActivity a) {
  String list(String lead, List<String> addresses) {
    final first = addresses.first;
    final more = addresses.length - 1;
    final head = isContractAddress(first) ? 'contract ${_short(first)}' : _short(first);
    return '$lead $head${more > 0 ? ' and $more more' : ''}';
  }

  final protocol = a.protocol == null || a.protocol == 'argus_fee'
      ? null
      : protocolName(a.protocol!, role: a.role?.split(':').first);
  return switch (a.category) {
    ActivityCategory.received when a.protocol == 'argus_fee' => 'Argus app fee',
    ActivityCategory.received => a.senders.isEmpty ? null : list('from', a.senders),
    ActivityCategory.sent => a.recipients.isEmpty ? null : list('to', a.recipients),
    ActivityCategory.moved || ActivityCategory.consolidated => 'between your addresses',
    ActivityCategory.burned || ActivityCategory.minted => null,
    ActivityCategory.stealth => a.funded && a.recipients.isNotEmpty ? 'to stealth address' : 'stealth address',
    ActivityCategory.contract => a.contract != null
        ? 'contract ${_short(a.contract!)}'
        : protocol ?? (a.recipients.isNotEmpty ? list('to', a.recipients) : null),
    _ => protocol,
  };
}

/// The fee the wallet paid, as a labelled figure; null when it paid none.
ActivityFigure? _feeFigure(WalletActivity a) {
  final fee = -a.erg;
  return fee > BigInt.zero ? ActivityFigure([ActivityLeg(null, fee)], label: 'Fee') : null;
}

/// The amount column of [a].
({ActivityFigure primary, ActivityFigure? secondary}) activityFigures(WalletActivity a) {
  final ergLeg = a.erg == BigInt.zero ? null : ActivityLeg(null, a.erg);
  List<ActivityLeg> pos(List<ActivityLeg> l) => l;
  List<ActivityLeg> neg(List<ActivityLeg> l) => [for (final t in l) ActivityLeg(t.tokenId, -t.amount)];
  switch (a.category) {
    case ActivityCategory.moved:
    case ActivityCategory.consolidated:
      return (
        primary: _feeFigure(a) ?? ActivityFigure([ActivityLeg(null, BigInt.zero)], label: 'Fee'),
        secondary: null,
      );
    case ActivityCategory.burned:
      return (primary: ActivityFigure(neg(a.burned)), secondary: _feeFigure(a));
    case ActivityCategory.minted:
      return (primary: ActivityFigure(pos(a.minted)), secondary: _feeFigure(a));
    case ActivityCategory.swap:
    case ActivityCategory.liquidityAdded:
    case ActivityCategory.liquidityRemoved:
    case ActivityCategory.stableMint:
    case ActivityCategory.stableRedeem:
      final ins = a.inLegs;
      final fees = a.feesPaid;
      // When tokens went out, an ERG leg that is only the fees is not part
      // of the trade.
      final outs = [
        ...neg(a.sent),
        ...neg(a.burned),
        if (a.erg < BigInt.zero && !(a.sent.isNotEmpty && -a.erg <= fees)) ActivityLeg(null, a.erg),
        ...a.counterLegs,
      ];
      if (ins.isEmpty) return (primary: ActivityFigure(outs), secondary: null);
      return (primary: ActivityFigure(ins), secondary: outs.isEmpty ? null : ActivityFigure(outs));
    case ActivityCategory.received:
      final tokens = [...a.minted, ...a.received];
      if (tokens.isEmpty) return (primary: ActivityFigure([?ergLeg]), secondary: null);
      return (primary: ActivityFigure(tokens), secondary: ergLeg == null ? null : ActivityFigure([ergLeg]));
    case ActivityCategory.sent:
    case ActivityCategory.stealth:
    case ActivityCategory.bridge:
    case ActivityCategory.order:
      final tokens = [...neg(a.sent), ...neg(a.burned)];
      if (tokens.isEmpty) {
        final ins = [...a.received];
        return (
          primary: ActivityFigure([?ergLeg]),
          secondary: ins.isEmpty ? null : ActivityFigure(ins),
        );
      }
      return (primary: ActivityFigure(tokens), secondary: ergLeg == null ? null : ActivityFigure([ergLeg]));
    default:
      final legs = [...a.inLegs, ...a.outLegs];
      if (legs.isEmpty) return (primary: _feeFigure(a) ?? ActivityFigure([?ergLeg]), secondary: null);
      final tokens = legs.where((l) => !l.isErg).toList();
      return tokens.isEmpty || ergLeg == null
          ? (primary: ActivityFigure(legs), secondary: null)
          : (primary: ActivityFigure(tokens), secondary: ActivityFigure([ergLeg]));
  }
}

/// [tx] in words and figures: from its flows when it has them, else the
/// legacy reading.
ActivityView describeActivity(Map tx, {required TokenNamer name}) {
  if (tx['mix'] != true && tx['stealth'] != true) {
    final a = walletActivity(tx);
    if (a != null) {
      final f = activityFigures(a);
      // Named tokens lead, as in [tokenSummary]: the words a person can
      // read are the ones a row keeps.
      bool known(ActivityLeg l) => l.isErg || (name(l.tokenId!)?.trim().isNotEmpty ?? false);
      ActivityFigure order(ActivityFigure f) =>
          ActivityFigure([...f.legs.where(known), ...f.legs.where((l) => !known(l))], label: f.label);
      return ActivityView(
        kind: a.kind,
        title: activityTitleFor(a, name: name),
        who: _who(a),
        primary: order(f.primary),
        secondary: f.secondary == null ? null : order(f.secondary!),
        activity: a,
      );
    }
  }
  return _legacyView(Map<String, dynamic>.from(tx));
}

ActivityView _legacyView(Map<String, dynamic> tx) {
  final kind = classifyActivity(tx);
  final nano = (tx['value_nano_erg'] as num?)?.toInt() ?? 0;
  List<ActivityLeg> tokens(String key, int sign) => [
        for (final t in _tokens(tx, key))
          ActivityLeg(t['token_id']?.toString() ?? '', _big(t['amount']) * BigInt.from(sign)),
      ];
  final erg = nano == 0 ? null : ActivityLeg(null, BigInt.from(nano));
  final received = tokens('tokens_received', 1), sent = tokens('tokens_sent', -1);
  final legs = kind == ActivityKind.swap
      ? [...received, if (nano > 0) ?erg, ...sent, if (nano < 0) ?erg]
      : [?erg, ...received, ...sent];
  final counterparty = tx['counterparty']?.toString();
  final outgoing = kind == ActivityKind.sent || (kind != ActivityKind.received && nano < 0);
  final mixLabel = tx['mix'] == true ? tx['mix_label']?.toString() : null;
  final isStealth = tx['stealth'] == true;
  // A stealth receipt has no counterparty to name: the payer built a
  // one-time script, and nothing on chain says who they were.
  final who = mixLabel ??
      (isStealth
          ? 'to your stealth address'
          : counterparty == null || counterparty.isEmpty
              ? null
              : isContractAddress(counterparty)
                  ? (kind == ActivityKind.swap ? null : 'contract ${_short(counterparty)}')
                  : '${outgoing ? 'to' : 'from'} ${_short(counterparty)}');
  return ActivityView(
    kind: kind,
    title: isStealth && kind == ActivityKind.received ? 'Stealth payment' : activityTitle(kind),
    who: who,
    primary: ActivityFigure(legs.isEmpty ? const [] : [legs.first]),
    secondary: legs.length < 2 ? null : ActivityFigure(legs.sublist(1)),
  );
}

// ─── Legacy reading ──────────────────────────────────────────────────────

List<Map> _tokens(Map tx, String key) =>
    (tx[key] as List?)?.whereType<Map>().toList() ?? const [];

/// The icon family of [tx]. From its flows when it has them.
ActivityKind classifyActivity(Map tx) {
  if (tx['mix'] == true) return ActivityKind.mix;
  if (walletActivity(tx) case final a?) return a.kind;
  final nano = (tx['value_nano_erg'] as num?)?.toInt() ?? 0;
  final counterparty = tx['counterparty']?.toString();
  final tokensIn = _tokens(tx, 'tokens_received').isNotEmpty;
  final tokensOut = _tokens(tx, 'tokens_sent').isNotEmpty;
  if (counterparty == null || counterparty.isEmpty) {
    return nano > 0 ? ActivityKind.received : ActivityKind.selfTransfer;
  }
  if (isContractAddress(counterparty)) {
    if ((nano < 0 && tokensIn) || (nano > 0 && tokensOut)) return ActivityKind.swap;
    if (tokensIn && tokensOut) return ActivityKind.swap;
    if (nano > 0 && !tokensOut) return ActivityKind.received;
    if (nano < 0 && tokensOut) return ActivityKind.sent;
    return ActivityKind.contract;
  }
  return nano < 0 || (nano == 0 && tokensOut) ? ActivityKind.sent : ActivityKind.received;
}

String activityTitle(ActivityKind kind) => switch (kind) {
      ActivityKind.received => 'Received',
      ActivityKind.sent => 'Sent',
      ActivityKind.swap => 'Swapped',
      ActivityKind.selfTransfer => 'Moved',
      ActivityKind.contract => 'Contract',
      ActivityKind.mix => 'Mix',
    };

/// The most tokens a row names before summing up the rest.
const namedTokensPerRow = 2;

/// The tokens of one row, by name: `69 COMET`, `69 COMET + 1.5 SigUSD`, and
/// past [namedTokensPerRow], the first ones then `+ 3 more tokens`. Null for
/// none.
///
/// [name] and [decimals] are the token lookup's answers. A token with no
/// name shows its short id; one whose decimals nothing knows is shown in raw
/// units and says so. Named tokens come first, otherwise in the order the
/// transaction lists them, so the words a person can read are the ones the
/// row keeps.
String? tokenSummary(
  List<Map> tokens, {
  required String? Function(String id) name,
  required int? Function(String id) decimals,
}) {
  if (tokens.isEmpty) return null;
  String? named(String id) {
    final n = name(id)?.trim();
    return n == null || n.isEmpty ? null : n;
  }

  final entries = [
    for (final t in tokens)
      (
        id: t['token_id']?.toString() ?? '',
        amount: _big(t['amount']),
      ),
  ];
  final ordered = [
    ...entries.where((e) => named(e.id) != null),
    ...entries.where((e) => named(e.id) == null),
  ];
  final more = ordered.length - namedTokensPerRow;
  return [
    for (final e in ordered.take(namedTokensPerRow))
      unitsWithLabel(e.amount, decimals(e.id), named(e.id) ?? shortTokenId(e.id)),
    if (more > 0) '$more more ${more == 1 ? 'token' : 'tokens'}',
  ].join(' + ');
}

/// One unsigned figure: "1.5 SigUSD", "0.0011 ERG".
String legAmountText(
  ActivityLeg leg, {
  required TokenNamer name,
  required TokenScaler decimals,
}) =>
    leg.isErg
        ? formatErg(leg.amount.abs().toInt(), unit: true, maxFrac: 4)
        : unitsWithLabel(leg.amount.abs(), decimals(leg.tokenId!), _name(name, leg.tokenId));

/// One figure line in words: "Fee 0.0011 ERG", "100 Test Asset 3 + 5 more".
String figureText(
  ActivityFigure f, {
  required TokenNamer name,
  required TokenScaler decimals,
}) {
  if (f.legs.isEmpty) return formatErg(0, unit: true);
  final first = legAmountText(f.legs.first, name: name, decimals: decimals);
  final more = f.legs.length - 1;
  return [
    if (f.label != null) f.label!,
    first,
    if (more > 0) '+ $more more',
  ].join(' ');
}

/// Second line of an Activity tab row: what moved, e.g. `100 Test Asset 3
/// + 5 more · fee 0.0011 ERG`. An exchange shows what went out and what
/// came back: `2,000 COMET → 0.0349 ERG`.
String activityLine(
  Map<String, dynamic> tx, {
  required String? Function(String id) name,
  required int? Function(String id) decimals,
  bool hidden = false,
}) {
  if (hidden) return '••••';
  final view = describeActivity(tx, name: name);
  final a = view.activity;
  if (a == null) return _legacyLine(tx, name: name, decimals: decimals);
  String text(ActivityFigure f) => figureText(f, name: name, decimals: decimals);
  final secondary = view.secondary;
  if (view.kind == ActivityKind.swap && secondary != null) {
    return '${text(secondary)} → ${text(view.primary)}';
  }
  final second = secondary == null
      ? null
      : secondary.label == null
          ? text(secondary)
          : text(ActivityFigure(secondary.legs, label: secondary.label!.toLowerCase()));
  return [text(view.primary), ?second].join(' · ');
}

String _legacyLine(
  Map<String, dynamic> tx, {
  required String? Function(String id) name,
  required int? Function(String id) decimals,
}) {
  final nano = (tx['value_nano_erg'] as num?)?.toInt() ?? 0;
  final sent = _tokens(tx, 'tokens_sent');
  final received = _tokens(tx, 'tokens_received');
  String erg(int n) => formatErg(n.abs(), unit: true, maxFrac: 4);
  String? summary(List<Map> t) => tokenSummary(t, name: name, decimals: decimals);

  if (classifyActivity(tx) == ActivityKind.swap) {
    final out = [if (summary(sent) case final t?) t, if (nano < 0) erg(nano)];
    final back = [
      if (summary(received) case final t?) t,
      if (nano > 0) erg(nano),
    ];
    if (out.isNotEmpty && back.isNotEmpty) {
      return '${out.join(' + ')} for ${back.join(' + ')}';
    }
  }
  final tokens = nano < 0 || (nano == 0 && sent.isNotEmpty) ? sent : received;
  final parts = <String>[
    if (summary(tokens) case final t?) t,
    if (nano != 0) erg(nano),
  ];
  return parts.isEmpty ? formatErg(0, unit: true) : parts.join(' + ');
}
