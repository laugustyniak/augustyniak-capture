import 'dart:math' as math;

// `ValueListenable` lives in foundation; material re-exports only a subset.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import 'focus_timer_controller.dart';

/// The countdown itself: a ring that empties as the session runs, the remaining
/// time in the middle, and a sweep that keeps moving while it counts.
///
/// It subscribes to the controller's `remaining` notifier rather than taking a
/// `Duration`, so a tick repaints this widget and nothing else — the six tabs
/// in the shell's `IndexedStack` are not rebuilt four times a second to move
/// one arc.
///
/// **The sweep runs only while the session does.** A forever-repeating
/// animation is exactly what makes `pumpAndSettle` hang (see `PulseDot` and
/// `ScanLine` in the UI kit), so an idle, paused or finished dial schedules no
/// frames at all and a widget test that never starts a session can settle
/// normally.
class CountdownDial extends StatefulWidget {
  CountdownDial({
    super.key,
    required this.remaining,
    required this.total,
    required this.state,
    this.size = 236,
  });

  final ValueListenable<Duration> remaining;

  /// The length of the session on screen — the denominator of the ring. Comes
  /// from `sessionDuration`, not the configured length, so a session that was
  /// extended mid-run keeps a ring that means "this much of *this* session".
  final Duration total;

  final FocusTimerState state;
  final double size;

  @override
  State<CountdownDial> createState() => _CountdownDialState();
}

class _CountdownDialState extends State<CountdownDial>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 7),
  );

  @override
  void initState() {
    super.initState();
    _syncSweep();
  }

  @override
  void didUpdateWidget(covariant CountdownDial oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.state != oldWidget.state) _syncSweep();
  }

  void _syncSweep() {
    if (widget.state == FocusTimerState.running) {
      if (!_sweep.isAnimating) _sweep.repeat();
    } else {
      _sweep.stop();
      _sweep.value = 0;
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  /// Running is the accent, paused is amber (the app's "attention, not an
  /// error" colour) and finished is green. Idle keeps the accent so the ring a
  /// session starts from is the ring it runs in — a grey dial that turns blue
  /// on START reads as two different controls.
  Color get _color => switch (widget.state) {
    FocusTimerState.running => Console.accent,
    FocusTimerState.paused => Console.amber,
    FocusTimerState.finished => Console.green,
    FocusTimerState.idle => Console.accent,
  };

  String get _label => switch (widget.state) {
    FocusTimerState.running => 'FOCUS',
    FocusTimerState.paused => 'PAUSED',
    FocusTimerState.finished => 'DONE',
    FocusTimerState.idle => 'READY',
  };

  @override
  Widget build(BuildContext context) {
    final Color color = _color;

    return SizedBox.square(
      dimension: widget.size,
      child: ValueListenableBuilder<Duration>(
        valueListenable: widget.remaining,
        builder: (BuildContext context, Duration remaining, Widget? _) {
          final int total = widget.total.inMilliseconds;
          final double progress = total <= 0
              ? 0
              : (remaining.inMilliseconds / total).clamp(0.0, 1.0);

          return Stack(
            alignment: Alignment.center,
            children: <Widget>[
              // Smooths the 250 ms tick into continuous motion. Linear, and
              // exactly one tick long: any easing would make the arc speed up
              // and slow down four times a second, and anything longer would
              // leave it lagging behind the digits beside it.
              TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: progress, end: progress),
                duration: FocusTimerController.tickInterval,
                curve: Curves.linear,
                builder: (BuildContext context, double value, Widget? _) {
                  return AnimatedBuilder(
                    animation: _sweep,
                    builder: (BuildContext context, Widget? _) {
                      return CustomPaint(
                        size: Size.square(widget.size),
                        painter: _DialPainter(
                          progress: value,
                          spin: _sweep.value,
                          color: color,
                          track: Console.track,
                          tick: Console.border,
                          running: widget.state == FocusTimerState.running,
                        ),
                      );
                    },
                  );
                },
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    formatCountdown(remaining),
                    style: TextStyle(
                      fontFamily: ConsoleFont.mono,
                      // Tabular by construction: JetBrains Mono is monospaced,
                      // so the digits do not shuffle the layout as they change.
                      fontSize: widget.size * .195,
                      fontWeight: FontWeight.w600,
                      height: 1,
                      color: Console.text,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (widget.state == FocusTimerState.running) ...<Widget>[
                        PulseDot(color: color, size: 6),
                        const SizedBox(width: 7),
                      ],
                      Text(
                        _label,
                        style: ConsoleText.pill.copyWith(
                          fontSize: 11,
                          letterSpacing: 1.6,
                          fontWeight: FontWeight.w700,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Paints the dial: a clock face of ticks, the remaining arc over it, a head at
/// the arc's tip and — while running — a faint sweep circling the whole ring.
class _DialPainter extends CustomPainter {
  _DialPainter({
    required this.progress,
    required this.spin,
    required this.color,
    required this.track,
    required this.tick,
    required this.running,
  });

  /// `1` at the start of a session, `0` at the end.
  final double progress;

  /// `0`–`1` around the circle, the sweep's position.
  final double spin;

  final Color color;
  final Color track;
  final Color tick;
  final bool running;

  static const double _stroke = 10;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset centre = size.center(Offset.zero);
    final double radius = (size.shortestSide - _stroke) / 2;
    final Rect ring = Rect.fromCircle(center: centre, radius: radius);
    // Twelve o'clock, the only place a clock can start.
    const double start = -math.pi / 2;

    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..color = track,
    );

    _paintTicks(canvas, centre, radius);

    if (running) {
      // A 50° arc travelling round the whole ring once every seven seconds.
      // It carries no information — the arc below already says how much is
      // left — and exists so a running session is distinguishable from a paused
      // one at a glance, from across a desk, without reading digits.
      canvas.drawArc(
        ring,
        start + spin * 2 * math.pi,
        50 * math.pi / 180,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _stroke
          ..strokeCap = StrokeCap.round
          ..shader = SweepGradient(
            startAngle: 0,
            endAngle: 2 * math.pi,
            transform: GradientRotation(start + spin * 2 * math.pi),
            colors: <Color>[
              color.withValues(alpha: 0),
              color.withValues(alpha: .28),
              color.withValues(alpha: 0),
            ],
            stops: const <double>[0, .07, .14],
          ).createShader(ring),
      );
    }

    if (progress <= 0) return;

    // Clockwise from twelve, and it is the time that is **left** — so the arc
    // shrinks and its head travels backwards towards twelve as the session
    // drains, which is the direction the ticks below dim in. Drawing the time
    // *spent* instead would grow a bar while the digits beside it counted down,
    // and the two would read as contradicting each other.
    final double swept = progress * 2 * math.pi;
    canvas.drawArc(
      ring,
      start,
      swept,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..strokeCap = StrokeCap.round
        ..color = color,
    );

    // The head, where the countdown currently is. Halo first, so the solid dot
    // sits on top of it.
    final double angle = start + swept;
    final Offset head =
        centre + Offset(math.cos(angle), math.sin(angle)) * radius;
    canvas.drawCircle(
      head,
      _stroke,
      Paint()..color = color.withValues(alpha: .22),
    );
    canvas.drawCircle(head, _stroke / 2.6, Paint()..color = color);
  }

  /// Sixty marks, one per minute of a clock face, inside the ring. Purely a
  /// clock affordance — they do not track the session length, which can be
  /// anything from one minute to four hours.
  void _paintTicks(Canvas canvas, Offset centre, double radius) {
    final Paint paint = Paint()
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    final double outer = radius - _stroke;
    for (int index = 0; index < 60; index++) {
      final bool quarter = index % 5 == 0;
      final double angle = -math.pi / 2 + index * math.pi / 30;
      final Offset unit = Offset(math.cos(angle), math.sin(angle));
      // A tick is lit while the countdown has not passed it yet, so the face
      // dims from twelve as the session is spent.
      final bool spent = index / 60 > progress;
      paint.color = spent ? tick : color.withValues(alpha: quarter ? .55 : .3);
      canvas.drawLine(
        centre + unit * (outer - (quarter ? 9 : 5)),
        centre + unit * outer,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DialPainter old) =>
      old.progress != progress ||
      old.spin != spin ||
      old.color != color ||
      old.track != track ||
      old.tick != tick ||
      old.running != running;
}
