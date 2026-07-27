import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';

/// The reviewed/running/failed counters above the queue list.
class MetricsRow extends StatelessWidget {
  const MetricsRow({
    super.key,
    required this.total,
    required this.reviewed,
    required this.running,
    required this.failed,
  });

  final int total;
  final int reviewed;
  final int running;
  final int failed;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: _AnimatedMetricCard(
                value: reviewed,
                suffix: '/$total',
                label: 'REVIEWED',
                accent: Console.green,
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: _AnimatedMetricCard(value: running, label: 'RUNNING'),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: _AnimatedMetricCard(
                value: failed,
                label: 'FAILED',
                accent: failed == 0 ? Console.green : Console.red,
              ),
            ),
          ],
        ),
        const SizedBox(height: 9),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: total == 0 ? 0 : reviewed / total),
            duration: const Duration(milliseconds: 550),
            curve: Curves.easeOutCubic,
            builder: (BuildContext context, double value, Widget? child) {
              return LinearProgressIndicator(
                value: value,
                minHeight: 5,
                color: Console.green,
                backgroundColor: const Color(0xFF17314B),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _AnimatedMetricCard extends StatelessWidget {
  const _AnimatedMetricCard({
    required this.value,
    required this.label,
    this.suffix = '',
    this.accent = Console.cyan,
  });

  final int value;
  final String suffix;
  final String label;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Console.surface,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Console.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            transitionBuilder: (Widget child, Animation<double> animation) {
              return ScaleTransition(
                scale: CurvedAnimation(
                    parent: animation, curve: Curves.easeOutBack),
                child: FadeTransition(opacity: animation, child: child),
              );
            },
            child: Text(
              '$value$suffix',
              key: ValueKey<String>('$value$suffix'),
              style: TextStyle(
                color: accent,
                fontSize: 19,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(
              color: Console.muted,
              fontSize: 8,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
