import 'dart:convert';

import 'package:flutter/foundation.dart';

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

class TokenBalance {
  final String id;
  final int amount;
  final String? name;
  final int decimals;
  final int? emissionAmount;
  final String? iconUrl;

  TokenBalance({
    required this.id,
    required this.amount,
    this.name,
    this.decimals = 0,
    this.emissionAmount,
    this.iconUrl,
  });

  bool get isNft =>
      amount == 1 && decimals == 0 && (emissionAmount == null || emissionAmount == 1);

  String get label {
    final n = name?.trim();
    if (n != null && n.isNotEmpty) return n;
    return id.length > 8 ? '${id.substring(0, 8)}…' : id;
  }
}

class WalletRouteArgs {
  final String senderAddress;
  final String receiveAddress;
  final String changeAddress;
  final List<String> historyAddresses;
  final List<TokenBalance> tokens;
  final int? spendableNano;
  final Map<String, dynamic>? transaction;

  const WalletRouteArgs({
    required this.senderAddress,
    required this.receiveAddress,
    required this.changeAddress,
    this.historyAddresses = const [],
    this.tokens = const [],
    this.spendableNano,
    this.transaction,
  });

  static WalletRouteArgs from(Object? args) {
    if (args is WalletRouteArgs) return args;
    if (args is String && args.isNotEmpty) {
      return WalletRouteArgs(
        senderAddress: args,
        receiveAddress: args,
        changeAddress: args,
        historyAddresses: [args],
      );
    }
    return const WalletRouteArgs(
      senderAddress: '',
      receiveAddress: '',
      changeAddress: '',
    );
  }

  WalletRouteArgs copyWith({Map<String, dynamic>? transaction}) {
    return WalletRouteArgs(
      senderAddress: senderAddress,
      receiveAddress: receiveAddress,
      changeAddress: changeAddress,
      historyAddresses: historyAddresses,
      tokens: tokens,
      spendableNano: spendableNano,
      transaction: transaction ?? this.transaction,
    );
  }
}

class SendPreview {
  final int preparationId;
  final String recipient;
  final String? changeAddress;
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
    this.changeAddress,
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
      changeAddress: json['change_address'] as String?,
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
int? parseErgToNano(String raw) => parseDecimalToBase(raw, 9);

/// Parse a decimal token amount into the on-chain integer.
int? parseDecimalToBase(String raw, int decimals) {
  if (decimals < 0 || decimals > 18) return null;
  final text = raw.trim();
  if (text.isEmpty) return null;
  final parts = text.split('.');
  if (parts.length > 2) return null;
  final wholeStr = parts[0];
  final fracStr = parts.length == 2 ? parts[1] : '';
  if (wholeStr.isEmpty && fracStr.isEmpty) return null;
  if (wholeStr.isNotEmpty && !RegExp(r'^\d+$').hasMatch(wholeStr)) return null;
  if (fracStr.isNotEmpty && !RegExp(r'^\d+$').hasMatch(fracStr)) return null;
  if (fracStr.length > decimals) return null;
  final whole = wholeStr.isEmpty ? BigInt.zero : BigInt.parse(wholeStr);
  final frac = fracStr.isEmpty ? BigInt.zero : BigInt.parse(fracStr.padRight(decimals, '0'));
  var scale = BigInt.one;
  for (var i = 0; i < decimals; i++) {
    scale *= BigInt.from(10);
  }
  final total = whole * scale + frac;
  final max = BigInt.parse('9223372036854775807');
  if (total > max) return null;
  return total.toInt();
}

const minerFeeNano = 1100000;
const minBoxNano = 1000000;

String? validatePin(String pin) {
  final n = pin.runes.length;
  if (n < 6 || n > 32) return 'PIN must be 6-32 characters';
  return null;
}

List<String> mnemonicWords(String raw) {
  return raw
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
}

bool mnemonicWordsEqual(String a, String b) {
  final left = mnemonicWords(a);
  final right = mnemonicWords(b);
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

bool isIncorrectPin(Object error) {
  final msg = error is ArgusException ? error.message : error.toString();
  return msg.toLowerCase().contains('incorrect pin');
}

class WalletService {
  int? _handleId;
  bool _initialized = false;
  final ValueNotifier<bool> unlocked = ValueNotifier(false);
  final Map<String, TokenBalance> _tokenMeta = {};

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
    _setHandle(session.handleId);
    return session;
  }

  Future<String> wrapKeyWithPin(String wrapKey, String pin) {
    return RustLib.instance.api.crateApiWrapKeyWithPin(wrapKeyHex: wrapKey, pin: pin);
  }

  Future<String> unwrapKeyWithPin(String pinWrapJson, String pin) {
    return RustLib.instance.api.crateApiUnwrapKeyWithPin(pinWrapJson: pinWrapJson, pin: pin);
  }

  Future<void> restoreWallet(String encryptedSeedJson, {String? wrapKey}) async {
    final raw = await RustLib.instance.api.crateApiWalletRestore(
      encryptedSeedJson: encryptedSeedJson,
      wrapKey: wrapKey,
    );
    _setHandle(raw.toInt());
  }

  Future<void> lock() async {
    if (_handleId == null) {
      unlocked.value = false;
      return;
    }
    try {
      await RustLib.instance.api.crateApiWalletLock(handleId: BigInt.from(_handleId!));
    } finally {
      _handleId = null;
      unlocked.value = false;
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
    List<String>? spendAddresses,
    required String changeAddress,
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
      spendAddresses: spendAddresses ?? const [],
      changeAddress: changeAddress,
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
    final map = await getBalance(address, nodeUrl: nodeUrl);
    return (map['balance_nano_erg'] as num?)?.toInt() ?? 0;
  }

  Future<Map<String, dynamic>> getBalance(String address, {String? nodeUrl}) async {
    final raw = await RustLib.instance.api
        .crateApiGetBalance(address: address, nodeUrl: nodeUrl);
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<List<TokenBalance>> tokensFor(String address, {String? nodeUrl}) async {
    final map = await getBalance(address, nodeUrl: nodeUrl);
    return hydrateTokens(map['tokens']);
  }

  Future<List<TokenBalance>> hydrateTokens(dynamic raw) async {
    final items = raw is List ? raw : const [];
    final jobs = <Future<TokenBalance>>[];
    for (final item in items) {
      if (item is! Map) continue;
      final id = item['id']?.toString() ?? '';
      final amount = (item['amount'] as num?)?.toInt() ?? 0;
      if (id.isEmpty || amount <= 0) continue;
      jobs.add(tokenMeta(id, amount));
    }
    return Future.wait(jobs);
  }

  Future<List<Map<String, dynamic>>> loadHistory(
    List<String> addresses, {
    int limit = 20,
    int offset = 0,
  }) async {
    var ok = 0;
    var failed = 0;
    final results = await Future.wait(
      addresses.map((address) async {
        try {
          final raw = await getTransactionHistory(address, limit: limit, offset: offset);
          ok++;
          return jsonDecode(raw) as List;
        } catch (_) {
          failed++;
          return const [];
        }
      }),
    );
    if (ok == 0 && failed > 0) {
      throw ArgusException(
        code: 'NODE_UNREACHABLE',
        message: 'Could not load activity',
      );
    }
    final all = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final txs in results) {
      for (final tx in txs) {
        if (tx is! Map) continue;
        final map = Map<String, dynamic>.from(tx);
        final id = map['tx_id']?.toString() ?? '';
        if (id.isEmpty || !seen.add(id)) continue;
        all.add(map);
      }
    }
    all.sort((a, b) {
      final tb = (b['timestamp'] as num?)?.toInt() ?? 0;
      final ta = (a['timestamp'] as num?)?.toInt() ?? 0;
      return tb.compareTo(ta);
    });
    return all;
  }

  Future<TokenBalance> tokenMeta(String id, int amount) async {
    final cached = _tokenMeta[id];
    if (cached != null) {
      return TokenBalance(
        id: id,
        amount: amount,
        name: cached.name,
        decimals: cached.decimals,
        emissionAmount: cached.emissionAmount,
        iconUrl: cached.iconUrl,
      );
    }
    try {
      final raw = await RustLib.instance.api.crateApiGetTokenInfo(tokenId: id);
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final info = TokenBalance(
        id: id,
        amount: amount,
        name: map['name'] as String?,
        decimals: (map['decimals'] as num?)?.toInt() ?? 0,
        emissionAmount: (map['emissionAmount'] as num?)?.toInt(),
        iconUrl: map['iconUrl'] as String? ?? map['icon_url'] as String?,
      );
      _tokenMeta[id] = info;
      return info;
    } catch (_) {
      return TokenBalance(id: id, amount: amount);
    }
  }

  Future<String> getTransactionHistory(String address, {int limit = 20, int offset = 0, String? nodeUrl}) {
    return RustLib.instance.api.crateApiGetTransactionHistory(
      address: address,
      nodeUrl: nodeUrl,
      limit: BigInt.from(limit),
      offset: BigInt.from(offset),
    );
  }

  void _setHandle(int id) {
    _handleId = id;
    unlocked.value = true;
  }

  void _requireUnlocked() {
    if (_handleId == null) {
      throw ArgusException(code: 'WALLET_LOCKED', message: 'Wallet is locked');
    }
  }
}

final walletService = WalletService();
