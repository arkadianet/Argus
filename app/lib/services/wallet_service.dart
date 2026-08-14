import '../bridge/frb_generated.dart';
import '../bridge/argus_error.dart';

/// High-level API over the Rust FRB bridge.
/// All errors arrive as [ArgusException] with machine-readable codes.
class WalletService {
  int? _handleId;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    await RustLib.init();
    _initialized = true;
  }

  bool get isUnlocked => _handleId != null;
  int? get handleId => _handleId;

  // ─── Wallet lifecycle ──────────────────────────────────────────────────

  Future<String> generateMnemonic({int strength = 128}) async {
    final raw = await RustLib.instance.api
        .crateApiGenerateMnemonic(strength: strength);
    return raw;
  }

  Future<void> createWallet(String mnemonic, {String passphrase = ''}) async {
    final raw = await RustLib.instance.api
        .crateApiWalletCreate(mnemonicPhrase: mnemonic, passphrase: passphrase);
    _handleId = raw.toInt();
  }

  Future<String> createEncryptedSeed(String mnemonic, {String passphrase = ''}) async {
    return await RustLib.instance.api
        .crateApiCreateEncryptedSeed(mnemonicPhrase: mnemonic, passphrase: passphrase);
  }

  Future<void> restoreWallet(String encryptedSeedJson, List<int> keyMaterial) async {
    final raw = await RustLib.instance.api
        .crateApiWalletRestore(encryptedSeedJson: encryptedSeedJson, keyMaterial: keyMaterial);
    _handleId = raw.toInt();
  }

  void lock() {
    if (_handleId != null) {
      RustLib.instance.api.crateApiWalletLock(handleId: BigInt.from(_handleId!));
      _handleId = null;
    }
  }

  // ─── Addresses ─────────────────────────────────────────────────────────

  Future<String> deriveAddress(int index) {
    _requireUnlocked();
    return RustLib.instance.api
        .crateApiDeriveAddress(handleId: BigInt.from(_handleId!), index: index);
  }

  Future<String> discoverAddresses({int gapLimit = 20, String? nodeUrl}) async {
    _requireUnlocked();
    return await RustLib.instance.api.crateApiDiscoverAddresses(
      handleId: BigInt.from(_handleId!),
      nodeUrl: nodeUrl,
      gapLimit: gapLimit,
    );
  }

  // ─── Transactions ──────────────────────────────────────────────────────

  Future<String> sendErg({
    required String senderAddress,
    required String recipientAddress,
    required int amountNanoErg,
    String? tokenId,
    int? tokenAmount,
    String? nodeUrl,
  }) {
    _requireUnlocked();
    return RustLib.instance.api.crateApiSendErg(
      handleId: BigInt.from(_handleId!),
      senderAddress: senderAddress,
      recipientAddress: recipientAddress,
      amountNanoErg: amountNanoErg,
      tokenId: tokenId,
      tokenAmount: tokenAmount != null ? BigInt.from(tokenAmount) : null,
      nodeUrl: nodeUrl,
    );
  }

  Future<String> getTransactionHistory(String address, {int limit = 20, String? nodeUrl}) {
    return RustLib.instance.api.crateApiGetTransactionHistory(
      address: address,
      nodeUrl: nodeUrl,
      limit: BigInt.from(limit),
    );
  }

  // ─── Test / debug ──────────────────────────────────────────────────────

  Future<String> testDeriveDisplay() {
    return RustLib.instance.api.crateApiTestDeriveDisplay();
  }

  // ─── Internal ──────────────────────────────────────────────────────────

  void _requireUnlocked() {
    if (_handleId == null) {
      throw ArgusException(code: 'WALLET_LOCKED', message: 'Wallet is locked');
    }
  }
}

final walletService = WalletService();