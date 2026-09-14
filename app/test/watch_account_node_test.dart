import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/watch_account_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'node change clears completed snapshots but preserves known frontier',
    () {
      final network = NetworkController()..activeUrl = 'node-a';
      final service = WatchAccountService(network: network);
      final account = WatchAccount('key', highestUsed: 3)
        ..snapshot = WatchAccountSnapshot(['4'], '4', 123, {}, [], 3);
      service.accounts.add(account);
      var notifications = 0;
      service.addListener(() => notifications++);
      network.setErgRate(fiatPerErg: 1, usdPerErg: 1);
      expect(account.snapshot, isNotNull);
      expect(notifications, 0);
      network.activeUrl = 'node-b';
      network.setErgRate(fiatPerErg: 1, usdPerErg: 1);
      expect(account.snapshot, isNull);
      expect(account.highestUsed, 3);
      expect(account.error, contains('Refresh'));
      expect(notifications, 1);
      service.dispose();
      network.dispose();
    },
  );
}
