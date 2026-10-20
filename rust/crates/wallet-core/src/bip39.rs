//! BIP-39 phrase normalisation, word checks and checksum.
//!
//! One validator for every entry point: the restore screen's live check
//! ([`check_phrase`]) and [`crate::seed::MnemonicPhrase::parse`] both go
//! through [`normalize_words`] and [`checksum_ok`], so what the screen
//! accepts is exactly what the wallet derives from.
//!
//! All ten official BIP-39 lists are known. English is what Argus creates;
//! the others are accepted on restore because the BIP-39 seed is PBKDF2 over
//! the NFKD-normalised words joined by spaces, independent of the list, and
//! the Ergo node lets its operator pick the phrase language. A phrase in
//! another list is only accepted when every word is in that one list and its
//! checksum holds.

use std::collections::HashMap;
use std::sync::OnceLock;

use serde::Serialize;
use sha2::{Digest, Sha256};
use unicode_normalization::char::is_combining_mark;
use unicode_normalization::UnicodeNormalization;

use crate::CoreError;

/// The BIP-39 word lists, from github.com/bitcoin/bips/tree/master/bip-0039.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Language {
    English,
    Spanish,
    French,
    Italian,
    Portuguese,
    Czech,
    Japanese,
    Korean,
    ChineseSimplified,
    ChineseTraditional,
}

impl Language {
    pub const ALL: [Language; 10] = [
        Language::English,
        Language::Spanish,
        Language::French,
        Language::Italian,
        Language::Portuguese,
        Language::Czech,
        Language::Japanese,
        Language::Korean,
        Language::ChineseSimplified,
        Language::ChineseTraditional,
    ];

    fn source(self) -> &'static str {
        match self {
            Language::English => include_str!("bip39_english.txt"),
            Language::Spanish => include_str!("bip39_wordlists/spanish.txt"),
            Language::French => include_str!("bip39_wordlists/french.txt"),
            Language::Italian => include_str!("bip39_wordlists/italian.txt"),
            Language::Portuguese => include_str!("bip39_wordlists/portuguese.txt"),
            Language::Czech => include_str!("bip39_wordlists/czech.txt"),
            Language::Japanese => include_str!("bip39_wordlists/japanese.txt"),
            Language::Korean => include_str!("bip39_wordlists/korean.txt"),
            Language::ChineseSimplified => include_str!("bip39_wordlists/chinese_simplified.txt"),
            Language::ChineseTraditional => {
                include_str!("bip39_wordlists/chinese_traditional.txt")
            }
        }
    }
}

struct WordList {
    language: Language,
    /// NFKD form, the form [`normalize_words`] produces.
    words: Vec<String>,
    index: HashMap<String, u16>,
}

fn lists() -> &'static [WordList] {
    static LISTS: OnceLock<Vec<WordList>> = OnceLock::new();
    LISTS.get_or_init(|| {
        Language::ALL
            .iter()
            .map(|&language| {
                let words: Vec<String> = language
                    .source()
                    .lines()
                    .map(|w| w.nfkd().collect())
                    .collect();
                let index = words
                    .iter()
                    .enumerate()
                    .map(|(i, w)| (w.clone(), i as u16))
                    .collect();
                WordList {
                    language,
                    words,
                    index,
                }
            })
            .collect()
    })
}

fn list(language: Language) -> &'static WordList {
    &lists()[Language::ALL.iter().position(|l| *l == language).unwrap_or(0)]
}

pub const VALID_WORD_COUNTS: [usize; 5] = [12, 15, 18, 21, 24];

/// Splits pasted or typed text into BIP-39 words.
///
/// - zero-width and other invisible format characters (ZWSP, ZWJ, BOM,
///   soft hyphen, …) are dropped;
/// - NFKD folds NBSP, ideographic and other Unicode spaces to a plain
///   space, full-width letters to ASCII, and matches the form the seed
///   is computed over;
/// - anything that cannot be part of a word — whitespace, digits, commas,
///   full stops, brackets, so `1. abandon 2) ability,` — separates words;
/// - everything is lower-cased (every BIP-39 list is lower case).
pub fn normalize_words(raw: &str) -> Vec<String> {
    let folded: String = raw
        .chars()
        .filter(|c| !is_invisible(*c))
        .collect::<String>()
        .nfkd()
        .flat_map(char::to_lowercase)
        .collect();
    folded
        .split(|c: char| !(c.is_alphabetic() || is_combining_mark(c)))
        .filter(|w| !w.is_empty())
        .map(str::to_owned)
        .collect()
}

fn is_invisible(c: char) -> bool {
    matches!(
        c,
        '\u{00AD}' | '\u{180E}' | '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}'
            | '\u{2060}'..='\u{2064}' | '\u{FEFF}'
    )
}

/// The list holding most of `words`, English on a tie.
fn best_language(words: &[String]) -> Language {
    let mut best = (Language::English, 0usize);
    for l in lists() {
        let hits = words.iter().filter(|w| l.index.contains_key(*w)).count();
        if hits > best.1 {
            best = (l.language, hits);
        }
    }
    best.0
}

/// Checks the BIP-39 checksum of `words`, all of which must be in `language`.
pub fn checksum_ok(words: &[String], language: Language) -> bool {
    let list = list(language);
    let n = words.len();
    if !VALID_WORD_COUNTS.contains(&n) {
        return false;
    }
    let mut bits = Vec::with_capacity(n * 11);
    for w in words {
        let Some(&idx) = list.index.get(w) else {
            return false;
        };
        for i in (0..11).rev() {
            bits.push((idx >> i) & 1 == 1);
        }
    }
    let ent_len = n * 11 * 32 / 33;
    let cs_len = n * 11 - ent_len;
    let mut entropy = vec![0u8; ent_len / 8];
    for (i, bit) in bits.iter().take(ent_len).enumerate() {
        if *bit {
            entropy[i / 8] |= 1 << (7 - (i % 8));
        }
    }
    let hash = Sha256::digest(&entropy);
    zeroize::Zeroize::zeroize(&mut entropy);
    (0..cs_len).all(|i| bits[ent_len + i] == ((hash[i / 8] >> (7 - (i % 8))) & 1 == 1))
}

/// A word that is not in the phrase's list.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct UnknownWord {
    /// 1-based, as people count words on paper.
    pub position: usize,
    pub word: String,
    /// Closest list words, best first; at most three.
    pub suggestions: Vec<String>,
}

/// What the restore screen shows about a phrase as it is typed.
///
/// Holds the words in memory only; neither side logs or stores it.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct PhraseCheck {
    /// The normalised words, so the screen can rewrite the field (and
    /// apply a suggestion) without tokenising again.
    pub words: Vec<String>,
    pub language: Language,
    pub unknown: Vec<UnknownWord>,
    pub count_ok: bool,
    /// Only meaningful once `count_ok` and `unknown` is empty.
    pub checksum_ok: bool,
}

impl PhraseCheck {
    pub fn is_valid(&self) -> bool {
        self.count_ok && self.unknown.is_empty() && self.checksum_ok
    }
}

pub fn check_phrase(raw: &str) -> PhraseCheck {
    let words = normalize_words(raw);
    let language = best_language(&words);
    let list = list(language);
    let unknown: Vec<UnknownWord> = words
        .iter()
        .enumerate()
        .filter(|(_, w)| !list.index.contains_key(*w))
        .map(|(i, w)| UnknownWord {
            position: i + 1,
            word: w.clone(),
            suggestions: suggestions(w, list),
        })
        .collect();
    let count_ok = VALID_WORD_COUNTS.contains(&words.len());
    let checksum_ok = count_ok && unknown.is_empty() && checksum_ok(&words, language);
    PhraseCheck {
        words,
        language,
        unknown,
        count_ok,
        checksum_ok,
    }
}

/// Closest words to `typed`: a list word sharing its first four letters
/// first (BIP-39 lists are unique on four letters, so that one is meant),
/// then words within edit distance two, nearest first.
fn suggestions(typed: &str, list: &WordList) -> Vec<String> {
    let typed_chars: Vec<char> = typed.chars().collect();
    let mut out: Vec<String> = Vec::new();
    if typed_chars.len() >= 4 {
        let prefix: String = typed_chars[..4].iter().collect();
        let matches: Vec<&String> = list.words.iter().filter(|w| w.starts_with(&prefix)).collect();
        if matches.len() == 1 {
            out.push(matches[0].clone());
        }
    }
    let mut near: Vec<(usize, &String)> = list
        .words
        .iter()
        .filter_map(|w| {
            let d = edit_distance(&typed_chars, &w.chars().collect::<Vec<_>>());
            (d <= 2 && d < typed_chars.len()).then_some((d, w))
        })
        .collect();
    near.sort();
    for (_, w) in near {
        if out.len() >= 3 {
            break;
        }
        if !out.contains(w) {
            out.push(w.clone());
        }
    }
    out
}

/// Optimal string alignment distance: insertions, deletions, substitutions
/// and swaps of neighbours, the four ways a word gets mistyped.
fn edit_distance(a: &[char], b: &[char]) -> usize {
    let (n, m) = (a.len(), b.len());
    let mut d = vec![vec![0usize; m + 1]; n + 1];
    for (i, row) in d.iter_mut().enumerate() {
        row[0] = i;
    }
    for j in 0..=m {
        d[0][j] = j;
    }
    for i in 1..=n {
        for j in 1..=m {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            d[i][j] = (d[i - 1][j] + 1)
                .min(d[i][j - 1] + 1)
                .min(d[i - 1][j - 1] + cost);
            if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                d[i][j] = d[i][j].min(d[i - 2][j - 2] + 1);
            }
        }
    }
    d[n][m]
}

/// Validates `raw` and returns its normalised words. The error says which
/// rule failed, by word position where there is one.
pub fn validated_words(raw: &str) -> Result<Vec<String>, CoreError> {
    let check = check_phrase(raw);
    if !check.count_ok {
        return Err(CoreError::Mnemonic(format!(
            "mnemonic must be 12, 15, 18, 21, or 24 words (found {})",
            check.words.len()
        )));
    }
    if let Some(u) = check.unknown.first() {
        return Err(CoreError::Mnemonic(format!(
            "word {} is not in the BIP-39 word list",
            u.position
        )));
    }
    if !check.checksum_ok {
        return Err(CoreError::Mnemonic("invalid checksum".into()));
    }
    Ok(check.words)
}

/// BIP-39 checksum + wordlist check.
pub fn validate_phrase(phrase: &str) -> Result<(), CoreError> {
    validated_words(phrase).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    const ABOUT: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const APPKIT: &str = "slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet";

    #[test]
    fn abandon_about_is_valid() {
        validate_phrase(ABOUT).unwrap();
    }

    #[test]
    fn abandon_abandon_is_invalid() {
        assert!(validate_phrase(
            "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon"
        )
        .is_err());
    }

    #[test]
    fn every_list_is_complete_and_survives_normalisation() {
        for l in lists() {
            assert_eq!(l.words.len(), 2048, "{:?}", l.language);
            assert_eq!(l.index.len(), 2048, "{:?} has duplicates", l.language);
            for w in &l.words {
                assert_eq!(normalize_words(w), vec![w.clone()], "{:?}", l.language);
            }
        }
    }

    #[test]
    fn unicode_spaces_and_invisible_characters_are_cleaned() {
        let words: Vec<&str> = APPKIT.split(' ').collect();
        let messy = format!(
            "\u{FEFF}{}\u{00A0}{}\u{2003}{}\u{3000}{}\u{200B} {}\t{}\n{}\u{202F}{}\u{2009}{} {}\u{200D} {} {} {} {} {}",
            words[0], words[1], words[2], words[3], words[4], words[5], words[6], words[7],
            words[8], words[9], words[10], words[11], words[12], words[13], words[14]
        );
        assert_eq!(normalize_words(&messy).join(" "), APPKIT);
        assert!(check_phrase(&messy).is_valid());
        // A zero-width space inside a word is dropped, not a split.
        assert_eq!(normalize_words("aban\u{200B}don"), vec!["abandon"]);
    }

    #[test]
    fn numbered_lists_commas_and_case_are_cleaned() {
        let numbered: String = APPKIT
            .split(' ')
            .enumerate()
            .map(|(i, w)| format!("{}. {},", i + 1, w.to_uppercase()))
            .collect::<Vec<_>>()
            .join("\n");
        assert_eq!(normalize_words(&numbered).join(" "), APPKIT);
        assert_eq!(normalize_words("1)slow 2.silly;3-start"), vec!["slow", "silly", "start"]);
        // Full-width letters from an East Asian keyboard fold to ASCII.
        assert_eq!(normalize_words("ｓｌｏｗ"), vec!["slow"]);
    }

    #[test]
    fn unknown_words_are_reported_by_position_with_suggestions() {
        let typo = APPKIT.replace("bundle", "bundel").replace("helmet", "helmut");
        let check = check_phrase(&typo);
        assert!(!check.is_valid());
        assert_eq!(check.unknown.len(), 2);
        assert_eq!(check.unknown[0].position, 5);
        assert_eq!(check.unknown[0].word, "bundel");
        assert_eq!(check.unknown[0].suggestions[0], "bundle");
        assert_eq!(check.unknown[1].position, 15);
        assert_eq!(check.unknown[1].suggestions[0], "helmet");
        assert!(!check.checksum_ok);
        assert_eq!(
            validate_phrase(&typo).unwrap_err().to_string(),
            "Mnemonic error: word 5 is not in the BIP-39 word list"
        );
    }

    #[test]
    fn a_four_letter_prefix_names_the_word() {
        let list = list(Language::English);
        assert_eq!(suggestions("abando", list)[0], "abandon");
        assert_eq!(suggestions("ancientt", list)[0], "ancient");
        // Swapped letters are one edit away.
        assert_eq!(suggestions("slwo", list)[0], "slow");
        // Nothing close: no suggestion rather than a wild guess.
        assert!(suggestions("zzzzzzzz", list).is_empty());
    }

    #[test]
    fn valid_words_in_the_wrong_order_fail_only_the_checksum() {
        let mut words: Vec<&str> = APPKIT.split(' ').collect();
        words.swap(0, 1);
        let check = check_phrase(&words.join(" "));
        assert!(check.count_ok);
        assert!(check.unknown.is_empty());
        assert!(!check.checksum_ok);
        assert_eq!(
            validate_phrase(&words.join(" ")).unwrap_err().to_string(),
            "Mnemonic error: invalid checksum"
        );
    }

    #[test]
    fn word_count_is_reported() {
        let check = check_phrase("slow silly start");
        assert!(!check.count_ok);
        assert!(check.unknown.is_empty());
        assert!(validate_phrase("slow silly start")
            .unwrap_err()
            .to_string()
            .contains("found 3"));
    }

    /// bip32JP test vector 1 (github.com/bip32JP/bip32JP.github.io,
    /// test_JP_BIP39.json): ideographic spaces, kana needing NFKD.
    #[test]
    fn japanese_phrase_is_recognised_and_checksummed() {
        let phrase = "あいこくしん　あいこくしん　あいこくしん　あいこくしん　あいこくしん　あいこくしん　あいこくしん　あいこくしん　あいこくしん　あいこくしん　あいこくしん　あおぞら";
        let check = check_phrase(phrase);
        assert_eq!(check.language, Language::Japanese);
        assert!(check.is_valid(), "{check:?}");
    }

    #[test]
    fn other_lists_are_detected_by_majority() {
        // Spanish entropy 0 phrase: index 0 eleven times, then the checksum word.
        let spanish = list(Language::Spanish);
        let mut words = vec![spanish.words[0].clone(); 11];
        let last = (0..2048u16)
            .map(|i| spanish.words[i as usize].clone())
            .find(|w| {
                let mut all = words.clone();
                all.push(w.clone());
                checksum_ok(&all, Language::Spanish)
            })
            .unwrap();
        words.push(last);
        let check = check_phrase(&words.join(" "));
        assert_eq!(check.language, Language::Spanish);
        assert!(check.is_valid());
        // Accented input typed precomposed matches the NFKD list.
        assert!(check_phrase("ábaco").unknown.is_empty());
    }
}
