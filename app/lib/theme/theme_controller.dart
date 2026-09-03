import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'argus_theme.dart';

/// Legacy single choice, kept for the stored preference and the old
/// Display rows: system follows the OS, the other two force a brightness.
enum ArgusPalette { system, watchful, ledger }

enum ArgusThemeMode { system, light, dark }

class ThemeController extends ChangeNotifier {
  static const _key = 'argus_palette';
  static const _modeKey = 'argus_theme_mode';
  static const _darkKey = 'argus_palette_dark';
  static const _lightKey = 'argus_palette_light';

  ArgusThemeMode mode = ArgusThemeMode.system;
  PaletteSpec darkPalette = watchfulPalette;
  PaletteSpec lightPalette = ledgerPalette;

  /// Kept so existing callers keep compiling; derived from [mode].
  ArgusPalette get palette => switch (mode) {
        ArgusThemeMode.system => ArgusPalette.system,
        ArgusThemeMode.dark => ArgusPalette.watchful,
        ArgusThemeMode.light => ArgusPalette.ledger,
      };

  ThemeMode get themeMode => switch (mode) {
        ArgusThemeMode.system => ThemeMode.system,
        ArgusThemeMode.dark => ThemeMode.dark,
        ArgusThemeMode.light => ThemeMode.light,
      };

  ThemeData get lightTheme => argusThemeFor(lightPalette);
  ThemeData get darkTheme => argusThemeFor(darkPalette);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final modeRaw = prefs.getString(_modeKey);
    if (modeRaw != null) {
      mode = ArgusThemeMode.values.firstWhere((m) => m.name == modeRaw, orElse: () => ArgusThemeMode.system);
    } else {
      // Migrate the old single palette preference.
      mode = switch (prefs.getString(_key)) {
        'watchful' => ArgusThemeMode.dark,
        'ledger' => ArgusThemeMode.light,
        _ => ArgusThemeMode.system,
      };
    }
    darkPalette = paletteById(prefs.getString(_darkKey), fallback: Brightness.dark);
    lightPalette = paletteById(prefs.getString(_lightKey), fallback: Brightness.light);
    notifyListeners();
  }

  Future<void> setMode(ArgusThemeMode next) async {
    mode = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, next.name);
  }

  /// Old API: system / watchful / ledger.
  Future<void> setPalette(ArgusPalette next) => setMode(switch (next) {
        ArgusPalette.system => ArgusThemeMode.system,
        ArgusPalette.watchful => ArgusThemeMode.dark,
        ArgusPalette.ledger => ArgusThemeMode.light,
      });

  Future<void> setDarkPalette(PaletteSpec p) async {
    darkPalette = p;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_darkKey, p.id);
  }

  Future<void> setLightPalette(PaletteSpec p) async {
    lightPalette = p;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lightKey, p.id);
  }
}

final themeController = ThemeController();
