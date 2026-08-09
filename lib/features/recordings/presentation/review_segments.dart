import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import 'queue_tab.dart';

/// `DESK 4 · OFF DESK 33 · ANY 37` as one segmented control.
///
/// A segmented control rather than three [ConsoleChip]s: these options are
/// mutually exclusive and always exactly three, which is what a segment says and
/// a chip does not — and the shared track is what lets them sit in a 34 px strip
/// instead of a 44 px row of separate pills.
///
/// **Shared by the phone header and the wide toolbar on purpose.** It began as a
/// private widget inside `compact_queue_header.dart` while the wide form used
/// three chips inside `ReviewedStrip`, and the two carried the same labels and
/// the same counts in two places. The words and the count arithmetic are the
/// thing that must not drift between the forms — a phone and a desktop naming
/// the same axis differently is a bug no test would ever catch, because each
/// half is internally consistent.
class ReviewSegments extends StatelessWidget {
  ReviewSegments({
    super.key,
    required this.total,
    required this.reviewed,
    required this.filter,
    required this.onChanged,
  });

  final int total;
  final int reviewed;
  final ReviewFilter filter;
  final ValueChanged<ReviewFilter> onChanged;

  /// [ReviewFilter.handedOff] shortens to `OFF DESK` rather than spelling the
  /// verb out: on a phone the three segments have to stay on one line, and
  /// `HANDED OFF` pushes them onto a second. The pair reads as one thought
  /// anyway — the same desk, before and after.
  ///
  /// `ANY` rather than the obvious `ALL`: the status control beside it owns that
  /// word, and two controls reading `ALL 28` on one line is a genuine ambiguity.
  static String labelFor(ReviewFilter value) => switch (value) {
    ReviewFilter.desk => 'DESK',
    ReviewFilter.handedOff => 'OFF DESK',
    ReviewFilter.all => 'ANY',
  };

  int _count(ReviewFilter value) => switch (value) {
    ReviewFilter.desk => total - reviewed,
    ReviewFilter.handedOff => reviewed,
    ReviewFilter.all => total,
  };

  /// The green is the same "you are finished with it" green the review tick
  /// uses on a card.
  Color _color(ReviewFilter value) =>
      value == ReviewFilter.handedOff ? Console.green : Console.accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Console.surfaceRaised,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Console.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: ReviewFilter.values.map((ReviewFilter value) {
          final bool selected = filter == value;
          final Color color = _color(value);
          return Semantics(
            button: true,
            selected: selected,
            child: InkWell(
              onTap: () => onChanged(value),
              borderRadius: BorderRadius.circular(7),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                constraints: const BoxConstraints(minHeight: 34),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 11),
                decoration: BoxDecoration(
                  color: selected ? color : Colors.transparent,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  '${labelFor(value)} ${_count(value)}',
                  style: ConsoleText.chip.copyWith(
                    fontSize: 10,
                    letterSpacing: .5,
                    color: selected ? Console.ink : Console.muted,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
