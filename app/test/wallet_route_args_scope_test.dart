import 'package:argus_wallet/services/wallet_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('WalletRouteArgs.of prefers an enclosing scope over route arguments',
      (tester) async {
    WalletRouteArgs? seen;
    await tester.pumpWidget(MaterialApp(
      onGenerateRoute: (_) => MaterialPageRoute(
        settings: const RouteSettings(arguments: 'route-addr'),
        builder: (_) => WalletArgsScope(
          args: const WalletRouteArgs(
            senderAddress: 'scope-addr',
            receiveAddress: 'scope-addr',
            changeAddress: 'scope-addr',
          ),
          child: Builder(builder: (ctx) {
            seen = WalletRouteArgs.of(ctx);
            return const SizedBox();
          }),
        ),
      ),
    ));
    expect(seen?.senderAddress, 'scope-addr');
  });

  testWidgets('WalletRouteArgs.of falls back to route arguments', (tester) async {
    WalletRouteArgs? seen;
    await tester.pumpWidget(MaterialApp(
      onGenerateRoute: (_) => MaterialPageRoute(
        settings: const RouteSettings(arguments: 'route-addr'),
        builder: (_) => Builder(builder: (ctx) {
          seen = WalletRouteArgs.of(ctx);
          return const SizedBox();
        }),
      ),
    ));
    expect(seen?.senderAddress, 'route-addr');
  });
}
