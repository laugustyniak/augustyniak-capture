import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'orb_painter.dart';
import 'orb_preset.dart';

/// The orb as a widget: owns a [Ticker], feeds elapsed seconds to an
/// [OrbPainter] inside a [RepaintBoundary], and freezes while [paused].
///
/// [startSeconds] seeds the clock, so a paused scene can show a chosen still
/// frame. [child] is laid over the orb in the same [Stack].
class OrbScene extends StatefulWidget {
  OrbScene({
    super.key,
    required this.preset,
    this.paused = false,
    this.startSeconds = 0,
    this.child,
  });

  final OrbPreset preset;
  final bool paused;
  final double startSeconds;
  final Widget? child;

  @override
  State<OrbScene> createState() => _OrbSceneState();
}

class _OrbSceneState extends State<OrbScene>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  late final ValueNotifier<double> _seconds = ValueNotifier<double>(
    widget.startSeconds,
  );

  /// Seconds accumulated before the running ticker was last started.
  late double _base = widget.startSeconds;

  double get debugSeconds => _seconds.value;

  void _onTick(Duration elapsed) {
    _seconds.value = _base + elapsed.inMicroseconds / 1e6;
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(OrbScene oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.startSeconds != widget.startSeconds) {
      _base = _seconds.value = widget.startSeconds;
      if (_ticker.isActive) {
        _ticker.stop();
        _ticker.start();
      }
    }
    if (oldWidget.paused != widget.paused) _sync();
  }

  void _sync() {
    if (widget.paused) {
      if (_ticker.isActive) _ticker.stop();
      _base = _seconds.value;
    } else if (!_ticker.isActive) {
      _base = _seconds.value;
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _seconds.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        RepaintBoundary(
          child: ValueListenableBuilder<double>(
            valueListenable: _seconds,
            builder: (BuildContext _, double seconds, Widget? _) => CustomPaint(
              painter: OrbPainter(seconds: seconds, preset: widget.preset),
            ),
          ),
        ),
        if (widget.child case final Widget child) child,
      ],
    );
  }
}
