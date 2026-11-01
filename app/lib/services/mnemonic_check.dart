/// What the restore screen shows about a recovery phrase: the live word
/// check (from Rust's BIP-39 validator, `check_mnemonic`) and the
/// key-derivation probe (`probe_restore_derivation`).
///
/// Pure models and wording, so they can be tested without the bridge.
/// Nothing here logs or stores a word; instances live only as long as the
/// screen holding them.
library;

/// Display names for the BIP-39 lists Rust reports.
const _languageNames = {
  'english': 'English',
  'spanish': 'Spanish',
  'french': 'French',
  'italian': 'Italian',
  'portuguese': 'Portuguese',
  'czech': 'Czech',
  'japanese': 'Japanese',
  'korean': 'Korean',
  'chinese_simplified': 'Chinese (simplified)',
  'chinese_traditional': 'Chinese (traditional)',
};

class UnknownWord {
  /// 1-based, as written on a backup sheet.
  final int position;
  final String word;
  final List<String> suggestions;
  const UnknownWord(this.position, this.word, this.suggestions);

  factory UnknownWord.fromJson(Map<String, dynamic> j) => UnknownWord(
        (j['position'] as num).toInt(),
        j['word'] as String,
        (j['suggestions'] as List? ?? const []).cast<String>(),
      );

  String get message => "Word $position '$word' isn't a BIP-39 word";
}

class PhraseCheck {
  /// The phrase as Rust normalised it: invisible characters gone, NFKD,
  /// lower case, numbering and punctuation removed.
  final List<String> words;
  final String language;
  final List<UnknownWord> unknown;
  final bool countOk;
  final bool checksumOk;

  const PhraseCheck({
    required this.words,
    required this.language,
    required this.unknown,
    required this.countOk,
    required this.checksumOk,
  });

  static const empty = PhraseCheck(
    words: [],
    language: 'english',
    unknown: [],
    countOk: false,
    checksumOk: false,
  );

  factory PhraseCheck.fromJson(Map<String, dynamic> j) => PhraseCheck(
        words: (j['words'] as List? ?? const []).cast<String>(),
        language: j['language'] as String? ?? 'english',
        unknown: [
          for (final u in (j['unknown'] as List? ?? const []))
            UnknownWord.fromJson((u as Map).cast<String, dynamic>()),
        ],
        countOk: j['count_ok'] == true,
        checksumOk: j['checksum_ok'] == true,
      );

  bool get isValid => countOk && unknown.isEmpty && checksumOk;

  String get languageName => _languageNames[language] ?? language;

  /// The phrase as it should be passed on: normalised words, one space.
  String get phrase => words.join(' ');

  /// Unknown words worth flagging while the user is still typing: the last
  /// word is left alone until something follows it, so "aban" on its way
  /// to "abandon" is not called a mistake.
  List<UnknownWord> visibleUnknown(String raw) {
    final typingLast = raw.isNotEmpty && !_separatorAtEnd.hasMatch(raw);
    return [
      for (final u in unknown)
        if (!(typingLast && u.position == words.length)) u,
    ];
  }

  /// Shown under the field when the phrase is not English: Argus creates
  /// English phrases, but restores any official BIP-39 list.
  String? get languageNote => language == 'english' || words.isEmpty
      ? null
      : 'These are words from the $languageName BIP-39 list. Argus can '
          'restore a $languageName phrase; it checks the words against that list.';

  /// Why Continue cannot go on, in plain words, or null when it can.
  String? get continueError {
    if (words.isEmpty) return 'Enter your recovery phrase.';
    if (unknown.isNotEmpty) {
      final first = unknown.first;
      final more = unknown.length > 1 ? ' (and ${unknown.length - 1} more)' : '';
      final hint = first.suggestions.isEmpty
          ? ''
          : ' Did you mean ${first.suggestions.map((s) => "'$s'").join(' or ')}?';
      return '${first.message}$more.$hint';
    }
    if (!countOk) {
      return 'A recovery phrase has 12, 15, 18, 21, or 24 words. '
          'This one has ${words.length}.';
    }
    if (!checksumOk) {
      return "All words are valid but the checksum doesn't match: one word "
          'is wrong or the order is off. Check each word against your backup.';
    }
    return null;
  }

  /// The field text after replacing word [position] (1-based) with
  /// [replacement]; the rest is written back normalised.
  String replaceWord(int position, String replacement) {
    final next = List<String>.of(words);
    if (position >= 1 && position <= next.length) next[position - 1] = replacement;
    return '${next.join(' ')} ';
  }
}

final _separatorAtEnd = RegExp(r'[\s,.;:) 　]$');

/// The probe's answer: does this phrase derive differently under the
/// pre-1627 bug, and if so, where is its history?
class RestoreDerivationProbe {
  final bool affected;
  final bool? standardUsed;
  final bool? legacyUsed;
  final bool recommendLegacy;
  final String standardAddress;
  final String legacyAddress;

  const RestoreDerivationProbe({
    required this.affected,
    required this.standardUsed,
    required this.legacyUsed,
    required this.recommendLegacy,
    required this.standardAddress,
    required this.legacyAddress,
  });

  factory RestoreDerivationProbe.fromJson(Map<String, dynamic> j) =>
      RestoreDerivationProbe(
        affected: j['affected'] == true,
        standardUsed: j['standard_used'] as bool?,
        legacyUsed: j['legacy_used'] as bool?,
        recommendLegacy: j['recommended'] == 'pre1627',
        standardAddress: j['standard_address'] as String? ?? '',
        legacyAddress: j['legacy_address'] as String? ?? '',
      );
}

/// Shown with a legacy wallet's backup advice: the phrase alone is not
/// enough to get the same addresses elsewhere.
const legacyDerivationBackupNote =
    'Key derivation: legacy (pre-1627). This phrase was made by an early Ergo '
    'wallet. To restore it elsewhere, turn on that wallet\'s legacy or '
    '"pre-1627 derivation" option (Argus restores it automatically), '
    'or the addresses will differ.';

/// The derivation a restore goes ahead with, and what to tell the user.
typedef RestoreDerivationDecision = ({bool legacy, String? notice});

const _legacyName = 'the older pre-1627 key derivation';
const _advancedHint = 'Advanced → Legacy (pre-1627) derivation';

/// Decides the restore derivation.
///
/// [forced] is the Advanced switch. [probe] is null when the node could
/// not be asked. Legacy is used when forced, or when legacy alone has
/// history; both, neither or unknown mean standard.
RestoreDerivationDecision decideRestoreDerivation({
  required bool forced,
  required RestoreDerivationProbe? probe,
}) {
  if (probe != null && !probe.affected) {
    return (
      legacy: false,
      notice: forced
          ? 'For this phrase the legacy and standard derivations give the '
              'same keys, so it restores the same either way.'
          : null,
    );
  }
  if (forced) {
    final first = probe == null ? '' : ' Its first address is ${probe.legacyAddress}.';
    return (
      legacy: true,
      notice: 'Restoring with $_legacyName, as you chose.$first',
    );
  }
  if (probe == null) {
    return (
      legacy: false,
      notice: 'This phrase gives different addresses under $_legacyName used by '
          'early Ergo wallets, and Argus could not reach a node to check which one '
          'you used. It will use the standard one. If your funds do not show, '
          'remove this wallet and restore again with $_advancedHint.',
    );
  }
  if (probe.recommendLegacy) {
    return (
      legacy: true,
      notice: "This phrase's history is under $_legacyName, used by early "
          'versions of the Ergo node and the wallets built on it, not under the '
          'standard one. Argus will restore it that way, so your addresses '
          'match the wallet you made it in.',
    );
  }
  if (probe.standardUsed == true && probe.legacyUsed == true) {
    return (
      legacy: false,
      notice: 'This phrase has history under both the standard derivation and '
          '$_legacyName. Argus will restore the standard one. To open the other, '
          'restore the phrase again with $_advancedHint.',
    );
  }
  return (legacy: false, notice: null);
}
