import 'dart:math' as math;
import 'package:flutter/material.dart';

class DoneBurstParticle {
  DoneBurstParticle({
    required this.angle,
    required this.distance,
    required this.size,
    required this.color,
  });

  final double angle;
  final double distance;
  final double size;
  final Color color;
}

class DoneBurstAnimation extends StatefulWidget {
  const DoneBurstAnimation({
    super.key,
    required this.child,
    required this.reviewed,
  });

  final Widget child;
  final bool reviewed;

  @override
  State<DoneBurstAnimation> createState() => _DoneBurstAnimationState();
}

class _DoneBurstAnimationState extends State<DoneBurstAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  List<DoneBurstParticle> _particles = <DoneBurstParticle>[];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
  }

  @override
  void didUpdateWidget(DoneBurstAnimation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reviewed && !oldWidget.reviewed) {
      _triggerBurst();
    }
  }

  void _triggerBurst() {
    final math.Random rng = math.Random();
    final List<Color> colors = <Color>[
      const Color(0xFF10B981), // Emerald
      const Color(0xFF34D399), // Mint
      const Color(0xFFF59E0B), // Amber
      const Color(0xFF6366F1), // Indigo
      const Color(0xFFEC4899), // Pink
      Colors.white,
    ];

    _particles = List<DoneBurstParticle>.generate(12, (int i) {
      final double angle = (i / 12) * math.pi * 2 + (rng.nextDouble() - 0.5) * 0.3;
      final double distance = 16.0 + rng.nextDouble() * 18.0;
      final double size = 3.0 + rng.nextDouble() * 4.0;
      final Color color = colors[rng.nextInt(colors.length)];
      return DoneBurstParticle(
        angle: angle,
        distance: distance,
        size: size,
        color: color,
      );
    });

    _controller.forward(from: 0.0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        final double value = CurvedAnimation(
          parent: _controller,
          curve: Curves.easeOutCubic,
        ).value;

        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: <Widget>[
            if (_controller.isAnimating && value < 1.0)
              CustomPaint(
                size: Size.zero,
                painter: _DoneBurstPainter(
                  particles: _particles,
                  progress: value,
                ),
              ),
            widget.child,
          ],
        );
      },
    );
  }
}

class _DoneBurstPainter extends CustomPainter {
  _DoneBurstPainter({required this.particles, required this.progress});

  final List<DoneBurstParticle> particles;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final double opacity = (1.0 - progress).clamp(0.0, 1.0);

    for (final DoneBurstParticle p in particles) {
      final double currentDist = p.distance * progress;
      final double dx = math.cos(p.angle) * currentDist;
      final double dy = math.sin(p.angle) * currentDist;

      final Paint paint = Paint()
        ..color = p.color.withValues(alpha: opacity)
        ..style = PaintingStyle.fill;

      final double currentSize = p.size * (1.0 - progress * 0.4);
      canvas.drawCircle(Offset(dx, dy), currentSize, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DoneBurstPainter oldDelegate) => true;
}
