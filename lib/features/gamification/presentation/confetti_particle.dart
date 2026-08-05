import 'dart:math' as math;
import 'package:flutter/material.dart';

class ConfettiParticle {
  ConfettiParticle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.size,
    required this.color,
    required this.rotation,
    required this.rotationSpeed,
    required this.shape,
  });

  double x;
  double y;
  double vx;
  double vy;
  double size;
  Color color;
  double rotation;
  double rotationSpeed;
  int shape; // 0: rect, 1: circle, 2: star

  static List<ConfettiParticle> generate(int count, Size bounds) {
    final math.Random rng = math.Random();
    final List<Color> colors = <Color>[
      const Color(0xFF10B981), // Emerald
      const Color(0xFF6366F1), // Indigo
      const Color(0xFFEC4899), // Pink
      const Color(0xFFF59E0B), // Amber
      const Color(0xFF3B82F6), // Blue
      const Color(0xFFA855F7), // Purple
      const Color(0xFF06B6D4), // Cyan
      const Color(0xFFEAB308), // Gold
    ];

    return List<ConfettiParticle>.generate(count, (int index) {
      final double x = rng.nextDouble() * bounds.width;
      final double y = -rng.nextDouble() * bounds.height * 0.5;
      final double vx = (rng.nextDouble() - 0.5) * 4;
      final double vy = 3.0 + rng.nextDouble() * 5.0;
      final double size = 6.0 + rng.nextDouble() * 8.0;
      final Color color = colors[rng.nextInt(colors.length)];
      final double rotation = rng.nextDouble() * math.pi * 2;
      final double rotationSpeed = (rng.nextDouble() - 0.5) * 0.2;
      final int shape = rng.nextInt(3);

      return ConfettiParticle(
        x: x,
        y: y,
        vx: vx,
        vy: vy,
        size: size,
        color: color,
        rotation: rotation,
        rotationSpeed: rotationSpeed,
        shape: shape,
      );
    });
  }

  void update(double dt, Size bounds) {
    x += vx + math.sin(y * 0.05) * 1.5;
    y += vy;
    rotation += rotationSpeed;
    vy += 0.05; // gravity
  }
}

class ConfettiPainter extends CustomPainter {
  ConfettiPainter({required this.particles, required this.progress});

  final List<ConfettiParticle> particles;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    for (final ConfettiParticle p in particles) {
      final double alpha = (1.0 - (p.y / size.height)).clamp(0.0, 1.0);
      final Paint paint = Paint()
        ..color = p.color.withValues(alpha: alpha * (1.0 - progress * 0.3))
        ..style = PaintingStyle.fill;

      canvas.save();
      canvas.translate(p.x, p.y);
      canvas.rotate(p.rotation);

      if (p.shape == 0) {
        // Rectangle
        canvas.drawRect(
          Rect.fromCenter(
            center: Offset.zero,
            width: p.size,
            height: p.size * 0.6,
          ),
          paint,
        );
      } else if (p.shape == 1) {
        // Circle
        canvas.drawCircle(Offset.zero, p.size * 0.4, paint);
      } else {
        // Diamond / Star shape
        final Path path = Path()
          ..moveTo(0, -p.size * 0.5)
          ..lineTo(p.size * 0.3, 0)
          ..lineTo(0, p.size * 0.5)
          ..lineTo(-p.size * 0.3, 0)
          ..close();
        canvas.drawPath(path, paint);
      }

      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant ConfettiPainter oldDelegate) => true;
}

class ConfettiShowerWidget extends StatefulWidget {
  const ConfettiShowerWidget({super.key, this.duration = const Duration(seconds: 4)});

  final Duration duration;

  @override
  State<ConfettiShowerWidget> createState() => _ConfettiShowerWidgetState();
}

class _ConfettiShowerWidgetState extends State<ConfettiShowerWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  List<ConfettiParticle> _particles = <ConfettiParticle>[];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    )..addListener(() {
        setState(() {
          final Size size = MediaQuery.sizeOf(context);
          if (_particles.isEmpty && size.width > 0) {
            _particles = ConfettiParticle.generate(70, size);
          }
          for (final ConfettiParticle p in _particles) {
            p.update(0.016, size);
          }
        });
      });

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? child) {
          return CustomPaint(
            size: Size.infinite,
            painter: ConfettiPainter(
              particles: _particles,
              progress: _controller.value,
            ),
          );
        },
      ),
    );
  }
}
