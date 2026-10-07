import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/ui/restore_wallet_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _appkit =
    'slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet';

PhraseCheck _check({
  List<String>? words,
  List<UnknownWord> unknown = const [],
  bool countOk = true,
  bool checksumOk = true,
  String language = 'english',
}) =>
    PhraseCheck(
      words: words ?? _appkit.split(' '),
      language: language,
      unknown: unknown,
      countOk: countOk,
      checksumOk: checksumOk,
    );

RestoreDerivationProbe _probe({
  bool affected = true,
  bool? standardUsed,
  bool? legacyUsed,
  bool recommendLegacy = false,
}) =>
    RestoreDerivationProbe(
      affected: affected,
      standardUsed: standardUsed,
      legacyUsed: legacyUsed,
      recommendLegacy: recommendLegacy,
      standardAddress: '9eYMpb',
      legacyAddress: '9ewv8s',
    );

/// Stands in for the Rust validator: words not in [known] are unknown,
/// with [suggest] as their suggestions; the checksum holds only for the
/// appkit phrase.
class FakeGateway implements RestorePhraseGateway {
  FakeGateway({this.probeResult, this.probeError = false});
  final RestoreDerivationProbe? probeResult;
  final bool probeError;
  bool? lastQueryNode;
  String? lastPhrase;
  final known = _appkit.split(' ').toSet();
  final suggest = {'bundel': ['bundle']};

  @override
  PhraseCheck check(String raw) {
    final words = mnemonicWords(raw);
    final unknown = [
      for (final (i, w) in words.indexed)
        if (!known.contains(w)) UnknownWord(i + 1, w, suggest[w] ?? const []),
    ];
    final countOk = const [12, 15, 18, 21, 24].contains(words.length);
    return PhraseCheck(
      words: words,
      language: 'english',
      unknown: unknown,
      countOk: countOk,
      checksumOk: countOk && unknown.isEmpty && words.join(' ') == _appkit,
    );
  }

  @override
  Future<RestoreDerivationProbe> probe({
    required String phrase,
    required String passphrase,
    required bool queryNode,
  }) async {
    lastQueryNode = queryNode;
    lastPhrase = phrase;
    if (probeError) throw Exception('node unreachable');
    return probeResult ?? _probe(affected: false);
  }
}

void main() {
  group('mnemonicWords normalisation', () {
    test('unicode spaces, zero-width characters, numbering and commas', () {
      final messy = '﻿1. Slow 2. silly, 3) start​ 4.wash\n'
          '5 bundle;　suffer‍ bulb';
      expect(mnemonicWords(messy), [
        'slow', 'silly', 'start', 'wash', 'bundle', 'suffer', 'bulb',
      ]);
    });

    test('a zero-width space inside a word is removed, not a split', () {
      expect(mnemonicWords('aban​don'), ['abandon']);
    });
  });

  group('PhraseCheck', () {
    test('parses the Rust JSON', () {
      final c = PhraseCheck.fromJson({
        'words': ['a', 'b'],
        'language': 'spanish',
        'unknown': [
          {'position': 2, 'word': 'b', 'suggestions': ['bb']},
        ],
        'count_ok': false,
        'checksum_ok': false,
      });
      expect(c.unknown.single.position, 2);
      expect(c.unknown.single.suggestions, ['bb']);
      expect(c.languageName, 'Spanish');
      expect(c.isValid, isFalse);
    });

    test('unknown words are named by position with a suggestion', () {
      final c = _check(unknown: const [UnknownWord(7, 'abandom', ['abandon'])], checksumOk: false);
      expect(c.continueError, "Word 7 'abandom' isn't a BIP-39 word. Did you mean 'abandon'?");
    });

    test('a bad checksum is explained plainly', () {
      expect(
        _check(checksumOk: false).continueError,
        "All words are valid but the checksum doesn't match: one word is wrong "
        'or the order is off. Check each word against your backup.',
      );
    });

    test('a wrong word count says how many there are', () {
      expect(
        _check(words: ['slow', 'silly'], countOk: false, checksumOk: false).continueError,
        contains('This one has 2'),
      );
    });

    test('the word being typed is not flagged until something follows it', () {
      final c = _check(
        words: ['slow', 'sil'],
        unknown: const [UnknownWord(2, 'sil', [])],
        countOk: false,
        checksumOk: false,
      );
      expect(c.visibleUnknown('slow sil'), isEmpty);
      expect(c.visibleUnknown('slow sil '), hasLength(1));
    });

    test('replacing a word rewrites the field normalised', () {
      final c = _check(words: ['slow', 'sily', 'start']);
      expect(c.replaceWord(2, 'silly'), 'slow silly start ');
    });

    test('another BIP-39 list is named', () {
      expect(_check().languageNote, isNull);
      expect(_check(language: 'japanese').languageNote, contains('Japanese'));
    });
  });

  group('decideRestoreDerivation', () {
    test('an unaffected phrase stays standard with nothing to say', () {
      final d = decideRestoreDerivation(forced: false, probe: _probe(affected: false));
      expect(d.legacy, isFalse);
      expect(d.notice, isNull);
    });

    test('legacy alone with history restores legacy and says so', () {
      final d = decideRestoreDerivation(
        forced: false,
        probe: _probe(standardUsed: false, legacyUsed: true, recommendLegacy: true),
      );
      expect(d.legacy, isTrue);
      expect(d.notice, contains('pre-1627'));
    });

    test('both with history: standard, and how to reach the other', () {
      final d = decideRestoreDerivation(
        forced: false,
        probe: _probe(standardUsed: true, legacyUsed: true),
      );
      expect(d.legacy, isFalse);
      expect(d.notice, contains('Advanced'));
    });

    test('neither with history: standard, silently', () {
      final d = decideRestoreDerivation(
        forced: false,
        probe: _probe(standardUsed: false, legacyUsed: false),
      );
      expect(d.legacy, isFalse);
      expect(d.notice, isNull);
    });

    test('node unreachable: standard, and the way out', () {
      final d = decideRestoreDerivation(forced: false, probe: null);
      expect(d.legacy, isFalse);
      expect(d.notice, contains('could not reach a node'));
    });

    test('forced legacy wins unless the modes agree', () {
      expect(decideRestoreDerivation(forced: true, probe: _probe()).legacy, isTrue);
      expect(decideRestoreDerivation(forced: true, probe: null).legacy, isTrue);
      final same = decideRestoreDerivation(forced: true, probe: _probe(affected: false));
      expect(same.legacy, isFalse);
      expect(same.notice, contains('same keys'));
    });
  });

  group('WalletInfo derivation', () {
    test('round-trips and stays off for older entries', () {
      final info = WalletInfo(
        walletId: 'w',
        name: 'n',
        createdAt: DateTime.utc(2026),
        legacyDerivation: true,
      );
      expect(info.toJson()['derivation'], 'pre1627');
      expect(WalletInfo.fromJson(info.toJson()).legacyDerivation, isTrue);
      expect(
        WalletInfo.fromJson({'walletId': 'w', 'name': 'n', 'createdAt': ''}).legacyDerivation,
        isFalse,
      );
    });

    testWidgets('survives a rename', (tester) async {
      SharedPreferences.setMockInitialValues({});
      const channel = MethodChannel('com.argus.wallet/secure_storage');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'listWalletIds' ? ['legacy-w'] : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
      );
      final listed = await tester.runAsync(() async {
        await walletService.saveWalletInfo(
          'legacy-w',
          name: 'Old',
          createdAt: DateTime.utc(2026),
          legacyDerivation: true,
        );
        await walletService.renameWallet('legacy-w', 'Renamed');
        return walletService.listWallets();
      });
      final w = listed!.singleWhere((w) => w.walletId == 'legacy-w');
      expect(w.name, 'Renamed');
      expect(w.legacyDerivation, isTrue);
    });
  });

  group('RestoreWalletScreen', () {
    Future<void> pump(WidgetTester tester, FakeGateway gateway) async {
      tester.view.physicalSize = const Size(400, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: RestoreWalletScreen(gateway: gateway)));
      await tester.pumpAndSettle();
    }

    Future<void> enter(WidgetTester tester, String text) async {
      await tester.enterText(find.byKey(const ValueKey('restore-phrase')), text);
      await tester.pumpAndSettle();
    }

    testWidgets('marks an unknown word live and a suggestion replaces it', (tester) async {
      await pump(tester, FakeGateway());
      await enter(tester, _appkit.replaceFirst('bundle', 'bundel'));
      expect(find.text("Word 5 'bundel' isn't a BIP-39 word"), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('suggest-5-bundle')));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byKey(const ValueKey('restore-phrase')));
      expect(field.controller!.text, '$_appkit ');
      expect(find.textContaining("isn't a BIP-39 word"), findsNothing);
    });

    testWidgets('keeps the secure keyboard settings', (tester) async {
      await pump(tester, FakeGateway());
      final field = tester.widget<TextField>(find.byKey(const ValueKey('restore-phrase')));
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
      expect(field.enableIMEPersonalizedLearning, isFalse);
      expect(field.keyboardType, TextInputType.visiblePassword);
    });

    testWidgets('Continue explains a checksum failure and stays', (tester) async {
      final gateway = FakeGateway();
      await pump(tester, gateway);
      final swapped = _appkit.split(' ');
      final first = swapped[0];
      swapped[0] = swapped[1];
      swapped[1] = first;
      await enter(tester, swapped.join(' '));
      await tester.tap(find.byKey(const ValueKey('restore-continue')));
      await tester.pumpAndSettle();
      expect(find.textContaining("checksum doesn't match"), findsOneWidget);
      expect(gateway.lastPhrase, isNull, reason: 'no probe for an invalid phrase');
      expect(find.text('Set a PIN'), findsNothing);
    });

    testWidgets('a legacy-only history restores legacy and says so', (tester) async {
      final gateway = FakeGateway(
        probeResult: _probe(standardUsed: false, legacyUsed: true, recommendLegacy: true),
      );
      await pump(tester, gateway);
      await enter(tester, '1. ${_appkit.replaceAll(' ', ', ')}');
      await tester.tap(find.byKey(const ValueKey('restore-continue')));
      await tester.pumpAndSettle();
      expect(gateway.lastQueryNode, isTrue);
      expect(gateway.lastPhrase, _appkit);
      expect(find.text('Set a PIN'), findsOneWidget);
      expect(find.byKey(const ValueKey('restore-derivation-notice')), findsOneWidget);
      expect(find.textContaining('pre-1627'), findsOneWidget);
    });

    testWidgets('the Advanced switch forces legacy without asking the node', (tester) async {
      final gateway = FakeGateway(probeResult: _probe());
      await pump(tester, gateway);
      await enter(tester, _appkit);
      await tester.tap(find.byKey(const ValueKey('restore-advanced')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('restore-legacy-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('restore-continue')));
      await tester.pumpAndSettle();
      expect(gateway.lastQueryNode, isFalse);
      expect(find.textContaining('as you chose'), findsOneWidget);
    });

    testWidgets('an unreachable node still lets the restore go on', (tester) async {
      final gateway = FakeGateway(probeError: true);
      await pump(tester, gateway);
      await enter(tester, _appkit);
      await tester.tap(find.byKey(const ValueKey('restore-continue')));
      await tester.pumpAndSettle();
      expect(find.text('Set a PIN'), findsOneWidget);
      expect(find.textContaining('could not reach a node'), findsOneWidget);
    });
  });
}
