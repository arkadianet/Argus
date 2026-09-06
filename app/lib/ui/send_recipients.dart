import '../format.dart';
import '../services/stealth_service.dart';
import '../services/wallet_service.dart';

/// A validation failure in the send form, phrased for the user.
class SendFormException implements Exception {
  const SendFormException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// One token as typed: which, and how much.
class TokenDraft {
  const TokenDraft(this.tokenId, this.amountText);
  final String tokenId;
  final String? amountText;
}

/// One recipient as typed into the form, before parsing. ERG and any
/// number of tokens travel in the recipient's one box.
class RecipientDraft {
  RecipientDraft({
    required this.address,
    required this.ergText,
    String? tokenId,
    String? tokenAmountText,
    List<TokenDraft> tokens = const [],
  }) : tokens = [
          if (tokenId != null && tokenId.isNotEmpty) TokenDraft(tokenId, tokenAmountText),
          ...tokens,
        ];

  final String address;
  final String ergText;
  final List<TokenDraft> tokens;
}

/// Parses every draft into the recipient maps the wallet core expects,
/// or throws [SendFormException] naming the first problem.
///
/// Amounts are validated against the held [tokens] so a bad entry is caught
/// before a preparation round-trip to the node.
List<Map<String, dynamic>> buildRecipients(
  List<RecipientDraft> drafts, {
  required List<TokenBalance> tokens,
}) {
  final out = <Map<String, dynamic>>[];
  for (var i = 0; i < drafts.length; i++) {
    final d = drafts[i];
    final who = drafts.length > 1 ? 'Recipient ${i + 1}: ' : '';
    final address = d.address.trim();
    if (!looksLikeRecipient(address)) {
      throw SendFormException('${who}not an Ergo or stealth address');
    }
    final nano = parseErgToNano(d.ergText);
    if (nano == null || nano < minBoxNano) {
      throw SendFormException(
        '${who}minimum ${formatErg(minBoxNano, unit: false)} ERG',
      );
    }
    final entry = <String, dynamic>{
      'address': address,
      'amount_nano_erg': nano,
    };
    // A stealth recipient keeps its published string here; the one-time
    // payment address is derived just before the transaction is built, so
    // every payment lands on a fresh, unlinkable script.
    if (looksLikeStealthAddress(address)) entry['stealth'] = true;
    // Every token this recipient gets, summed where one is named twice and
    // checked against the holding as a whole.
    final wanted = <String, int>{};
    for (final td in d.tokens) {
      final tokenId = td.tokenId;
      if (tokenId.isEmpty) continue;
      TokenBalance? token;
      for (final t in tokens) {
        if (t.id == tokenId) {
          token = t;
          break;
        }
      }
      if (token == null) {
        throw SendFormException('${who}token is not in this wallet');
      }
      final int amount;
      if (token.isNft) {
        amount = 1;
      } else {
        final parsed = parseDecimalToBase(td.amountText ?? '', token.decimals);
        if (parsed == null || parsed <= 0) {
          throw SendFormException('${who}enter a token amount for ${token.label}');
        }
        amount = parsed;
      }
      final total = (wanted[tokenId] ?? 0) + amount;
      if (total > token.amount) {
        throw SendFormException(
          '${who}you hold ${formatTokenAmount(token.amount, token.decimals)} '
          '${token.label}',
        );
      }
      wanted[tokenId] = total;
    }
    if (wanted.isNotEmpty) {
      entry['tokens'] = [
        for (final e in wanted.entries) {'token_id': e.key, 'amount': e.value},
      ];
      // The single-token shape too, for the one-recipient path.
      if (wanted.length == 1) {
        entry['token_id'] = wanted.keys.first;
        entry['token_amount'] = wanted.values.first;
      }
    }
    out.add(entry);
  }
  return out;
}

/// Whether any recipient carries more than one token, which only the
/// multi-recipient builder can do.
bool needsMultiBuilder(List<Map<String, dynamic>> recipients) =>
    recipients.length > 1 || recipients.any((r) => ((r['tokens'] as List?)?.length ?? 0) > 1);

/// Total nanoERG leaving the wallet across [recipients], before the fee.
int totalNanoErg(List<Map<String, dynamic>> recipients) {
  var total = 0;
  for (final r in recipients) {
    total += (r['amount_nano_erg'] as num?)?.toInt() ?? 0;
  }
  return total;
}

/// Replace every stealth recipient with a freshly derived one-time payment
/// address, keeping the published string under `stealth_address` so the
/// confirm sheet can show who is really being paid.
///
/// Call this once, immediately before preparing the transaction: each call
/// draws new `r` and `y`, so two calls produce unlinkable addresses.
Future<List<Map<String, dynamic>>> resolveStealthRecipients(
  List<Map<String, dynamic>> recipients,
) async {
  final out = <Map<String, dynamic>>[];
  for (final r in recipients) {
    if (r['stealth'] != true) {
      out.add(r);
      continue;
    }
    final published = r['address'] as String;
    final String payTo;
    try {
      payTo = await stealthPaymentAddress(published);
    } catch (_) {
      throw SendFormException(
        'That stealth address is not valid (checksum failed)',
      );
    }
    out.add({
      ...r,
      'address': payTo,
      'stealth_address': published,
    }..remove('stealth'));
  }
  return out;
}

/// True when any recipient is being paid through a stealth address.
bool hasStealthRecipient(List<Map<String, dynamic>> recipients) =>
    recipients.any((r) => r['stealth'] == true || r['stealth_address'] != null);
