import 'dart:math';

import 'package:flutter/material.dart';

const iris = Color(0xFFC4A46A);
/// Brand iris darkened for text/buttons on light paper (~6.4:1 vs ~2.1:1).
const irisDeep = Color(0xFF6B5320);
const ink = Color(0xFF0E1110);
const watchfulSurface = Color(0xFF171C1A);
const bone = Color(0xFFE8E4D9);
const watchfulMuted = Color(0xFF8A867A);
const paper = Color(0xFFF5F1E8);
const ledgerSurface = Color(0xFFFEFCF7);
const ledgerInk = Color(0xFF1C1914);
const ledgerMuted = Color(0xFF6B6458);
const rust = Color(0xFFB54A3C);
/// Brand rust brightened for text on dark ink (~6.9:1 vs ~3.6:1).
const rustBright = Color(0xFFE08A70);
const moss = Color(0xFF3E7A55);
const bannerTint = Color(0xFFF0E6D2);

/// Palette-aware rust for *text*: the brand rust fails WCAG on dark
/// surfaces, so dark mode gets [rustBright]. Icons and borders keep [rust].
Color rustFor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? rustBright : rust;

const cardRadius = 20.0;
const buttonRadius = 14.0;

/// Accent colour for the current palette (gold on Watchful and Ledger).
Color accentOf(BuildContext context) => ArgusColors.of(context).accent;

/// One complete palette. Two ship as the defaults (Watchful, Ledger); the
/// rest are alternatives the user can pick per brightness.
class PaletteSpec {
  const PaletteSpec({
    required this.id,
    required this.name,
    required this.hint,
    required this.brightness,
    required this.background,
    required this.surface,
    required this.surfaceHigh,
    required this.ink,
    required this.muted,
    required this.outline,
    required this.cardBorder,
    required this.chip,
    required this.accent,
    required this.onAccent,
    required this.accentText,
  });

  final String id;
  final String name;
  final String hint;
  final Brightness brightness;
  final Color background;
  final Color surface;
  final Color surfaceHigh;
  final Color ink;
  final Color muted;
  final Color outline;
  final Color cardBorder;
  final Color chip;
  final Color accent;
  final Color onAccent;

  /// Accent as text on this background, contrast-safe.
  final Color accentText;

  bool get isDark => brightness == Brightness.dark;
}

const watchfulPalette = PaletteSpec(
  id: 'watchful', name: 'Watchful', hint: 'Ink ground, bone type, gold', brightness: Brightness.dark,
  background: ink, surface: watchfulSurface, surfaceHigh: Color(0xFF1E2421), ink: bone, muted: watchfulMuted,
  outline: Color(0xFF2C3330), cardBorder: Color(0xFF262C29), chip: watchfulSurface,
  accent: iris, onAccent: ink, accentText: iris,
);

const ledgerPalette = PaletteSpec(
  id: 'ledger', name: 'Ledger', hint: 'Warm paper, dark ink, gold', brightness: Brightness.light,
  background: paper, surface: ledgerSurface, surfaceHigh: Color(0xFFEDE4D4), ink: ledgerInk, muted: ledgerMuted,
  outline: Color(0xFFD4C8B4), cardBorder: Color(0xFFEDE4D3), chip: bannerTint,
  accent: iris, onAccent: ink, accentText: irisDeep,
);

const obsidianPalette = PaletteSpec(
  id: 'obsidian', name: 'Obsidian', hint: 'True black, steel accent', brightness: Brightness.dark,
  background: Color(0xFF000000), surface: Color(0xFF111214), surfaceHigh: Color(0xFF1A1C1F), ink: Color(0xFFE9EAEC), muted: Color(0xFF8B9096),
  outline: Color(0xFF2A2D31), cardBorder: Color(0xFF232629), chip: Color(0xFF17191C),
  accent: Color(0xFF9DB8CC), onAccent: Color(0xFF0B1216), accentText: Color(0xFF9DB8CC),
);

const harborPalette = PaletteSpec(
  id: 'harbor', name: 'Harbor', hint: 'Deep navy, teal accent', brightness: Brightness.dark,
  background: Color(0xFF0B1220), surface: Color(0xFF141D2E), surfaceHigh: Color(0xFF1B2638), ink: Color(0xFFE3E8F0), muted: Color(0xFF8592A6),
  outline: Color(0xFF283449), cardBorder: Color(0xFF222D40), chip: Color(0xFF182233),
  accent: Color(0xFF5FB3A4), onAccent: Color(0xFF06201C), accentText: Color(0xFF7CC9BB),
);

const emberPalette = PaletteSpec(
  id: 'ember', name: 'Ember', hint: 'Warm charcoal, copper accent', brightness: Brightness.dark,
  background: Color(0xFF151210), surface: Color(0xFF201B18), surfaceHigh: Color(0xFF29221E), ink: Color(0xFFEDE3D9), muted: Color(0xFF9A8E84),
  outline: Color(0xFF3A312C), cardBorder: Color(0xFF302925), chip: Color(0xFF261F1B),
  accent: Color(0xFFD48A5A), onAccent: Color(0xFF1E120A), accentText: Color(0xFFE0A07A),
);

const parchmentPalette = PaletteSpec(
  id: 'parchment', name: 'Parchment', hint: 'Cream, sage accent', brightness: Brightness.light,
  background: Color(0xFFFAF6EC), surface: Color(0xFFFFFDF8), surfaceHigh: Color(0xFFF0EADA), ink: Color(0xFF2A2318), muted: Color(0xFF6F675A),
  outline: Color(0xFFD9D0BC), cardBorder: Color(0xFFEAE3D2), chip: Color(0xFFF1EBDC),
  accent: Color(0xFF5E8A6A), onAccent: Color(0xFFF6FBF6), accentText: Color(0xFF3F6B4C),
);

const frostPalette = PaletteSpec(
  id: 'frost', name: 'Frost', hint: 'Cool white, slate-blue accent', brightness: Brightness.light,
  background: Color(0xFFF3F5F8), surface: Color(0xFFFFFFFF), surfaceHigh: Color(0xFFE8ECF2), ink: Color(0xFF1B1F26), muted: Color(0xFF6B7380),
  outline: Color(0xFFCFD6E0), cardBorder: Color(0xFFE2E7EE), chip: Color(0xFFEDF0F5),
  accent: Color(0xFF4A6FA5), onAccent: Color(0xFFF7F9FD), accentText: Color(0xFF3C5D8C),
);

const allPalettes = [watchfulPalette, ledgerPalette, obsidianPalette, harborPalette, emberPalette, parchmentPalette, frostPalette];

PaletteSpec paletteById(String? id, {required Brightness fallback}) {
  for (final p in allPalettes) {
    if (p.id == id) return p;
  }
  return fallback == Brightness.dark ? watchfulPalette : ledgerPalette;
}

/// Palette-dependent colours that screens used to re-derive by hand from
/// `Theme.of(context).brightness`.
class ArgusColors extends ThemeExtension<ArgusColors> {
  const ArgusColors({
    required this.muted,
    required this.cardBorder,
    required this.inset,
    required this.chip,
    this.accent = iris,
    this.onAccent = ink,
    this.accentText = iris,
  });

  factory ArgusColors.fromSpec(PaletteSpec p) => ArgusColors(
        muted: p.muted,
        cardBorder: p.cardBorder,
        inset: p.background,
        chip: p.chip,
        accent: p.accent,
        onAccent: p.onAccent,
        accentText: p.accentText,
      );

  /// Primary accent (buttons, links, selected states).
  final Color accent;
  final Color onAccent;

  /// Accent used as text on the page background.
  final Color accentText;

  /// Secondary text.
  final Color muted;

  /// Hairline around soft cards.
  final Color cardBorder;

  /// Recessed panel inside a card (status strip, address box).
  final Color inset;

  /// Small tinted container (icon wells, badges).
  final Color chip;

  static const light = ArgusColors(
    muted: ledgerMuted,
    cardBorder: Color(0xFFEDE4D3),
    inset: paper,
    chip: bannerTint,
    accentText: irisDeep,
  );

  static const dark = ArgusColors(
    muted: watchfulMuted,
    cardBorder: Color(0xFF262C29),
    inset: ink,
    chip: watchfulSurface,
  );

  static ArgusColors of(BuildContext context) =>
      Theme.of(context).extension<ArgusColors>() ??
      (Theme.of(context).brightness == Brightness.dark ? dark : light);

  @override
  ArgusColors copyWith({Color? muted, Color? cardBorder, Color? inset, Color? chip, Color? accent, Color? onAccent, Color? accentText}) =>
      ArgusColors(
        muted: muted ?? this.muted,
        cardBorder: cardBorder ?? this.cardBorder,
        inset: inset ?? this.inset,
        chip: chip ?? this.chip,
        accent: accent ?? this.accent,
        onAccent: onAccent ?? this.onAccent,
        accentText: accentText ?? this.accentText,
      );

  @override
  ArgusColors lerp(ThemeExtension<ArgusColors>? other, double t) {
    if (other is! ArgusColors) return this;
    return ArgusColors(
      muted: Color.lerp(muted, other.muted, t)!,
      cardBorder: Color.lerp(cardBorder, other.cardBorder, t)!,
      inset: Color.lerp(inset, other.inset, t)!,
      chip: Color.lerp(chip, other.chip, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      accentText: Color.lerp(accentText, other.accentText, t)!,
    );
  }
}

ThemeData argusTheme({required bool watchful}) =>
    argusThemeFor(watchful ? watchfulPalette : ledgerPalette);

ThemeData argusThemeFor(PaletteSpec p) {
  final watchful = p.isDark;
  final scheme = ColorScheme(
    brightness: p.brightness,
    primary: p.accent,
    onPrimary: p.onAccent,
    secondary: p.accent,
    onSecondary: p.onAccent,
    error: rust,
    onError: bone,
    surface: p.surface,
    onSurface: p.ink,
    surfaceContainerHighest: p.surfaceHigh,
    outline: p.outline,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: scheme.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.background,
    canvasColor: p.background,
    fontFamily: 'Karla',
  );

  final text = base.textTheme.copyWith(
    displayLarge: const TextStyle(
      fontFamily: 'Newsreader',
      fontWeight: FontWeight.w600,
      fontSize: 56,
      height: 0.95,
      letterSpacing: -1.2,
    ),
    headlineSmall: const TextStyle(
      fontFamily: 'Newsreader',
      fontWeight: FontWeight.w600,
      fontSize: 28,
      height: 1.1,
    ),
    titleLarge: const TextStyle(
      fontFamily: 'Newsreader',
      fontWeight: FontWeight.w600,
      fontSize: 22,
    ),
    titleMedium: const TextStyle(
      fontFamily: 'Karla',
      fontWeight: FontWeight.w500,
      fontSize: 16,
      letterSpacing: 0.1,
    ),
    titleSmall: const TextStyle(
      fontFamily: 'Karla',
      fontWeight: FontWeight.w500,
      fontSize: 13,
      letterSpacing: 1.4,
    ),
    bodyLarge: const TextStyle(fontFamily: 'Karla', fontSize: 16, height: 1.45),
    bodyMedium: const TextStyle(fontFamily: 'Karla', fontSize: 14, height: 1.45),
    bodySmall: const TextStyle(fontFamily: 'Karla', fontSize: 12, height: 1.4),
    labelLarge: const TextStyle(
      fontFamily: 'Karla',
      fontWeight: FontWeight.w500,
      fontSize: 14,
      letterSpacing: 0.4,
    ),
  ).apply(
    bodyColor: p.ink,
    displayColor: p.ink,
  );

  return base.copyWith(
    extensions: [ArgusColors.fromSpec(p)],
    textTheme: text,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: p.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
    ),
    cardTheme: CardThemeData(
      color: p.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(cardRadius),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: watchful ? p.outline : p.cardBorder,
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(buttonRadius),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(buttonRadius),
        borderSide: BorderSide(color: scheme.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(buttonRadius),
        borderSide: BorderSide(color: p.accent, width: 1.2),
      ),
      labelStyle: TextStyle(color: p.muted),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        elevation: 0,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(buttonRadius),
        ),
        textStyle: const TextStyle(
          fontFamily: 'Karla',
          fontWeight: FontWeight.w500,
          letterSpacing: 0.6,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.ink,
        minimumSize: const Size.fromHeight(52),
        side: BorderSide(color: p.accent),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(buttonRadius),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.accentText,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.background,
      indicatorColor: p.accent.withValues(alpha: 0.18),
      elevation: 0,
      height: 68,
      labelTextStyle: WidgetStatePropertyAll(
        text.bodySmall?.copyWith(letterSpacing: 0.6),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: watchful ? p.surface : p.ink,
      contentTextStyle: TextStyle(fontFamily: 'Karla', color: watchful ? p.ink : p.background),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.accent),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(cardRadius),
      ),
    ),
  );
}

TextStyle monoStyle(BuildContext context, {double size = 13}) {
  return TextStyle(
    fontFamily: 'IBMPlexMono',
    fontSize: size,
    height: 1.4,
    color: Theme.of(context).colorScheme.onSurface,
  );
}

class Hairline extends StatelessWidget {
  const Hairline({super.key, this.gold = false});
  final bool gold;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      color: gold ? iris : Theme.of(context).dividerColor,
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.scope});
  final String text;

  /// Optional scope tag shown next to the label, e.g. 'This wallet' or
  /// 'App-wide', so readers know what a settings section applies to.
  final String? scope;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).brightness == Brightness.dark
        ? watchfulMuted
        : ledgerMuted;
    return Row(
      children: [
        Text(
          text.toUpperCase(),
          style: Theme.of(context).textTheme.titleSmall?.copyWith(color: muted),
        ),
        if (scope != null) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              border: Border.all(color: muted, width: 0.8),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              scope!.toUpperCase(),
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                color: muted,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class WarningStrip extends StatefulWidget {
  const WarningStrip({super.key});

  @override
  State<WarningStrip> createState() => _WarningStripState();
}

class _WarningStripState extends State<WarningStrip> {
  bool _dismissed = false;

  void _learnMore() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Prototype software'),
        content: const Text(
          'Argus is an unaudited prototype. Transactions on Ergo are '
          'irreversible — use only funds you can afford to lose.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: dark ? watchfulSurface : bannerTint,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Icons.shield_outlined, size: 18, color: iris),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Unaudited prototype. Use only funds you can afford to lose.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          TextButton(
            onPressed: _learnMore,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
            ),
            child: const Text('Learn more'),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Dismiss',
            onPressed: () => setState(() => _dismissed = true),
          ),
        ],
      ),
    );
  }
}

class StepDots extends StatelessWidget {
  const StepDots({super.key, required this.total, required this.index});
  final int total;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(total, (i) {
        return Container(
          width: i == index ? 22 : 7,
          height: 7,
          margin: const EdgeInsets.only(right: 6),
          color: i == index ? iris : Theme.of(context).dividerColor,
        );
      }),
    );
  }
}

Route<T> fadeRoute<T>(Widget page, {RouteSettings? settings}) {
  return PageRouteBuilder<T>(
    settings: settings,
    pageBuilder: (_, _, _) => page,
    transitionDuration: const Duration(milliseconds: 240),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    transitionsBuilder: (_, animation, _, child) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      );
    },
  );
}

class IrisMark extends StatelessWidget {
  const IrisMark({super.key, this.size = 56});
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size.square(size), painter: _IrisPainter());
  }
}

class _IrisPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size canvasSize) {
    final side = canvasSize.shortestSide;
    final stroke = Paint()
      ..color = iris
      ..style = PaintingStyle.stroke
      ..strokeWidth = side * 0.07;
    final c = Offset(canvasSize.width / 2, canvasSize.height / 2);
    final r = side * 0.36;
    canvas.drawCircle(c, r, stroke);

    const ang = -0.5235987755982988; // 2 o'clock
    final outer = Offset(c.dx + cos(ang) * r, c.dy + sin(ang) * r);
    final inward = Offset(c.dx + cos(ang) * r * 0.52, c.dy + sin(ang) * r * 0.52);
    const perp = ang + 1.5707963267948966;
    final half = side * 0.055;
    final path = Path()
      ..moveTo(outer.dx + cos(perp) * half, outer.dy + sin(perp) * half)
      ..lineTo(inward.dx, inward.dy)
      ..lineTo(outer.dx - cos(perp) * half, outer.dy - sin(perp) * half)
      ..close();
    canvas.drawPath(path, Paint()..color = iris);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
