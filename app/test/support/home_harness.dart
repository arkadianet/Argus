import 'dart:convert';

import 'package:argus_wallet/bridge/argus_error.dart';
import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/theme/theme_controller.dart';
import 'package:argus_wallet/ui/dashboard_screen.dart';
import 'package:argus_wallet/ui/receive_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'render_harness.dart';

const secureStorageChannel = MethodChannel('com.argus.wallet/secure_storage');

/// Native stand-in for the home screen: public reads answer from [balances]
/// and [histories]; an unlocked wallet derives `<walletId>-addr<index>`
/// style addresses through [derived].
class HomeApi extends RustLibApi {
  int handles = 0;
  final restored = <String?>[];
  final balances = <String, Map<String, dynamic>>{};
  final histories = <String, List<Map<String, dynamic>>>{};
  final balanceCalls = <String>[];
  int watchScans = 0;

  /// Addresses an unlocked wallet derives, by index.
  String Function(int index) derived = (i) => 'addr$i';

  /// Discovery's answer for an unlocked wallet.
  Map<String, dynamic> discovery = {'addresses': [], 'next_unused_index': 0};

  /// Addresses a watched extended key derives, by index.
  String Function(int index) watchDerived = (i) => 'watch$i';

  Map<String, dynamic> _balance(String address) =>
      balances[address] ?? {'balance_nano_erg': 0, 'tokens': []};

  @override
  Future<void> crateApiInitApp() async {}

  @override
  Future<BigInt> crateApiWalletRestore({
    required String encryptedSeedJson,
    String? wrapKey,
  }) async {
    restored.add(wrapKey);
    return BigInt.from(++handles);
  }

  @override
  Future<void> crateApiWalletLock({required BigInt handleId}) async {}

  /// The PIN [crateApiUnwrapKeyWithPin] accepts.
  String goodPin = '123456';

  @override
  Future<String> crateApiUnwrapKeyWithPin({
    required String pinWrapJson,
    required String pin,
  }) async {
    if (pin != goodPin) throw ArgusException(code: 'WRONG_PIN', message: 'Wrong PIN');
    return 'wrap-key';
  }

  @override
  Future<String> crateApiDeriveAddress({
    required BigInt handleId,
    required int index,
  }) async =>
      derived(index);

  @override
  Future<String> crateApiDiscoverAddresses({
    required BigInt handleId,
    String? nodeUrl,
    required int gapLimit,
  }) async =>
      jsonEncode(discovery);

  @override
  Future<String> crateApiGetBalance({
    required String address,
    String? nodeUrl,
  }) async {
    balanceCalls.add(address);
    return jsonEncode(_balance(address));
  }

  @override
  Future<String> crateApiGetSyncInputs({
    required List<String> addresses,
    String? nodeUrl,
  }) async =>
      jsonEncode({
        'balances': {for (final a in addresses) a: _balance(a)},
        'pending': [],
        'utxo_count': addresses.length,
        'served_by': null,
      });

  /// The public refresh of locked wallets reads all of a wallet's addresses
  /// in one call that walks them in turn; answered, and recorded, per
  /// address as [crateApiGetBalance] is.
  @override
  Future<String> crateApiMempoolGetPublicSyncInputs({
    required List<String> addresses,
    String? nodeUrl,
  }) async {
    final balances = <String, dynamic>{};
    for (final address in addresses) {
      balances[address] = jsonDecode(
        await crateApiGetBalance(address: address, nodeUrl: nodeUrl),
      );
    }
    return jsonEncode({'balances': balances, 'pending': []});
  }

  @override
  Future<String> crateApiGetTransactionHistory({
    required String address,
    String? nodeUrl,
    required BigInt limit,
    required BigInt offset,
  }) async =>
      offset == BigInt.zero ? jsonEncode(histories[address] ?? const []) : '[]';

  @override
  Future<String> crateApiGetPendingTransactions({
    required List<String> addresses,
    String? nodeUrl,
  }) async =>
      '[]';

  @override
  Future<List<String>> crateApiDeriveWatchAddresses({
    required String input,
    required int start,
    required int count,
  }) async {
    watchScans++;
    return List.generate(count, (i) => watchDerived(start + i));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The platform keystore: which wallets have a sealed seed, a PIN, and a
/// biometric copy of the key, and what the biometric sheet answers.
class FakeKeystore {
  FakeKeystore({
    this.wallets = const ['w1'],
    this.biometric = true,
    this.pin = true,
  });

  List<String> wallets;
  bool biometric;
  bool pin;

  /// The wrap key the biometric sheet hands back; null is a cancel.
  String? biometricResult;

  /// Every biometric sheet shown.
  int prompts = 0;

  void install(WidgetTester tester) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureStorageChannel, (call) async {
      final args = call.arguments;
      final walletId = args is Map ? args['walletId'] : null;
      switch (call.method) {
        case 'listWalletIds':
          return wallets;
        case 'hasEncryptedSeed':
          return walletId != null && wallets.contains(walletId);
        case 'hasPinWrap':
          return pin;
        case 'hasWrapKey':
        case 'hasBiometric':
          return biometric;
        case 'authenticateBiometric':
          prompts++;
          return biometricResult;
        case 'loadEncryptedSeed':
          return '{"v":2}';
        case 'loadPinWrap':
          return '{"pin":"wrap"}';
        case 'loadPinGate':
          return {'count': 0, 'until': 0};
        default:
          return null;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(secureStorageChannel, null));
  }
}

/// Pumps the real home screen at phone size, in the app's theme, without
/// native init or the node probe. Text scale is clamped to 1.6 as the app
/// itself does, unless [clampText] is false.
Future<void> pumpHome(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double textScale = 1,
  bool clampText = true,
  bool dark = false,
  Map<String, WidgetBuilder> routes = const {},
  TransitionBuilder? builder,
}) async {
  networkController.probing = true;
  addTearDown(() => networkController.probing = false);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final scaler = TextScaler.linear(textScale);
  await tester.pumpWidget(
    RepaintBoundary(
      key: renderBoundaryKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: themeController.lightTheme,
        darkTheme: themeController.darkTheme,
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        builder: (context, child) {
          final scaled = MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: clampText ? scaler.clamp(maxScaleFactor: 1.6) : scaler,
            ),
            child: child!,
          );
          return builder == null ? scaled : builder(context, scaled);
        },
        home: DashboardScreen(initializeWalletService: () async {}),
        routes: {
          '/receive': (_) => const ReceiveScreen(),
          ...routes,
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Disposes the home screen, so its timers stop before the test ends, and
/// locks whatever it unlocked.
Future<void> disposeHome(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  if (walletService.isUnlocked) await walletService.lock();
  // An unlock reschedules background mixing, which on a test host starts a
  // process whose zero-length timer lands after the tree is gone. Let it
  // run out before the test's own timer check.
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 1));
  }
}

/// Records a wallet's name and first address the way create and restore do.
Future<void> saveWallet(
  String walletId, {
  required String name,
  String? address0,
  int? pinnedIndex,
  String? pinnedAddress,
}) async {
  await walletService.saveWalletInfo(
    walletId,
    name: name,
    createdAt: DateTime(2026),
    address0: address0,
  );
  if (pinnedIndex != null) {
    await walletService.setPinnedAddressIndex(walletId, pinnedIndex, address: pinnedAddress);
  }
}
