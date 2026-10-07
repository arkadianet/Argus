// The overview and a wallet's page drawn from the figures in the look the
// user chose (two phone screens: the overview and Main Wallet), in
// Watchful, Harbor and a light palette, checked for layout errors, 48 dp
// targets and labelled controls. To also save PNGs under
// <repo>/ui-renders/ref/, each Watchful one beside the reference when the
// reference is on this machine (ARGUS_REFERENCE names it):
//
//   ARGUS_UI_RENDERS=1 ARGUS_REFERENCE=/path/to/reference.png \
//     flutter test test/home_reference_render_test.dart

import 'dart:io';

import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/ui/home/home_models.dart';
import 'package:argus_wallet/ui/home/overview_screen.dart';
import 'package:argus_wallet/ui/home/unlock_gate.dart';
import 'package:argus_wallet/ui/home/wallet_nav_bar.dart';
import 'package:argus_wallet/ui/home/wallet_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/render_harness.dart';

const _aud = FiatCurrency(symbol: r'A$', code: 'AUD');

int _nano(num erg) => (erg * 1e9).round();

/// Where the two phones sit in the reference image, in its pixels.
const _overviewCrop = Rect.fromLTRB(84, 12, 610, 1190);
const _walletCrop = Rect.fromLTRB(705, 12, 1233, 1190);

const _pinned = '9iArkadiXq3Nb7Kx2Ty5Vm8Gc1Rz4Fd6Ls9Pw0Ja3Ue7MWspUZA';

final _main = WalletSummary(
  ref: const WalletRef.seed('main'),
  name: 'Main Wallet',
  nanoErg: _nano(203.16),
  fiatValue: 90.84,
  tokenCount: null,
  pockets: [PocketBalance(pocket: Pocket.stealth, nanoErg: _nano(0.001))],
  otherAddresses: FundsElsewhere(nanoErg: _nano(0.6101), tokenCount: 0, addressCount: 1),
  unlocked: true,
  address: _pinned,
  pinnedIndex: 275,
);

final _evoke = WalletSummary(
  ref: const WalletRef.seed('9evoke9'),
  name: '9evoke9',
  nanoErg: _nano(10),
  fiatValue: 4.47,
  tokenCount: 44,
  publicTokensOnly: true,
  asOf: 'just now',
);

WalletSummary _watched(String id, String name, num erg, double fiat, int tokens) => WalletSummary(
      ref: WalletRef.watchedAddress(id),
      name: name,
      nanoErg: _nano(erg),
      fiatValue: fiat,
      tokenCount: tokens,
    );

OverviewData _overviewData() => OverviewData(
      wallets: [_main, _evoke],
      watched: [
        _watched('9hUMAN', '9hUMAN…o9go', 25421.62, 11366.16, 38),
        _watched('88dhgZ', '88dhgZ…CAJg', 441.87, 197.56, 1),
      ],
      currency: _aud,
      network: const NetworkStatus(state: SyncState.synced, blockHeight: 1889207, label: 'Connected'),
      totalNano: _nano(26076.67),
      totalFiat: 11659.04,
      unpricedCount: 83,
    );

AmountLeg _erg(num erg) => AmountLeg(amount: BigInt.from(_nano(erg)), decimals: 9, unit: 'ERG');

WalletPageData _walletData() => WalletPageData(
      wallet: WalletSummary(
        ref: const WalletRef.seed('main'),
        name: 'Main Wallet',
        nanoErg: _nano(203.16),
        fiatValue: 90.77,
        pockets: [PocketBalance(pocket: Pocket.stealth, nanoErg: _nano(0.001))],
        otherAddresses: FundsElsewhere(nanoErg: _nano(0.6101), tokenCount: 0, addressCount: 1),
        unlocked: true,
        address: _pinned,
        pinnedIndex: 275,
      ),
      currency: _aud,
      status: const NetworkStatus(state: SyncState.synced, blockHeight: 1889190, label: 'Synced', age: 'just now'),
      utxoCount: 20,
      assets: [
        AssetRowData(
          id: 'ERG',
          ticker: 'ERG',
          name: 'Ergo',
          amount: BigInt.from(_nano(203.16)),
          decimals: 9,
          fiatValue: 90.77,
          unitFiat: 0.4468,
          kind: AssetKind.erg,
        ),
      ],
      assetCount: 1,
      activity: [
        ActivityRowData(
          id: 'a1',
          kind: ActivityKind.sent,
          time: '3:19 pm',
          counterparty: 'to 9iArka…pUZA',
          legs: [
            _erg(-2.09),
            AmountLeg(amount: BigInt.from(-999), decimals: 0, unit: 'XIXA'),
            for (var i = 0; i < 5; i++) AmountLeg(amount: BigInt.from(-1), decimals: 0, unit: 'T$i'),
          ],
        ),
        ActivityRowData(
          id: 'a2',
          kind: ActivityKind.sent,
          time: '2:49 pm',
          counterparty: 'contract 5vSUZR…SCqM',
          legs: [_erg(-0.0001), AmountLeg(amount: BigInt.from(-2000), decimals: 0, unit: '🍆💦')],
        ),
        ActivityRowData(
          id: 'a3',
          kind: ActivityKind.sent,
          time: '2:49 pm',
          counterparty: 'contract 5vSUZR…SCqM',
          legs: [_erg(-0.1087), AmountLeg(amount: BigInt.from(-5732), decimals: 2, unit: 'Flux')],
        ),
      ],
    );

void _noop([Object? _]) {}

Widget _overview() => OverviewScreen(
      data: _overviewData(),
      onOpenWallet: _noop,
      onReorder: (_, _) {},
      onAdd: _noop,
      onSettings: _noop,
      onToggleHidden: _noop,
      onNetwork: _noop,
      onLearnMore: _noop,
      onAction: _noop,
    );

Widget _wallet() => WalletPageScreen(
      title: 'Main Wallet',
      subtitle: 'Unlocked',
      subtitleLive: true,
      immersive: true,
      onBack: _noop,
      actions: [
        IconButton(key: const Key('wallet-scan'), icon: const Icon(Icons.qr_code_scanner), tooltip: 'Scan a QR code', onPressed: _noop),
        IconButton(icon: const Icon(Icons.more_vert), tooltip: 'Wallet settings', onPressed: _noop),
      ],
      body: WalletPageView(
        data: _walletData(),
        onToggleHidden: _noop,
        onAction: _noop,
        onTool: _noop,
        onAsset: _noop,
        onAllAssets: _noop,
        onActivity: _noop,
        onAllActivity: _noop,
        onStatus: _noop,
        onOtherAddresses: _noop,
      ),
      navBar: WalletNavBar(current: WalletTab.wallet, onSelect: _noop),
    );

Widget _locked() => WalletPageScreen(
      title: 'Main Wallet',
      subtitle: 'Locked',
      immersive: true,
      onBack: _noop,
      body: UnlockGate(
        name: 'Main Wallet',
        method: UnlockMethod.biometric,
        pinController: TextEditingController(),
        busy: false,
        usePin: false,
        onUnlock: _noop,
        onUsePin: _noop,
        onUnlockWithPin: _noop,
        onUnlockLegacy: _noop,
        address: _pinned,
        pinnedIndex: 275,
        lastKnownNano: _nano(203.16),
        lastKnownAge: const Duration(hours: 3),
      ),
    );

Future<void> _accessible(WidgetTester tester) async {
  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
}

void main() {
  setUpAll(loadRenderFonts);
  final reference = Platform.environment['ARGUS_REFERENCE'];

  for (final palette in [watchfulPalette, harborPalette, ledgerPalette]) {
    testWidgets('overview, ${palette.name}', (tester) async {
      await pumpRender(tester, _overview(), palette: palette);
      expect(tester.takeException(), isNull);
      await saveRender(tester, 'ref/overview-${palette.id}-1x');
      if (palette == watchfulPalette && reference != null) {
        await saveBesideReference(tester, 'ref/overview-beside-reference', referencePath: reference, crop: _overviewCrop);
      }
      expect(find.byKey(const Key('home-scene')), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp(r'^Total balance 26,076\.67 ERG, about A\$11,659\.04 AUD, 83 tokens unpriced$')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Connected, Block 1,889,207'), findsOneWidget);
      for (final action in ['send', 'receive', 'swap', 'more']) {
        expect(find.byKey(Key('overview-action-$action')), findsOneWidget);
      }
      await _accessible(tester);
    });

    testWidgets('wallet page, ${palette.name}', (tester) async {
      await pumpRender(tester, _wallet(), palette: palette);
      expect(tester.takeException(), isNull);
      await saveRender(tester, 'ref/wallet-${palette.id}-1x');
      if (palette == watchfulPalette && reference != null) {
        await saveBesideReference(tester, 'ref/wallet-beside-reference', referencePath: reference, crop: _walletCrop);
      }
      expect(find.byKey(const Key('wallet-medallion')), findsOneWidget);
      expect(find.bySemanticsLabel('Pinned address #275, 9iArkadi…WspUZA'), findsOneWidget);
      expect(find.bySemanticsLabel('Synced, Block 1,889,190, 20 UTXOs, just now'), findsOneWidget);
      await _accessible(tester);

      // Each tab shows what it holds.
      await tester.ensureVisible(find.byKey(const Key('wallet-page-tab-utxos')));
      await tester.tap(find.byKey(const Key('wallet-page-tab-utxos')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('wallet-utxo-tools')), findsOneWidget);
      await tester.tap(find.byKey(const Key('wallet-page-tab-addresses')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('wallet-every-address')), findsOneWidget);
    });

    testWidgets('locked page, ${palette.name}', (tester) async {
      await pumpRender(tester, _locked(), palette: palette);
      expect(tester.takeException(), isNull);
      await saveRender(tester, 'ref/locked-${palette.id}-1x');
      expect(find.byKey(const Key('gate-unlock')), findsOneWidget);
      await _accessible(tester);
    });
  }
}
