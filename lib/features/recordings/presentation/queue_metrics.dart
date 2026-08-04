import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import 'queue_tab.dart';

/// The user-owned done progress row above the queue list.
///
/// The design replaced three separate metric cards with this single strip: the
/// per-status counts moved onto the filter chips, which is where they are
/// actionable, leaving only the one number that is a goal rather than a fact —
/// how much of the queue the user has actually read.
///
/// It also *is* the review filter. The number and the control belong together:
/// the strip used to state a goal (`DONE 27 / 28`) that nothing on screen could
/// act on, which is the definition of a vanity metric — the one remaining item
/// had to be found by eye, among twenty-seven finished ones that never left.
class ReviewedStrip extends StatelessWidget {
  const ReviewedStrip({
    super.key,
    required this.total,
    required this.reviewed,
    required this.filter,
    required this.onFilterChanged,
  });

  final int total;
  final int reviewed;
  final ReviewFilter filter;
  final ValueChanged<ReviewFilter> onFilterChanged;

  /// `ANY` rather than the obvious `ALL`: the status row below already owns a
  /// chip with that label, and two chips reading `ALL 28` on one screen is a
  /// genuine ambiguity, not just a finder collision in the tests.
  String _label(ReviewFilter value) => switch (value) {
    ReviewFilter.inbox => 'INBOX',
    ReviewFilter.done => 'DONE',
    ReviewFilter.all => 'ANY',
  };

  int _count(ReviewFilter value) => switch (value) {
    ReviewFilter.inbox => total - reviewed,
    ReviewFilter.done => reviewed,
    ReviewFilter.all => total,
  };

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
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: ReviewFilter.values.map((ReviewFilter value) {
                          return ConsoleChip(
                            label: _label(value),
                            count: _count(value),
                            selected: filter == value,
                            selectedColor: value == ReviewFilter.done
                                ? Console.green
                                : Console.cyan,
                            onSelected: () => onFilterChanged(value),
                          );
                        }).toList(),
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
                  const SizedBox(height: 9),
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
