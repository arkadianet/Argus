// Hand-written API surface matching wallet-ffi.
// Replace with `flutter_rust_bridge_codegen generate` output when wiring the .so.

class RustLib {
  RustLib._();
  static final instance = RustLib._();
  final api = RustApi();

  static Future<void> init() async {}
}

class RustApi {
  Future<String> crateApiGenerateMnemonic({required int strength}) {
    throw UnimplementedError('run flutter_rust_bridge_codegen generate');
  }

  Future<String> crateApiWalletCreate({
    required String mnemonicPhrase,
    required String passphrase,
  }) {
    throw UnimplementedError('run flutter_rust_bridge_codegen generate');
  }

  Future<BigInt> crateApiWalletRestore({required String encryptedSeedJson}) {
    throw UnimplementedError('run flutter_rust_bridge_codegen generate');
  }

  Future<void> crateApiWalletLock({required BigInt handleId}) {
    throw UnimplementedError('run flutter_rust_bridge_codegen generate');
  }

  Future<String> crateApiDeriveAddress({
    required BigInt handleId,
    required int index,
  }) {
    throw UnimplementedError('run flutter_rust_bridge_codegen generate');
  }

  Future<String> crateApiDiscoverAddresses({
    required BigInt handleId,
    String? nodeUrl,
    required int gapLimit,
  }) {
    throw UnimplementedError('run flutter_rust_bridge_codegen generate');
  }

  Future<String> crateApiPrepareSend({
    required BigInt handleId,
    required String senderAddress,
    required String recipientAddress,
    required int amountNanoErg,
    String? tokenId,
    BigInt? tokenAmount,
    String? nodeUrl,
  }) {
    throw UnimplementedError('run flutter_rust_bridge_codegen generate');
  }

  Future<String> crateApiSendErg({
    required BigInt handleId,
    required String senderAddress,
    required String recipientAddress,
    required int amountNanoErg,
    String? tokenId,
    BigInt? tokenAmount,
    String? nodeUrl,
  }) {
    throw UnimplementedError('run flutter_rust_bridge_codegen generate');
  }

  Future<String> crateApiGetBalance({required String address, String? nodeUrl}) {
    throw UnimplementedError('run flutter_rust_bridge_codegen generate');
  }

  Future<String> crateApiGetTransactionHistory({
    required String address,
    String? nodeUrl,
    required BigInt limit,
  }) {
    throw UnimplementedError('run flutter_rust_bridge_codegen generate');
  }
}
