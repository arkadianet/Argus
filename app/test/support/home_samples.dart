import 'dart:math' as math;

import 'package:argus_wallet/ui/home/home_models.dart';

/// Sample data for the home redesign: the figures from the beta.1 home
/// screen (25,529.3427 ERG across 2 wallets and 1 watched, A$11,951.52,
/// 46 unpriced, block 1,888,681, 165 UTXOs), with a pending payment,
/// other-address funds and token names.

const aud = FiatCurrency(symbol: r'A$', code: 'AUD');

const connected = NetworkStatus(state: SyncState.synced, blockHeight: 1888681, label: 'Connected');

const syncedAtTip = NetworkStatus(state: SyncState.synced, blockHeight: 1888681, age: 'just now', label: 'Synced');

BigInt _units(num whole, int decimals) => BigInt.from((whole * math.pow(10, decimals)).round());
int _nano(num erg) => (erg * 1e9).round();

/// Hourly oracle prices over the last day, ending at A$0.4682 (+2.4%).
const ergPricePoints = [
  0.4571, 0.4568, 0.4580, 0.4592, 0.4585, 0.4577, 0.4589, 0.4603, 0.4611, 0.4598, 0.4606, 0.4624, 0.4631, //
  0.4619, 0.4627, 0.4645, 0.4652, 0.4641, 0.4650, 0.4668, 0.4659, 0.4664, 0.4677, 0.4671, 0.4682,
];

const ergPriceWithHistory = ErgPriceView(
  fiatPerErg: 0.4682,
  source: 'SigmaUSD oracle',
  points: ergPricePoints,
  changePercent: 2.4,
);

/// What the strip shows on a node without the extra index.
const ergPriceWithoutHistory = ErgPriceView(
  fiatPerErg: 0.4682,
  source: 'SigmaUSD oracle',
  historyUnavailable: 'This node has no price history for SigmaUSD oracle yet',
);

const mainAddress = '9fRAxbQ2mTe8LwZk5Ny7cVh3PdG6uJs1BqX4aKoHnYtMv9WEeR';
const watchedAddress = '9hY16vzHmmfyVBwKeFGHvb2bMFsG94A1u7To1QWtUokACyFVENQ';

/// 2.5 ERG arriving into a wallet showing 107.7134.
final mainPending = PendingBalance(
  confirmedNano: _nano(107.7134) - _nano(2.5),
  pendingInNano: _nano(2.5),
  transactions: 1,
);

final mainWallet = WalletSummary(
  ref: const WalletRef.seed('main'),
  name: 'Main Wallet',
  nanoErg: _nano(107.7134),
  fiatValue: 50.43,
  tokenCount: 50,
  pockets: [PocketBalance(pocket: Pocket.stealth, nanoErg: _nano(0.001))],
  pending: mainPending,
  otherAddresses: FundsElsewhere(nanoErg: _nano(3.2), tokenCount: 4, addressCount: 1),
  unlocked: true,
  address: mainAddress,
);

const emptyWallet = WalletSummary(
  ref: WalletRef.seed('9evoke9'),
  name: '9evoke9',
  nanoErg: 0,
  fiatValue: 0,
  tokenCount: 0,
);

final watchedWallet = WalletSummary(
  ref: const WalletRef.watchedAddress(watchedAddress),
  name: 'Watched',
  nanoErg: _nano(25421.6293),
  fiatValue: 11901.08,
  tokenCount: 3,
  address: watchedAddress,
);

OverviewData sampleOverview({bool hidden = false, List<WalletSummary>? wallets, List<WalletSummary>? watched}) =>
    OverviewData(
      wallets: wallets ?? [emptyWallet, mainWallet],
      watched: watched ?? [watchedWallet],
      currency: aud,
      network: connected,
      totalNano: _nano(25529.3427),
      totalFiat: 11951.52,
      unpricedCount: 46,
      pending: mainPending.under(_nano(25529.3427)),
      price: ergPriceWithHistory,
      hidden: hidden,
    );

final _mainAssets = [
  AssetRowData(
    id: 'ERG',
    ticker: 'ERG',
    name: 'Ergo',
    amount: BigInt.from(_nano(107.7134)),
    decimals: 9,
    fiatValue: 50.43,
    unitFiat: 0.4682,
    changePercent: 2.4,
    kind: AssetKind.erg,
  ),
  AssetRowData(
    id: 'b4f5a8c2e96d1f0374a2c6e8d9b0517f3e2a4c6d8f0b1e3a5c7d9f1b3e5a7c9d',
    ticker: 'ERG_SigRSV_LP',
    name: 'ERG / SigRSV pool share',
    amount: BigInt.from(86),
    fiatValue: 4.18,
    kind: AssetKind.lpShare,
  ),
  AssetRowData(
    id: 'e023c5f382b6e96fbd878f6811aac73345489032157ad5affb84aefd4956c297',
    ticker: 'rsADA',
    name: 'Rosen-bridged ADA',
    amount: _units(1.5, 6),
    decimals: 6,
    fiatValue: 0.98,
    verified: true,
  ),
  AssetRowData(
    id: '6de6f46e0c2b8a4f1d3e5a7b9c0d2e4f6a8b0c1d3e5f7a9b0c2d4e6f8a0b1c3d',
    ticker: 'Ergo_6de6f46e_LP',
    name: 'Spectrum pool share',
    amount: BigInt.from(18252893012),
    fiatValue: 0.87,
    kind: AssetKind.lpShare,
  ),
  AssetRowData(
    id: '0cd8c9f416e5b1ca9f986a7f10a84191dfb85941619e49e53c0dc30ebf83324b',
    ticker: 'COMET',
    name: 'Comet',
    amount: BigInt.from(69),
    fiatValue: 0.21,
    verified: true,
  ),
  AssetRowData(
    id: '1fd6e032e8476c4aa54c18c1a308dce83940e8f4a28f576440513ed7326ad489',
    ticker: 'Paideia',
    name: 'Paideia DAO token',
    amount: _units(240, 4),
    decimals: 4,
    fiatValue: 0.12,
    verified: true,
  ),
  AssetRowData(
    id: '003bd19d0187117f130b62e1bcab0939929ff5c7709f843c5c4dd158949285d0',
    ticker: 'SigRSV',
    name: 'SigmaUSD reserve',
    amount: BigInt.from(79),
    fiatValue: 0.04,
    verified: true,
  ),
];

final _mainActivity = [
  ActivityRowData(
    id: 'a1',
    kind: ActivityKind.received,
    time: '10:41 pm',
    pending: true,
    counterparty: 'from 9gF3uX…Wq7z',
    legs: [AmountLeg(amount: BigInt.from(_nano(2.5)), decimals: 9, unit: 'ERG')],
  ),
  ActivityRowData(
    id: 'a2',
    kind: ActivityKind.sent,
    time: '10:08 pm',
    counterparty: 'contract 5vSUZR…SCqM',
    legs: [
      AmountLeg(amount: BigInt.from(-_nano(1.8162)), decimals: 9, unit: 'ERG'),
      AmountLeg(amount: BigInt.from(-69), decimals: 0, unit: 'COMET'),
      AmountLeg(amount: BigInt.from(-1250), decimals: 2, unit: 'SigUSD'),
    ],
  ),
  ActivityRowData(
    id: 'a3',
    kind: ActivityKind.swap,
    time: 'Yesterday',
    legs: [
      AmountLeg(amount: BigInt.from(79), decimals: 0, unit: 'SigRSV'),
      AmountLeg(amount: BigInt.from(-_nano(4.2)), decimals: 9, unit: 'ERG'),
    ],
  ),
  ActivityRowData(
    id: 'a4',
    kind: ActivityKind.received,
    time: 'Sep 30',
    counterparty: 'stealth payment',
    legs: [AmountLeg(amount: BigInt.from(_nano(0.001)), decimals: 9, unit: 'ERG')],
  ),
];

WalletPageData sampleMainPage({bool hidden = false, List<ActivityRowData>? activity}) => WalletPageData(
      wallet: mainWallet,
      currency: aud,
      status: syncedAtTip,
      assets: _mainAssets,
      assetCount: 51,
      activity: activity ?? _mainActivity,
      utxoCount: 165,
      fragmented: true,
      unpricedCount: 46,
      hidden: hidden,
      pendingCount: 1,
    );

WalletPageData sampleWatchedPage({bool hidden = false}) => WalletPageData(
      wallet: watchedWallet,
      currency: aud,
      assets: [
        // On a node without price history the row has the price but no
        // 24h change.
        AssetRowData(
          id: 'ERG',
          ticker: 'ERG',
          name: 'Ergo',
          amount: BigInt.from(_nano(25421.6293)),
          decimals: 9,
          fiatValue: 11901.08,
          unitFiat: 0.4682,
          kind: AssetKind.erg,
        ),
        AssetRowData(
          id: 'e023c5f382b6e96fbd878f6811aac73345489032157ad5affb84aefd4956c297',
          ticker: 'rsADA',
          name: 'Rosen-bridged ADA',
          amount: _units(1204.5, 6),
          decimals: 6,
          verified: true,
        ),
        AssetRowData(
          id: '1fd6e032e8476c4aa54c18c1a308dce83940e8f4a28f576440513ed7326ad489',
          ticker: 'Paideia',
          name: 'Paideia DAO token',
          amount: _units(2400, 4),
          decimals: 4,
          verified: true,
        ),
      ],
      assetCount: 4,
      activity: [
        ActivityRowData(
          id: 'w1',
          kind: ActivityKind.received,
          time: 'Oct 2',
          counterparty: 'from 9fRxq3…3kQe',
          legs: [AmountLeg(amount: BigInt.from(_nano(12000)), decimals: 9, unit: 'ERG')],
        ),
        ActivityRowData(
          id: 'w2',
          kind: ActivityKind.sent,
          time: 'Sep 18',
          counterparty: 'to 9hP2kd…Lx8v',
          legs: [AmountLeg(amount: BigInt.from(-_nano(500)), decimals: 9, unit: 'ERG')],
        ),
        ActivityRowData(
          id: 'w3',
          kind: ActivityKind.received,
          time: 'Sep 2',
          counterparty: 'from 9gRosn…Br1d',
          legs: [AmountLeg(amount: _units(1204.5, 6), decimals: 6, unit: 'rsADA')],
        ),
      ],
      hidden: hidden,
      watched: const WatchedDetails(
        status: ['Watch-only · cannot sign here', 'Updated 2m ago'],
        notes: [
          'Cannot sign locally. Send with an offline signer; change returns to this same address. '
              'A watched account tracks more addresses.',
        ],
      ),
    );

/// The samples' own amounts and counts as summary surfaces print them, for
/// checking that hidden-balances mode shows none of them. Specific enough
/// not to match a block height or a time.
const hiddenModeFigures = [
  '25,529', '107.71', '25,421', '11,951', '11,901', '50.43', '2.5 ERG', '3.2 ERG', '0.001',
  '18,252,893,012', '1.81', '4.2 ERG', '12,000', '1,204.5', '2,400', '4.18', '0.87', '0.21',
  '69 COMET', '79 SigRSV', '50 tokens', '4 tokens', '3 tokens', 'Empty', 'empty', 'Assets, 51', '165',
  'confirmed',
];
