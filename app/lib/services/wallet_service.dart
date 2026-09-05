import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../bridge/argus_error.dart';
import '../bridge/frb_generated.dart';
import 'app_fee.dart';
import 'secure_storage.dart';
import 'wallet_database_service.dart';

/// Metadata for a stored wallet.
class WalletInfo {
  final String walletId;
  final String name;
  final DateTime createdAt;
  final String? address0;
  final int? pinnedAddressIndex;

  /// The pinned address itself, stored when pinning so a locked wallet can
  /// still show and query its primary address.
  final String? pinnedAddress;
  final bool isUnlocked;

  WalletInfo({
    required this.walletId,
    required this.name,
    required this.createdAt,
    this.address0,
    this.pinnedAddressIndex,
    this.pinnedAddress,
    this.isUnlocked = false,
  });

  /// Address to show for this wallet when it is not the active one.
  String? get displayAddress =>
      (pinnedAddressIndex ?? 0) > 0 && pinnedAddress != null ? pinnedAddress : address0;

  WalletInfo copyWith({bool? isUnlocked}) => WalletInfo(
        walletId: walletId,
        name: name,
        createdAt: createdAt,
        address0: address0,
        pinnedAddressIndex: pinnedAddressIndex,
        pinnedAddress: pinnedAddress,
        isUnlocked: isUnlocked ?? this.isUnlocked,
      );

  Map<String, dynamic> toJson() => {
        'walletId': walletId,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'address0': address0,
        'pinnedAddressIndex': pinnedAddressIndex,
        'pinnedAddress': pinnedAddress,
      };

  factory WalletInfo.fromJson(Map<String, dynamic> json) => WalletInfo(
        walletId: json['walletId'] as String,
        name: json['name'] as String,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
        address0: json['address0'] as String?,
        pinnedAddressIndex: json['pinnedAddressIndex'] as int?,
        pinnedAddress: json['pinnedAddress'] as String?,
      );
}

class WalletSession {
  final String walletId;
  final BigInt handleId;
  final String encryptedSeedJson;
  final String wrapKey;
  WalletSession({
    required this.walletId,
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

  /// How much of [amount] sits in stealth boxes rather than in the wallet's
  /// own P2PK boxes. Stealth funds are real but are not offered to ordinary
  /// coin selection; they are swept first.
  final int stealthAmount;

  TokenBalance({
    required this.id,
    required this.amount,
    this.name,
    this.decimals = 0,
    this.emissionAmount,
    this.iconUrl,
    this.stealthAmount = 0,
  });

  /// True when any part of this holding is in stealth boxes.
  bool get hasStealth => stealthAmount > 0;

  bool get isNft =>
      amount == 1 && decimals == 0 && (emissionAmount == null || emissionAmount == 1);

  String get label {
    final n = name?.trim();
    if (n != null && n.isNotEmpty) return n;
    return id.length > 8 ? '${id.substring(0, 8)}…' : id;
  }
}

/// Supplies [WalletRouteArgs] to screens embedded without their own route,
/// so they see live balances the same way pushed screens do via arguments.
class WalletArgsScope extends InheritedWidget {
  const WalletArgsScope({super.key, required this.args, required super.child});

  final WalletRouteArgs args;

  static WalletRouteArgs? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WalletArgsScope>()?.args;

  @override
  bool updateShouldNotify(WalletArgsScope old) => old.args != args;
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

  /// Wallet context for [context]: an enclosing [WalletArgsScope] (tabs
  /// embedded in the home screen) or, failing that, the route arguments.
  static WalletRouteArgs of(BuildContext context) {
    final routeArgs = ModalRoute.of(context)?.settings.arguments;
    final scoped = WalletArgsScope.maybeOf(context);
    if (scoped == null) return from(routeArgs);
    // Balances come from the live scope; a transaction is route-specific.
    final tx = routeArgs is WalletRouteArgs ? routeArgs.transaction : null;
    return tx == null ? scoped : scoped.copyWith(transaction: tx);
  }

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

  /// The UTXOs selected to fund this transaction, for use in an advanced
  /// preview. Empty for older preparations that predate this field.
  final List<InputBoxInput> inputBoxes;

  /// For multi-recipient sends, the list of individual recipients.
  /// Each entry has keys: address, amount_nano_erg, token_id (optional), token_amount (optional).
  final List<Map<String, dynamic>>? recipients;

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
    this.inputBoxes = const [],
    this.recipients,
  });

  factory SendPreview.fromJson(Map<String, dynamic> json) {
    final recipient = json['recipient'];
    if (recipient is! String || recipient.isEmpty) {
      throw const FormatException('SendPreview missing or invalid recipient');
    }
    final recipsRaw = json['recipients'];
    List<Map<String, dynamic>>? recips;
    if (recipsRaw is List) {
      recips = recipsRaw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
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
      inputBoxes: _parseInputBoxes(json['input_boxes']),
      recipients: recips,
    );
  }
}

class ConsolidatePreview {
  final int preparationId;
  final int inputCount;
  final int totalErgIn;
  final int changeNanoErg;
  final int tokenCount;
  final int minerFee;
  final List<InputBoxInput> inputBoxes;

  ConsolidatePreview({required this.preparationId, required this.inputCount, required this.totalErgIn, required this.changeNanoErg, required this.tokenCount, required this.minerFee, this.inputBoxes = const []});

  factory ConsolidatePreview.fromJson(Map<String, dynamic> json) => ConsolidatePreview(
    preparationId: _requireInt(json, 'preparation_id'), inputCount: _requireInt(json, 'input_count'),
    totalErgIn: _requireInt(json, 'total_erg_in'), changeNanoErg: _requireInt(json, 'change_nano_erg'),
    tokenCount: _requireInt(json, 'token_count'), minerFee: _requireInt(json, 'miner_fee'),
    inputBoxes: _parseInputBoxes(json['input_boxes']),
  );
}

class SplitPreview {
  final int preparationId;
  final int splitCount;
  final BigInt amountPerBox;
  final BigInt totalSplit;
  final int changeNanoErg;
  final int minerFee;
  final String? tokenId;
  final List<InputBoxInput> inputBoxes;

  SplitPreview({required this.preparationId, required this.splitCount, required this.amountPerBox, required this.totalSplit, required this.changeNanoErg, required this.minerFee, this.tokenId, this.inputBoxes = const []});

  factory SplitPreview.fromJson(Map<String, dynamic> json) {
    final tokenId = json['token_id'];
    if (tokenId != null && (tokenId is! String || tokenId.isEmpty)) {
      throw const FormatException('SplitPreview has invalid token_id');
    }
    return SplitPreview(
      preparationId: _requireInt(json, 'preparation_id'), splitCount: _requireInt(json, 'split_count'),
      amountPerBox: _requireBigInt(json, 'amount_per_box'), totalSplit: _requireBigInt(json, 'total_split'),
      changeNanoErg: _requireInt(json, 'change_nano_erg'), minerFee: _requireInt(json, 'miner_fee'),
      tokenId: tokenId as String?, inputBoxes: _parseInputBoxes(json['input_boxes']),
    );
  }
}

class RestructurePreview {
  final int preparationId;
  final int inputCount;
  final int outputCount;
  final int totalErgIn;
  final int allocatedErg;
  final int changeNanoErg;
  final bool hasChange;
  final int minerFee;
  final List<InputBoxInput> inputBoxes;

  RestructurePreview({required this.preparationId, required this.inputCount, required this.outputCount, required this.totalErgIn, required this.allocatedErg, required this.changeNanoErg, required this.hasChange, required this.minerFee, this.inputBoxes = const []});

  factory RestructurePreview.fromJson(Map<String, dynamic> json) {
    final hasChange = json['has_change'];
    if (hasChange is! bool) throw const FormatException('RestructurePreview missing or invalid has_change');
    return RestructurePreview(
      preparationId: _requireInt(json, 'preparation_id'), inputCount: _requireInt(json, 'input_count'),
      outputCount: _requireInt(json, 'output_count'), totalErgIn: _requireInt(json, 'total_erg_in'),
      allocatedErg: _requireInt(json, 'allocated_erg'), changeNanoErg: _requireInt(json, 'change_nano_erg'),
      hasChange: hasChange, minerFee: _requireInt(json, 'miner_fee'), inputBoxes: _parseInputBoxes(json['input_boxes']),
    );
  }
}

List<InputBoxInput> _parseInputBoxes(dynamic raw) {
  if (raw is! List) return const [];
  final out = <InputBoxInput>[];
  for (final item in raw) {
    if (item is! Map) continue;
    out.add(InputBoxInput.fromJson(item as Map<String, dynamic>));
  }
  return out;
}

/// Parses an on-chain amount that may arrive as a JSON string (node EIP-12
/// uses strings for box values and token amounts) or a number. Falls back to
/// zero on a malformed value rather than throwing, so a single bad field can
/// never sink the whole preview.
BigInt _parseBigInt(dynamic raw) {
  if (raw is num) return BigInt.from(raw.toInt());
  if (raw is String) {
    final s = raw.trim();
    if (s.isEmpty) return BigInt.zero;
    return BigInt.tryParse(s) ?? BigInt.zero;
  }
  return BigInt.zero;
}

/// A selected UTXO shown in the advanced send preview.
class InputBoxInput {
  final String boxId;
  final BigInt valueNanoErg;
  final int creationHeight;
  final List<InputAsset> assets;
  final String? address;

  InputBoxInput({
    required this.boxId,
    required this.valueNanoErg,
    required this.creationHeight,
    required this.assets,
    this.address,
  });

  factory InputBoxInput.fromJson(Map<String, dynamic> json) {
    return _parseBoxHelper(
      json,
      boxIdKey: 'box_id',
      valueKey: 'value_nano_erg',
      heightKey: 'creation_height',
      tokenIdKey: 'token_id',
      amountKey: 'amount',
    );
  }

  /// Parse from an ErgoBox JSON object returned by the node REST API
  /// (`/blockchain/box/unspent/byAddress`), whose keys use camelCase
  /// (e.g. `boxId`, `value`, `creationHeight`, `tokenId`, `amount`).
  factory InputBoxInput.fromErgoBox(Map<String, dynamic> json, {String? address}) {
    return _parseBoxHelper(
      json,
      boxIdKey: 'boxId',
      valueKey: 'value',
      heightKey: 'creationHeight',
      tokenIdKey: 'tokenId',
      amountKey: 'amount',
      address: address,
    );
  }

  static InputBoxInput _parseBoxHelper(
    Map<String, dynamic> json, {
    required String boxIdKey,
    required String valueKey,
    required String heightKey,
    required String tokenIdKey,
    required String amountKey,
    String? address,
  }) {
    final boxId = json[boxIdKey];
    if (boxId is! String || boxId.isEmpty) {
      throw FormatException('InputBoxInput missing or invalid $boxIdKey');
    }
    final valueRaw = json[valueKey];
    final value = _parseBigInt(valueRaw);
    final height = (json[heightKey] as num?)?.toInt() ?? 0;
    final assets = <InputAsset>[];
    final rawAssets = json['assets'];
    if (rawAssets is List) {
      for (final a in rawAssets) {
        if (a is! Map) continue;
        final aMap = a as Map<String, dynamic>;
        final id = aMap[tokenIdKey] as String? ?? '';
        final amt = _parseBigInt(aMap[amountKey]);
        if (id.isNotEmpty) {
          assets.add(InputAsset(tokenId: id, amount: amt));
        }
      }
    }
    return InputBoxInput(
      boxId: boxId,
      valueNanoErg: value,
      creationHeight: height,
      assets: assets,
      address: address ?? (json['address'] as String?),
    );
  }
}

/// A token held by a selected [InputBoxInput].
class InputAsset {
  final String tokenId;
  final BigInt amount;

  const InputAsset({required this.tokenId, required this.amount});
}

int _requireInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! num || !value.isFinite || value != value.truncate()) {
    throw FormatException('SendPreview missing or invalid $key');
  }
  return value.toInt();
}

BigInt _requireBigInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is int) return BigInt.from(value);
  if (value is num && value.isFinite && value == value.truncate()) return BigInt.from(value);
  if (value is String) {
    final parsed = BigInt.tryParse(value);
    if (parsed != null) return parsed;
  }
  throw FormatException('SplitPreview missing or invalid $key');
}

/// Parse decimal ERG text into nanoERG without using [double].
int? parseErgToNano(String raw) => parseDecimalToBase(raw, 9);

/// Normalize `,` decimals; reject grouping separators instead of guessing.
///
/// "1,5" is a locale decimal → "1.5". "1,234" is ambiguous across locales
/// (1234 vs 1.234) and mixed forms like "1,23.4" are malformed → both return
/// null so the caller shows an input error rather than silently mis-scaling.
String? _normalizeDecimalSeparators(String trimmed) {
  if (!trimmed.contains(',')) return trimmed;
  final thousandsWithFraction = RegExp(r'^\d{1,3}(,\d{3})+\.\d+$');
  if (trimmed.contains('.')) {
    // Dot present: commas are only acceptable as strict thousands groups.
    return thousandsWithFraction.hasMatch(trimmed)
        ? trimmed.replaceAll(',', '')
        : null;
  }
  final thousandsOnly = RegExp(r'^\d{1,3}(,\d{3})+$');
  if (thousandsOnly.hasMatch(trimmed)) return null;
  final decimalComma = RegExp(r'^\d+,\d+$');
  return decimalComma.hasMatch(trimmed) ? trimmed.replaceFirst(',', '.') : null;
}

/// Parse a decimal token amount into the on-chain integer.
///
/// Accepts both `.` and `,` as the decimal separator; see
/// [_normalizeDecimalSeparators] for grouping-separator handling.
int? parseDecimalToBase(String raw, int decimals) {
  if (decimals < 0 || decimals > 18) return null;
  final text = _normalizeDecimalSeparators(raw.trim());
  if (text == null || text.isEmpty) return null;
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
const maxInputsPerTx = 200;
const utxoFragmentationThreshold = 80;

/// Upper bound on UTXOs gathered per listing call across all addresses.
/// Beyond this the wallet's view of funds is partial by design.
const maxUnspentBoxesTotal = 2000;

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

/// BIP-39 word counts. 15 is the Ergo ecosystem standard (160-bit entropy).
bool isValidMnemonicWordCount(int n) => const [12, 15, 18, 21, 24].contains(n);

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
  /// All wallet handle IDs currently in memory, keyed by wallet ID.
  final Map<String, BigInt> _handles = {};

  /// The currently active wallet ID (null when locked or unassigned).
  String? _currentWalletId;

  /// Handle ID for the active wallet (computed).
  BigInt? get _handleId => _handles[_currentWalletId];

  /// WalletId-scoped key for [SharedPreferences].
  static const _walletMetaKey = 'argus_wallet_meta_v2';

  bool _initialized = false;
  final ValueNotifier<bool> unlocked = ValueNotifier(false);
  final ValueNotifier<String?> currentWalletId = ValueNotifier<String?>(null);
  final Map<String, TokenBalance> _tokenMeta = {};
  static const _tokenMetaKey = 'argus_token_meta_v2';
  bool _tokenMetaDirty = false;

  Future<void> init() async {
    if (_initialized) return;
    await Future.wait([RustLib.init(), loadTokenMeta()]);
    // Belt and braces with the frb(init) attribute: the app fee config must
    // be installed before any transaction is built.
    await RustLib.instance.api.crateApiInitApp();
    _initialized = true;
    await _migrateLegacyIfNeeded();
  }

  int get cachedTokenMetaCount => _tokenMeta.length;

  /// Caches [meta] (name, decimals, emission, icon) for its token id. Call
  /// [persistTokenMeta] afterwards to keep it across launches.
  void rememberTokenMeta(TokenBalance meta) {
    _tokenMeta[meta.id] = meta;
    _tokenMetaDirty = true;
  }

  /// Token metadata is public chain data and never changes for a given id,
  /// so it is safe to keep in plain preferences and skip the node next time.
  Future<void> loadTokenMeta() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_tokenMetaKey);
      if (raw == null || raw.isEmpty) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in map.entries) {
        final v = entry.value;
        if (v is! Map) continue;
        _tokenMeta[entry.key] = TokenBalance(
          id: entry.key,
          amount: 0,
          name: v['name'] as String?,
          decimals: (v['decimals'] as num?)?.toInt() ?? 0,
          emissionAmount: (v['emissionAmount'] as num?)?.toInt(),
          iconUrl: v['iconUrl'] as String?,
        );
      }
    } catch (_) {
      // A corrupt cache only costs a refetch.
    }
  }

  Future<void> persistTokenMeta() async {
    if (!_tokenMetaDirty) return;
    _tokenMetaDirty = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _tokenMetaKey,
      jsonEncode({
        for (final e in _tokenMeta.entries)
          e.key: {
            'name': e.value.name,
            'decimals': e.value.decimals,
            'emissionAmount': e.value.emissionAmount,
            'iconUrl': e.value.iconUrl,
          },
      }),
    );
  }

  /// Migrate pre-multi-wallet single-slot storage to a new wallet ID.
  Future<void> _migrateLegacyIfNeeded() async {
    final migratedId = await SecureStorageService.migrateLegacyWallet();
    if (migratedId != null) {
      await _upsertWalletMeta(
        migratedId,
        name: 'Wallet 1',
        createdAt: DateTime.now().toUtc(),
      );
    }
  }

  bool get isUnlocked => _handleId != null;

  /// The handle ID of the currently active wallet.
  BigInt? get handleId => _handleId;

  /// The wallet ID of the currently active wallet.
  String? get activeWalletId => _currentWalletId;

  Future<String> generateMnemonic({int strength = 256}) async {
    return RustLib.instance.api.crateApiGenerateMnemonic(strength: strength);
  }

  /// Provision a new wallet end-to-end: generate a name, create the wallet,
  /// wrap the key with a PIN, persist the sealed seed, derive the first
  /// address, and save wallet metadata. Returns the new wallet ID.
  Future<String> provisionWallet({
    required String phrase,
    required String passphrase,
    required String pin,
    String? name,
  }) async {
    final walletId = const Uuid().v4();
    final chosen = name?.trim();
    final walletName = chosen != null && chosen.isNotEmpty ? chosen : await generateWalletName();
    final session = await createWallet(
      phrase,
      passphrase: passphrase,
      walletId: walletId,
    );
    try {
      final pinWrap = await wrapKeyWithPin(session.wrapKey, pin);
      await SecureStorageService.saveWalletWithPin(
        walletId: walletId,
        encryptedSeedJson: session.encryptedSeedJson,
        pinWrapJson: pinWrap,
      );
      final address0 = await deriveAddress(0);
      await saveWalletInfo(
        walletId,
        name: walletName,
        createdAt: DateTime.now().toUtc(),
        address0: address0,
      );
    } catch (_) {
      await lock(walletId);
      rethrow;
    }
    return walletId;
  }

  /// Create a new wallet. If [walletId] is omitted, a UUID is generated.
  Future<WalletSession> createWallet(
    String mnemonic, {
    String passphrase = '',
    String? walletId,
  }) async {
    final raw = await RustLib.instance.api
        .crateApiWalletCreate(mnemonicPhrase: mnemonic, passphrase: passphrase);
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final id = walletId ?? const Uuid().v4();
    final session = WalletSession(
      walletId: id,
      handleId: BigInt.parse(map['handle_id'].toString()),
      encryptedSeedJson: map['encrypted_seed_json'] as String,
      wrapKey: map['wrap_key'] as String,
    );
    _setHandle(id, session.handleId);
    return session;
  }

  Future<String> wrapKeyWithPin(String wrapKey, String pin) {
    return RustLib.instance.api.crateApiWrapKeyWithPin(wrapKeyHex: wrapKey, pin: pin);
  }

  Future<String> unwrapKeyWithPin(String pinWrapJson, String pin) {
    return RustLib.instance.api.crateApiUnwrapKeyWithPin(pinWrapJson: pinWrapJson, pin: pin);
  }

  /// Restore a wallet from an encrypted seed JSON blob.
  /// If [walletId] is omitted, a UUID is generated.
  Future<void> restoreWallet(
    String encryptedSeedJson, {
    String? wrapKey,
    String? walletId,
  }) async {
    final raw = await RustLib.instance.api.crateApiWalletRestore(
      encryptedSeedJson: encryptedSeedJson,
      wrapKey: wrapKey,
    );
    final id = walletId ?? const Uuid().v4();
    _setHandle(id, raw);
  }

  /// Lock the currently active wallet. If [walletId] is provided, lock only
  /// that specific wallet; otherwise lock the active one.
  Future<void> lock([String? walletId]) async {
    final id = _handles[walletId ?? _currentWalletId];
    final wid = walletId ?? _currentWalletId;
    if (id == null) {
      unlocked.value = false;
      if (wid == null) currentWalletId.value = null;
      return;
    }
    try {
      await RustLib.instance.api.crateApiWalletLock(handleId: id);
    } finally {
      if (_handles[wid] == id) {
        _handles.remove(wid);
        if (_currentWalletId == wid) {
          _currentWalletId = null;
          currentWalletId.value = null;
          unlocked.value = false;
        }
      }
    }
  }

  /// Returns metadata for all stored wallets.
  Future<List<WalletInfo>> listWallets() async {
    final ids = await SecureStorageService.listWalletIds();
    final all = await _loadAllWalletMeta();
    final List<WalletInfo> infos = [];
    for (final id in ids) {
      final meta = all[id];
      final info = meta != null
          ? WalletInfo.fromJson(meta)
          : WalletInfo(
              walletId: id,
              name: 'Wallet',
              createdAt: DateTime.now(),
            );
      infos.add(info.copyWith(isUnlocked: _handles.containsKey(id)));
    }
    return infos;
  }

  /// Returns the pinned address index for [walletId] (defaults to the active
  /// wallet), or 0 if none pinned.
  /// Fills in the pinned address for a wallet that has a pinned *index*
  /// but no stored address, which is every pin made before the address was
  /// recorded alongside it. Without this a locked wallet shows its index-0
  /// address instead of the one the user pinned.
  Future<void> backfillPinnedAddress() async {
    final id = _currentWalletId;
    if (id == null || !isUnlocked) return;
    final meta = await _loadWalletMeta(id);
    final index = meta.pinnedAddressIndex ?? 0;
    if (index <= 0 || meta.pinnedAddress != null) return;
    final addr = await tryDeriveAddress(index);
    if (addr == null) return;
    // Deriving is async: the user may have switched wallets, locked, or
    // changed the pin meanwhile. Writing then would restore a pin they
    // just cleared, or record an address for the wrong wallet.
    if (_currentWalletId != id || !isUnlocked) return;
    final now = await _loadWalletMeta(id);
    if ((now.pinnedAddressIndex ?? 0) != index || now.pinnedAddress != null) return;
    await setPinnedAddressIndex(id, index, address: addr);
  }

  Future<int> getPinnedAddressIndex({String? walletId}) async {
    final id = walletId ?? _currentWalletId;
    if (id == null) return 0;
    final meta = await _loadWalletMeta(id);
    return meta.pinnedAddressIndex ?? 0;
  }

  /// Persist metadata for a wallet (name, address, creation time).
  Future<void> saveWalletInfo(
    String walletId, {
    required String name,
    required DateTime createdAt,
    String? address0,
    int? pinnedAddressIndex,
  }) async {
    await _upsertWalletMeta(
      walletId,
      name: name,
      createdAt: createdAt,
      address0: address0,
      pinnedAddressIndex: pinnedAddressIndex,
    );
  }

  /// Auto-generate a wallet name based on the current count.
  Future<String> generateWalletName() async {
    final existing = await listWallets();
    return 'Wallet ${existing.length + 1}';
  }

  /// Rename a stored wallet.
  Future<void> renameWallet(String walletId, String newName) async {
    final meta = await _loadWalletMeta(walletId);
    await _upsertWalletMeta(
      walletId,
      name: newName,
      createdAt: meta.createdAt,
      address0: meta.address0,
      pinnedAddressIndex: meta.pinnedAddressIndex,
    );
  }

  /// Pin a specific address index as the primary send/receive address for this wallet.
  /// Pass `null` to reset to the default (index 0).
  Future<void> setPinnedAddressIndex(String walletId, int? index, {String? address}) async {
    final meta = await _loadWalletMeta(walletId);
    await _upsertWalletMeta(
      walletId,
      name: meta.name,
      createdAt: meta.createdAt,
      address0: meta.address0,
      pinnedAddressIndex: index,
      pinnedAddress: (index ?? 0) > 0 ? address : null,
    );
  }

  /// Token metadata already known (persisted cache), without a node call.
  TokenBalance? cachedTokenMeta(String id) => _tokenMeta[id];

  /// Fetches metadata for any of [ids] not yet known and persists it.
  Future<void> prefetchTokenMeta(Iterable<String> ids) async {
    final missing = ids.where((id) => id.isNotEmpty && !_tokenMeta.containsKey(id)).toSet();
    if (missing.isEmpty) return;
    await Future.wait(missing.map((id) => tokenMeta(id, 0)));
    await persistTokenMeta();
  }

  /// Delete a wallet and all its secure storage.
  Future<void> deleteWallet(String walletId) async {
    await WalletDatabaseService.clearWallet(walletId).catchError((_) {});
    if (_handles.containsKey(walletId)) {
      await lock(walletId);
    }
    await SecureStorageService.deleteWallet(walletId);
    await _removeWalletMeta(walletId);
  }

  /// Highest address index the wallet core can derive and scan (inclusive).
  /// Mirrors MAX_OWN_SCAN in rust/crates/wallet-core/src/wallet.rs — indices
  /// beyond this make deriveAddress throw.
  static const maxAddressIndex = 512;

  Future<String> deriveAddress(int index) {
    _requireUnlocked();
    return RustLib.instance.api
        .crateApiDeriveAddress(handleId: _handleId!, index: index);
  }

  /// Derive like [deriveAddress] but return null on failure (e.g. an index
  /// above [maxAddressIndex]) instead of throwing, so one bad pinned index
  /// cannot take down the whole sync flow.
  Future<String?> tryDeriveAddress(int index) async {
    try {
      return await deriveAddress(index);
    } catch (_) {
      return null;
    }
  }

  Future<String> discoverAddresses({int gapLimit = 20, String? nodeUrl}) async {
    _requireUnlocked();
    return RustLib.instance.api.crateApiDiscoverAddresses(
      handleId: _handleId!,
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
    int? feeNanoErg,
    List<String>? inputBoxIds,
    String? stealthBoxesJson,
  }) async {
    _requireUnlocked();
    final raw = await RustLib.instance.api.crateApiPrepareSend(
      handleId: _handleId!,
      senderAddress: senderAddress,
      spendAddresses: spendAddresses ?? const [],
      changeAddress: changeAddress,
      recipientAddress: recipientAddress,
      amountNanoErg: amountNanoErg,
      tokenId: tokenId,
      tokenAmount: tokenAmount != null ? BigInt.from(tokenAmount) : null,
      nodeUrl: nodeUrl,
      feeNano: feeNanoErg,
      inputBoxIds: inputBoxIds,
      stealthBoxesJson: stealthBoxesJson,
    );
    return SendPreview.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// Prepare a multi-recipient send.
  /// Each recipient in [recipients] must have keys: address, amount_nano_erg (optional if token),
  /// token_id (optional), token_amount (optional).
  Future<SendPreview> prepareSendMulti({
    required String senderAddress,
    List<String>? spendAddresses,
    required String changeAddress,
    required List<Map<String, dynamic>> recipients,
    String? nodeUrl,
    int? feeNanoErg,
    List<String>? inputBoxIds,
    String? stealthBoxesJson,
  }) async {
    _requireUnlocked();
    final raw = await RustLib.instance.api.crateApiPrepareSendMulti(
      handleId: _handleId!,
      senderAddress: senderAddress,
      spendAddresses: spendAddresses ?? const [],
      changeAddress: changeAddress,
      recipientsJson: jsonEncode(recipients),
      nodeUrl: nodeUrl,
      feeNano: feeNanoErg,
      inputBoxIds: inputBoxIds,
      stealthBoxesJson: stealthBoxesJson,
    );
    return SendPreview.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// A fresh one-time address for our own stealth change, with its script.
  Future<Map<String, dynamic>> stealthSelfChangeTarget(String stealthAddress) async {
    final raw = await RustLib.instance.api
        .crateApiStealthSelfChangeTarget(stealthAddress: stealthAddress);
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Prepare a UTXO consolidation transaction.
  Future<ConsolidatePreview> prepareConsolidate({
    required List<String> spendAddresses,
    List<String>? selectedBoxIds,
    required String changeAddress,
    String? nodeUrl,
    int? feeNanoErg,
  }) async {
    _requireUnlocked();
    final raw = await RustLib.instance.api.crateApiPrepareConsolidate(
      handleId: _handleId!,
      spendAddresses: spendAddresses,
      selectedBoxIds: selectedBoxIds ?? const [],
      changeAddress: changeAddress,
      nodeUrl: nodeUrl,
      feeNano: feeNanoErg,
    );
    return ConsolidatePreview.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// Prepare a transaction to split ERG into N equal boxes.
  Future<SplitPreview> prepareSplitErg({
    required List<String> spendAddresses,
    List<String>? selectedBoxIds,
    required int count,
    required int amountPerBoxNano,
    required String changeAddress,
    String? nodeUrl,
    int? feeNanoErg,
  }) async {
    _requireUnlocked();
    final raw = await RustLib.instance.api.crateApiPrepareSplitErg(
      handleId: _handleId!,
      spendAddresses: spendAddresses,
      selectedBoxIds: selectedBoxIds ?? const [],
      count: count,
      amountPerBoxNano: amountPerBoxNano,
      changeAddress: changeAddress,
      nodeUrl: nodeUrl,
      feeNano: feeNanoErg,
    );
    return SplitPreview.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// Prepare a transaction to split a token into N equal boxes.
  Future<SplitPreview> prepareSplitToken({
    required List<String> spendAddresses,
    List<String>? selectedBoxIds,
    required String tokenId,
    required int count,
    required BigInt amountPerBox,
    required int ergPerBoxNano,
    required String changeAddress,
    String? nodeUrl,
    int? feeNanoErg,
  }) async {
    _requireUnlocked();
    final raw = await RustLib.instance.api.crateApiPrepareSplitToken(
      handleId: _handleId!,
      spendAddresses: spendAddresses,
      selectedBoxIds: selectedBoxIds ?? const [],
      tokenId: tokenId,
      count: count,
      amountPerBox: amountPerBox,
      ergPerBoxNano: ergPerBoxNano,
      changeAddress: changeAddress,
      nodeUrl: nodeUrl,
      feeNano: feeNanoErg,
    );
    return SplitPreview.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// Prepare a custom restructure transaction to allocate inputs into custom outputs.
  Future<RestructurePreview> prepareRestructure({
    required List<String> spendAddresses,
    List<String>? selectedBoxIds,
    required List<Map<String, dynamic>> outputs,
    required String changeAddress,
    String? nodeUrl,
    int? feeNanoErg,
  }) async {
    _requireUnlocked();
    final raw = await RustLib.instance.api.crateApiPrepareRestructure(
      handleId: _handleId!,
      spendAddresses: spendAddresses,
      selectedBoxIds: selectedBoxIds ?? const [],
      outputsJson: jsonEncode(outputs),
      changeAddress: changeAddress,
      nodeUrl: nodeUrl,
      feeNano: feeNanoErg,
    );
    return RestructurePreview.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<String> sendErg({required int preparationId}) async {
    final map = await sendErgDetailed(preparationId: preparationId);
    return map['tx_id'] as String? ?? '';
  }

  /// Like [sendErg], returning the whole result: `tx_id`, fees, and
  /// `output_box_ids`, the ids of the transaction's outputs.
  Future<Map<String, dynamic>> sendErgDetailed({required int preparationId}) async {
    _requireUnlocked();
    final raw = await RustLib.instance.api.crateApiSendErg(
      handleId: _handleId!,
      preparationId: BigInt.from(preparationId),
    );
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  // ── Stealth addresses ───────────────────────────────────────────────

  /// This wallet's published `stealth…` string.
  Future<String> stealthAddress() {
    _requireUnlocked();
    return RustLib.instance.api.crateApiStealthAddress(handleId: _handleId!);
  }

  /// Which of the explorer's stealth boxes this wallet can spend.
  /// [explorerBoxesJson] is the raw body of the template-hash endpoint.
  Future<Map<String, dynamic>> stealthScan(String explorerBoxesJson) async {
    _requireUnlocked();
    final raw = await RustLib.instance.api.crateApiStealthScan(
      handleId: _handleId!,
      explorerBoxesJson: explorerBoxesJson,
    );
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Prepare a sweep of every owned stealth box to one of our own addresses.
  /// Broadcast it with [sendErg], like any other preparation.
  Future<SendPreview> prepareStealthSweep({
    required String explorerBoxesJson,
    required String destinationAddress,
    String? nodeUrl,
    int? feeNanoErg,
  }) async {
    _requireUnlocked();
    final raw = await RustLib.instance.api.crateApiPrepareStealthSweep(
      handleId: _handleId!,
      explorerBoxesJson: explorerBoxesJson,
      destinationAddress: destinationAddress,
      nodeUrl: nodeUrl,
      feeNano: feeNanoErg,
    );
    return SendPreview.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  // ── ZeroJoin mixing ─────────────────────────────────────────────────
  //
  // Thin JSON pass-throughs; `MixService` owns the meaning of each. The
  // secret for a mix round is derived inside the handle and never returned.

  Future<String> mixObserve({
    required String stateJson,
    required String chainJson,
    required int nowUnix,
  }) {
    _requireUnlocked();
    return RustLib.instance.api.crateApiMixObserve(
      handleId: _handleId!,
      stateJson: stateJson,
      chainJson: chainJson,
      nowUnix: nowUnix,
    );
  }

  Future<String> mixRecover({required String chainJson, required int nowUnix}) {
    _requireUnlocked();
    return RustLib.instance.api.crateApiMixRecover(
      handleId: _handleId!,
      chainJson: chainJson,
      nowUnix: nowUnix,
    );
  }

  /// Prepare a mix entry; confirm it with [sendErg] like any send.
  Future<String> mixPrepareEntry({
    required String stateJson,
    required String chainJson,
    required String fundingAddress,
    required String fundingBoxId,
    required List<String> ownHalfBoxIds,
    String? nodeUrl,
    int? feeNanoErg,
    required int nowUnix,
  }) {
    _requireUnlocked();
    return RustLib.instance.api.crateApiMixPrepareEntry(
      handleId: _handleId!,
      stateJson: stateJson,
      chainJson: chainJson,
      fundingAddress: fundingAddress,
      fundingBoxId: fundingBoxId,
      ownHalfBoxIds: ownHalfBoxIds,
      nodeUrl: nodeUrl,
      feeNano: feeNanoErg,
      nowUnix: nowUnix,
    );
  }

  /// Build, sign and broadcast one remix or withdrawal.
  Future<String> mixAdvance({
    required String stateJson,
    required String chainJson,
    required List<String> ownHalfBoxIds,
    String? nodeUrl,
    int? feeNanoErg,
    required int nowUnix,
  }) {
    _requireUnlocked();
    return RustLib.instance.api.crateApiMixAdvance(
      handleId: _handleId!,
      stateJson: stateJson,
      chainJson: chainJson,
      ownHalfBoxIds: ownHalfBoxIds,
      nodeUrl: nodeUrl,
      feeNano: feeNanoErg,
      nowUnix: nowUnix,
    );
  }

  /// Withdraw or reclaim a mix now.
  Future<String> mixLeave({
    required String stateJson,
    required String chainJson,
    String? destinationAddress,
    String? nodeUrl,
    int? feeNanoErg,
    required int nowUnix,
  }) {
    _requireUnlocked();
    return RustLib.instance.api.crateApiMixLeave(
      handleId: _handleId!,
      stateJson: stateJson,
      chainJson: chainJson,
      destinationAddress: destinationAddress,
      nodeUrl: nodeUrl,
      feeNano: feeNanoErg,
      nowUnix: nowUnix,
    );
  }

  // ── ErgoPay (EIP-20) ────────────────────────────────────────────────

  /// Summary JSON for a reduced transaction (see `describe_reduced_transaction`).
  Future<Map<String, dynamic>> describeReducedTransaction(
    Uint8List reducedTx, {
    String? nodeUrl,
  }) async {
    _requireUnlocked();
    final raw = await RustLib.instance.api.crateApiDescribeReducedTransaction(
      handleId: _handleId!,
      reducedTxBytes: reducedTx,
      nodeUrl: nodeUrl,
    );
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Signs a reduced transaction with the unlocked wallet; returns node JSON.
  Future<String> signReducedTransaction(Uint8List reducedTx) {
    _requireUnlocked();
    return RustLib.instance.api.crateApiSignReducedTransaction(
      handleId: _handleId!,
      reducedTxBytes: reducedTx,
    );
  }

  /// Broadcasts signed transaction JSON and returns the tx id.
  Future<String> submitSignedTransaction(String txJson, {String? nodeUrl}) {
    return RustLib.instance.api.crateApiSubmitSignedTransaction(
      txJson: txJson,
      nodeUrl: nodeUrl,
    );
  }

  Future<bool> ownsAddress(String address) {
    _requireUnlocked();
    return RustLib.instance.api.crateApiWalletOwnsAddress(
      handleId: _handleId!,
      address: address,
    );
  }

  /// Sign a prepared transaction without submitting it. Returns the raw signed
  /// transaction JSON (for export / air-gapped signing).
  Future<String> signPreparation({required int preparationId}) async {
    _requireUnlocked();
    return RustLib.instance.api.crateApiSignPreparation(
      handleId: _handleId!,
      preparationId: BigInt.from(preparationId),
    );
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
    final out = await Future.wait(jobs);
    // Fire and forget: the write must not slow the balance refresh.
    persistTokenMeta().catchError((_) {});
    return out;
  }

  /// True when the last [loadHistory] succeeded but at least one address
  /// failed to load, meaning the returned activity may be incomplete.
  bool lastHistoryPartial = false;

  Future<List<Map<String, dynamic>>> loadHistory(
    List<String> addresses, {
    int limit = 20,
    int offset = 0,
    Map<String, int>? perAddressOffsets,
  }) async {
    var ok = 0;
    var failed = 0;
    final results = await Future.wait(
      addresses.map((address) async {
        try {
          final off = perAddressOffsets != null
              ? (perAddressOffsets[address] ?? 0)
              : offset;
          final raw = await getTransactionHistory(address, limit: limit, offset: off);
          ok++;
          final decoded = jsonDecode(raw) as List;
          if (perAddressOffsets != null) {
            perAddressOffsets[address] = off + decoded.length;
          }
          return decoded;
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
    lastHistoryPartial = failed > 0;
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
    // Unconfirmed transactions ride ahead of confirmed history. A mempool
    // failure must never break the activity list, so it degrades to confirmed.
    var pending = const <dynamic>[];
    try {
      final raw = await RustLib.instance.api
          .crateApiGetPendingTransactions(addresses: addresses);
      pending = jsonDecode(raw) as List;
    } catch (_) {}

    return mergePending(pending, all);
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
      rememberTokenMeta(info);
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

  /// Fetch all unspent boxes (UTXOs) for the given addresses by calling the
  /// node's REST API directly. Returns parsed [InputBoxInput] objects.
  ///
  /// Caps at [maxUnspentBoxesTotal] across all addresses; a node error is
  /// raised, never silently treated as an empty wallet.
  Future<List<InputBoxInput>> listUnspentBoxes(
    List<String> addresses, {
    required String? nodeUrl,
    int limit = 100,
  }) async {
    if (nodeUrl == null || nodeUrl.isEmpty) return [];
    final normalizedUrl = nodeUrl.endsWith('/')
        ? nodeUrl.substring(0, nodeUrl.length - 1)
        : nodeUrl;
    final client = http.Client();
    try {
      final all = <InputBoxInput>[];
      final seen = <String>{};
      for (final addr in addresses) {
        if (addr.isEmpty) continue;
        if (all.length >= maxUnspentBoxesTotal) break;
        var offset = 0;
        while (all.length < maxUnspentBoxesTotal) {
          final endpoint = '$normalizedUrl/blockchain/box/unspent/byAddress'
              '?offset=$offset&limit=$limit';
          final response = await client
              .post(Uri.parse(endpoint),
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode(addr))
              .timeout(const Duration(seconds: 15));
          if (response.statusCode != 200) {
            throw Exception(
                'Node returned ${response.statusCode} for unspent boxes');
          }
          final body = response.body;
          if (body.isEmpty) break;
          final value = jsonDecode(body);
          final items = (value is List)
              ? value
              : (value is Map ? (value['items'] as List? ?? []) : []);
          if (items.isEmpty) break;
          for (final item in items) {
            if (item is! Map) continue;
            try {
              final b = InputBoxInput.fromErgoBox(
                item as Map<String, dynamic>,
                address: addr,
              );
              if (seen.add(b.boxId)) {
                all.add(b);
                if (all.length >= maxUnspentBoxesTotal) break;
              }
            } catch (_) {
              // skip malformed entries
            }
          }
          if (items.length < limit || all.length >= maxUnspentBoxesTotal) break;
          offset += limit;
        }
      }
      return all;
    } finally {
      client.close();
    }
  }

  /// Consolidate ERG by sending-to-self in batches of up to 200 inputs.
  ///
  /// sigma-rust's coin selection (`select_for_send`) picks the largest boxes
  /// first. Since it trusts the node to reject oversized txs, we cap each
  /// batch at 200 inputs — well under Ergo's practical tx-size ceiling of
  /// ~500 inputs / ~250 KB. The node parameters (`inputCost` = 2407,
  /// `maxBlockCost` ≈ 8,000,091) would theoretically allow ~3300 inputs per
  /// block, but serialization in EIP-12 JSON pushes ~500 bytes per input, so
  /// 200 keeps each batch safe and reliably includable.
  ///
  /// Returns the list of transaction IDs for all consolidation txs.
  /// Only consolidates ERG (no tokens moved; token-bearing boxes untouched).
  Future<List<String>> consolidateErg({
    required List<String> addresses,
    required String changeAddress,
    String? nodeUrl,
  }) async {
    _requireUnlocked();
    if (addresses.isEmpty) return [];

    final reserve = BigInt.from(minerFeeNano + argusFeeNano + minBoxNano);
    final txIds = <String>[];

    while (true) {
      final boxes = await listUnspentBoxes(addresses, nodeUrl: nodeUrl);
      // Only ERG-only boxes — leave token-bearing boxes alone.
      var ergOnly = boxes.where((b) => b.assets.isEmpty).toList();
      if (ergOnly.length < 2) break;

      // Sort largest first so each batch hits the most value with the fewest inputs.
      ergOnly.sort((a, b) => b.valueNanoErg.compareTo(a.valueNanoErg));
      final batch = ergOnly.take(maxInputsPerTx).toList();
      if (batch.length < 2) break;

      final totalNano = batch.fold(BigInt.zero, (s, b) => s + b.valueNanoErg);
      if (totalNano <= reserve + BigInt.from(minBoxNano)) break;

      final amountToSend = totalNano - reserve;
      if (amountToSend <= BigInt.from(minBoxNano)) break;

      final batchOwners = batch
          .map((b) => b.address)
          .whereType<String>()
          .where((a) => a.isNotEmpty)
          .toSet()
          .toList();
      final spendAddrs = batchOwners.isNotEmpty ? batchOwners : addresses;

      try {
        final preview = await prepareSend(
          senderAddress: changeAddress,
          spendAddresses: spendAddrs,
          changeAddress: changeAddress,
          recipientAddress: changeAddress,
          amountNanoErg: amountToSend.toInt(),
          nodeUrl: nodeUrl,
        );
        final txId = await sendErg(preparationId: preview.preparationId);
        txIds.add(txId);
        if (ergOnly.length <= maxInputsPerTx) break;
      } catch (e) {
        // Progress already broadcast is preserved; a total failure is a real
        // error the caller must see rather than an empty success.
        if (txIds.isEmpty) rethrow;
        debugPrint('argus: consolidation stopped after ${txIds.length} batch(es): $e');
        break;
      }
    }
    return txIds;
  }

  /// Track a singleton token (NFT / contract state) forward through spent transaction outputs.
  /// Works without extraIndex or explorer indexing by following spent box transaction chains.
  Future<Map<String, dynamic>> walkSingletonLineage({
    required String singletonTokenId,
    required String startingBoxId,
    String? nodeUrl,
    int? maxHops,
  }) async {
    final raw = await RustLib.instance.api.crateApiWalkSingletonLineage(
      singletonTokenId: singletonTokenId,
      startingBoxId: startingBoxId,
      nodeUrl: nodeUrl,
      maxHops: maxHops,
    );
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Compute total balances and summary from a local WalletDatabase JSON snapshot.
  Future<Map<String, dynamic>> computeDbSummary(String dbJson) async {
    final raw = await RustLib.instance.api.crateApiDbComputeSummary(dbJson: dbJson);
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  void _setHandle(String walletId, BigInt id) {
    _handles[walletId] = id;
    _currentWalletId = walletId;
    currentWalletId.value = walletId;
    unlocked.value = true;
  }

  void _requireUnlocked() {
    if (_handleId == null) {
      throw ArgusException(code: 'WALLET_LOCKED', message: 'Wallet is locked');
    }
  }

  /// --- Wallet metadata (stored in [SharedPreferences], unencrypted) ---

  Map<String, dynamic>? _metaCache;
  Future<void>? _metaWrite;

  Future<Map<String, dynamic>> _loadAllWalletMeta() async {
    final cached = _metaCache;
    if (cached != null) return cached;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_walletMetaKey);
    if (raw == null) {
      final empty = <String, dynamic>{};
      _metaCache = empty;
      return empty;
    }
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final all = decoded.map((k, v) => MapEntry(k, Map<String, dynamic>.from(v as Map)));
    _metaCache = all;
    return all;
  }

  Future<WalletInfo> _loadWalletMeta(String walletId) async {
    final all = await _loadAllWalletMeta();
    final meta = all[walletId];
    if (meta != null) {
      return WalletInfo.fromJson(meta);
    }
    return WalletInfo(
      walletId: walletId,
      name: 'Wallet',
      createdAt: DateTime.now(),
    );
  }

  Future<void> _withMetaWrite(Future<void> Function() body) async {
    final previous = _metaWrite;
    final last = Completer<void>();
    _metaWrite = last.future;
    if (previous != null) await previous;
    try {
      await body();
    } finally {
      last.complete();
    }
  }

  Future<void> _upsertWalletMeta(
    String walletId, {
    required String name,
    required DateTime createdAt,
    String? address0,
    int? pinnedAddressIndex,
    String? pinnedAddress,
  }) => _withMetaWrite(() async {
    final prior = await _loadAllWalletMeta();
    final next = Map<String, dynamic>.from(prior);
    final existing = prior[walletId];
    next[walletId] = {
      'walletId': walletId,
      'name': name,
      'createdAt': createdAt.toIso8601String(),
      'address0': address0,
      'pinnedAddressIndex': pinnedAddressIndex,
      // Keep a stored pinned address unless this write sets or clears it.
      'pinnedAddress': pinnedAddress ??
          ((pinnedAddressIndex ?? 0) > 0 && existing is Map ? existing['pinnedAddress'] : null),
    };
    await _persistMetaCache(next);
  });

  Future<void> _removeWalletMeta(String walletId) => _withMetaWrite(() async {
    final prior = await _loadAllWalletMeta();
    final next = Map<String, dynamic>.from(prior);
    next.remove(walletId);
    await _persistMetaCache(next);
  });

  /// Persists [next], swapping the in-memory cache only after the write
  /// succeeds. Propagates write failures and leaves the prior cache intact.
  Future<void> _persistMetaCache(Map<String, dynamic> next) async {
    final prefs = await SharedPreferences.getInstance();
    final ok = await prefs.setString(_walletMetaKey, jsonEncode(next));
    if (ok != true) {
      throw StateError('Failed to persist wallet metadata');
    }
    _metaCache = next;
  }
}

final walletService = WalletService();

/// Pending transactions ahead of confirmed history, deduplicated by id.
///
/// The mempool is queried once per wallet address, so a transaction touching
/// two of our addresses — spending from one, change to another — arrives
/// twice. A transaction that has since confirmed wins over its pending copy.
List<Map<String, dynamic>> mergePending(
  List<dynamic> pending,
  List<dynamic> confirmed,
) {
  String idOf(Map m) => m['tx_id']?.toString() ?? '';
  final confirmedIds = <String>{
    for (final c in confirmed) idOf((c as Map).cast<String, dynamic>()),
  };
  final seen = <String>{};
  final out = <Map<String, dynamic>>[];

  for (final p in pending) {
    final m = (p as Map).cast<String, dynamic>();
    final id = idOf(m);
    if (id.isEmpty || confirmedIds.contains(id) || !seen.add(id)) continue;
    out.add(m);
  }
  for (final c in confirmed) {
    out.add((c as Map).cast<String, dynamic>());
  }
  return out;
}
