import 'dart:math' as math;

import 'package:flutter/rendering.dart';

import 'orb_preset.dart';

/// Core orb, spectrum spokes, three counter-rotating dashed rings with
/// orbiting particles, a radar sweep and expanding pulse waves, over a faint
/// grid. Everything is a pure function of [seconds] and [preset]: time is
/// `t = seconds * speed / period` and is never wrapped, so there is no loop
/// seam, and a frozen [seconds] gives a still frame instead of an empty box.
class OrbPainter extends CustomPainter {
  OrbPainter({required this.seconds, required this.preset});

  /// Elapsed real time, unbounded.
  final double seconds;
  final OrbPreset preset;

  static const double _tau = math.pi * 2;

  @override
  void paint(Canvas canvas, Size size) {
    final OrbTuning k = preset.tuning;
    final OrbLayers on = preset.layers;
    final Color accent = preset.palette.accent;
    final Color violet = preset.palette.violet;
    final Color pink = preset.palette.pink;
    final Color backdrop = preset.palette.backdrop;

    final double t = seconds * k.speed / k.period;
    final Offset c = Offset(size.width / 2, size.height * k.centerY);
    final double r =
        math.min(size.width, size.height * 0.88) / 2 * k.radiusScale;

    // Opaque fill first, so the picture is complete without a host frame.
    canvas.drawRect(Offset.zero & size, Paint()..color = backdrop);

    if (on.grid) _paintGrid(canvas, size, t);

    // Backdrop glow.
    if (on.core) {
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[
              accent.withValues(alpha: 0.20),
              backdrop.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }

    // Expanding pulse waves: three phases, each fades as it grows.
    if (on.pulses) {
      for (int i = 0; i < 3; i++) {
        final double p = (t * k.pulse + i / 3) % 1;
        canvas.drawCircle(
          c,
          r * (0.22 + 0.78 * p),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2 * (1 - p) + 0.5
            ..color = accent.withValues(alpha: 0.45 * (1 - p)),
        );
      }
    }

    // Spectrum spokes around the core.
    if (on.spokes) {
      final int spokes = k.spokeCount;
      final double inner = r * 0.30;
      final Paint spoke = Paint()
        ..strokeWidth = math.max(2, r * 0.012)
        ..strokeCap = StrokeCap.round;
      for (int i = 0; i < spokes; i++) {
        final double a = i / spokes * _tau;
        final double level =
            0.5 +
            0.5 *
                math.sin(a * 5 + t * _tau * k.spokeFast) *
                math.cos(a * 3 - t * _tau * k.spokeSlow);
        final double len = r * (0.04 + 0.16 * level.abs());
        spoke.color = Color.lerp(
          accent,
          violet,
          i / spokes,
        )!.withValues(alpha: 0.35 + 0.55 * level.abs());
        canvas.drawLine(
          c + Offset(math.cos(a), math.sin(a)) * inner,
          c + Offset(math.cos(a), math.sin(a)) * (inner + len),
          spoke,
        );
      }
    }

    // Counter-rotating dashed rings, each carrying orbiting particles.
    if (on.rings) {
      final List<(double, double, Color, int)> rings =
          <(double, double, Color, int)>[
            (0.62, k.rings[0], accent, k.dots[0]),
            (0.78, k.rings[1], violet, k.dots[1]),
            (0.94, k.rings[2], pink, k.dots[2]),
          ];
      for (final (double scale, double speed, Color color, int dots) in rings) {
        final double radius = r * scale;
        final double spin = t * _tau * speed;
        final Paint ring = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = color.withValues(alpha: 0.55);
        const int dashes = 36;
        for (int i = 0; i < dashes; i += 2) {
          canvas.drawArc(
            Rect.fromCircle(center: c, radius: radius),
            spin + i / dashes * _tau,
            _tau / dashes * 0.9,
            false,
            ring,
          );
        }
        for (int i = 0; i < dots; i++) {
          final double a = spin * 2 + i / dots * _tau;
          final Offset at = c + Offset(math.cos(a), math.sin(a)) * radius;
          // Short comet tail behind each particle.
          for (int j = 1; j <= 5; j++) {
            final double ta = a - j * 0.045 * speed.sign;
            canvas.drawCircle(
              c + Offset(math.cos(ta), math.sin(ta)) * radius,
              3.2 - j * 0.5,
              Paint()..color = color.withValues(alpha: 0.5 - j * 0.09),
            );
          }
          canvas.drawCircle(at, 4, Paint()..color = color);
          canvas.drawCircle(
            at,
            9,
            Paint()
              ..color = color.withValues(alpha: 0.25)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
          );
        }
      }
    }

    // Radar sweep.
    if (on.sweep) {
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(t * _tau * k.sweep);
      canvas.drawCircle(
        Offset.zero,
        r * 0.94,
        Paint()
          ..shader =
              SweepGradient(
                colors: <Color>[
                  accent.withValues(alpha: 0),
                  accent.withValues(alpha: 0.30),
                ],
                stops: const <double>[0.78, 1],
              ).createShader(
                Rect.fromCircle(center: Offset.zero, radius: r * 0.94),
              ),
      );
      canvas.restore();
    }

    // Breathing core.
    if (on.core) {
      final double breath = 0.5 + 0.5 * math.sin(t * _tau * k.breath);
      canvas.drawCircle(
        c,
        r * (0.20 + 0.03 * breath),
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[
              Color.lerp(accent, const Color(0xFFFFFFFF), 0.55)!,
              accent,
              violet.withValues(alpha: 0.6),
            ],
            stops: const <double>[0, 0.55, 1],
          ).createShader(Rect.fromCircle(center: c, radius: r * 0.24)),
      );
      canvas.drawCircle(
        c,
        r * 0.26,
        Paint()
          ..color = accent.withValues(alpha: 0.30 + 0.25 * breath)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
      );
    }
  }

  /// A faint grid that scrolls slowly upward, fading out toward the edges.
  void _paintGrid(Canvas canvas, Size size, double t) {
    final double step = preset.tuning.gridStep;
    final Color backdrop = preset.palette.backdrop;
    final double shift = (t * preset.tuning.gridScroll * step) % step;
    final Paint line = Paint()
      ..strokeWidth = 1
      ..color = preset.palette.grid.withValues(alpha: 0.35);
    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    for (double y = -shift; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          colors: <Color>[backdrop.withValues(alpha: 0), backdrop],
          stops: const <double>[0.35, 1],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(OrbPainter old) =>
      old.seconds != seconds || old.preset != preset;
}
