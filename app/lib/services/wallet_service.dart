import 'dart:convert';

import '../bridge/argus_error.dart';
import '../bridge/frb_generated.dart';

class WalletSession {
  final int handleId;
  final String encryptedSeedJson;
  WalletSession({required this.handleId, required this.encryptedSeedJson});
}

class SendPreview {
  final String recipient;
  final int amountNanoErg;
  final int minerFee;
  final int changeNanoErg;
  final int inputCount;

  SendPreview({
    required this.recipient,
    required this.amountNanoErg,
    required this.minerFee,
    required this.changeNanoErg,
    required this.inputCount,
  });

  factory SendPreview.fromJson(Map<String, dynamic> json) => SendPreview(
        recipient: json['recipient'] as String? ?? '',
        amountNanoErg: (json['amount_nano_erg'] as num?)?.toInt() ?? 0,
        minerFee: (json['miner_fee'] as num?)?.toInt() ?? 0,
        changeNanoErg: (json['change_nano_erg'] as num?)?.toInt() ?? 0,
        inputCount: (json['input_count'] as num?)?.toInt() ?? 0,
      );
}

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

  Future<String> generateMnemonic({int strength = 256}) async {
    return RustLib.instance.api.crateApiGenerateMnemonic(strength: strength);
  }

  Future<WalletSession> createWallet(String mnemonic, {String passphrase = ''}) async {
    final raw = await RustLib.instance.api
        .crateApiWalletCreate(mnemonicPhrase: mnemonic, passphrase: passphrase);
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final session = WalletSession(
      handleId: (map['handle_id'] as num).toInt(),
      encryptedSeedJson: map['encrypted_seed_json'] as String,
    );
    _handleId = session.handleId;
    return session;
  }

  Future<void> restoreWallet(String encryptedSeedJson) async {
    final raw = await RustLib.instance.api
        .crateApiWalletRestore(encryptedSeedJson: encryptedSeedJson);
    _handleId = raw.toInt();
  }

  Future<void> lock() async {
    if (_handleId == null) return;
    try {
      await RustLib.instance.api.crateApiWalletLock(handleId: BigInt.from(_handleId!));
    } finally {
      _handleId = null;
    }
  }

  Future<String> deriveAddress(int index) {
    _requireUnlocked();
    return RustLib.instance.api
        .crateApiDeriveAddress(handleId: BigInt.from(_handleId!), index: index);
  }

  Future<String> discoverAddresses({int gapLimit = 20, String? nodeUrl}) async {
    _requireUnlocked();
    return RustLib.instance.api.crateApiDiscoverAddresses(
      handleId: BigInt.from(_handleId!),
      nodeUrl: nodeUrl,
      gapLimit: gapLimit,
    );
  }

  Future<SendPreview> prepareSend({
    required String senderAddress,
    required String recipientAddress,
    required int amountNanoErg,
    String? tokenId,
    int? tokenAmount,
    String? nodeUrl,
  }) async {
    _requireUnlocked();
    final raw = await RustLib.instance.api.crateApiPrepareSend(
      handleId: BigInt.from(_handleId!),
      senderAddress: senderAddress,
      recipientAddress: recipientAddress,
      amountNanoErg: amountNanoErg,
      tokenId: tokenId,
      tokenAmount: tokenAmount != null ? BigInt.from(tokenAmount) : null,
      nodeUrl: nodeUrl,
    );
    return SendPreview.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<String> sendErg({
    required String senderAddress,
    required String recipientAddress,
    required int amountNanoErg,
    String? tokenId,
    int? tokenAmount,
    String? nodeUrl,
  }) async {
    _requireUnlocked();
    final raw = await RustLib.instance.api.crateApiSendErg(
      handleId: BigInt.from(_handleId!),
      senderAddress: senderAddress,
      recipientAddress: recipientAddress,
      amountNanoErg: amountNanoErg,
      tokenId: tokenId,
      tokenAmount: tokenAmount != null ? BigInt.from(tokenAmount) : null,
      nodeUrl: nodeUrl,
    );
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return map['tx_id'] as String? ?? raw;
  }

  Future<int> getBalanceNano(String address, {String? nodeUrl}) async {
    final raw = await RustLib.instance.api
        .crateApiGetBalance(address: address, nodeUrl: nodeUrl);
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return (map['balance_nano_erg'] as num?)?.toInt() ?? 0;
  }

  Future<String> getTransactionHistory(String address, {int limit = 20, String? nodeUrl}) {
    return RustLib.instance.api.crateApiGetTransactionHistory(
      address: address,
      nodeUrl: nodeUrl,
      limit: BigInt.from(limit),
    );
  }

  void _requireUnlocked() {
    if (_handleId == null) {
      throw ArgusException(code: 'WALLET_LOCKED', message: 'Wallet is locked');
    }
  }
}

final walletService = WalletService();
