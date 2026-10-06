import 'package:argus_wallet/ui/home/home_format.dart';
import 'package:argus_wallet/ui/home/home_models.dart';
import 'package:argus_wallet/ui/home/home_widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _aud = FiatCurrency(symbol: r'A$', code: 'AUD');
const _yen = FiatCurrency(symbol: '¥', code: 'JPY', decimals: 0);

void main() {
  group('summary figures', () {
    test('keep two decimals at or above one unit, grouped and truncated', () {
      expect(summaryErg(25529342700000), '25,529.34');
      expect(summaryErg(107713400000), '107.71');
      expect(summaryErg(107719999999), '107.71', reason: 'never rounds up past what is held');
      expect(summaryErg(2500000000), '2.5');
      expect(summaryErg(100000000000), '100');
    });

    test('keep up to four decimals below one unit', () {
      expect(summaryErg(1000000), '0.001');
      expect(summaryErg(123456789), '0.1234');
    });

    test('never show a holding as zero', () {
      expect(summaryErg(0), '0');
      expect(summaryErg(12345), '0.000012');
      expect(summaryErg(1), '0.000000001');
      expect(summaryAmount(BigInt.from(1234), 8), '0.000012');
    });

    test('group whole-unit tokens', () {
      expect(summaryAmount(BigInt.from(18252893012), 0), '18,252,893,012');
      expect(summaryAmount(BigInt.from(69), 0), '69');
      expect(summaryAmount(BigInt.from(1204500000), 6), '1,204.5');
    });

    test('sign what moved with a true minus', () {
      expect(signedSummaryAmount(BigInt.from(-1816200000), 9), '−1.81');
      expect(signedSummaryAmount(BigInt.from(2500000000), 9), '+2.5');
      expect(signedSummaryAmount(BigInt.zero, 9), '0');
    });

    test('detail figures keep full precision', () {
      expect(detailErg(25529342700000), '25,529.3427');
      expect(detailErg(1), '0.000000001');
    });
  });

  group('fiat', () {
    test('is grouped and approximate', () {
      expect(spoken(fiatFigure(11951.52, _aud)), '≈ A\$11,951.52');
      expect(fiatFigure(50.43, _aud, approximate: false), 'A\$50.43');
      expect(fiatFigure(1234.4, _yen, approximate: false), '¥1,234');
    });

    test('says "less than" rather than zero for a crumb', () {
      expect(spoken(fiatFigure(0.004, _aud)), '< A\$0.01');
    });

    test('keeps the approximation sign with its figure', () {
      expect(fiatFigure(50.43, _aud), contains('≈$nbsp'));
    });

    test('prices ERG with more places when it is cheap', () {
      expect(ergPriceFigure(0.4682, _aud), 'A\$0.47');
      expect(ergPriceFigure(0.04682, _aud), 'A\$0.0468');
      expect(ergPriceFigure(1234.5, _aud), 'A\$1,234.50');
    });
  });

  test('percent change carries its sign', () {
    expect(percentChange(2.43), '+2.4%');
    expect(percentChange(-0.81), '−0.8%');
    expect(percentChange(0.01), '0.0%');
  });

  group('balance notes', () {
    const one = OtherAddressFunds(nanoErg: 3200000000, tokenCount: 4, addressCount: 1);
    const two = OtherAddressFunds(nanoErg: 0, tokenCount: 1, addressCount: 2);

    test('say where funds sit off the primary address', () {
      expect(spoken(otherAddressLine(one, hidden: false)), 'incl. 3.2 ERG · 4 tokens on 1 other address');
      expect(spoken(otherAddressLine(one, hidden: false, compact: true)), '3.2 ERG · 4 tokens on another address');
      expect(spoken(otherAddressLine(two, hidden: false)), 'incl. 1 token on 2 other addresses');
      expect(spoken(otherAddressLine(one, hidden: true)), 'incl. funds on 1 other address');
      expect(spoken(otherAddressLine(one, hidden: true, compact: true)), 'Funds on another address');
    });

    test('say what is pending', () {
      const incoming = PendingFunds(nanoErg: 2500000000);
      const outgoing = PendingFunds(nanoErg: -1200000000, tokenCount: 2);
      expect(spoken(pendingLine(incoming, hidden: false)), '+2.5 ERG pending');
      expect(spoken(pendingLine(incoming, hidden: false, short: true)), '+2.5 pending');
      expect(spoken(pendingLine(outgoing, hidden: false)), '−1.2 ERG · 2 tokens pending');
      expect(spoken(pendingLine(incoming, hidden: true)), '•••• ERG pending');
    });
  });

  test('tiles take one line, then two, then one per line', () {
    expect(fittingColumns(maxWidth: 358, gap: 10, needs: [60, 80, 60, 60]), 4);
    expect(fittingColumns(maxWidth: 358, gap: 10, needs: [60, 120, 60, 60]), 2);
    expect(fittingColumns(maxWidth: 358, gap: 10, needs: [60, 200, 60, 60]), 1);
    expect(fittingColumns(maxWidth: 358, gap: 10, needs: [100, 100, 100]), 3);
    expect(fittingColumns(maxWidth: 358, gap: 10, needs: [130, 100, 100]), 1);
  });

  test('wallet page offers what each kind of wallet can do', () {
    const watched = WalletSummary(id: 'w', name: 'Cold', kind: WalletKind.watchOnly);
    const seed = WalletSummary(id: 's', name: 'Main');
    const net = NetworkStatus(state: SyncState.synced);
    expect(
      const WalletPageData(wallet: watched, currency: _aud, network: net).actions,
      [WalletAction.sendOffline, WalletAction.receive],
    );
    expect(
      const WalletPageData(wallet: seed, currency: _aud, network: net).actions,
      [WalletAction.send, WalletAction.receive, WalletAction.swap, WalletAction.more],
    );
    final tools = const WalletPageData(wallet: seed, currency: _aud, network: net, fragmented: true).tools;
    expect(tools.map((t) => t.tool), [WalletTool.mix, WalletTool.tokens, WalletTool.utxos, WalletTool.addresses, WalletTool.lock]);
    expect(tools[2].status, 'Fragmented');
    expect(tools[2].warn, isTrue);
  });
}
