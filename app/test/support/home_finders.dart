import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// The home screens join a figure to its unit with a no-break space and set
// most lines as rich text. These find and read text as a person reads it,
// with no-break spaces made plain.

/// [text]'s words, rich or plain, with no-break spaces made plain.
String plainText(Text text) => (text.data ?? text.textSpan?.toPlainText() ?? '').replaceAll(' ', ' ');

/// A [Text] whose words are exactly [text].
Finder textPlain(String text) =>
    find.byWidgetPredicate((w) => w is Text && plainText(w) == text, description: 'text "$text"');

/// A [Text] whose words contain [pattern].
Finder textPlainContaining(Pattern pattern) =>
    find.byWidgetPredicate((w) => w is Text && plainText(w).contains(pattern), description: 'text containing "$pattern"');

/// The words of the one [Text] [finder] finds.
String plainOf(WidgetTester tester, Finder finder) => plainText(tester.widget<Text>(finder));

/// Every word on screen, one [Text] per line, for failure messages.
String screenText(WidgetTester tester) =>
    tester.widgetList<Text>(find.byType(Text)).map(plainText).where((t) => t.isNotEmpty).join('\n');
