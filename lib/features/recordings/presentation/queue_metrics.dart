import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';

/// The user-owned done progress row above the queue list.
///
/// The design replaced three separate metric cards with this single strip: the
/// per-status counts moved onto the filter chips, which is where they are
/// actionable, leaving only the one number that is a goal rather than a fact —
/// how much of the queue the user has actually read.
class ReviewedStrip extends StatelessWidget {
  const ReviewedStrip({super.key, required this.total, required this.reviewed});

  final int total;
  final int reviewed;

  @override
  Widget build(BuildContext context) {
    final double progress = total == 0 ? 0 : reviewed / total;
    final bool allReviewed = total > 0 && reviewed == total;

    return Semantics(
      label: 'Done $reviewed of $total captures',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Console.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Console.border),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.check_rounded,
              size: 18,
              color: allReviewed ? Console.green : Console.cyan,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      Text(
                        'DONE',
                        style: ConsoleText.cardMeta.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        '$reviewed / $total',
                        style: ConsoleText.cardMeta.copyWith(
                          fontWeight: FontWeight.w500,
                          color: Console.text,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(end: progress),
                      duration: const Duration(milliseconds: 550),
                      curve: Curves.easeOutCubic,
                      builder:
                          (BuildContext context, double value, Widget? child) {
                            return LinearProgressIndicator(
                              value: value,
                              minHeight: 4,
                              color: allReviewed ? Console.green : Console.cyan,
                              backgroundColor: Console.track,
                            );
                          },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
