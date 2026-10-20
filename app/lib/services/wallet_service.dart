import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../bridge/argus_error.dart';
import '../bridge/frb_generated.dart';
import 'app_fee.dart';
import 'network_controller.dart';
import 'privacy_service.dart';
import 'token_catalog.dart';
import 'token_decimals.dart';
import 'token_descriptor_store.dart';
import 'mnemonic_check.dart';
import 'token_evidence.dart';
export 'token_evidence.dart';
export 'mnemonic_check.dart';
import 'verified_tokens.dart' show knownToken;
import 'mix_service.dart';
import 'spend_policy.dart';
import 'activity_classifier.dart' show reownActivity;
import 'stealth_change_book.dart';
import 'stealth_service.dart';
import 'wallet_sync_controller.dart';
import 'secure_storage.dart';
import 'wallet_database_service.dart';

/// Metadata for a stored wallet.
/// [wallets] in the order of [order] (wallet ids); any not listed keep
/// their place after the listed ones.
List<WalletInfo> orderWallets(List<WalletInfo> wallets, List<String> order) {
  if (order.isEmpty) return wallets;
  final rank = {for (final (i, id) in order.indexed) id: i};
  final out = List<WalletInfo>.of(wallets);
  final base = order.length;
  int key(WalletInfo w) => rank[w.walletId] ?? base + wallets.indexOf(w);
  out.sort((a, b) => key(a).compareTo(key(b)));
  return out;
}

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

  /// Restored with the pre-1627 key derivation. Display only: the sealed
  /// seed carries the mode the keys are actually derived with.
  final bool legacyDerivation;

  WalletInfo({
    required this.walletId,
    required this.name,
    required this.createdAt,
    this.address0,
    this.pinnedAddressIndex,
    this.pinnedAddress,
    this.isUnlocked = false,
    this.legacyDerivation = false,
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
        legacyDerivation: legacyDerivation,
      );

  Map<String, dynamic> toJson() => {
        'walletId': walletId,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'address0': address0,
        'pinnedAddressIndex': pinnedAddressIndex,
        'pinnedAddress': pinnedAddress,
        if (legacyDerivation) 'derivation': 'pre1627',
      };

  factory WalletInfo.fromJson(Map<String, dynamic> json) => WalletInfo(
        walletId: json['walletId'] as String,
        name: json['name'] as String,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
        address0: json['address0'] as String?,
        pinnedAddressIndex: json['pinnedAddressIndex'] as int?,
        pinnedAddress: json['pinnedAddress'] as String?,
        legacyDerivation: json['derivation'] == 'pre1627',
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
  final String? originalName;
  final int decimals;
  final int? emissionAmount;
  final String? iconUrl;

  final String? description;
  final SupplyEvidence supplyEvidence;
  final DecimalsEvidence decimalsEvidence;
  final DeclaredAssetKind declaredAssetKind;
  final MetadataState metadataState;
  final MediaState mediaState;
  final String? source;
  final String? issuanceBoxId;
  final String? issuanceHash;
  final String? rawRegisters;

  /// How much of [amount] sits in stealth boxes rather than in the wallet's
  /// own P2PK boxes. Stealth funds are real but are not offered to ordinary
  /// coin selection; they are swept first.
  final int stealthAmount;

  TokenBalance({
    required this.id,
    required this.amount,
    String? name,
    this.decimals = 0,
    this.emissionAmount,
    this.iconUrl,
    this.stealthAmount = 0,
    this.description,
    this.supplyEvidence = SupplyEvidence.unknown,
    this.decimalsEvidence = DecimalsEvidence.unknown,
    this.declaredAssetKind = DeclaredAssetKind.none,
    this.metadataState = MetadataState.unavailable,
    this.mediaState = MediaState.unknown,
    this.source,
    this.issuanceBoxId,
    this.issuanceHash,
    this.rawRegisters,
  }) : originalName = name, name = name == null ? null : issuerText(name);

  /// True when any part of this holding is in stealth boxes.
  bool get hasStealth => stealthAmount > 0;

  bool get isCollectible =>
      metadataState != MetadataState.invalid &&
      metadataState != MetadataState.conflict &&
      (declaredAssetKind != DeclaredAssetKind.none ||
          (supplyEvidence == SupplyEvidence.originalEmission &&
              emissionAmount == 1 &&
              decimalsEvidence.readFromToken &&
              decimals == 0));

  String get classification {
    if (metadataState == MetadataState.invalid) return 'Metadata invalid';
    if (metadataState == MetadataState.conflict) return 'Metadata conflict';
    if (declaredAssetKind == DeclaredAssetKind.collection)
      return 'Collection token';
    if (declaredAssetKind == DeclaredAssetKind.unsupported)
      return 'Declared NFT · unsupported type';
    final single =
        supplyEvidence == SupplyEvidence.originalEmission &&
        emissionAmount == 1 &&
        decimalsEvidence.readFromToken &&
        decimals == 0;
    if (declaredAssetKind != DeclaredAssetKind.none) {
      if (single) return 'Single-unit artwork · ${declaredAssetKind.name}';
      if (supplyEvidence == SupplyEvidence.originalEmission &&
          (emissionAmount ?? 0) > 1) {
        return 'Declared artwork · multiple units';
      }
      return 'Declared artwork · supply unconfirmed';
    }
    if (single) return 'Single-unit token';
    return metadataState == MetadataState.complete
        ? 'Token'
        : 'Token · metadata unavailable';
  }

  TokenBalance withHolding(int amount, {int? stealthAmount}) =>
      TokenBalance._withHolding(
        this,
        amount,
        stealthAmount ?? this.stealthAmount,
      );

  // Copy both representations verbatim; only issuer input is sanitised.
  TokenBalance._withHolding(TokenBalance token, this.amount, this.stealthAmount)
    : id = token.id,
      name = token.name,
      originalName = token.originalName,
      decimals = token.decimals,
      emissionAmount = token.emissionAmount,
      iconUrl = token.iconUrl,
      description = token.description,
      supplyEvidence = token.supplyEvidence,
      decimalsEvidence = token.decimalsEvidence,
      declaredAssetKind = token.declaredAssetKind,
      metadataState = token.metadataState,
      mediaState = token.mediaState,
      source = token.source,
      issuanceBoxId = token.issuanceBoxId,
      issuanceHash = token.issuanceHash,
      rawRegisters = token.rawRegisters;

  String get label {
    final n = issuerText(name).trim();
    if (n.isNotEmpty) return n;
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
  final bool watchOnly;
  final bool watchAccount;
  final String senderAddress;
  final String receiveAddress;
  final String changeAddress;
  final List<String> historyAddresses;
  final List<TokenBalance> tokens;
  final int? spendableNano;
  final Map<String, dynamic>? transaction;

  const WalletRouteArgs({
    this.watchOnly = false,
    this.watchAccount = false,
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
    // A watched receive route must not inherit the active signing wallet.
    if (routeArgs is WalletRouteArgs && routeArgs.watchOnly) return routeArgs;
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
      watchOnly: watchOnly,
      watchAccount: watchAccount,
    );
  }
}

/// A fee paid in a token through a babel box (EIP-31).
class BabelFee {
  const BabelFee({
    required this.tokenId,
    required this.tokensPaid,
    required this.price,
    required this.feeNano,
  });
  final String tokenId;
  final int tokensPaid;

  /// nanoERG the babel box pays per token unit.
  final int price;
  final int feeNano;

  static BabelFee? fromJson(Object? v) {
    if (v is! Map) return null;
    return BabelFee(
      tokenId: v['token_id'] as String,
      tokensPaid: (v['tokens_paid'] as num).toInt(),
      price: (v['price'] as num).toInt(),
      feeNano: (v['fee_nano'] as num).toInt(),
    );
  }
}

class SendPreview {
  final int preparationId;
  final String recipient;
  final String? changeAddress;
  final int amountNanoErg;
  final int minerFee;
  final int appFeeNano;
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
    this.appFeeNano = 0,
    required this.changeNanoErg,
    required this.inputCount,
    this.changeAddress,
    this.tokenId,
    this.tokenAmount,
    this.inputBoxes = const [],
    this.recipients,
    this.babel,
  });

  /// Set when the miner fee was paid in a token rather than ERG.
  final BabelFee? babel;

  factory SendPreview.fromJson(Map<String, dynamic> json) {
    final recipsRaw = json['recipients'];
    List<Map<String, dynamic>>? recips;
    if (recipsRaw is List) {
      recips = recipsRaw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    // Multi-send previews describe recipients in an array. Older cores omit
    // the top-level single-send field, including for one multi-token recipient.
    final recipient = json['recipient'] ?? (recips?.isNotEmpty == true ? recips!.first['address'] : null);
    if (recipient is! String || recipient.isEmpty) {
      throw const FormatException('SendPreview missing or invalid recipient');
    }
    return SendPreview(
      preparationId: _requireInt(json, 'preparation_id'),
      recipient: recipient,
      changeAddress: json['change_address'] as String?,
      amountNanoErg: _requireInt(json, 'amount_nano_erg'),
      minerFee: _requireInt(json, 'miner_fee'),
      appFeeNano: (json['citadel_fee_nano'] as num?)?.toInt() ?? 0,
      changeNanoErg: _requireInt(json, 'change_nano_erg'),
      inputCount: _requireInt(json, 'input_count'),
      tokenId: json['token_id'] as String?,
      tokenAmount: (json['token_amount'] as num?)?.toInt(),
      inputBoxes: _parseInputBoxes(json['input_boxes']),
      recipients: recips,
      babel: BabelFee.fromJson(json['babel']),
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

  ConsolidatePreview({
    required this.preparationId,
    required this.inputCount,
    required this.totalErgIn,
    required this.changeNanoErg,
    required this.tokenCount,
    required this.minerFee,
    this.inputBoxes = const [],
  });

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

  SplitPreview({
    required this.preparationId,
    required this.splitCount,
    required this.amountPerBox,
    required this.totalSplit,
    required this.changeNanoErg,
    required this.minerFee,
    this.tokenId,
    this.inputBoxes = const [],
  });

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

  RestructurePreview({
    required this.preparationId,
    required this.inputCount,
    required this.outputCount,
    required this.totalErgIn,
    required this.allocatedErg,
    required this.changeNanoErg,
    required this.hasChange,
    required this.minerFee,
    this.inputBoxes = const [],
  });

  factory RestructurePreview.fromJson(Map<String, dynamic> json) {
    final hasChange = json['has_change'];
    if (hasChange is! bool)
      throw const FormatException(
        'RestructurePreview missing or invalid has_change',
      );
    return RestructurePreview(
      preparationId: _requireInt(json, 'preparation_id'),
      inputCount: _requireInt(json, 'input_count'),
      outputCount: _requireInt(json, 'output_count'),
      totalErgIn: _requireInt(json, 'total_erg_in'),
      allocatedErg: _requireInt(json, 'allocated_erg'),
      changeNanoErg: _requireInt(json, 'change_nano_erg'),
      hasChange: hasChange,
      minerFee: _requireInt(json, 'miner_fee'),
      inputBoxes: _parseInputBoxes(json['input_boxes']),
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

  /// False for a box a transaction still in the mempool created: an
  /// incoming payment or change not confirmed yet. Listed only while
  /// unconfirmed funds may be spent.
  final bool confirmed;

  /// The box's exact serialized size, which storage rent is charged on.
  /// Set by the wallet's own listing ([WalletService.listUnspentBoxes]);
  /// null elsewhere.
  final int? sizeBytes;

  InputBoxInput({
    required this.boxId,
    required this.valueNanoErg,
    required this.creationHeight,
    required this.assets,
    this.address,
    this.confirmed = true,
    this.sizeBytes,
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
  factory InputBoxInput.fromErgoBox(
    Map<String, dynamic> json, {
    String? address,
  }) {
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
      confirmed: json['confirmed'] != false,
      sizeBytes: (json['size_bytes'] as num?)?.toInt(),
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

/// Invisible format characters a paste can carry: soft hyphen, zero-width
/// space/joiners, direction marks, word joiner, BOM.
final _invisible = RegExp('[\u00AD\u180E\u200B-\u200F\u202A-\u202E\u2060-\u2064\uFEFF]');

/// Anything that is not part of a word: spaces of every kind (NBSP,
/// ideographic, …), digits, punctuation. Mirrors `bip39::normalize_words`
/// in Rust, which stays the authority (it also applies NFKD).
final _nonWord = RegExp(r'[^\p{L}\p{M}]+', unicode: true);

List<String> mnemonicWords(String raw) {
  return raw
      .replaceAll(_invisible, '')
      .toLowerCase()
      .split(_nonWord)
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

/// Completeness belongs to one history request, including its pending rows.
typedef HistoryResult = ({List<Map<String, dynamic>> rows, bool partial});

/// The single metadata job is already held. Typed rather than matched on
/// message text: Dart and Rust word this differently ("Another metadata
/// request is running" vs "Metadata request already running"), and a
/// substring check silently missed one of them.
/// Extends [StateError] so the pre-existing contract — callers and tests
/// that expect a StateError for a concurrent job — keeps holding, while the
/// type lets contention be told apart from a provider failure.
class MetadataBusyException extends StateError {
  MetadataBusyException() : super('Another metadata request is running');
}

class WalletService with WidgetsBindingObserver {
  bool _observingMetadata = false;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) clearSessionMetadata();
  }
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

  /// The old app-wide table, read once at startup and never written again.
  /// Kept as a base layer so names known before this change do not vanish;
  /// the active wallet's own descriptors overlay it.
  final Map<String, TokenBalance> _legacyTokenMeta = {};
  static const _tokenMetaKey = 'argus_token_meta_v2';
  bool _tokenMetaDirty = false;

  final metadataChanges = ValueNotifier<int>(0);
  final Map<String, TokenBalance> _descriptors = {};
  int _descriptorEpoch = 0;
  bool _metadataBusy = false;
  String _descriptorKey(String id) =>
      '${currentWalletId.value}|${networkController.activeUrl}|${networkController.explorer}|$id|1';

  TokenBalance displayMetadata(TokenBalance holding) {
    final session = _descriptors[_descriptorKey(holding.id)];
    if (session != null) {
      return session.withHolding(
        holding.amount,
        stealthAmount: holding.stealthAmount,
      );
    }
    // A holding published before anything knew its token carries no record,
    // and one restored from a snapshot carries a name but none of the
    // evidence behind it. Show what is known now instead of waiting for the
    // next sync to republish it. With nothing known — after "Clear
    // collectible cache" — the holding keeps what it was published with.
    if (holding.metadataState == MetadataState.unavailable) {
      final known = _displayLayers(holding.id);
      if (known != null) {
        return known.withHolding(
          holding.amount,
          stealthAmount: holding.stealthAmount,
        );
      }
    }
    return holding;
  }

  /// [cachedTokenMeta] with this session's explicitly loaded descriptor on
  /// top, for screens that name a token by id. Display only: a session
  /// descriptor is memory-only and must never be copied into a holding,
  /// because holdings are persisted.
  ///
  /// Watched wallets' own descriptors sit below this wallet's: a watched
  /// address or account names its holdings from them on its page, in its
  /// activity and in its prices, and [cachedTokenMeta] — what a seed wallet
  /// builds and persists its holdings from — never reads them.
  TokenBalance? displayTokenMeta(String id) =>
      _descriptors[_descriptorKey(id)] ?? _displayLayers(id);

  /// The display lookup under this session's explicit loads: this wallet's
  /// own descriptors, then watched wallets', then the public layers and
  /// the legacy table.
  TokenBalance? _displayLayers(String id) =>
      _ownTokenMeta(id) ?? _watchedTokenMeta(id) ?? cachedTokenMeta(id);

  TokenBalance? _ownTokenMeta(String id) {
    final own = _tokenMeta[id];
    return own != null && !identical(own, _legacyTokenMeta[id]) ? own : null;
  }

  // ── Watched wallets' token descriptors ──────────────────────────────────

  /// What each watched wallet's holdings were resolved to, keyed by its
  /// watched key ([watchedAddressKey], [watchedAccountKey]). Per wallet in
  /// memory and in that wallet's own stored table, as a seed wallet's are,
  /// never in an app-wide one: nothing on disk lists what two wallets have
  /// in common. Read for display only ([displayTokenMeta]).
  final Map<String, Map<String, CachedDescriptor>> _watchedTables = {};

  /// Ids a watched wallet's node answered "no such token" for, per
  /// `key|node`, so later passes this session do not ask again.
  final Map<String, Set<String>> _watchedMisses = {};
  final Map<String, int> _watchedCursors = {};

  /// Watched wallets with a pass running: one at a time per wallet.
  final Set<String> _watchedPasses = {};

  /// A watched wallet's next pass, when its last one left tokens unnamed.
  final Map<String, Timer> _watchedFollowUps = {};

  /// Passes in a row, per watched wallet, that named nothing new.
  final Map<String, int> _watchedIdlePasses = {};

  /// How soon a pass follows one that named something but not everything
  /// (the per-pass cap, or a run of failures cut it short).
  @visibleForTesting
  static Duration watchedFollowUpDelay = const Duration(seconds: 2);

  /// How long, times the number of idle passes so far, a pass waits after
  /// one that named nothing (the node not answering, the job held
  /// elsewhere). After [maxWatchedIdlePasses] of those, follow-ups stop and
  /// the wallet's next balance read starts again.
  @visibleForTesting
  static Duration watchedIdleDelay = const Duration(seconds: 15);
  static const maxWatchedIdlePasses = 3;

  /// Bumped when a watched wallet stops being watched or the caches are
  /// wiped, so a pass or a load already running cannot write back.
  final Map<String, int> _watchedGenerations = {};
  int _watchedWipes = 0;

  /// Told of every balance [getBalance] reads, with the node it asked. The
  /// watched wallets' resolver (`watched_token_meta.dart`) listens here,
  /// since the overview and a watched wallet's page read balances this way.
  void Function(String address, Map<String, dynamic> balance, String? nodeUrl)?
  onBalanceRead;

  static String watchedAddressKey(String address) => 'address:$address';
  static String watchedAccountKey(String key) => 'account:$key';
  static String _watchedTableId(String key) => 'watched:$key';

  /// Reads [key]'s stored table into memory, once.
  Future<void> loadWatchedTokenTable(String key) async {
    if (_watchedTables.containsKey(key)) return;
    final generation = _watchedGenerations[key] ?? 0;
    final wipes = _watchedWipes;
    final loaded = await TokenDescriptorStore.load(_watchedTableId(key));
    if ((_watchedGenerations[key] ?? 0) != generation ||
        wipes != _watchedWipes ||
        _watchedTables.containsKey(key)) {
      return;
    }
    _watchedTables[key] = loaded;
    if (loaded.isNotEmpty) metadataChanges.value++;
  }

  /// Drops a watched wallet's descriptors, in memory and on disk, once it
  /// is no longer watched.
  Future<void> forgetWatchedTokenTable(String key) async {
    _watchedGenerations[key] = (_watchedGenerations[key] ?? 0) + 1;
    final had = _watchedTables.remove(key)?.isNotEmpty ?? false;
    _watchedMisses.removeWhere((k, _) => k.startsWith('$key|'));
    _watchedCursors.remove(key);
    _watchedFollowUps.remove(key)?.cancel();
    _watchedIdlePasses.remove(key);
    await TokenDescriptorStore.clear(_watchedTableId(key));
    if (had) metadataChanges.value++;
  }

  /// Whether [key]'s own table already holds everything one lookup can say
  /// about [id], scale or no scale: asking again would say it again.
  bool watchedSettled(String key, String id) =>
      _watchedTables[key]?[id]?.incomplete == false;

  /// Whether a node already answered that [id] does not exist, for the
  /// watched wallet [key]: asking again this session would only repeat it.
  bool watchedMissed(String key, String id) => _watchedMisses.entries.any(
    (e) => e.key.startsWith('$key|') && e.value.contains(id),
  );

  /// What a watched wallet's own descriptors say about [id], preferring a
  /// complete one.
  TokenBalance? _watchedTokenMeta(String id) {
    CachedDescriptor? partial;
    for (final table in _watchedTables.values) {
      final d = table[id];
      if (d == null) continue;
      if (!d.incomplete) return _asBalance(d);
      partial ??= d;
    }
    return partial == null ? null : _asBalance(partial);
  }

  /// A scale the wallet-independent layers (the pool catalog, the curated
  /// registry, the legacy table) already give [id], so a watched wallet
  /// has no need to ask about it.
  bool _publiclyScaled(String id) {
    final m = publicTokenMeta(id) ?? _legacyTokenMeta[id];
    return m != null && m.decimalsEvidence.knowsScale;
  }

  /// How long a watched wallet's pass waits for the single metadata job
  /// while a seed wallet's pass or an explicit request holds it.
  static const _watchedJobPatience = Duration(minutes: 2);

  /// The single metadata job for a watched wallet's request: taken at once
  /// when free, from the catalog the moment its lookup ends, and otherwise
  /// waited for, up to [_watchedJobPatience], while [keepGoing] holds.
  Future<bool> _takeJobForWatched(bool Function() keepGoing) async {
    final deadline = DateTime.now().add(_watchedJobPatience);
    while (keepGoing()) {
      if (!_metadataBusy) {
        _metadataBusy = true;
        return true;
      }
      if (_catalogJob != null) {
        if (await _takeJobFromCatalog()) return true;
        continue;
      }
      if (DateTime.now().isAfter(deadline)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  /// Names what a watched wallet holds, under the rule a seed wallet's name
  /// pass follows (alpha.59): only from the node that served the wallet's
  /// balances, never the explorer or another node, and only about ids that
  /// node just served, so asking tells it nothing new.
  ///
  /// A plain balance read cannot say whether a fallback node answered, so
  /// the balances of [addresses] are read here through the public sync
  /// read, which names the node that did ([loadPublicSyncInputs]), one
  /// address at a time. Ids the public layers already scale are skipped.
  /// What the node answers goes to [key]'s own table. At most
  /// [maxTokenMetaPerSync] requests a pass, in the single metadata job,
  /// while the app is in front; the screens repaint as names arrive, and
  /// what a pass leaves unnamed is asked in the passes that follow it
  /// ([_followWatchedPass]).
  Future<void> resolveWatchedHoldings(
    String key,
    List<String> addresses, {
    String? nodeUrl,
  }) async {
    final targets = {
      for (final a in addresses)
        if (a.isNotEmpty) a,
    }.toList();
    if (targets.isEmpty || !_inForeground || !_watchedPasses.add(key)) return;
    // This pass is the one a follow-up was waiting to run.
    _watchedFollowUps.remove(key)?.cancel();
    final generation = _watchedGenerations[key] ?? 0;
    final wipes = _watchedWipes;
    bool current() =>
        _inForeground &&
        wipes == _watchedWipes &&
        (_watchedGenerations[key] ?? 0) == generation;
    var learned = false;
    // Unnamed tokens the pass set out to ask about, and how many of them it
    // left so: the difference is what it settled.
    var unsettled = 0;
    var left = 0;
    try {
      await loadWatchedTokenTable(key);
      if (!current()) return;
      final Map<String, dynamic> read;
      try {
        read = await loadPublicSyncInputs(targets, nodeUrl: nodeUrl);
      } catch (_) {
        return;
      }
      final servedBy = read['served_by'];
      if (servedBy is! String || servedBy.isEmpty || !current()) return;
      final served = <String>{
        for (final balance in ((read['balances'] as Map?) ?? const {}).values)
          if (balance is Map)
            for (final t in (balance['tokens'] as List? ?? const []))
              if (t is Map && t['id'] is String) t['id'] as String,
      };
      final misses = _watchedMisses.putIfAbsent('$key|$servedBy', () => {});
      final own = _watchedTables[key] ?? const <String, CachedDescriptor>{};
      final wanted = [
        for (final id in served)
          if (id.length == 64 &&
              !misses.contains(id) &&
              (own[id]?.incomplete ?? true) &&
              !_publiclyScaled(id))
            id,
      ]..sort();
      if (wanted.isEmpty) return;
      unsettled = wanted.length;
      left = wanted.length;
      // Backgrounding cancels a request in flight, as it does the wallet's.
      _observeLifecycle();
      final cursor = _watchedCursors[key] ?? 0;
      final start = cursor % wanted.length;
      final ordered = [...wanted.skip(start), ...wanted.take(start)];
      var attempted = 0;
      var consecutiveRetryable = 0;
      var consecutiveNotFound = 0;
      try {
        for (final id in ordered) {
          if (attempted >= maxTokenMetaPerSync || !current()) break;
          if (!await _takeJobForWatched(current)) break;
          if (!current()) {
            _metadataBusy = false;
            break;
          }
          attempted++;
          try {
            final raw = await RustLib.instance.api.crateApiInspectTokenMetadata(
              tokenId: id,
              providerUrl: servedBy,
              providerIsNode: true,
            );
            if (!current()) break;
            final m = jsonDecode(raw) as Map<String, dynamic>;
            if (m['id'] != id) continue;
            consecutiveRetryable = 0;
            consecutiveNotFound = 0;
            final table = _watchedTables.putIfAbsent(key, () => {});
            table.remove(id);
            while (table.length >= TokenDescriptorStore.maxEntries) {
              table.remove(table.keys.first);
            }
            table[id] = CachedDescriptor.fromInspection(m, source: servedBy);
            learned = true;
            // Names show as they arrive, not after the whole pass.
            metadataChanges.value++;
          } catch (e) {
            if (!current()) break;
            final text = e.toString().toLowerCase();
            if (e is MetadataBusyException || text.contains('already running')) {
              break;
            }
            if (text.contains('cancelled') || text.contains('canceled')) break;
            // As in the wallet's pass: only a definite answer is remembered.
            if (!_looksDurableNegative(e)) {
              if (++consecutiveRetryable >= maxConsecutiveRetryable) break;
              continue;
            }
            consecutiveRetryable = 0;
            misses.add(id);
            if (_looksUnsupported(e)) break;
            if (_looksNotFound(e)) {
              if (++consecutiveNotFound >= notFoundRunBeforeUnsupported) break;
            } else {
              consecutiveNotFound = 0;
            }
          } finally {
            _metadataBusy = false;
          }
        }
      } finally {
        _watchedCursors[key] = cursor + (attempted == 0 ? 1 : attempted);
        final table = _watchedTables[key] ?? const <String, CachedDescriptor>{};
        left = wanted
            .where((id) => (table[id]?.incomplete ?? true) && !misses.contains(id))
            .length;
      }
    } finally {
      _watchedPasses.remove(key);
      final table = _watchedTables[key];
      if (learned && table != null && current()) {
        await TokenDescriptorStore.save(_watchedTableId(key), Map.of(table));
      }
      if (left > 0 && current()) {
        _followWatchedPass(key, targets, nodeUrl, settled: unsettled - left);
      } else {
        _watchedIdlePasses.remove(key);
      }
    }
  }

  /// Another pass for a watched wallet whose last one left tokens unnamed,
  /// so they do not wait for its next balance read: the per-pass cap, a
  /// node that stopped answering, or the single metadata job busy elsewhere
  /// must not leave a holding unnamed for good. Soon after a pass that
  /// settled something; after one that settled nothing, later each time,
  /// and not after [maxWatchedIdlePasses] of those in a row. A token stays
  /// unnamed only when its node says it does not exist, or keeps failing.
  void _followWatchedPass(
    String key,
    List<String> addresses,
    String? nodeUrl, {
    required int settled,
  }) {
    _watchedFollowUps.remove(key)?.cancel();
    final idle = settled > 0 ? 0 : (_watchedIdlePasses[key] ?? 0) + 1;
    if (idle > maxWatchedIdlePasses) {
      _watchedIdlePasses.remove(key);
      return;
    }
    _watchedIdlePasses[key] = idle;
    final delay = idle == 0 ? watchedFollowUpDelay : watchedIdleDelay * idle;
    _watchedFollowUps[key] = Timer(delay, () {
      _watchedFollowUps.remove(key);
      if (!_inForeground) return;
      unawaited(resolveWatchedHoldings(key, addresses, nodeUrl: nodeUrl));
    });
  }

  void clearSessionMetadata() {
    if (_metadataBusy) {
      try { RustLib.instance.api.crateApiCancelTokenMetadata(); } catch (_) {}
    }
    _descriptorEpoch++;
    // An in-flight table load belongs to the epoch just discarded and will
    // refuse to apply itself. Drop the memoization with it, or the next
    // reader awaits that same aborted future and silently gets no table —
    // leaving persisted names unavailable until the wallet is reactivated,
    // and letting a later pass overwrite the stored table with only the
    // subset it happened to fetch.
    _tableLoadedFor = null;
    _tableLoad = null;
    _descriptors.clear();
    metadataChanges.value++;
  }

  /// Non-null while a wipe is in progress. Table loads wait behind it:
  /// clearing memory and bumping the epoch happens first, but the stored
  /// tables are deleted several awaits later, and a load starting in that
  /// window would capture the NEW epoch, read the not-yet-deleted table and
  /// put it all back — passing every epoch check on the way.
  Future<void>? _wipe;

  Future<void> clearCollectibleData() async {
    final done = Completer<void>();
    _wipe = done.future;
    try {
      clearSessionMetadata();
      // Balance snapshots and published holdings remain intact. This clears
      // lookup caches, not the wallet's last known view of its holdings.
      _tokenMeta.clear();
      _legacyTokenMeta.clear();
      _descriptorCache.clear();
      _metadataMisses.clear();
      _watchedWipes++;
      _watchedTables.clear();
      _watchedMisses.clear();
      _watchedCursors.clear();
      for (final timer in _watchedFollowUps.values) {
        timer.cancel();
      }
      _watchedFollowUps.clear();
      _watchedIdlePasses.clear();
      // A queued write would otherwise recreate what this just cleared.
      _pendingFlush.clear();
      _tokenMetaDirty = false;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_tokenMetaKey);
      await TokenDescriptorStore.clearAll();
      await publicTokenCatalog.clear();
    } finally {
      _wipe = null;
      done.complete();
      // Anything that queued behind the wipe reloads from storage that is
      // now empty, so there is nothing left to restore.
      _tableLoadedFor = null;
      _tableLoad = null;
    }
  }

  /// One explicit per-item request. New descriptors are memory-only, scoped
  /// to this wallet and provider; neither sync nor legacy prefetch calls here.
  Future<TokenBalance> loadMetadata(
    TokenBalance holding, {
    required String provider,
    bool providerIsNode = false,
  }) async {
    // Captured before any wait. Cancelling, closing the sheet, backgrounding
    // or switching wallet while this waits behind a catalog lookup bumps the
    // epoch, and must stop the request before anything is sent.
    final epoch = _descriptorEpoch;
    final key = _descriptorKey(holding.id);
    // A public-catalog lookup gives way to a person's request: wait out the
    // one it has in flight and take the job before the catalog can start
    // another. Everything below is then checked as of now. Handing the job
    // back here leaves no gap: from this line to `_metadataBusy = true` the
    // code runs without suspending, so nothing else can take it.
    final fromCatalog = _catalogJob != null && await _takeJobFromCatalog();
    if (fromCatalog) _metadataBusy = false;
    if (epoch != _descriptorEpoch || key != _descriptorKey(holding.id)) {
      throw StateError('Metadata request cancelled');
    }
    if (!isUnlocked ||
        privacyService.hideBalances ||
        networkController.activeUrl == null) {
      throw StateError('Metadata unavailable while locked, hidden or offline');
    }
    if (provider != (providerIsNode ? networkController.activeUrl : networkController.explorer))
      throw StateError('Metadata provider changed');
    if (_metadataBusy) throw MetadataBusyException();
    _observeLifecycle();
    _metadataBusy = true;
    try {
      final raw = await RustLib.instance.api.crateApiInspectTokenMetadata(
        tokenId: holding.id,
        providerUrl: provider,
        providerIsNode: providerIsNode,
      );
      if (epoch != _descriptorEpoch ||
          key != _descriptorKey(holding.id) ||
          !isUnlocked ||
          privacyService.hideBalances) {
        throw StateError('Metadata request cancelled');
      }
      if (utf8.encode(raw).length > 16384)
        throw StateError('Metadata exceeds wallet limits');
      final m = jsonDecode(raw) as Map<String, dynamic>;
      if (m['id'] != holding.id) throw StateError('Metadata conflict');
      final declared = declaredDecimals(m);
      final previous = _descriptors[key];
      final conflict = previous != null && (
        (previous.issuanceBoxId != null && m['boxId'] != null && previous.issuanceBoxId != m['boxId']) ||
        (previous.emissionAmount != null && m['emissionAmount'] != null && previous.emissionAmount != m['emissionAmount']) ||
        (previous.decimalsEvidence.readFromToken && declared.evidence.readFromToken && previous.decimals != declared.decimals));
      final result = TokenBalance(
        id: holding.id,
        amount: holding.amount,
        stealthAmount: holding.stealthAmount,
        name: m['name'] as String?,
        description: m['description'] as String?,
        decimals: declared.decimals,
        emissionAmount: (m['emissionAmount'] as num?)?.toInt(),
        iconUrl: m['iconUrl'] as String?,
        source: provider,
        issuanceBoxId: m['boxId'] as String?,
        issuanceHash: m['issuanceHash'] as String?,
        rawRegisters: m['rawRegisters'] as String?,
        supplyEvidence: SupplyEvidence.values.byName(
          m['supplyEvidence'] as String,
        ),
        decimalsEvidence: declared.evidence,
        declaredAssetKind: DeclaredAssetKind.values.byName(
          m['declaredAssetKind'] as String,
        ),
        metadataState: conflict ? MetadataState.conflict : declared.metadataState,
        mediaState: MediaState.values.byName(m['mediaState'] as String),
      );
      // 1,000 × 16 KiB bounds this memory-only cache to 16 MiB serialized.
      _descriptors.remove(key);
      while (_descriptors.length >= 1000) {
        _descriptors.remove(_descriptors.keys.first);
      }
      _descriptors[key] = result;
      metadataChanges.value++;
      return result;
    } finally {
      _metadataBusy = false;
    }
  }

  /// Set while a public-catalog lookup holds the metadata job. Wallet passes
  /// and explicit requests wait for it rather than give up: it is a single
  /// bounded request, and the catalog starts no other while they wait.
  Future<void>? _catalogJob;
  int _catalogWaiters = 0;

  /// One node lookup for the public pool-token catalog, in the same single
  /// metadata job as everything else, so its requests never overlap the
  /// wallet's. Null when the job is wanted elsewhere — this never waits for
  /// the wallet's work or competes with it — or while locked or in the
  /// background, when nothing should be asking the network for this.
  Future<String?> inspectForCatalog(String tokenId, String provider) async {
    if (_metadataBusy ||
        _catalogWaiters > 0 ||
        !isUnlocked ||
        !_inForeground) {
      return null;
    }
    // Backgrounding cancels a request already in flight, as it does an
    // explicit one, rather than letting it finish out of sight.
    _observeLifecycle();
    _metadataBusy = true;
    final done = Completer<void>();
    _catalogJob = done.future;
    try {
      return await RustLib.instance.api.crateApiInspectTokenMetadata(
        tokenId: tokenId,
        providerUrl: provider,
        providerIsNode: true,
      );
    } finally {
      _metadataBusy = false;
      _catalogJob = null;
      done.complete();
    }
  }

  /// Lifecycle changes clear session metadata and cancel the metadata job in
  /// flight ([didChangeAppLifecycleState]). Registered by the first request
  /// of either kind.
  void _observeLifecycle() {
    if (_observingMetadata) return;
    try {
      WidgetsBinding.instance.addObserver(this);
      _observingMetadata = true;
    } catch (_) {
      // No binding (a plain unit test): nothing to observe.
    }
  }

  static bool get _inForeground {
    try {
      final state = WidgetsBinding.instance.lifecycleState;
      return state == null || state == AppLifecycleState.resumed;
    } catch (_) {
      // No binding (a plain unit test): nothing is backgrounded.
      return true;
    }
  }

  /// Waits out the catalog lookup that holds the metadata job and takes the
  /// job in the same step, while still counted as waiting, so the catalog
  /// cannot slip another request in between. False when the job is not the
  /// catalog's, or another request took it first: the caller then yields as
  /// it always has. On true the caller holds the job and must release it.
  Future<bool> _takeJobFromCatalog() async {
    final job = _catalogJob;
    if (job == null) return false;
    _catalogWaiters++;
    try {
      await job;
      if (_metadataBusy) return false;
      _metadataBusy = true;
      return true;
    } finally {
      _catalogWaiters--;
    }
  }

  Future<void> init() async {
    if (_initialized) return;
    await Future.wait([
      RustLib.init(),
      loadTokenMeta(),
      publicTokenCatalog.ensureLoaded(),
    ]);
    // Belt and braces with the frb(init) attribute: the app fee config must
    // be installed before any transaction is built.
    await RustLib.instance.api.crateApiInitApp();
    // Likewise the unconfirmed-spending setting, which every spend's input
    // gathering in Rust follows.
    await spendPolicy.apply();
    _initialized = true;
    await _migrateLegacyIfNeeded();
  }

  int get cachedTokenMetaCount => _tokenMeta.length;

  /// Caches [meta] (name, decimals, emission, icon) for its token id. Call
  /// [persistTokenMeta] afterwards to keep it across launches.
  void rememberTokenMeta(TokenBalance meta) {
    if (utf8
            .encode(jsonEncode({'name': meta.name, 'iconUrl': meta.iconUrl}))
            .length >
        16384)
      return;
    // No independent eviction: `_descriptorCache` bounds growth, and the
    // two must agree. Dropping an entry here while the cache still holds it
    // would show an unresolved id that is never requested again.
    _tokenMeta[meta.id] = meta;
    _tokenMetaDirty = true;
  }

  /// Legacy cache records have no provenance and migrate as partial only.
  /// New descriptors never enter this app-wide, unencrypted store.
  Future<void> loadTokenMeta() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_tokenMetaKey);
      if (raw == null ||
          raw.isEmpty ||
          utf8.encode(raw).length > 16 * 1024 * 1024)
        return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in map.entries.take(1000)) {
        final v = entry.value;
        if (v is! Map) continue;
        _legacyTokenMeta[entry.key] = TokenBalance(
          id: entry.key,
          amount: 0,
          name: v['name'] as String?,
          decimals: (v['decimals'] as num?)?.toInt() ?? 0,
          emissionAmount: (v['emissionAmount'] as num?)?.toInt(),
          iconUrl: v['iconUrl'] as String?,
          decimalsEvidence: DecimalsEvidence.listed,
          metadataState: MetadataState.partial,
        );
        _tokenMeta[entry.key] = _legacyTokenMeta[entry.key]!;
      }
    } catch (_) {
      // A corrupt cache only costs a refetch.
    }
  }

  /// Writes descriptors to the active wallet's table. The legacy app-wide
  /// store is read at startup but never written again: it recorded no
  /// evidence, and one table shared by every wallet associates them.
  Future<void> persistTokenMeta() async {
    if (!_tokenMetaDirty) return;
    final walletId = _currentWalletId;
    if (walletId == null || walletId.isEmpty) return;
    _tokenMetaDirty = false;
    // Snapshot synchronously. `save` suspends on SharedPreferences, and a
    // wallet switch in that window clears or repopulates `_descriptorCache`
    // in place — passing it by reference could write the new wallet's
    // descriptors under the old wallet's key, or erase the old table.
    await TokenDescriptorStore.save(
      walletId,
      Map<String, CachedDescriptor>.from(_descriptorCache),
    );
  }

  /// Loads the active wallet's descriptors over whatever the legacy store
  /// supplied. Called when a wallet becomes active, not once at startup.
  /// [expectedEpoch] is the descriptor epoch at the moment the load was
  /// *requested*. Capturing it here instead would be too late: the load is
  /// chained behind a flush, so a wipe can land before this body starts and
  /// the load would then adopt the new epoch and undo it.
  Future<void> loadWalletTokenMeta(String walletId, {int? expectedEpoch}) async {
    final epoch = expectedEpoch ?? _descriptorEpoch;
    if (epoch != _descriptorEpoch) return;
    final loaded = await TokenDescriptorStore.load(walletId);
    if (_currentWalletId != walletId || epoch != _descriptorEpoch) return;
    // This runs unawaited after a wallet switch, so a sync may already have
    // resolved descriptors that are newer than the table on disk. Disk fills
    // gaps; it never overwrites what this session just learned.
    _descriptorOwner = walletId;
    for (final e in loaded.entries) {
      _descriptorCache.putIfAbsent(e.key, () => e.value);
    }
    // Deliberately not clearing _metadataMisses: wiping it here would race a
    // sync in flight and let it re-ask about ids that just failed.
    // _setHandle clears it synchronously, where the wallet actually changes.
    _rebuildTokenMetaView();
    // Rows already on screen were built from the view before this landed.
    metadataChanges.value++;
  }

  String? _tableLoadedFor;
  Future<void>? _tableLoad;

  /// Loads the active wallet's descriptor table once, on the first path that
  /// needs it. Memoized per wallet so concurrent syncs share one read.
  /// Tables captured from a wallet that was switched away from before its
  /// descriptors were written. Drained on the next awaited path rather than
  /// fired and forgotten, which would leave a platform-channel future owned
  /// by nobody.
  final List<(String, Map<String, CachedDescriptor>)> _pendingFlush = [];

  /// Snapshots [walletId]'s dirty descriptors for writing, synchronously, so
  /// whatever happens next cannot alter what gets saved or where.
  void _captureUnwrittenDescriptors(String? walletId) {
    if (!_tokenMetaDirty || walletId == null || walletId.isEmpty) return;
    if (_descriptorCache.isEmpty) return;
    _pendingFlush.add((
      walletId,
      Map<String, CachedDescriptor>.from(_descriptorCache),
    ));
    _tokenMetaDirty = false;
  }

  Future<void> flushPendingDescriptors() async {
    while (_pendingFlush.isNotEmpty) {
      final (walletId, table) = _pendingFlush.removeAt(0);
      try {
        await TokenDescriptorStore.save(walletId, table);
      } catch (_) {
        // A table that cannot be written is not worth retrying forever.
      }
    }
  }

  Future<void> ensureWalletTable() {
    final walletId = _currentWalletId;
    if (walletId == null || walletId.isEmpty) return Future<void>.value();
    if (_tableLoadedFor == walletId && _tableLoad != null) return _tableLoad!;
    _tableLoadedFor = walletId;
    final epoch = _descriptorEpoch;
    final barrier = _wipe ?? Future<void>.value();
    return _tableLoad = barrier
        .then((_) => flushPendingDescriptors())
        .then((_) => loadWalletTokenMeta(walletId, expectedEpoch: epoch))
        .catchError((_) {});
  }

  /// The legacy app-wide table as a base layer, with this wallet's own
  /// descriptors over the top.
  void _rebuildTokenMetaView() {
    _tokenMeta
      ..clear()
      ..addAll(_legacyTokenMeta);
    for (final e in _descriptorCache.entries) {
      _tokenMeta[e.key] = _asBalance(e.value);
    }
  }

  static TokenBalance _asBalance(CachedDescriptor d) => TokenBalance(
    id: d.id,
    amount: 0,
    name: d.name,
    decimals: d.decimals,
    emissionAmount: d.emissionAmount,
    iconUrl: d.iconUrl,
    supplyEvidence: d.supplyEvidence,
    decimalsEvidence: d.decimalsEvidence,
    declaredAssetKind: d.declaredAssetKind,
    metadataState: d.metadataState,
    mediaState: d.mediaState,
    source: d.source,
  );


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
    bool legacyDerivation = false,
  }) async {
    final walletId = const Uuid().v4();
    final chosen = name?.trim();
    final walletName = chosen != null && chosen.isNotEmpty ? chosen : await generateWalletName();
    final session = await createWallet(
      phrase,
      passphrase: passphrase,
      walletId: walletId,
      legacyDerivation: legacyDerivation,
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
        legacyDerivation: legacyDerivation,
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
    bool legacyDerivation = false,
  }) async {
    final raw = await RustLib.instance.api.crateApiWalletCreate(
      mnemonicPhrase: mnemonic,
      passphrase: passphrase,
      usePre1627Derivation: legacyDerivation,
    );
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final id = walletId ?? const Uuid().v4();
    final session = WalletSession(
      walletId: id,
      handleId: BigInt.parse(map['handle_id'].toString()),
      encryptedSeedJson: map['encrypted_seed_json'] as String,
      wrapKey: map['wrap_key'] as String,
    );
    _setHandle(id, session.handleId);
    // Write the outgoing wallet's table now rather than waiting for the
    // incoming wallet's first sync, which may never come.
    await _loadActivatedTable();
    return session;
  }

  /// Live BIP-39 check of a phrase being typed (sync, in Rust).
  PhraseCheck checkMnemonic(String raw) {
    if (raw.trim().isEmpty) return PhraseCheck.empty;
    final json = RustLib.instance.api.crateApiCheckMnemonic(mnemonicPhrase: raw);
    return PhraseCheck.fromJson(jsonDecode(json) as Map<String, dynamic>);
  }

  /// Which key derivation a phrase being restored should use. Asks the
  /// node only when the two derivations differ for this phrase, and only
  /// when [queryNode].
  Future<RestoreDerivationProbe> probeRestoreDerivation({
    required String phrase,
    required String passphrase,
    String? nodeUrl,
    bool queryNode = true,
  }) async {
    final json = await RustLib.instance.api.crateApiProbeRestoreDerivation(
      mnemonicPhrase: phrase,
      passphrase: passphrase,
      nodeUrl: nodeUrl,
      queryNode: queryNode,
    );
    return RestoreDerivationProbe.fromJson(jsonDecode(json) as Map<String, dynamic>);
  }

  Future<String> wrapKeyWithPin(String wrapKey, String pin) {
    return RustLib.instance.api.crateApiWrapKeyWithPin(
      wrapKeyHex: wrapKey,
      pin: pin,
    );
  }

  Future<String> unwrapKeyWithPin(String pinWrapJson, String pin) {
    return RustLib.instance.api.crateApiUnwrapKeyWithPin(
      pinWrapJson: pinWrapJson,
      pin: pin,
    );
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
    await _loadActivatedTable();
  }

  /// Lock the currently active wallet. If [walletId] is provided, lock only
  /// that specific wallet; otherwise lock the active one.
  Future<void> lock([String? walletId]) => _lock(walletId, switching: false);

  Future<void> lockForSwitch() => _lock(null, switching: true);

  Future<void> _lock(String? walletId, {required bool switching}) async {
    clearSessionMetadata();
    final wid = walletId ?? _currentWalletId;
    // Locking clears the active wallet id, so a metadata pass still in
    // flight can no longer prove ownership and its finally will skip the
    // write. Capture here as well as in `_setHandle`: switching goes
    // through lock first, and `_setHandle` would then see no outgoing id.
    // Only when the wallet being locked is the one whose descriptors are in
    // memory. Locking some other wallet must not file the active wallet's
    // table under its id.
    if (wid == _currentWalletId) _captureUnwrittenDescriptors(wid);
    final active = wid == _currentWalletId;
    final id = _handles[wid];
    if (active) {
      if (switching) {
        walletSyncController.deactivate();
      } else {
        walletSyncController.reset();
      }
    } else if (wid != null) {
      walletSyncController.forgetWallet(wid);
    }
    if (id == null) {
      if (active) {
        unlocked.value = false;
        if (wid == null) currentWalletId.value = null;
      }
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
  /// The order the user put their wallets in, as wallet ids; wallets not
  /// listed follow in storage order.
  static const _orderKey = 'argus_wallet_order_v1';

  Future<List<String>> walletOrder() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_orderKey) ?? const [];
  }

  Future<void> setWalletOrder(List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_orderKey, ids);
  }

  /// Wallets as the user ordered them, in every list that shows them.
  Future<List<WalletInfo>> listWallets() async {
    final ids = await SecureStorageService.listWalletIds();
    final all = await _loadAllWalletMeta();
    final List<WalletInfo> infos = [];
    for (final id in ids) {
      final meta = all[id];
      final info = meta != null
          ? WalletInfo.fromJson(meta)
          : WalletInfo(walletId: id, name: 'Wallet', createdAt: DateTime.now());
      infos.add(info.copyWith(isUnlocked: _handles.containsKey(id)));
    }
    return orderWallets(infos, await walletOrder());
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
    bool? legacyDerivation,
  }) async {
    await _upsertWalletMeta(
      walletId,
      name: name,
      createdAt: createdAt,
      address0: address0,
      pinnedAddressIndex: pinnedAddressIndex,
      legacyDerivation: legacyDerivation,
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
  Future<void> setPinnedAddressIndex(
    String walletId,
    int? index, {
    String? address,
  }) async {
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

  /// Token metadata already known, without a node call. The one lookup every
  /// screen and every published holding goes through, best layer first:
  ///
  ///  1. this wallet's own descriptors, resolved during its sync;
  ///  2. the public catalog of pool tokens ([publicTokenMeta]);
  ///  3. the curated registry built into the app;
  ///  4. the legacy app-wide table from older builds, which has no
  ///     provenance and so ranks last.
  ///
  /// Explicitly loaded session descriptors are not here: holdings are built
  /// from this and persisted, and those are memory-only. Screens that name a
  /// token by id use [displayTokenMeta], which adds them for display.
  TokenBalance? cachedTokenMeta(String id) {
    final own = _tokenMeta[id];
    // The legacy rows share the same view as a base layer, by reference.
    if (own != null && !identical(own, _legacyTokenMeta[id])) return own;
    return publicTokenMeta(id) ?? own;
  }

  /// What the wallet-independent layers say about [id]: the pool-token
  /// catalog, then the curated registry. For a context that is not this
  /// wallet's own, and for anything that may be stored app-wide.
  TokenBalance? publicTokenMeta(String id) {
    final d = publicTokenCatalog.lookup(id);
    if (d != null) return _asBalance(d);
    final curated = knownToken(id);
    if (curated == null) return null;
    // The ticker is the on-chain name the registry was checked against.
    // The scale is the app's list's, not an issuance read.
    return TokenBalance(
      id: id,
      amount: 0,
      name: curated.ticker,
      decimals: curated.decimals,
      decimalsEvidence: DecimalsEvidence.listed,
      metadataState: MetadataState.partial,
      source: curatedTokenSource,
    );
  }

  /// Shown as a descriptor's source when the name came from the registry
  /// built into the app rather than from a node.
  static const curatedTokenSource = 'Argus curated token list';

  /// Ids this session already asked the node about and did not get an answer
  /// for. Without it a wallet of unresolvable tokens re-asks on every sync.
  final Set<String> _metadataMisses = {};

  /// Set when the node cannot serve issuance lookups at all — no extraIndex,
  /// or an endpoint `token_descriptor::load_from` refuses (it is HTTPS-only,
  /// so a user-configured `http://ip:port` node can never answer). One such
  /// failure stops the whole wallet from retrying every sync.
  bool _metadataUnsupported = false;

  /// True when the active node has proved unable to resolve issuance data,
  /// so the UI can say so instead of leaving ids unexplained.
  bool get metadataLookupUnsupported => _metadataUnsupported;

  /// Cleared when the provider changes: a new node deserves one chance.
  String? _metadataCapabilityFor;

  /// Resolves any of [ids] not already cached, from [servedBy] — the node
  /// that actually answered the balance request these ids came from.
  ///
  /// Every piece of context is an argument rather than an ambient read.
  /// `_currentWalletId` and `networkController.activeUrl` can both change
  /// while this runs, and reading them here would let a response for wallet
  /// A be written under wallet B, or send A's ids to a node that never saw
  /// them. [stillCurrent] is the caller's own generation check.
  ///
  /// Only ordinary public holdings are passed in. Stealth-only ids are never
  /// given to this method: they are not derivable from the wallet's public
  /// addresses, so [servedBy] has never seen them.
  ///
  /// This is the reversal of an earlier posture that held "receiving or
  /// displaying an ID is not consent to disclose it to a metadata provider".
  /// The balance request already crossed that line: [servedBy] received the
  /// addresses and answered with the boxes these ids come from. Running it
  /// after sync publishes — rather than when a token is tapped — also keeps
  /// the provider from learning which token the user looked at.
  Future<Map<String, TokenBalance>> prefetchTokenMeta(
    Iterable<String> ids, {
    required String walletId,
    required String servedBy,
    required bool Function() stillCurrent,
  }) async {
    if (walletId.isEmpty || servedBy.isEmpty) return const {};
    if (!isUnlocked || !stillCurrent()) return const {};
    // Captured before the first await. Taking it afterwards would let a pass
    // that was suspended across a wipe adopt the new epoch and write its
    // pre-wipe results back.
    final epoch = _descriptorEpoch;
    bool owns() => _owns(walletId, stillCurrent) && epoch == _descriptorEpoch;
    await ensureWalletTable();
    if (!owns()) return const {};

    // Capability and miss state belong to a provider. Only the pass that
    // introduced this provider may reset them, or an overlapping pass on
    // another node would clear the verdict this one is about to record.
    final ownsProvider = _metadataCapabilityFor == servedBy;
    if (!ownsProvider) {
      _metadataCapabilityFor = servedBy;
      _metadataUnsupported = false;
      _metadataMisses.clear();
    }

    final requested = [
      for (final id in ids)
        if (id.length == 64) id,
    ];
    // Already-known descriptors go back to the caller too. After a restart
    // the display cache is empty when holdings publish, so returning only
    // freshly fetched entries would leave a wallet full of cached names
    // showing raw ids until some later hydration.
    final resolvedNow = <String, TokenBalance>{
      for (final id in requested)
        if (cachedTokenMeta(id) != null) id: cachedTokenMeta(id)!,
    };

    // Declared outside the try so the finally can advance the cursor.
    var attempted = 0;
    // Whether this pass taught the lookup anything, for its listeners.
    var learned = false;
    try {
      if (_metadataUnsupported) return resolvedNow;
      final wanted = [
        for (final id in requested)
          // The descriptor's own flag is the only authority. A parallel set
          // in memory survived wallet switches and forced refetches of
          // another wallet's complete descriptors, which a second box
          // failure could then downgrade.
          if ((_descriptorCache[id]?.incomplete ?? true) &&
              !_legacyTokenMeta.containsKey(id) &&
              !_metadataMisses.contains(id))
            id,
      ];

      // Rotate the starting point. A pass always restarting at the head
      // would let a few permanently failing ids monopolise the budget and
      // starve everything behind them.
      final cursorKey = '$walletId|$servedBy';
      final cursor = _passCursors[cursorKey] ?? 0;
      final start = wanted.isEmpty ? 0 : cursor % wanted.length;
      final ordered = [...wanted.skip(start), ...wanted.take(start)];

      // Pass-local: an exhausted counter inherited from a previous pass
      // would end a healthy one on its first hiccup.
      var consecutiveRetryable = 0;
      var consecutiveNotFound = 0;
      for (final id in ordered) {
        if (!owns() || _metadataUnsupported) return resolvedNow;
        if (attempted >= maxTokenMetaPerSync) return resolvedNow;
        if (!_metadataBusy) {
          _metadataBusy = true;
        } else {
          // An explicit request owns the job. Yield rather than compete. A
          // catalog lookup is one bounded request: wait it out and take the
          // job before the catalog can start another.
          if (_catalogJob == null || !await _takeJobFromCatalog()) {
            return resolvedNow;
          }
          if (!owns() || _metadataUnsupported) {
            _metadataBusy = false;
            return resolvedNow;
          }
        }
        attempted++;
        try {
          final raw = await RustLib.instance.api.crateApiInspectTokenMetadata(
            tokenId: id,
            providerUrl: servedBy,
            providerIsNode: true,
          );
          // Discard rather than return: results from a session the user has
          // discarded must not reach the screen.
          if (!owns()) return const {};
          final m = jsonDecode(raw) as Map<String, dynamic>;
          if (m['id'] != id) continue;
          consecutiveNotFound = 0;
          _rememberDescriptor(id, m, servedBy);
          learned = true;
          // The index answered but the issuance box did not, so the
          // registers are missing. Keep what came back — a name beats an id
          // — but leave the token eligible so a later pass can complete it
          // rather than caching a register-less descriptor forever.
          final meta = cachedTokenMeta(id);
          if (meta != null) resolvedNow[id] = meta;
        } catch (e) {
          if (!owns()) return const {};
          if (e is MetadataBusyException) return resolvedNow;
          final text = e.toString().toLowerCase();
          if (text.contains('already running')) return resolvedNow;
          if (text.contains('cancelled') || text.contains('canceled')) {
            return const {};
          }
          // Only the pass that owns this provider may record anything about
          // it — misses included. A late failure from a node that no longer
          // holds the slot would otherwise suppress this token for whichever
          // node does.
          if (_metadataCapabilityFor != servedBy) return resolvedNow;
          // A provider that failed to answer has said nothing — not about
          // this token and not about its own capabilities. Short-circuit
          // before any classification: these error strings carry the request
          // URL, so a token id containing "404" would otherwise be counted
          // as a not-found, and one containing "extraindex" would write the
          // node off outright.
          if (!_looksDurableNegative(e)) {
            if (++consecutiveRetryable >= maxConsecutiveRetryable) {
              // The node is not answering at all; stop burning the budget.
              return resolvedNow;
            }
            continue;
          }
          consecutiveRetryable = 0;
          // A miss recorded before the request would outlive a pass that
          // never finished, suppressing a token that might have resolved.
          _metadataMisses.add(id);
          if (_looksUnsupported(e)) {
            // Unambiguous: the endpoint says it cannot do this at all.
            _metadataUnsupported = true;
            return resolvedNow;
          }
          if (_looksNotFound(e)) {
            // A run of these ends THIS pass but records no verdict. A node
            // without the index answers 404, but so does a capable node
            // asked about tokens it has never seen — and eight unknown
            // tokens must not disable a provider that would have resolved
            // the ninth.
            if (++consecutiveNotFound >= notFoundRunBeforeUnsupported) {
              return resolvedNow;
            }
          } else {
            consecutiveNotFound = 0;
          }
        } finally {
          _metadataBusy = false;
        }
      }
      return resolvedNow;
    } finally {
      final key = '$walletId|$servedBy';
      _passCursors[key] = (_passCursors[key] ?? 0) + (attempted == 0 ? 1 : attempted);
      // Covers every exit, including the ones that resolve nothing: a pass
      // invalidated after some successes would otherwise leave them dirty
      // and lose them at the next wallet switch.
      if (_tokenMetaDirty && _currentWalletId == walletId) {
        await persistTokenMeta();
      }
      // Holdings republish through the sync; everything else that reads
      // the lookup by id (activity rows, prices) hears it here, once a pass.
      if (learned && owns()) metadataChanges.value++;
      // That await is itself a window: a wipe landing in it would leave the
      // already-selected map free to reach the caller and repopulate the
      // display that was just cleared. Emptying it here is visible to the
      // caller because the map is returned by reference.
      if (!owns()) resolvedNow.clear();
    }
  }

  /// Whether this pass still belongs to the wallet that started it.
  bool _owns(String walletId, bool Function() stillCurrent) =>
      isUnlocked && _currentWalletId == walletId && stillCurrent();

  /// Ceiling for one refresh. What is left resolves on later refreshes,
  /// since misses are only remembered for ids actually attempted.
  static const maxTokenMetaPerSync = 40;

  /// An unambiguous "this endpoint cannot serve issuance lookups at all".
  /// Shared with the pool-token catalog; see [DescriptorLookupFailure].
  static bool _looksUnsupported(Object error) =>
      DescriptorLookupFailure.unsupported(error);

  /// How long a run of not-founds ends a pass. Deliberately not a verdict
  /// about the provider: unknown tokens and a missing index look alike.
  static const notFoundRunBeforeUnsupported = 8;

  /// Consecutive failures-to-answer before the pass gives up. Bounded so a
  /// node that is simply down cannot consume the whole per-pass budget.
  static const maxConsecutiveRetryable = 3;

  /// Where the next pass starts in the candidate list, so a stubborn prefix
  /// cannot starve the ids behind it. Keyed by wallet and provider: a single
  /// counter let one wallet's passes advance another's, so alternating
  /// wallets could land the same id at the head every time and never ask it.
  final Map<String, int> _passCursors = {};

  /// Marker the Rust side puts on an error the provider failed to answer,
  /// as opposed to one it answered negatively.
  static const retryableMarker = DescriptorLookupFailure.retryableMarker;

  /// Whether the provider gave a definite "no such token", as opposed to
  /// failing to answer. Only the former is worth remembering. Shared with
  /// the pool-token catalog; see [DescriptorLookupFailure].
  static bool _looksDurableNegative(Object error) =>
      DescriptorLookupFailure.durableNegative(error);

  static bool _looksNotFound(Object error) =>
      DescriptorLookupFailure.notFound(error);

  void _rememberDescriptor(String id, Map<String, dynamic> m, String source) {
    final descriptor = CachedDescriptor.fromInspection(m, source: source);
    // One bound, shared with the display view and the persisted table, so
    // an eviction here cannot leave a resolved token looking unresolved and
    // be requested again on every refresh forever.
    _descriptorCache.remove(id);
    while (_descriptorCache.length >= TokenDescriptorStore.maxEntries) {
      final oldest = _descriptorCache.keys.first;
      _descriptorCache.remove(oldest);
      _tokenMeta.remove(oldest);
    }
    _descriptorCache[id] = descriptor;
    // `TokenBalance`'s constructor runs issuerText() over the name, so a
    // hostile label is sanitised on the way in as well as on the way out.
    rememberTokenMeta(_asBalance(descriptor));
  }

  final Map<String, CachedDescriptor> _descriptorCache = {};

  /// Which wallet the in-memory descriptors belong to. Tracked separately
  /// from `_currentWalletId`, which is null whenever the wallet is locked —
  /// deleting an already-locked wallet would otherwise look like it
  /// concerned someone else and leave its descriptors behind.
  String? _descriptorOwner;

  /// Delete a wallet and all its secure storage.
  Future<void> deleteWallet(String walletId) async {
    walletSyncController.forgetWallet(walletId);
    await WalletDatabaseService.clearWallet(walletId).catchError((_) {});
    if (_handles.containsKey(walletId)) {
      await lock(walletId);
    }
    // Invalidate before clearing, so a load or save still in flight for this
    // wallet cannot recreate the table after it is gone.
    if (_tableLoadedFor == walletId) {
      _tableLoadedFor = null;
      _tableLoad = null;
    }
    if (_descriptorOwner == walletId) {
      // Its descriptors must not outlive it in memory. Guarded on nothing
      // having been activated since, so a newly opened wallet is not emptied
      // by a deletion that preceded it.
      _descriptorCache.clear();
      _tokenMeta
        ..clear()
        ..addAll(_legacyTokenMeta);
      _metadataMisses.clear();
      _tokenMetaDirty = false;
      _descriptorOwner = null;
    }
    // Drop queued writes for this wallet first, or a flush after the delete
    // would write its table straight back.
    _pendingFlush.removeWhere((entry) => entry.$1 == walletId);
    await TokenDescriptorStore.clear(walletId).catchError((_) {});
    await stealthChangeBook.forget(walletId);
    await SecureStorageService.deleteWallet(walletId);
    await _removeWalletMeta(walletId);
  }

  /// Highest address index the wallet core can derive and scan (inclusive).
  /// Mirrors MAX_OWN_SCAN in rust/crates/wallet-core/src/wallet.rs — indices
  /// beyond this make deriveAddress throw.
  static const maxAddressIndex = 512;

  Future<String> deriveAddress(int index) {
    _requireUnlocked();
    return RustLib.instance.api.crateApiDeriveAddress(
      handleId: _handleId!,
      index: index,
    );
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
    String? babelTokenId,
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
      babelTokenId: babelTokenId,
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
    String? babelTokenId,
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
      babelTokenId: babelTokenId,
    );
    return SendPreview.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// A fresh one-time address for our own stealth change, with its script.
  Future<Map<String, dynamic>> stealthSelfChangeTarget(
    String stealthAddress,
  ) async {
    final raw = await RustLib.instance.api.crateApiStealthSelfChangeTarget(
      stealthAddress: stealthAddress,
    );
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
  Future<Map<String, dynamic>> sendErgDetailed({
    required int preparationId,
  }) async {
    _requireUnlocked();
    final raw = await RustLib.instance.api.crateApiSendErg(
      handleId: _handleId!,
      preparationId: BigInt.from(preparationId),
    );
    final map = jsonDecode(raw) as Map<String, dynamic>;
    _recordBroadcast(
      map['tx_id']?.toString() ?? '',
      (map['wallet_delta_nano_erg'] as num?)?.toInt(),
    );
    return map;
  }

  final Map<String, String> _broadcastWarnings = {};
  String? broadcastWarning(String txId) => _broadcastWarnings[txId];

  void _recordBroadcast(String txId, int? delta) {
    try {
      onBroadcast?.call(txId, delta);
    } catch (e) {
      _broadcastWarnings[txId] =
          'Transaction submitted, but Activity could not be updated: $e. Keep this transaction ID.';
    }
  }

  /// Told of every transaction this app broadcasts: its id and, when the
  /// preparation knew it, the wallet's balance change. The sync controller
  /// hooks this so the row and the figure show without waiting for a poll.
  void Function(String txId, int? walletDeltaNano)? onBroadcast;

  // ── Stealth addresses ───────────────────────────────────────────────

  /// This wallet's published `stealth…` string.
  Future<String> stealthAddress() {
    _requireUnlocked();
    return RustLib.instance.api.crateApiStealthAddress(handleId: _handleId!);
  }

  /// The published `stealth…` string for stealth identity [index].
  Future<String> stealthAddressAt(int index) {
    _requireUnlocked();
    return RustLib.instance.api.crateApiStealthAddressAt(
      handleId: _handleId!,
      index: index,
    );
  }

  /// Tell the handle to scan and spend with identities `0..=index`.
  /// Returns how many identities are in use afterwards.
  Future<int> stealthUseIdentity(int index) {
    _requireUnlocked();
    return RustLib.instance.api.crateApiStealthUseIdentity(
      handleId: _handleId!,
      index: index,
    );
  }

  /// Which stealth identities hold funds in [explorerBoxesJson], for a
  /// restore that has no persisted identity list to go on.
  Future<Map<String, dynamic>> stealthDiscoverIdentities(
    String explorerBoxesJson,
  ) async {
    _requireUnlocked();
    final raw = await RustLib.instance.api.crateApiStealthDiscoverIdentities(
      handleId: _handleId!,
      explorerBoxesJson: explorerBoxesJson,
    );
    return jsonDecode(raw) as Map<String, dynamic>;
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

  /// Prepare a sweep of owned stealth boxes to one of our own addresses.
  /// Broadcast it with [sendErg], like any other preparation.
  ///
  /// [onlyIdentity] sweeps a single stealth identity; null sweeps them all,
  /// which merges their funds into one output and so links them on chain.
  Future<SendPreview> prepareStealthSweep({
    required String explorerBoxesJson,
    required String destinationAddress,
    String? nodeUrl,
    int? feeNanoErg,
    int? onlyIdentity,
  }) async {
    _requireUnlocked();
    final raw = await RustLib.instance.api.crateApiPrepareStealthSweep(
      handleId: _handleId!,
      explorerBoxesJson: explorerBoxesJson,
      destinationAddress: destinationAddress,
      nodeUrl: nodeUrl,
      feeNano: feeNanoErg,
      onlyIdentity: onlyIdentity,
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

  /// Set aside the funding boxes of pending mixes so no other coin
  /// selection spends them; an empty list frees everything.
  void mixSetReservedFunding(String reservationsJson) {
    if (!isUnlocked) return;
    RustLib.instance.api.crateApiMixSetReservedFunding(
      handleId: _handleId!,
      reservationsJson: reservationsJson,
    );
  }

  /// Boxes that came out of a mix: automatic coin selection leaves them
  /// alone, and a hand-picked set may hold them only on their own.
  void mixSetMixedBoxes(List<String> boxIds) {
    if (!isUnlocked) return;
    RustLib.instance.api.crateApiMixSetMixedBoxes(
      handleId: _handleId!,
      boxIds: boxIds,
    );
  }

  /// The key for one mix, for the background job's keystore. It can spend
  /// that mix's boxes and nothing else.
  Future<Uint8List> mixExportKey(int mixId) {
    _requireUnlocked();
    return RustLib.instance.api.crateApiMixExportKey(
      handleId: _handleId!,
      mixId: mixId,
    );
  }

  /// Everything a preparation will do, for the confirm sheet's details.
  /// Does not consume the preparation.
  Future<Map<String, dynamic>> preparationDetails(int preparationId) async {
    _requireUnlocked();
    final raw = await RustLib.instance.api.crateApiPreparationDetails(
      handleId: _handleId!,
      preparationId: BigInt.from(preparationId),
    );
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  // ── Tokens: issue and burn ─────────────────────────────────────────

  /// Issue a token into this wallet; confirm with [sendErg].
  Future<Map<String, dynamic>> prepareMint({
    required String senderAddress,
    required List<String> spendAddresses,
    required String changeAddress,
    required String name,
    required String description,
    required int decimals,
    required BigInt amount,
    String? nftKind,
    String? nftContentHashHex,
    String? nftUrl,
    String? nodeUrl,
    int? feeNanoErg,
  }) async {
    _requireUnlocked();
    final raw = await RustLib.instance.api.crateApiPrepareMint(
      handleId: _handleId!,
      senderAddress: senderAddress,
      spendAddresses: spendAddresses,
      changeAddress: changeAddress,
      name: name,
      description: description,
      decimals: decimals,
      amount: amount,
      nftKind: nftKind,
      nftContentHashHex: nftContentHashHex,
      nftUrl: nftUrl,
      nodeUrl: nodeUrl,
      feeNano: feeNanoErg,
    );
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Burn tokens held by this wallet; confirm with [sendErg]. `burns` maps
  /// token id to the amount to destroy.
  Future<Map<String, dynamic>> prepareBurn({
    required String senderAddress,
    required List<String> spendAddresses,
    required String changeAddress,
    required Map<String, int> burns,
    String? nodeUrl,
  }) async {
    _requireUnlocked();
    final raw = await RustLib.instance.api.crateApiPrepareBurn(
      handleId: _handleId!,
      senderAddress: senderAddress,
      spendAddresses: spendAddresses,
      changeAddress: changeAddress,
      burnsJson: jsonEncode([
        for (final e in burns.entries) {'token_id': e.key, 'amount': e.value},
      ]),
      nodeUrl: nodeUrl,
    );
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  // ── EIP-12 dApp connector ───────────────────────────────────────────

  /// Check and summarise an unsigned EIP-12 transaction from a dApp page;
  /// sign with [signPreparation].
  Future<String> dappPrepareSign(String txJson, {String? nodeUrl}) {
    _requireUnlocked();
    return RustLib.instance.api.crateApiDappPrepareSign(
      handleId: _handleId!,
      txJson: txJson,
      nodeUrl: nodeUrl,
    );
  }

  /// The wallet's unspent boxes in the shape `ergo.get_utxos()` returns.
  Future<String> dappUtxos(List<String> addresses, {String? nodeUrl}) {
    _requireUnlocked();
    return RustLib.instance.api.crateApiDappUtxos(
      handleId: _handleId!,
      addresses: addresses,
      nodeUrl: nodeUrl,
    );
  }

  // ── Duckpools ───────────────────────────────────────────────────────

  /// Prepare a Duckpools order of any kind; confirm with [sendErg].
  Future<String> duckpoolsPrepareOrder({
    required String poolBoxesJson,
    required String poolKey,
    required String kind,
    required int amount,
    required int slippageBps,
    required int refundAfterBlocks,
    required String userAddress,
    required List<String> spendAddresses,
    required String changeAddress,
    String? nodeUrl,
    int? feeNanoErg,
    String? loanBoxesJson,
    String? collateralAsset,
    int? collateralAmount,
    String? collateralBoxId,
  }) {
    _requireUnlocked();
    return RustLib.instance.api.crateApiDuckpoolsPrepareOrder(
      handleId: _handleId!,
      poolBoxesJson: poolBoxesJson,
      poolKey: poolKey,
      kind: kind,
      amount: amount,
      slippageBps: slippageBps,
      refundAfterBlocks: refundAfterBlocks,
      userAddress: userAddress,
      spendAddresses: spendAddresses,
      changeAddress: changeAddress,
      nodeUrl: nodeUrl,
      feeNano: feeNanoErg,
      loanBoxesJson: loanBoxesJson,
      collateralAsset: collateralAsset,
      collateralAmount: collateralAmount,
      collateralBoxId: collateralBoxId,
    );
  }

  /// Prepare a Rosen bridge transfer out of Ergo; confirm with [sendErg].
  Future<Map<String, dynamic>> rosenPrepareLock({
    required String senderAddress,
    required List<String> spendAddresses,
    required String changeAddress,
    required String tokenId,
    required int amount,
    required String toChain,
    required String toAddress,
    required int bridgeFee,
    required int networkFee,
    String? nodeUrl,
    int? feeNanoErg,
  }) async {
    _requireUnlocked();
    final raw = await RustLib.instance.api.crateApiRosenPrepareLock(
      handleId: _handleId!,
      senderAddress: senderAddress,
      spendAddresses: spendAddresses,
      changeAddress: changeAddress,
      tokenId: tokenId,
      amount: amount,
      toChain: toChain,
      toAddress: toAddress,
      bridgeFee: bridgeFee,
      networkFee: networkFee,
      nodeUrl: nodeUrl,
      feeNano: feeNanoErg,
    );
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Prepare a collateral adjustment on a Duckpools loan; confirm with
  /// [sendErg].
  Future<String> duckpoolsPrepareAdjust({
    required String loanBoxesJson,
    required String poolKey,
    required String collateralBoxId,
    required int newAmount,
    required String userAddress,
    required List<String> spendAddresses,
    required String changeAddress,
    String? nodeUrl,
    int? feeNanoErg,
  }) {
    _requireUnlocked();
    return RustLib.instance.api.crateApiDuckpoolsPrepareAdjust(
      handleId: _handleId!,
      loanBoxesJson: loanBoxesJson,
      poolKey: poolKey,
      collateralBoxId: collateralBoxId,
      newAmount: newAmount,
      userAddress: userAddress,
      spendAddresses: spendAddresses,
      changeAddress: changeAddress,
      nodeUrl: nodeUrl,
      feeNano: feeNanoErg,
    );
  }

  // ── SigmaFi ───────────────────────────────────────────

  /// Prepare a SigmaFi loan request; confirm with [sendErg].
  Future<String> sigmafiPrepareOpen({
    required String loanAsset,
    required int principal,
    required int repayment,
    required int termBlocks,
    required int collateralErg,
    required String collateralTokensJson,
    required String userAddress,
    required List<String> spendAddresses,
    required String changeAddress,
    String? nodeUrl,
    int? feeNanoErg,
  }) {
    _requireUnlocked();
    return RustLib.instance.api.crateApiSigmafiPrepareOpen(
      handleId: _handleId!,
      loanAsset: loanAsset,
      principal: principal,
      repayment: repayment,
      termBlocks: termBlocks,
      collateralErg: collateralErg,
      collateralTokensJson: collateralTokensJson,
      userAddress: userAddress,
      spendAddresses: spendAddresses,
      changeAddress: changeAddress,
      nodeUrl: nodeUrl,
      feeNano: feeNanoErg,
    );
  }

  Future<String> stakeRecoveryPrepareProxy({
    String? refundBoxJson,
    String? stateBoxJson,
    String? stakeBoxJson,
    required String userAddress,
    required List<String> spendAddresses,
    String? nodeUrl,
  }) {
    _requireUnlocked();
    return RustLib.instance.api.crateApiStakeRecoveryPrepareProxy(
      handleId: _handleId!,
      refundBoxJson: refundBoxJson,
      stateBoxJson: stateBoxJson,
      stakeBoxJson: stakeBoxJson,
      userAddress: userAddress,
      spendAddresses: spendAddresses,
      nodeUrl: nodeUrl,
    );
  }

  String stakeRecoveryProxyRecord(String signed, String recipient) {
    _requireUnlocked();
    return RustLib.instance.api.crateApiStakeRecoveryProxyRecord(
      handleId: _handleId!,
      signedTxJson: signed,
      recipientAddress: recipient,
    );
  }

  Future<String> stakeRecoveryPrepareDirect({
    required String stateBoxJson,
    required String stakeBoxJson,
    required String keyId,
    required String userAddress,
    required List<String> spendAddresses,
    String? nodeUrl,
  }) {
    _requireUnlocked();
    return RustLib.instance.api.crateApiStakeRecoveryPrepareDirect(
      handleId: _handleId!,
      stateBoxJson: stateBoxJson,
      stakeBoxJson: stakeBoxJson,
      keyId: keyId,
      userAddress: userAddress,
      spendAddresses: spendAddresses,
      nodeUrl: nodeUrl,
    );
  }

  /// Prepare a cancel, close, repay or liquidate of a SigmaFi box;
  /// confirm with [sendErg].
  Future<String> sigmafiPrepareSpend({
    required String action,
    required String boxJson,
    required String userAddress,
    required List<String> spendAddresses,
    String? nodeUrl,
    int? feeNanoErg,
  }) {
    _requireUnlocked();
    return RustLib.instance.api.crateApiSigmafiPrepareSpend(
      handleId: _handleId!,
      action: action,
      boxJson: boxJson,
      userAddress: userAddress,
      spendAddresses: spendAddresses,
      nodeUrl: nodeUrl,
      feeNano: feeNanoErg,
    );
  }

  /// Prepare the refund of an unfilled order; confirm with [sendErg].
  Future<String> duckpoolsPrepareRefund({
    required String proxyBoxJson,
    required String userAddress,
    String? nodeUrl,
  }) {
    _requireUnlocked();
    return RustLib.instance.api.crateApiDuckpoolsPrepareRefund(
      handleId: _handleId!,
      proxyBoxJson: proxyBoxJson,
      userAddress: userAddress,
      nodeUrl: nodeUrl,
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
  Future<String> submitSignedTransaction(
    String txJson, {
    String? nodeUrl,
  }) async {
    final txId = await RustLib.instance.api.crateApiSubmitSignedTransaction(
      txJson: txJson,
      nodeUrl: nodeUrl,
    );
    _recordBroadcast(txId, null);
    return txId;
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

  Future<Map<String, dynamic>> loadSyncInputs(
    List<String> addresses, {
    String? nodeUrl,
  }) async {
    final raw = await RustLib.instance.api.crateApiGetSyncInputs(
      addresses: addresses,
      nodeUrl: nodeUrl,
    );
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getBalance(
    String address, {
    String? nodeUrl,
  }) async {
    final raw = await RustLib.instance.api.crateApiGetBalance(
      address: address,
      nodeUrl: nodeUrl,
    );
    final balance = jsonDecode(raw) as Map<String, dynamic>;
    onBalanceRead?.call(address, balance, nodeUrl);
    return balance;
  }

  Future<List<TokenBalance>> tokensFor(
    String address, {
    String? nodeUrl,
  }) async {
    final map = await getBalance(address, nodeUrl: nodeUrl);
    return hydrateTokens(map['tokens']);
  }

  /// Cache-only, always. Resolution is a separate pass the sync controller
  /// runs after balances are published, so a slow node cannot hold up the
  /// balance the user is waiting for, and so the ids that go to the network
  /// are chosen at one explicit call site rather than by a flag threaded
  /// through this interface.
  Future<List<TokenBalance>> hydrateTokens(dynamic raw) async {
    // The wallet's own table first. It used to load only inside the name
    // pass, which runs after history and the stealth scan, so the first
    // balance after every unlock republished each holding without its name
    // and the pass put it back seconds later. Memoized: only the first call
    // waits, and only on local storage.
    await ensureWalletTable();
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

  /// Carries completeness with the rows so overlapping wallet requests cannot
  /// borrow each other's status while waiting for balances or pending activity.
  Future<HistoryResult> loadHistory(
    List<String> addresses, {
    int limit = 20,
    int offset = 0,
    Map<String, int>? perAddressOffsets,
    Future<List<dynamic>>? pending,
  }) async {
    var ok = 0;
    var failed = 0;
    // Unconfirmed transactions ride ahead of confirmed history and are read
    // alongside it. A mempool failure must never break the activity list,
    // so it degrades to confirmed only.
    final pendingFuture =
        (pending ??
                RustLib.instance.api
                    .crateApiGetPendingTransactions(addresses: addresses)
                    .then((raw) => jsonDecode(raw) as List))
            .catchError((_) => const <dynamic>[]);
    final results = await Future.wait(
      addresses.map((address) async {
        try {
          final off = perAddressOffsets != null
              ? (perAddressOffsets[address] ?? 0)
              : offset;
          // Every row is read against all of [addresses]: a move between
          // two of them is the wallet's own, not a payment.
          final raw = await getTransactionHistory(
            address,
            limit: limit,
            offset: off,
            walletAddresses: addresses,
          );
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
    final all = <Map<String, dynamic>>[];
    final seen = <String>{};
    // Change this wallet sent to a one-time stealth address of its own is
    // the wallet's, though no address of [addresses] names it. Only this
    // wallet's list: another wallet's change paid to this one is a payment.
    final walletId = _currentWalletId;
    await stealthChangeBook.load(walletId);
    final change = stealthChangeBook.addressesFor(walletId);
    for (final txs in results) {
      for (final tx in txs) {
        if (tx is! Map) continue;
        final map = reownActivity(Map<String, dynamic>.from(tx), change);
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
    return (rows: mergePending(await pendingFuture, all), partial: failed > 0);
  }

  Future<TokenBalance> tokenMeta(String id, int amount) async {
    return cachedTokenMeta(id)?.withHolding(amount) ??
        TokenBalance(id: id, amount: amount);
  }

  /// One page of [address]'s history, each transaction read from the point
  /// of view of a wallet owning [walletAddresses] (and [address]).
  Future<String> getTransactionHistory(
    String address, {
    int limit = 20,
    int offset = 0,
    String? nodeUrl,
    List<String> walletAddresses = const [],
  }) {
    return RustLib.instance.api.crateApiGetTransactionHistory(
      address: address,
      walletAddresses: walletAddresses,
      nodeUrl: nodeUrl,
      limit: BigInt.from(limit),
      offset: BigInt.from(offset),
    );
  }

  /// The wallet's spendable boxes on [addresses], for coin control and the
  /// UTXO tools, as the Rust core gathers them for a spend: boxes a pending
  /// transaction already spends are never listed, and unconfirmed ones —
  /// incoming payments and change, marked [InputBoxInput.confirmed] false —
  /// only while Settings allows spending them. [confirmedOnly] asks for
  /// confirmed boxes whatever the setting (the mix funding finder waits for
  /// its box to confirm). Mix reservations and mixed boxes are still listed;
  /// the spend applies those rules.
  ///
  /// Caps at [maxUnspentBoxesTotal] across all addresses; a node error is
  /// raised, never silently treated as an empty wallet.
  Future<List<InputBoxInput>> listUnspentBoxes(
    List<String> addresses, {
    required String? nodeUrl,
    bool confirmedOnly = false,
  }) async {
    _requireUnlocked();
    final raw = await RustLib.instance.api.crateApiMempoolListSpendableBoxes(
      handleId: _handleId!,
      addresses: [
        for (final a in addresses)
          if (a.isNotEmpty) a,
      ],
      nodeUrl: nodeUrl == null || nodeUrl.isEmpty ? null : nodeUrl,
      confirmedOnly: confirmedOnly,
    );
    final boxes = _parseInputBoxes(jsonDecode(raw));
    return boxes.length > maxUnspentBoxesTotal
        ? boxes.sublist(0, maxUnspentBoxesTotal)
        : boxes;
  }

  /// Balances, pending activity and the wallet-wide pending summary for a
  /// wallet that is not unlocked, read one address at a time.
  Future<Map<String, dynamic>> loadPublicSyncInputs(
    List<String> addresses, {
    String? nodeUrl,
  }) async {
    final raw = await RustLib.instance.api.crateApiMempoolGetPublicSyncInputs(
      addresses: addresses,
      nodeUrl: nodeUrl,
    );
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Consolidate ERG by sending-to-self in batches of up to 200 inputs.
  ///
  /// Older ERG-only boxes are refreshed first. Each batch is passed as an
  /// exact input selection so ordinary coin selection cannot exceed the
  /// 200-input cap or pull a token-bearing box into a consolidation.
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

      ergOnly.sort((a, b) {
        final aHeight = a.creationHeight > 0 ? a.creationHeight : 0x7fffffff;
        final bHeight = b.creationHeight > 0 ? b.creationHeight : 0x7fffffff;
        final age = aHeight.compareTo(bHeight);
        return age != 0 ? age : b.valueNanoErg.compareTo(a.valueNanoErg);
      });
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
          inputBoxIds: batch.map((b) => b.boxId).toList(),
          nodeUrl: nodeUrl,
        );
        final txId = await sendErg(preparationId: preview.preparationId);
        txIds.add(txId);
        if (ergOnly.length <= maxInputsPerTx) break;
      } catch (e) {
        // Progress already broadcast is preserved; a total failure is a real
        // error the caller must see rather than an empty success.
        if (txIds.isEmpty) rethrow;
        debugPrint(
          'argus: consolidation stopped after ${txIds.length} batch(es): $e',
        );
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
    final raw = await RustLib.instance.api.crateApiDbComputeSummary(
      dbJson: dbJson,
    );
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  void _setHandle(String walletId, BigInt id) {
    clearSessionMetadata();
    // Drop overlays tied to the outgoing key before publishing the new view.
    walletSyncController.deactivate();
    stealthService.reset();
    mixService.reset();
    // Capture the outgoing wallet's unwritten table BEFORE
    // `_currentWalletId` moves — reading it afterwards would file the old
    // wallet's descriptors under the new wallet's key.
    _captureUnwrittenDescriptors(_currentWalletId);
    _handles[walletId] = id;
    _currentWalletId = walletId;
    _descriptorOwner = walletId;
    _descriptorCache.clear();
    _metadataMisses.clear();
    _tokenMeta
      ..clear()
      ..addAll(_legacyTokenMeta);
    // The table is read right after this, by the caller (see
    // [_loadActivatedTable]); the memoization was already dropped by
    // clearSessionMetadata above.
    walletSyncController.activateWallet(walletId);
    currentWalletId.value = walletId;
    unlocked.value = true;
  }

  /// Reads the newly active wallet's descriptor table before unlocking
  /// returns, so names it has already learned are in memory for the first
  /// frame and the first balance, rather than arriving after the first sync.
  /// It is local storage, and the outgoing wallet's table is written first.
  Future<void> _loadActivatedTable() async {
    await flushPendingDescriptors();
    await ensureWalletTable();
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
    final all = decoded.map(
      (k, v) => MapEntry(k, Map<String, dynamic>.from(v as Map)),
    );
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
    bool? legacyDerivation,
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
      // Kept across renames and pins; only provisioning sets it.
      if (legacyDerivation ?? (existing is Map && existing['derivation'] == 'pre1627'))
        'derivation': 'pre1627',
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
