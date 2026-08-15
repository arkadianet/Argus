import 'dart:convert';

import '../bridge/argus_error.dart';
import '../bridge/frb_generated.dart';

class WalletSession {
  final int handleId;
  final String encryptedSeedJson;
  final String wrapKey;
  WalletSession({
    required this.handleId,
    required this.encryptedSeedJson,
    required this.wrapKey,
  });
}

class SendPreview {
  final int preparationId;
  final String recipient;
  final int amountNanoErg;
  final int minerFee;
  final int changeNanoErg;
  final int inputCount;
  final String? tokenId;
  final int? tokenAmount;

  SendPreview({
    required this.preparationId,
    required this.recipient,
    required this.amountNanoErg,
    required this.minerFee,
    required this.changeNanoErg,
    required this.inputCount,
    this.tokenId,
    this.tokenAmount,
  });

  factory SendPreview.fromJson(Map<String, dynamic> json) {
    final recipient = json['recipient'];
    if (recipient is! String || recipient.isEmpty) {
      throw const FormatException('SendPreview missing or invalid recipient');
    }
    return SendPreview(
      preparationId: _requireInt(json, 'preparation_id'),
      recipient: recipient,
      amountNanoErg: _requireInt(json, 'amount_nano_erg'),
      minerFee: _requireInt(json, 'miner_fee'),
      changeNanoErg: _requireInt(json, 'change_nano_erg'),
      inputCount: _requireInt(json, 'input_count'),
      tokenId: json['token_id'] as String?,
      tokenAmount: (json['token_amount'] as num?)?.toInt(),
    );
  }
}

int _requireInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! num) {
    throw FormatException('SendPreview missing or invalid $key');
  }
  return value.toInt();
}

/// Parse decimal ERG text into nanoERG without using [double].
int? parseErgToNano(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final parts = text.split('.');
  if (parts.length > 2) return null;
  final wholeStr = parts[0];
  final fracStr = parts.length == 2 ? parts[1] : '';
  if (wholeStr.isEmpty && fracStr.isEmpty) return null;
  if (wholeStr.isNotEmpty && !RegExp(r'^\d+$').hasMatch(wholeStr)) return null;
  if (fracStr.isNotEmpty && !RegExp(r'^\d+$').hasMatch(fracStr)) return null;
  if (fracStr.length > 9) return null;
  final whole = wholeStr.isEmpty ? 0 : int.parse(wholeStr);
  final frac = fracStr.isEmpty ? 0 : int.parse(fracStr.padRight(9, '0'));
  return whole * 1000000000 + frac;
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
      wrapKey: map['wrap_key'] as String,
    );
    _handleId = session.handleId;
    return session;
  }

  Future<void> restoreWallet(String encryptedSeedJson, {String? wrapKey}) async {
    final raw = await RustLib.instance.api.crateApiWalletRestore(
      encryptedSeedJson: encryptedSeedJson,
      wrapKey: wrapKey,
    );
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

  Future<String> sendErg({required int preparationId}) async {
    _requireUnlocked();
    final raw = await RustLib.instance.api.crateApiSendErg(
      handleId: BigInt.from(_handleId!),
      preparationId: BigInt.from(preparationId),
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
