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

    // The range, far to near: pale, high crests under the light, then
    // nearer and darker ridges falling to the lower left, the nearest all
    // but the page. Each is a mass with light only on its crest's faces
    // that turn toward the light, and a few lit gullies running down from
    // its peaks.
    final ranges = light == SceneLight.eclipse ? _overviewRange : _walletRange;
    final first = spec.ridges.first;
    final last = spec.ridges.last;
    for (final (i, range) in ranges.indexed) {
      final points = range.crest(size);
      final crest = Path()..addPolygon(points, false);
      final fill = Path.from(crest)
        ..lineTo(w, h)
        ..lineTo(0, h)
        ..close();
      // Far to near, from the palest ridge colour to the darkest.
      final colour = Color.lerp(first, last, ranges.length == 1 ? 0 : i / (ranges.length - 1))!;
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
      // The slope nearest the light, washed with it.
      canvas.drawPath(
        fill,
        Paint()
          ..shader = RadialGradient(
            center: lightAlign,
            radius: 0.7,
            colors: [spec.lit.withValues(alpha: spec.lit.a * strength), spec.lit.withValues(alpha: 0)],
          ).createShader(rect),
      );
      _gullies(canvas, points, colour, strength, centre, w, range.seed);
      _rim(canvas, points, strength, centre, w);
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

  /// How lit a point is: full beside the light, fading over most of the
  /// scene's width.
  double _nearness(Offset p, Offset light, double w) => (1 - (p - light).distance / (w * 0.95)).clamp(0.0, 1.0);

  /// Light along a crest, segment by segment: bright where a face turns
  /// toward the light and near it, absent where it turns away, so the
  /// crest reads as rock catching a low light rather than a drawn line.
  void _rim(Canvas canvas, List<Offset> points, double strength, Offset light, double w) {
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 0.9;
    final bloom = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 4
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1];
      final b = points[i];
      final d = b - a;
      if (d.distance == 0) continue;
      // The face's outward normal (up, for a crest), against the way to
      // the light.
      final normal = Offset(d.dy, -d.dx) / d.distance;
      final toLight = light - Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
      final facing = ((normal.dx * toLight.dx + normal.dy * toLight.dy) / toLight.distance).clamp(0.0, 1.0);
      final near = _nearness(b, light, w);
      final alpha = 0.6 * strength * facing * (0.2 + 0.8 * near) * near;
      if (alpha < 0.02) continue;
      canvas.drawLine(a, b, line..color = spec.rimLight.withValues(alpha: alpha.clamp(0.0, 1.0)));
      if (near > 0.6) canvas.drawLine(a, b, bloom..color = spec.glow.withValues(alpha: alpha * 0.3));
    }
  }

  /// A few lit gullies and ribs down the faces below the higher peaks:
  /// short strokes from a peak, a shade off the ridge's own colour, the
  /// texture of rock.
  void _gullies(Canvas canvas, List<Offset> points, Color colour, double strength, Offset light, double w, int seed) {
    final random = math.Random(seed * 31 + 5);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.4
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.8);
    for (var i = 2; i < points.length - 2; i++) {
      final p = points[i];
      // A peak: higher than both neighbours.
      if (p.dy > points[i - 1].dy || p.dy > points[i + 1].dy) continue;
      final near = _nearness(p, light, w);
      if (near < 0.15) continue;
      for (var k = 0; k < 3; k++) {
        final length = 10 + random.nextDouble() * 34;
        final lean = (random.nextDouble() - 0.5) * 0.9;
        final path = Path()..moveTo(p.dx, p.dy + 1);
        var x = p.dx;
        var y = p.dy + 1;
        for (var step = 0; step < 4; step++) {
          x += lean * length / 4 + (random.nextDouble() - 0.5) * 3;
          y += length / 4;
          path.lineTo(x, y);
        }
        // Only the faces turned to the light show; the others are already
        // in shadow.
        if (lean <= 0) continue;
        canvas.drawPath(path, paint..color = spec.rimLight.withValues(alpha: 0.12 * strength * near));
      }
    }
  }

  /// A thin crescent of light on the limb that faces away from the range,
  /// with a glow that falls off fast. The disc itself is barely darker than
  /// the sky: the eclipse is mostly its edge.
  void _eclipse(Canvas canvas, Offset c, double r) {
    final disc = Rect.fromCircle(center: c, radius: r);
    // Bright from the top round to the right, gone by the lower left.
    Shader sweep(Color colour, double peak) => SweepGradient(
          transform: const GradientRotation(-math.pi * 0.66),
          colors: [
            colour.withValues(alpha: 0),
            colour.withValues(alpha: peak * 0.5),
            colour.withValues(alpha: peak),
            colour.withValues(alpha: peak),
            colour.withValues(alpha: peak * 0.3),
            colour.withValues(alpha: 0),
            colour.withValues(alpha: 0),
          ],
          stops: const [0, 0.1, 0.22, 0.4, 0.52, 0.64, 1],
        ).createShader(disc);
    // The glow: wide and faint, then close and strong.
    canvas.drawCircle(
      c,
      r + 6,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 30
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22)
        ..shader = sweep(spec.glow, 0.75),
    );
    canvas.drawCircle(
      c,
      r + 1.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5)
        ..shader = sweep(spec.glow, 0.9),
    );
    // The disc, a breath darker than the sky round it, over the glow's
    // inner spill.
    canvas.drawCircle(c, r - 1, Paint()..color = Color.lerp(spec.sky, page, 0.2)!.withValues(alpha: 0.4));
    // The limb itself.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..shader = sweep(Color.lerp(spec.rimLight, Colors.white, 0.35)!, 1),
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

/// The overview's range, far to near: a wall of crests under the eclipse,
/// two ranges falling from tall summits to the lower left, and two low
/// ridges closing the foot.
const _overviewRange = [
  _Range(seed: 7, rim: 0.55, rough: 0.12, points: [
    (0.0, 0.62), (0.16, 0.57), (0.30, 0.52), (0.42, 0.48), (0.50, 0.44), (0.56, 0.46), (0.61, 0.39),
    (0.66, 0.42), (0.71, 0.34), (0.75, 0.37), (0.80, 0.31), (0.85, 0.35), (0.90, 0.32), (0.95, 0.36), (1.0, 0.34),
  ]),
  _Range(seed: 13, rim: 0.8, rough: 0.12, points: [
    (0.0, 0.78), (0.14, 0.71), (0.28, 0.64), (0.40, 0.58), (0.50, 0.54), (0.57, 0.48), (0.62, 0.51),
    (0.68, 0.43), (0.72, 0.46), (0.77, 0.40), (0.83, 0.45), (0.89, 0.41), (0.95, 0.46), (1.0, 0.44),
  ]),
  _Range(seed: 3, rim: 1.0, rough: 0.11, points: [
    (0.0, 0.94), (0.12, 0.86), (0.25, 0.78), (0.36, 0.71), (0.46, 0.65), (0.53, 0.61), (0.58, 0.56),
    (0.63, 0.59), (0.69, 0.51), (0.73, 0.54), (0.79, 0.49), (0.85, 0.54), (0.91, 0.51), (1.0, 0.56),
  ]),
  _Range(seed: 19, rim: 0.45, rough: 0.09, points: [
    (0.0, 0.84), (0.10, 0.80), (0.22, 0.85), (0.34, 0.80), (0.46, 0.84), (0.60, 0.78), (0.74, 0.82),
    (0.86, 0.74), (1.0, 0.70),
  ]),
  _Range(seed: 11, rim: 0.0, rough: 0.07, points: [
    (0.0, 0.90), (0.15, 0.87), (0.32, 0.92), (0.50, 0.89), (0.68, 0.93), (0.84, 0.86), (1.0, 0.84),
  ]),
];

/// A wallet's range: low behind the pills and actions, rising to the right
/// under the medallion.
const _walletRange = [
  _Range(seed: 5, rim: 0.5, rough: 0.12, points: [
    (0.0, 0.78), (0.22, 0.72), (0.42, 0.66), (0.55, 0.59), (0.62, 0.61), (0.70, 0.52), (0.76, 0.55),
    (0.83, 0.47), (0.89, 0.51), (0.95, 0.45), (1.0, 0.48),
  ]),
  _Range(seed: 17, rim: 0.7, rough: 0.11, points: [
    (0.0, 0.88), (0.2, 0.83), (0.38, 0.77), (0.52, 0.71), (0.62, 0.66), (0.70, 0.69), (0.80, 0.60),
    (0.88, 0.63), (1.0, 0.58),
  ]),
  _Range(seed: 9, rim: 0.35, rough: 0.09, points: [
    (0.0, 0.93), (0.2, 0.89), (0.42, 0.85), (0.58, 0.80), (0.70, 0.76), (0.82, 0.79), (0.90, 0.71), (1.0, 0.74),
  ]),
  _Range(seed: 2, rim: 0.0, rough: 0.06, points: [
    (0.0, 0.96), (0.3, 0.92), (0.55, 0.96), (0.8, 0.89), (1.0, 0.88),
  ]),
];

/// One crest line, through hand-placed [points] (fractions of the scene,
/// left to right) with craggy detail added between them by midpoint
/// displacement: each half of a span moved by a share of its length,
/// [rough], smaller at every level, mostly downward so peaks stay sharp,
/// the same every time for its [seed].
class _Range {
  const _Range({required this.seed, required this.rim, required this.rough, required this.points});

  final int seed;

  /// How strongly its crest catches the light; 0 for none.
  final double rim;
  final double rough;
  final List<(double, double)> points;

  List<Offset> crest(Size size) {
    final random = math.Random(seed);
    var line = [for (final (x, y) in points) Offset(x * size.width, y * size.height)];
    var amount = rough;
    for (var level = 0; level < 5; level++) {
      final next = <Offset>[line.first];
      for (var i = 1; i < line.length; i++) {
        final a = line[i - 1];
        final b = line[i];
        final span = (b - a).distance;
        final shift = (random.nextDouble() - 0.38) * span * amount;
        final mid = Offset((a.dx + b.dx) / 2 + (random.nextDouble() - 0.5) * span * 0.25, (a.dy + b.dy) / 2 + shift);
        next
          ..add(mid)
          ..add(b);
      }
      line = next;
      amount *= 0.68;
    }
    return line;
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
