import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/argus_theme.dart';

/// What lights the scene: an eclipse's rim (the overview) or the haze of a
/// wallet's medallion (a wallet's page).
enum SceneLight { eclipse, medallion }

/// The art the home pages open on, drawn here rather than shipped as an
/// image: a sky settling into the page, the accent's haze, an eclipse's
/// glowing rim, a range of mountains with light along their crests, and a
/// faint grain.
///
/// It is painted behind [child], over the top [height] of it: a page's
/// backdrop, which stays put while the page scrolls over it, so the balance
/// and the actions sit straight on it with no card around them and the
/// header lies on it too. Its colours come
/// from the palette ([SceneSpec]); everything that text can fall on is
/// held dark (or, on a light palette, pale) enough for the page's type.
class HomeScene extends StatelessWidget {
  const HomeScene({
    super.key,
    required this.child,
    required this.light,
    required this.lightAt,
    required this.height,
    this.lightRadius = 70,
  });

  /// How much of the top of the page the scene covers; it settles into the
  /// page by its foot.
  final double height;

  final Widget child;
  final SceneLight light;

  /// Where the light is: its distance in from the right edge and down from
  /// the top, so it stays put beside the balance at any width.
  final Offset lightAt;

  /// The eclipse's radius.
  final double lightRadius;

  @override
  Widget build(BuildContext context) {
    final page = Theme.of(context).scaffoldBackgroundColor;
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: height,
          child: ExcludeSemantics(
            child: RepaintBoundary(
              child: CustomPaint(
                key: const Key('home-scene'),
                painter: ScenePainter(
                  spec: ArgusColors.sceneOf(context),
                  page: page,
                  light: light,
                  lightAt: lightAt,
                  lightRadius: lightRadius,
                  dark: Theme.of(context).brightness == Brightness.dark,
                ),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class ScenePainter extends CustomPainter {
  ScenePainter({
    required this.spec,
    required this.page,
    required this.light,
    required this.lightAt,
    required this.lightRadius,
    required this.dark,
  });

  final SceneSpec spec;
  final Color page;
  final SceneLight light;
  final Offset lightAt;
  final double lightRadius;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final w = size.width;
    final h = size.height;
    final centre = Offset(w - lightAt.dx, lightAt.dy);
    final lightAlign = Alignment((centre.dx / w) * 2 - 1, (centre.dy / h) * 2 - 1);

    // The sky, settling into the page by the scene's foot.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [spec.sky, Color.lerp(spec.sky, page, 0.55)!, page],
          stops: const [0, 0.5, 1],
        ).createShader(rect),
    );

    // The accent's haze, widest round the light.
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.scale(1, 0.85);
    final haze = Rect.fromCircle(center: Offset.zero, radius: w * 0.95);
    canvas.drawCircle(
      Offset.zero,
      w * 0.95,
      Paint()
        ..shader = RadialGradient(
          colors: [spec.haze, spec.haze.withValues(alpha: spec.haze.a * 0.45), spec.haze.withValues(alpha: 0)],
          stops: const [0, 0.45, 1],
        ).createShader(haze),
    );
    canvas.restore();

    if (light == SceneLight.eclipse) _eclipse(canvas, centre, lightRadius);

    // The range, far to near. The far crests stand under the light, paler;
    // the main range falls from them to the lower left; a near ridge, all
    // but the page, closes the foot. Light runs along each crest, bright
    // under the light and gone by the far side.
    final ranges = light == SceneLight.eclipse ? _overviewRange : _walletRange;
    for (final (i, range) in ranges.indexed) {
      final crest = range.crest(size);
      final fill = Path.from(crest)
        ..lineTo(w, h)
        ..lineTo(0, h)
        ..close();
      final colour = spec.ridges[i];
      final bounds = fill.getBounds();
      canvas.drawPath(
        fill,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [colour, Color.lerp(colour, page, 0.5)!, page],
            stops: const [0, 0.55, 1],
          ).createShader(bounds),
      );
      final strength = range.rim;
      if (strength == 0) continue;
      canvas.drawPath(
        fill,
        Paint()
          ..shader = RadialGradient(
            center: lightAlign,
            radius: 0.75,
            colors: [spec.lit.withValues(alpha: spec.lit.a * strength), spec.lit.withValues(alpha: 0)],
          ).createShader(rect),
      );
      canvas.drawPath(
        crest,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..strokeJoin = StrokeJoin.round
          ..shader = RadialGradient(
            center: lightAlign,
            radius: 0.6,
            colors: [
              spec.rimLight.withValues(alpha: strength),
              spec.rimLight.withValues(alpha: strength * 0.35),
              spec.rimLight.withValues(alpha: 0),
            ],
            stops: const [0, 0.4, 1],
          ).createShader(rect),
      );
      // A softer bloom along the brightest part of the crest.
      canvas.drawPath(
        crest,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)
          ..shader = RadialGradient(
            center: lightAlign,
            radius: 0.55,
            colors: [spec.glow.withValues(alpha: strength * 0.35), spec.glow.withValues(alpha: 0)],
          ).createShader(rect),
      );
    }

    // A faint grain, so the dark reads as air rather than flat fill.
    final grain = Paint()
      ..color = (dark ? Colors.white : Colors.black).withValues(alpha: 0.03)
      ..strokeWidth = 0.8;
    final random = math.Random(42);
    canvas.drawPoints(
      ui.PointMode.points,
      [for (var i = 0; i < (w * h / 240).round(); i++) Offset(random.nextDouble() * w, random.nextDouble() * h)],
      grain,
    );

    // The foot of the scene is the page itself.
    final foot = Rect.fromLTWH(0, h * 0.7, w, h * 0.3);
    canvas.drawRect(
      foot,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [page.withValues(alpha: 0), page],
        ).createShader(foot),
    );
  }

  /// A dark disc whose rim burns brightest along its upper right, with a
  /// corona round it. Nothing is set this close to it, so it may be as
  /// bright as the accent goes.
  void _eclipse(Canvas canvas, Offset c, double r) {
    final disc = Rect.fromCircle(center: c, radius: r);
    // The corona: the accent, close round the disc.
    final corona = Rect.fromCircle(center: c, radius: r * 2.1);
    canvas.drawCircle(
      c,
      r * 2.1,
      Paint()
        ..shader = RadialGradient(
          colors: [spec.glow.withValues(alpha: 0.32), spec.glow.withValues(alpha: 0.10), spec.glow.withValues(alpha: 0)],
          stops: const [0.45, 0.62, 1],
        ).createShader(corona),
    );
    canvas.drawCircle(c, r, Paint()..color = Color.lerp(spec.sky, page, 0.12)!);
    // Brightest from the top round to the right, gone by the lower left.
    Shader sweep(Color colour, double peak) => SweepGradient(
          transform: const GradientRotation(-math.pi * 0.62),
          colors: [
            colour.withValues(alpha: 0),
            colour.withValues(alpha: peak * 0.6),
            colour.withValues(alpha: peak),
            colour.withValues(alpha: peak),
            colour.withValues(alpha: peak * 0.4),
            colour.withValues(alpha: 0),
            colour.withValues(alpha: 0),
          ],
          stops: const [0, 0.1, 0.22, 0.42, 0.55, 0.68, 1],
        ).createShader(disc);
    canvas.drawCircle(
      c,
      r + 3,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 16
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12)
        ..shader = sweep(spec.glow, 0.9),
    );
    canvas.drawCircle(
      c,
      r + 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5)
        ..shader = sweep(spec.glow, 1),
    );
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..shader = sweep(spec.rimLight, 1),
    );
  }

  @override
  bool shouldRepaint(ScenePainter old) =>
      old.spec != spec ||
      old.page != page ||
      old.light != light ||
      old.lightAt != lightAt ||
      old.lightRadius != lightRadius ||
      old.dark != dark;
}

/// The overview's range: a far wall of peaks under the eclipse, the main
/// range falling from a tall summit to the lower left, a near ridge at the
/// foot.
const _overviewRange = [
  _Range(seed: 7, rim: 0.6, rough: 0.07, points: [
    (0.0, 0.66), (0.18, 0.60), (0.34, 0.55), (0.46, 0.50), (0.54, 0.45), (0.58, 0.47), (0.64, 0.40),
    (0.69, 0.43), (0.74, 0.35), (0.78, 0.38), (0.83, 0.33), (0.88, 0.37), (0.94, 0.34), (1.0, 0.38),
  ]),
  _Range(seed: 3, rim: 0.95, rough: 0.06, points: [
    (0.0, 0.94), (0.12, 0.86), (0.26, 0.78), (0.38, 0.71), (0.48, 0.64), (0.55, 0.61), (0.60, 0.55),
    (0.64, 0.57), (0.70, 0.48), (0.73, 0.51), (0.78, 0.45), (0.83, 0.50), (0.89, 0.47), (0.95, 0.53), (1.0, 0.51),
  ]),
  _Range(seed: 11, rim: 0.2, rough: 0.05, points: [
    (0.0, 0.88), (0.12, 0.84), (0.26, 0.89), (0.42, 0.86), (0.60, 0.91), (0.78, 0.83), (0.92, 0.80), (1.0, 0.76),
  ]),
];

/// A wallet's range: low behind the pills and actions, rising to the right
/// under the medallion.
const _walletRange = [
  _Range(seed: 5, rim: 0.5, rough: 0.07, points: [
    (0.0, 0.80), (0.25, 0.74), (0.45, 0.68), (0.58, 0.60), (0.66, 0.62), (0.74, 0.53), (0.80, 0.56),
    (0.87, 0.48), (0.93, 0.52), (1.0, 0.46),
  ]),
  _Range(seed: 9, rim: 0.7, rough: 0.06, points: [
    (0.0, 0.93), (0.2, 0.88), (0.42, 0.82), (0.58, 0.75), (0.68, 0.70), (0.76, 0.72), (0.86, 0.63), (1.0, 0.66),
  ]),
  _Range(seed: 2, rim: 0.0, rough: 0.05, points: [
    (0.0, 0.95), (0.3, 0.91), (0.55, 0.95), (0.8, 0.88), (1.0, 0.86),
  ]),
];

/// One crest line, through hand-placed [points] (fractions of the scene,
/// left to right) with detail added between them by midpoint displacement:
/// each half of a span moved up or down by a share of its length, [rough],
/// smaller at every level, the same every time for its [seed].
class _Range {
  const _Range({required this.seed, required this.rim, required this.rough, required this.points});

  final int seed;

  /// How strongly its crest catches the light; 0 for none.
  final double rim;
  final double rough;
  final List<(double, double)> points;

  Path crest(Size size) {
    final random = math.Random(seed);
    var line = [for (final (x, y) in points) Offset(x * size.width, y * size.height)];
    var amount = rough;
    for (var level = 0; level < 4; level++) {
      final next = <Offset>[line.first];
      for (var i = 1; i < line.length; i++) {
        final a = line[i - 1];
        final b = line[i];
        final span = (b - a).distance;
        // Mostly downward: crests stay sharp, the dips between them shallow.
        final shift = (random.nextDouble() - 0.35) * span * amount;
        final mid = Offset((a.dx + b.dx) / 2 + (random.nextDouble() - 0.5) * span * 0.2, (a.dy + b.dy) / 2 + shift);
        next
          ..add(mid)
          ..add(b);
      }
      line = next;
      amount *= 0.62;
    }
    return Path()..addPolygon(line, false);
  }
}

/// A wallet's medallion: its initial on a dark disc inside rings of soft
/// glow, set beside its balance. Decorative: the page's title names the
/// wallet.
class WalletMedallion extends StatelessWidget {
  const WalletMedallion({super.key, required this.letter, this.size = 132});

  final String letter;
  final double size;

  @override
  Widget build(BuildContext context) {
    final spec = ArgusColors.sceneOf(context);
    final page = Theme.of(context).scaffoldBackgroundColor;
    final ink = Theme.of(context).colorScheme.onSurface;
    return ExcludeSemantics(
      child: SizedBox.square(
        key: const Key('wallet-medallion'),
        dimension: size,
        child: CustomPaint(
          painter: _MedallionPainter(spec: spec, page: page),
          child: Center(
            child: Text(
              letter,
              textScaler: TextScaler.noScaling,
              style: TextStyle(fontFamily: 'Newsreader', fontSize: size * 0.26, fontWeight: FontWeight.w500, height: 1, color: ink),
            ),
          ),
        ),
      ),
    );
  }
}

class _MedallionPainter extends CustomPainter {
  _MedallionPainter({required this.spec, required this.page});

  final SceneSpec spec;
  final Color page;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width * 0.3;
    final outer = Rect.fromCircle(center: c, radius: size.width / 2);
    // A soft glow behind it all.
    canvas.drawCircle(
      c,
      size.width / 2,
      Paint()
        ..shader = RadialGradient(
          colors: [spec.glow.withValues(alpha: 0.22), spec.glow.withValues(alpha: 0.08), spec.glow.withValues(alpha: 0)],
          stops: const [0.5, 0.72, 1],
        ).createShader(outer),
    );
    // Rings, fading outward.
    for (final (k, alpha) in [(1.62, 0.08), (1.36, 0.16)]) {
      canvas.drawCircle(
        c,
        r * k,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = spec.glow.withValues(alpha: alpha),
      );
    }
    canvas.drawCircle(
      c,
      r * 1.1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8)
        ..color = spec.glow.withValues(alpha: 0.18),
    );
    final disc = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.3, -0.4),
          colors: [Color.lerp(page, const Color(0xFF6E8A80), 0.2)!, Color.lerp(page, const Color(0xFF6E8A80), 0.08)!],
        ).createShader(disc),
    );
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = spec.glow.withValues(alpha: 0.4),
    );
  }

  @override
  bool shouldRepaint(_MedallionPainter old) => old.spec != spec || old.page != page;
}
