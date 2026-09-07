import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';

/// Generates a natural-looking normalized waveform bar pattern for an audio capture.
List<double> generateWaveformSamples(String seedKey, {int count = 36}) {
  final int hash = seedKey.hashCode.abs();
  final List<double> samples = <double>[];
  for (int i = 0; i < count; i++) {
    // Generate organic undulating speech-like cadence
    final double sin1 = (math.sin((i + hash % 17) * 0.45) + 1.0) / 2.0;
    final double sin2 = (math.sin((i + hash % 31) * 0.95) + 1.0) / 2.0;
    final double base = (sin1 * 0.6 + sin2 * 0.4);
    final double val = (0.25 + base * 0.75).clamp(0.2, 1.0);
    samples.add(val);
  }
  return samples;
}

/// Interactive amplitude waveform scrubber for audio playback.
class AudioWaveformVisualizer extends StatelessWidget {
  const AudioWaveformVisualizer({
    super.key,
    required this.progress,
    required this.samples,
    this.onSeek,
    this.height = 26,
  });

  final double progress;
  final List<double> samples;
  final ValueChanged<double>? onSeek;
  final double height;

  void _handleSeek(Offset localPosition, double width) {
    if (width <= 0 || onSeek == null) return;
    final double ratio = (localPosition.dx / width).clamp(0.0, 1.0);
    onSeek!(ratio);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (TapDownDetails details) =>
              _handleSeek(details.localPosition, constraints.maxWidth),
          onHorizontalDragUpdate: (DragUpdateDetails details) =>
              _handleSeek(details.localPosition, constraints.maxWidth),
          child: SizedBox(
            height: height,
            width: constraints.maxWidth,
            child: CustomPaint(
              size: Size(constraints.maxWidth, height),
              painter: WaveformPainter(
                samples: samples,
                progress: progress.clamp(0.0, 1.0),
                activeColor: Console.accent,
                inactiveColor: Console.track,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// CustomPainter rendering vertical amplitude bars with an active progress threshold.
class WaveformPainter extends CustomPainter {
  WaveformPainter({
    required this.samples,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
  });

  final List<double> samples;
  final double progress;
  final Color activeColor;
  final Color inactiveColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty || size.width <= 0) return;
    final int count = samples.length;
    const double barWidth = 3.0;
    final double spacing =
        count > 1 ? ((size.width - (count * barWidth)) / (count - 1)).clamp(1.5, 6.0) : 2.0;
    final double totalWidth = count * barWidth + (count - 1) * spacing;
    final double startX = ((size.width - totalWidth) / 2.0).clamp(0.0, size.width);
    final double progressX = progress * size.width;

    final Paint activePaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.fill;
    final Paint inactivePaint = Paint()
      ..color = inactiveColor
      ..style = PaintingStyle.fill;

    for (int i = 0; i < count; i++) {
      final double x = startX + i * (barWidth + spacing);
      final double barHeight = (samples[i] * size.height).clamp(4.0, size.height);
      final double y = (size.height - barHeight) / 2.0;
      final RRect rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, barWidth, barHeight),
        const Radius.circular(1.5),
      );
      final bool isActive = (x + barWidth / 2) <= progressX;
      canvas.drawRRect(rrect, isActive ? activePaint : inactivePaint);
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.inactiveColor != inactiveColor ||
        oldDelegate.samples != samples;
  }
}
