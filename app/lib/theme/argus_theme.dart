import 'dart:math';

import 'package:flutter/material.dart';

const iris = Color(0xFFC4A46A);
const ink = Color(0xFF0E1110);
const watchfulSurface = Color(0xFF171C1A);
const bone = Color(0xFFE8E4D9);
const watchfulMuted = Color(0xFF8A867A);
const paper = Color(0xFFF5F1E8);
const ledgerSurface = Color(0xFFFEFCF7);
const ledgerInk = Color(0xFF1C1914);
const ledgerMuted = Color(0xFF6B6458);
const rust = Color(0xFFB54A3C);
const moss = Color(0xFF3E7A55);
const bannerTint = Color(0xFFF0E6D2);

const cardRadius = 20.0;
const buttonRadius = 14.0;

ThemeData argusTheme({required bool watchful}) {
  final scheme = ColorScheme(
    brightness: watchful ? Brightness.dark : Brightness.light,
    primary: iris,
    onPrimary: ink,
    secondary: iris,
    onSecondary: ink,
    error: rust,
    onError: bone,
    surface: watchful ? watchfulSurface : ledgerSurface,
    onSurface: watchful ? bone : ledgerInk,
    surfaceContainerHighest: watchful ? const Color(0xFF1E2421) : const Color(0xFFEDE4D4),
    outline: watchful ? const Color(0xFF2C3330) : const Color(0xFFD4C8B4),
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: scheme.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: watchful ? ink : paper,
    canvasColor: watchful ? ink : paper,
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
    bodyColor: watchful ? bone : ledgerInk,
    displayColor: watchful ? bone : ledgerInk,
  );

  return base.copyWith(
    textTheme: text,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: watchful ? bone : ledgerInk,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
    ),
    cardTheme: CardThemeData(
      color: watchful ? watchfulSurface : ledgerSurface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(cardRadius),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: watchful ? const Color(0xFF2C3330) : const Color(0xFFE9E1D2),
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: watchful ? watchfulSurface : ledgerSurface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(buttonRadius),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(buttonRadius),
        borderSide: BorderSide(color: scheme.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(buttonRadius),
        borderSide: const BorderSide(color: iris, width: 1.2),
      ),
      labelStyle: TextStyle(color: watchful ? watchfulMuted : ledgerMuted),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: iris,
        foregroundColor: ink,
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
        foregroundColor: watchful ? bone : ledgerInk,
        minimumSize: const Size.fromHeight(52),
        side: const BorderSide(color: iris),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(buttonRadius),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: iris),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: watchful ? ink : paper,
      indicatorColor: iris.withValues(alpha: 0.18),
      elevation: 0,
      height: 68,
      labelTextStyle: WidgetStatePropertyAll(
        text.bodySmall?.copyWith(letterSpacing: 0.6),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: watchful ? watchfulSurface : ledgerInk,
      contentTextStyle: TextStyle(fontFamily: 'Karla', color: watchful ? bone : paper),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: iris),
    dialogTheme: DialogThemeData(
      backgroundColor: watchful ? watchfulSurface : ledgerSurface,
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
  const SectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: Theme.of(context).brightness == Brightness.dark
                ? watchfulMuted
                : ledgerMuted,
          ),
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
            visualDensity: VisualDensity.compact,
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
