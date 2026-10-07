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

/// The colours of the hero: the raised panel that heads the overview and
/// each wallet's page, holding the balance and the wallet's actions.
///
/// It is coloured, not a shade of the page, so it reads before anything
/// else does: either the palette's accent itself (solid) or the accent laid
/// into the page (tint), compared until one is chosen ([heroStyle]). Every
/// colour set on it is chosen for its surface: the page's accent, greens and
/// reds were picked for the page, so each has its own here. Text colours
/// meet WCAG AA on [surface] and [surfaceEnd], and the filled button and
/// every icon meet it on what they sit on (home_contrast_test.dart).
class HeroSpec {
  const HeroSpec({
    required this.surface,
    required this.surfaceEnd,
    required this.ink,
    required this.muted,
    required this.divider,
    required this.accent,
    required this.positive,
    required this.negative,
    required this.filled,
    required this.onFilled,
    required this.tonal,
    required this.onTonal,
  });

  /// The panel itself, from its top to its foot: a tint settles a shade
  /// toward the page as it goes down; a solid stays flat.
  final Color surface;
  final Color surfaceEnd;

  /// Figures and words: the balance, the actions' names.
  final Color ink;

  /// Labels and quieter lines: "BALANCE", the fiat caveats, the address.
  final Color muted;

  /// A hairline between parts of the panel.
  final Color divider;

  /// Links and marks in the accent: the price chart, a link's words.
  final Color accent;

  /// A rise or something arriving; a fall or something wrong.
  final Color positive;
  final Color negative;

  /// The one filled action (Send) and the mark on it.
  final Color filled;
  final Color onFilled;

  /// The other actions' wells and their marks.
  final Color tonal;
  final Color onTonal;

  /// Whether text on the panel is dark (a light panel) or light.
  Brightness get brightness => ThemeData.estimateBrightnessForColor(surface);

  static HeroSpec lerp(HeroSpec a, HeroSpec b, double t) => HeroSpec(
        surface: Color.lerp(a.surface, b.surface, t)!,
        surfaceEnd: Color.lerp(a.surfaceEnd, b.surfaceEnd, t)!,
        ink: Color.lerp(a.ink, b.ink, t)!,
        muted: Color.lerp(a.muted, b.muted, t)!,
        divider: Color.lerp(a.divider, b.divider, t)!,
        accent: Color.lerp(a.accent, b.accent, t)!,
        positive: Color.lerp(a.positive, b.positive, t)!,
        negative: Color.lerp(a.negative, b.negative, t)!,
        filled: Color.lerp(a.filled, b.filled, t)!,
        onFilled: Color.lerp(a.onFilled, b.onFilled, t)!,
        tonal: Color.lerp(a.tonal, b.tonal, t)!,
        onTonal: Color.lerp(a.onTonal, b.onTonal, t)!,
      );
}

/// The two heroes under comparison. Temporary: once one is chosen the
/// other and this switch go.
enum HeroStyle { solid, tint }

/// The hero style in use. Read when a theme is built, so a change shows
/// with the next theme.
HeroStyle heroStyle = HeroStyle.tint;

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
    required this.heroSolid,
    required this.heroTint,
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

  /// The hero panel in each style being compared ([heroStyle]).
  final HeroSpec heroSolid;
  final HeroSpec heroTint;

  /// The hero panel in the style in use.
  HeroSpec get hero => heroStyle == HeroStyle.solid ? heroSolid : heroTint;

  bool get isDark => brightness == Brightness.dark;
}

// Two heroes per palette, compared side by side until one is chosen
// ([heroStyle]). Solid: the panel is the palette's accent itself, the
// colour of its filled buttons, with dark type on the light accents and
// light type on the deep ones; Send is the panel's ink, filled. Tint: the
// accent laid into the page (22-34%, tuned per palette), settling a shade
// toward the page at its foot, with the page's own type; Send keeps the
// accent, deepened on the light palettes where the pale accent would not
// hold the button's shape. Parchment's solid uses its deeper sage: light
// type on its mid green would not reach 4.5:1. Every pair is checked in
// home_contrast_test.dart.

const _watchfulSolid = HeroSpec(
  surface: Color(0xFFC4A46A), surfaceEnd: Color(0xFFC4A46A), ink: Color(0xFF14100A), muted: Color(0xFF473B26),
  divider: Color(0xFF9D8355), accent: Color(0xFF49391D), positive: Color(0xFF22422E), negative: Color(0xFF662A22),
  filled: Color(0xFF14100A), onFilled: Color(0xFFC4A46A), tonal: Color(0xFFAF925E), onTonal: Color(0xFF14100A),
);

const _watchfulTint = HeroSpec(
  surface: Color(0xFF453D2B), surfaceEnd: Color(0xFF3A3426), ink: Color(0xFFE8E4D9), muted: Color(0xFFAFAA9C),
  divider: Color(0xFF696251), accent: Color(0xFFC5A66E), positive: Color(0xFF75B98F), negative: Color(0xFFDB9B93),
  filled: Color(0xFFC4A46A), onFilled: Color(0xFF0E1110), tonal: Color(0xFF554E3C), onTonal: Color(0xFFE8E4D9),
);

const _ledgerSolid = HeroSpec(
  surface: Color(0xFFC4A46A), surfaceEnd: Color(0xFFC4A46A), ink: Color(0xFF14100A), muted: Color(0xFF473B26),
  divider: Color(0xFF9D8355), accent: Color(0xFF49391D), positive: Color(0xFF22422E), negative: Color(0xFF662A22),
  filled: Color(0xFF14100A), onFilled: Color(0xFFC4A46A), tonal: Color(0xFFAF925E), onTonal: Color(0xFF14100A),
);

const _ledgerTint = HeroSpec(
  surface: Color(0xFFE6DAC2), surfaceEnd: Color(0xFFE9DFCA), ink: Color(0xFF1C1914), muted: Color(0xFF655E53),
  divider: Color(0xFFBAB09C), accent: Color(0xFF745B2E), positive: Color(0xFF356949), negative: Color(0xFF9E4134),
  filled: Color(0xFF745B2E), onFilled: Color(0xFFFAFCF8), tonal: Color(0xFFD2C7B1), onTonal: Color(0xFF1C1914),
);

const _obsidianSolid = HeroSpec(
  surface: Color(0xFF9DB8CC), surfaceEnd: Color(0xFF9DB8CC), ink: Color(0xFF14100A), muted: Color(0xFF404648),
  divider: Color(0xFF7F93A1), accent: Color(0xFF2F485B), positive: Color(0xFF274C35), negative: Color(0xFF742F26),
  filled: Color(0xFF14100A), onFilled: Color(0xFF9DB8CC), tonal: Color(0xFF8DA4B5), onTonal: Color(0xFF14100A),
);

const _obsidianTint = HeroSpec(
  surface: Color(0xFF2F373D), surfaceEnd: Color(0xFF262C31), ink: Color(0xFFE9EAEC), muted: Color(0xFF9DA1A4),
  divider: Color(0xFF585E64), accent: Color(0xFF9DB8CC), positive: Color(0xFF64B081), negative: Color(0xFFD68D83),
  filled: Color(0xFF9DB8CC), onFilled: Color(0xFF0B1216), tonal: Color(0xFF42494E), onTonal: Color(0xFFE9EAEC),
);

const _harborSolid = HeroSpec(
  surface: Color(0xFF5FB3A4), surfaceEnd: Color(0xFF5FB3A4), ink: Color(0xFF04181A), muted: Color(0xFF1B3F3D),
  divider: Color(0xFF4B9186), accent: Color(0xFF1E3E39), positive: Color(0xFF203F2C), negative: Color(0xFF612820),
  filled: Color(0xFF04181A), onFilled: Color(0xFF5FB3A4), tonal: Color(0xFF54A093), onTonal: Color(0xFF04181A),
);

const _harborTint = HeroSpec(
  surface: Color(0xFF28494D), surfaceEnd: Color(0xFF233F45), ink: Color(0xFFE3E8F0), muted: Color(0xFFA7B5BC),
  divider: Color(0xFF516C71), accent: Color(0xFF79BFB3), positive: Color(0xFF82C09A), negative: Color(0xFFDEA49C),
  filled: Color(0xFF5FB3A4), onFilled: Color(0xFF06201C), tonal: Color(0xFF3B595D), onTonal: Color(0xFFE3E8F0),
);

const _emberSolid = HeroSpec(
  surface: Color(0xFFD48A5A), surfaceEnd: Color(0xFFD48A5A), ink: Color(0xFF14100A), muted: Color(0xFF422D1D),
  divider: Color(0xFFAA6F48), accent: Color(0xFF4B2914), positive: Color(0xFF1C3827), negative: Color(0xFF55231C),
  filled: Color(0xFF14100A), onFilled: Color(0xFFD48A5A), tonal: Color(0xFFBD7B50), onTonal: Color(0xFF14100A),
);

const _emberTint = HeroSpec(
  surface: Color(0xFF4E3626), surfaceEnd: Color(0xFF432F22), ink: Color(0xFFEDE3D9), muted: Color(0xFFB4A599),
  divider: Color(0xFF715C4D), accent: Color(0xFFD9986E), positive: Color(0xFF70B68B), negative: Color(0xFFD9968D),
  filled: Color(0xFFD48A5A), onFilled: Color(0xFF1E120A), tonal: Color(0xFF5E4738), onTonal: Color(0xFFEDE3D9),
);

const _parchmentSolid = HeroSpec(
  surface: Color(0xFF3F6B4C), surfaceEnd: Color(0xFF3F6B4C), ink: Color(0xFFFAFCF8), muted: Color(0xFFD8E2D9),
  divider: Color(0xFF688B72), accent: Color(0xFFD1E4D7), positive: Color(0xFFCDE5D6), negative: Color(0xFFF2DBD8),
  filled: Color(0xFFFAFCF8), onFilled: Color(0xFF3F6B4C), tonal: Color(0xFF355A40), onTonal: Color(0xFFFAFCF8),
);

const _parchmentTint = HeroSpec(
  surface: Color(0xFFD5DCCD), surfaceEnd: Color(0xFFDEE3D5), ink: Color(0xFF2A2318), muted: Color(0xFF615E52),
  divider: Color(0xFFAFB3A5), accent: Color(0xFF44644D), positive: Color(0xFF356748), negative: Color(0xFF9C4034),
  filled: Color(0xFF44644D), onFilled: Color(0xFFFAFCF8), tonal: Color(0xFFC4CABB), onTonal: Color(0xFF2A2318),
);

const _frostSolid = HeroSpec(
  surface: Color(0xFF4A6FA5), surfaceEnd: Color(0xFF4A6FA5), ink: Color(0xFFFAFCF8), muted: Color(0xFFEFF4F3),
  divider: Color(0xFF718EB7), accent: Color(0xFFF1F4F9), positive: Color(0xFFEDF6F0), negative: Color(0xFFFAF2F1),
  filled: Color(0xFFFAFCF8), onFilled: Color(0xFF4A6FA5), tonal: Color(0xFF3E5D8B), onTonal: Color(0xFFFAFCF8),
);

const _frostTint = HeroSpec(
  surface: Color(0xFFCED8E6), surfaceEnd: Color(0xFFD8E0EB), ink: Color(0xFF1B1F26), muted: Color(0xFF565C65),
  divider: Color(0xFFA7AFBC), accent: Color(0xFF3E5D8B), positive: Color(0xFF346647), negative: Color(0xFF9A3F33),
  filled: Color(0xFF3E5D8B), onFilled: Color(0xFFFAFCF8), tonal: Color(0xFFBCC6D3), onTonal: Color(0xFF1B1F26),
);

const watchfulPalette = PaletteSpec(
  id: 'watchful', name: 'Watchful', hint: 'Ink ground, bone type, gold', brightness: Brightness.dark,
  background: ink, surface: watchfulSurface, surfaceHigh: Color(0xFF1E2421), ink: bone, muted: watchfulMuted,
  outline: Color(0xFF2C3330), cardBorder: Color(0xFF262C29), chip: watchfulSurface,
  accent: iris, onAccent: ink, accentText: iris,
  heroSolid: _watchfulSolid,
  heroTint: _watchfulTint,
);

const ledgerPalette = PaletteSpec(
  id: 'ledger', name: 'Ledger', hint: 'Warm paper, dark ink, gold', brightness: Brightness.light,
  background: paper, surface: ledgerSurface, surfaceHigh: Color(0xFFEDE4D4), ink: ledgerInk, muted: ledgerMuted,
  outline: Color(0xFFD4C8B4), cardBorder: Color(0xFFEDE4D3), chip: bannerTint,
  accent: iris, onAccent: ink, accentText: irisDeep,
  heroSolid: _ledgerSolid,
  heroTint: _ledgerTint,
);

const obsidianPalette = PaletteSpec(
  id: 'obsidian', name: 'Obsidian', hint: 'True black, steel accent', brightness: Brightness.dark,
  background: Color(0xFF000000), surface: Color(0xFF111214), surfaceHigh: Color(0xFF1A1C1F), ink: Color(0xFFE9EAEC), muted: Color(0xFF8B9096),
  outline: Color(0xFF2A2D31), cardBorder: Color(0xFF232629), chip: Color(0xFF17191C),
  accent: Color(0xFF9DB8CC), onAccent: Color(0xFF0B1216), accentText: Color(0xFF9DB8CC),
  heroSolid: _obsidianSolid,
  heroTint: _obsidianTint,
);

const harborPalette = PaletteSpec(
  id: 'harbor', name: 'Harbor', hint: 'Deep navy, teal accent', brightness: Brightness.dark,
  background: Color(0xFF0B1220), surface: Color(0xFF141D2E), surfaceHigh: Color(0xFF1B2638), ink: Color(0xFFE3E8F0), muted: Color(0xFF8592A6),
  outline: Color(0xFF283449), cardBorder: Color(0xFF222D40), chip: Color(0xFF182233),
  accent: Color(0xFF5FB3A4), onAccent: Color(0xFF06201C), accentText: Color(0xFF7CC9BB),
  heroSolid: _harborSolid,
  heroTint: _harborTint,
);

const emberPalette = PaletteSpec(
  id: 'ember', name: 'Ember', hint: 'Warm charcoal, copper accent', brightness: Brightness.dark,
  background: Color(0xFF151210), surface: Color(0xFF201B18), surfaceHigh: Color(0xFF29221E), ink: Color(0xFFEDE3D9), muted: Color(0xFF9A8E84),
  outline: Color(0xFF3A312C), cardBorder: Color(0xFF302925), chip: Color(0xFF261F1B),
  accent: Color(0xFFD48A5A), onAccent: Color(0xFF1E120A), accentText: Color(0xFFE0A07A),
  heroSolid: _emberSolid,
  heroTint: _emberTint,
);

const parchmentPalette = PaletteSpec(
  id: 'parchment', name: 'Parchment', hint: 'Cream, sage accent', brightness: Brightness.light,
  background: Color(0xFFFAF6EC), surface: Color(0xFFFFFDF8), surfaceHigh: Color(0xFFF0EADA), ink: Color(0xFF2A2318), muted: Color(0xFF6F675A),
  outline: Color(0xFFD9D0BC), cardBorder: Color(0xFFEAE3D2), chip: Color(0xFFF1EBDC),
  accent: Color(0xFF5E8A6A), onAccent: Color(0xFFF6FBF6), accentText: Color(0xFF3F6B4C),
  heroSolid: _parchmentSolid,
  heroTint: _parchmentTint,
);

// Muted is #687080 rather than #6B7380: on Frost's page and recessed wells
// the lighter grey read 4.38:1, short of WCAG AA; this reads 4.56:1.
const frostPalette = PaletteSpec(
  id: 'frost', name: 'Frost', hint: 'Cool white, slate-blue accent', brightness: Brightness.light,
  background: Color(0xFFF3F5F8), surface: Color(0xFFFFFFFF), surfaceHigh: Color(0xFFE8ECF2), ink: Color(0xFF1B1F26), muted: Color(0xFF687080),
  outline: Color(0xFFCFD6E0), cardBorder: Color(0xFFE2E7EE), chip: Color(0xFFEDF0F5),
  accent: Color(0xFF4A6FA5), onAccent: Color(0xFFF7F9FD), accentText: Color(0xFF3C5D8C),
  heroSolid: _frostSolid,
  heroTint: _frostTint,
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
    this.hero = _watchfulTint,
  });

  factory ArgusColors.fromSpec(PaletteSpec p) => ArgusColors(
        muted: p.muted,
        cardBorder: p.cardBorder,
        inset: p.background,
        chip: p.chip,
        accent: p.accent,
        onAccent: p.onAccent,
        accentText: p.accentText,
        hero: p.hero,
      );

  /// The hero panel's own colours (see [HeroSpec]).
  final HeroSpec hero;

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
    hero: _ledgerTint,
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
  ArgusColors copyWith({
    Color? muted,
    Color? cardBorder,
    Color? inset,
    Color? chip,
    Color? accent,
    Color? onAccent,
    Color? accentText,
    HeroSpec? hero,
  }) =>
      ArgusColors(
        muted: muted ?? this.muted,
        cardBorder: cardBorder ?? this.cardBorder,
        inset: inset ?? this.inset,
        chip: chip ?? this.chip,
        accent: accent ?? this.accent,
        onAccent: onAccent ?? this.onAccent,
        accentText: accentText ?? this.accentText,
        hero: hero ?? this.hero,
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
      hero: HeroSpec.lerp(hero, other.hero, t),
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
      // Left to the scheme, the selected icon took onSecondaryContainer,
      // which falls back to the ink-on-accent colour: dark ink on the gold
      // indicator in every dark palette. The current tab draws in the
      // accent and the others step back, so only one tab speaks.
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 24,
          color: states.contains(WidgetState.selected) ? p.accentText : p.muted,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => text.bodySmall?.copyWith(
          letterSpacing: 0.6,
          color: states.contains(WidgetState.selected) ? p.ink : p.muted,
          fontWeight: states.contains(WidgetState.selected) ? FontWeight.w500 : FontWeight.w400,
        ),
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

/// For a button that shares a line with something else.
///
/// The theme asks buttons to be as wide as their parent allows, which is
/// what a page's main action wants. A Row or a Wrap offers its children
/// unbounded width, so that minimum becomes infinite there and the line
/// cannot be laid out; this keeps the height and lets the button be as
/// wide as its label.
final inlineButtonStyle = ButtonStyle(
  minimumSize: WidgetStateProperty.all(const Size(0, 52)),
);

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
