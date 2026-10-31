import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/capture_type.dart';
import '../domain/recording.dart';
import 'card_parts.dart';

/// The large "something is happening" scene a capture shows while it has
/// nothing to read yet: no transcript (queued, transcribing, OCR) or no rewrite
/// (the enrichment model is working on a capture that has no summary).
///
/// It replaces the small [ProcessingStrip] there, because a one-line strip is
/// easy to miss at the exact moment the user has just stopped talking and
/// wants to know the note was taken. Height is at least [minScreenFraction] of
/// the screen; width is the panel's.
///
/// The animation repeats forever: a test pumping a screen with one of these on
/// it must pump explicit frames, never `pumpAndSettle`. It stands still when
/// the platform asks for reduced motion.
class ProcessingHero extends StatefulWidget {
  ProcessingHero({
    super.key,
    required this.enriching,
    this.type = CaptureType.audioRecording,
    this.processingTicker,
  });

  final bool enriching;
  final CaptureType type;

  /// Running time of the current job, or null when there is none to show.
  final ValueListenable<Duration>? processingTicker;

  /// Share of the screen's height the scene occupies, at minimum.
  static const double minScreenFraction = 0.6;

  /// Whether [recording] has nothing to read yet and should show the hero.
  /// [enriching] is true while the model works on it.
  static bool appliesTo(Recording recording, {required bool enriching}) {
    if (enriching) return (recording.summary ?? '').trim().isEmpty;
    return switch (recording.status) {
      RecordingStatus.pendingTranscription || RecordingStatus.transcribing =>
        (recording.transcript ?? '').trim().isEmpty,
      _ => false,
    };
  }

  static const String queuedLabel = 'QUEUED';

  @override
  State<ProcessingHero> createState() => _ProcessingHeroState();
}

class _ProcessingHeroState extends State<ProcessingHero>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
  );
  bool? _reduceMotion;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool reduce = MediaQuery.disableAnimationsOf(context);
    if (reduce == _reduceMotion) return;
    _reduceMotion = reduce;
    if (reduce) {
      _clock.stop();
      _clock.value = 0.18;
    } else {
      _clock.repeat();
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  String get _stage {
    if (widget.enriching) return ProcessingStrip.analyzingLabel;
    return widget.type == CaptureType.image
        ? ProcessingStrip.ocrLabel
        : ProcessingStrip.transcribingLabel;
  }

  String get _caption {
    if (widget.enriching) return 'title · summary · tags';
    return widget.type == CaptureType.image ? 'image → text' : 'speech → text';
  }

  @override
  Widget build(BuildContext context) {
    final double height = math.max(
      360,
      MediaQuery.sizeOf(context).height * ProcessingHero.minScreenFraction,
    );
    final ValueListenable<Duration>? ticker = widget.processingTicker;
    final TextStyle stageStyle = ConsoleText.micro.copyWith(
      color: Console.accent,
      fontSize: 15,
      letterSpacing: 4,
    );
    return Semantics(
      liveRegion: true,
      label: '$_stage in progress',
      child: ExcludeSemantics(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Console.surfaceDeep,
              border: Border.all(color: Console.border),
              borderRadius: BorderRadius.circular(18),
            ),
            child: SizedBox(
              height: height,
              width: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  RepaintBoundary(
                    child: CustomPaint(
                      painter: _HeroPainter(
                        clock: _clock,
                        accent: Console.accent,
                        violet: Console.violet,
                        pink: Console.pink,
                        grid: Console.border,
                        backdrop: Console.surfaceDeep,
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 28,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(_stage, style: stageStyle),
                        const SizedBox(height: 8),
                        if (ticker == null)
                          Text(
                            _caption,
                            style: ConsoleText.micro.copyWith(
                              color: Console.muted,
                            ),
                          )
                        else
                          ValueListenableBuilder<Duration>(
                            valueListenable: ticker,
                            builder:
                                (BuildContext _, Duration elapsed, Widget? _) =>
                                    Text(
                                      '$_caption · ${formatDuration(elapsed)}',
                                      style: ConsoleText.micro.copyWith(
                                        color: Console.muted,
                                      ),
                                    ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Core orb, spectrum spokes, three counter-rotating dashed rings with
/// orbiting particles, a radar sweep and expanding pulse waves, over a faint
/// grid. Everything is a pure function of the clock, so a repaint is cheap and
/// a frozen clock gives a still frame instead of an empty box.
class _HeroPainter extends CustomPainter {
  _HeroPainter({
    required this.clock,
    required this.accent,
    required this.violet,
    required this.pink,
    required this.grid,
    required this.backdrop,
  }) : super(repaint: clock);

  final Animation<double> clock;
  final Color accent;
  final Color violet;
  final Color pink;
  final Color grid;
  final Color backdrop;

  static const double _tau = math.pi * 2;

  @override
  void paint(Canvas canvas, Size size) {
    final double t = clock.value;
    final Offset c = Offset(size.width / 2, size.height * 0.44);
    final double r = math.min(size.width, size.height * 0.88) / 2;

    _paintGrid(canvas, size, t);

    // Backdrop glow.
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

    // Expanding pulse waves: three phases, each fades as it grows.
    for (int i = 0; i < 3; i++) {
      final double p = (t * 3 + i / 3) % 1;
      canvas.drawCircle(
        c,
        r * (0.22 + 0.78 * p),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 * (1 - p) + 0.5
          ..color = accent.withValues(alpha: 0.45 * (1 - p)),
      );
    }

    // Spectrum spokes around the core.
    const int spokes = 72;
    final double inner = r * 0.30;
    final Paint spoke = Paint()
      ..strokeWidth = math.max(2, r * 0.012)
      ..strokeCap = StrokeCap.round;
    for (int i = 0; i < spokes; i++) {
      final double a = i / spokes * _tau;
      final double level =
          0.5 +
          0.5 * math.sin(a * 5 + t * _tau * 4) * math.cos(a * 3 - t * _tau * 2);
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

    // Counter-rotating dashed rings, each carrying orbiting particles.
    final List<(double, double, Color, int)> rings =
        <(double, double, Color, int)>[
          (0.62, 1, accent, 5),
          (0.78, -1.6, violet, 7),
          (0.94, 2.3, pink, 4),
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
        final double a = spin * 1.5 + i / dots * _tau;
        final Offset at = c + Offset(math.cos(a), math.sin(a)) * radius;
        // Short comet tail behind each particle.
        for (int k = 1; k <= 5; k++) {
          final double ta = a - k * 0.045 * speed.sign;
          canvas.drawCircle(
            c + Offset(math.cos(ta), math.sin(ta)) * radius,
            3.2 - k * 0.5,
            Paint()..color = color.withValues(alpha: 0.5 - k * 0.09),
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

    // Radar sweep.
    final double sweep = t * _tau * 2;
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(sweep);
    canvas.drawCircle(
      Offset.zero,
      r * 0.94,
      Paint()
        ..shader = SweepGradient(
          colors: <Color>[
            accent.withValues(alpha: 0),
            accent.withValues(alpha: 0.30),
          ],
          stops: const <double>[0.78, 1],
        ).createShader(Rect.fromCircle(center: Offset.zero, radius: r * 0.94)),
    );
    canvas.restore();

    // Breathing core.
    final double breath = 0.5 + 0.5 * math.sin(t * _tau * 6);
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

  /// A faint grid that scrolls slowly upward, fading out toward the edges.
  void _paintGrid(Canvas canvas, Size size, double t) {
    const double step = 36;
    final double shift = (t * 12 * step) % step;
    final Paint line = Paint()
      ..strokeWidth = 1
      ..color = grid.withValues(alpha: 0.35);
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
  bool shouldRepaint(_HeroPainter old) =>
      old.accent != accent ||
      old.violet != violet ||
      old.pink != pink ||
      old.grid != grid ||
      old.backdrop != backdrop;
}
