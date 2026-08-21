import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ArgusPalette { system, watchful, ledger }

class ThemeController extends ChangeNotifier {
  static const _key = 'argus_palette';

  ArgusPalette palette = ArgusPalette.system;

  ThemeMode get themeMode => switch (palette) {
        ArgusPalette.system => ThemeMode.system,
        ArgusPalette.watchful => ThemeMode.dark,
        ArgusPalette.ledger => ThemeMode.light,
      };

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    palette = ArgusPalette.values.firstWhere(
      (v) => v.name == raw,
      orElse: () => ArgusPalette.system,
    );
    notifyListeners();
  }

  Future<void> setPalette(ArgusPalette next) async {
    palette = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, next.name);
  }
}

final themeController = ThemeController();
