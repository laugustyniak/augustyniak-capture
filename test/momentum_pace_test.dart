import 'package:augustyniak_capture/features/momentum/domain/closure_event.dart';
import 'package:augustyniak_capture/features/momentum/domain/momentum_snapshot.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:flutter_test/flutter_test.dart';

ClosureEvent _at(DateTime when) => ClosureEvent(
  recordingId: '${when.microsecondsSinceEpoch}',
  at: when,
  kind: ClosureKind.review,
  type: CaptureType.text,
);

/// [count] closures on [day], a minute apart so each has a distinct id.
List<ClosureEvent> _closures(DateTime day, int count) => <ClosureEvent>[
  for (int i = 0; i < count; i++) _at(day.add(Duration(minutes: i))),
];

void main() {
  group('closuresByDay', () {
    test('groups by local day, newest first', () {
      final List<DayClosures> days = closuresByDay(<ClosureEvent>[
        ..._closures(DateTime(2026, 8, 7, 10), 2),
        ..._closures(DateTime(2026, 8, 9, 10), 3),
      ]);

      expect(days.first.day, DateTime(2026, 8, 9));
      expect(days.first.closures, 3);
      expect(days.last.day, DateTime(2026, 8, 7));
      expect(days.last.closures, 2);
    });

    test('a capture closed at 23:50 and one at 00:30 land on different days', () {
      final List<DayClosures> days = closuresByDay(<ClosureEvent>[
        _at(DateTime(2026, 8, 8, 23, 50)),
        _at(DateTime(2026, 8, 9, 0, 30)),
      ]);

      expect(days.length, 2);
    });

    test('does not invent the empty days between', () {
      // Reporting what happened. A caller wanting an unbroken strip fills the
      // gaps where it knows how many days it means to show.
      final List<DayClosures> days = closuresByDay(<ClosureEvent>[
        _at(DateTime(2026, 8, 1, 10)),
        _at(DateTime(2026, 8, 9, 10)),
      ]);

      expect(days.length, 2);
    });

    test('is empty for no closures', () {
      expect(closuresByDay(const <ClosureEvent>[]), isEmpty);
    });
  });

  group('paceOf', () {
    final DateTime now = DateTime(2026, 8, 9, 18);

    test('is the median across active days, ignoring days with none', () {
      // 5, 1 and 3 on three active days; four idle days between them. A mean
      // over calendar days would answer 9/14 — a target of zero, which cannot
      // be missed and therefore says nothing.
      final List<ClosureEvent> events = <ClosureEvent>[
        ..._closures(DateTime(2026, 8, 3, 10), 5),
        ..._closures(DateTime(2026, 8, 6, 10), 1),
        ..._closures(DateTime(2026, 8, 9, 10), 3),
      ];

      expect(paceOf(events, now), 3);
    });

    test('averages the middle two on an even number of active days', () {
      final List<ClosureEvent> events = <ClosureEvent>[
        ..._closures(DateTime(2026, 8, 6, 10), 2),
        ..._closures(DateTime(2026, 8, 9, 10), 5),
      ];

      expect(paceOf(events, now), 3.5);
    });

    test('one exceptional afternoon does not raise the bar for a fortnight', () {
      // The reason this is a median and not a mean: clearing the queue before a
      // holiday must not make the next two weeks look like failures.
      final List<ClosureEvent> events = <ClosureEvent>[
        ..._closures(DateTime(2026, 8, 3, 10), 40),
        ..._closures(DateTime(2026, 8, 6, 10), 2),
        ..._closures(DateTime(2026, 8, 9, 10), 2),
      ];

      expect(paceOf(events, now), 2);
    });

    test('ignores closures older than the window', () {
      final List<ClosureEvent> events = <ClosureEvent>[
        ..._closures(DateTime(2026, 6, 1, 10), 40),
        ..._closures(DateTime(2026, 8, 9, 10), 2),
      ];

      expect(paceOf(events, now), 2);
    });

    test('is zero with no closures at all', () {
      expect(paceOf(const <ClosureEvent>[], now), 0);
    });
  });

  group('targetFrom', () {
    test('floors the pace', () {
      expect(targetFrom(3.8, 10), 3);
    });

    test('never drops below one, however low the pace', () {
      expect(targetFrom(0.2, 10), 1);
      expect(targetFrom(0, 10), 1);
    });

    test('is one while fewer than three active days exist', () {
      // The floor is the feature, not a guard: a fresh install and a return
      // after a fortnight both get a guaranteed win on the first day back,
      // rather than the target that was current when the user fell off.
      expect(targetFrom(9, 0), 1);
      expect(targetFrom(9, 2), 1);
      expect(targetFrom(9, 3), 9);
    });
  });

  group('activeDaysIn', () {
    test('counts distinct days with a closure inside the window', () {
      final DateTime now = DateTime(2026, 8, 9, 18);
      final List<ClosureEvent> events = <ClosureEvent>[
        ..._closures(DateTime(2026, 8, 8, 10), 3),
        ..._closures(DateTime(2026, 8, 9, 10), 1),
        ..._closures(DateTime(2026, 6, 1, 10), 9),
      ];

      expect(activeDaysIn(events, now), 2);
    });
  });

  group('daylight saving', () {
    // Europe/Warsaw springs forward on 2026-03-29, so the fortnight ending on
    // 2026-03-30 contains a 23-hour day.
    //
    // **These assert just after midnight, and that is the whole point.** An
    // implementation using `subtract(Duration(days: 13))` loses an hour across
    // the transition; at midday that only moves 12:00 to 11:00, which
    // `focusDayOf` truncates back to the same midnight, so the window looks
    // correct and the test would be vacuous. At 00:30 the lost hour moves the
    // boundary onto the *previous day*, widening the window by a full day —
    // which is the bug, and it is invisible for twenty-three hours out of
    // twenty-four. Verified by breaking the implementation and watching this
    // group go red.
    final DateTime now = DateTime(2026, 3, 30, 0, 30);

    test('a closure 13 days back is inside the window', () {
      final List<ClosureEvent> events = _closures(DateTime(2026, 3, 17, 12), 4);

      expect(paceOf(events, now), 4);
      expect(activeDaysIn(events, now), 1);
    });

    test('a closure 14 days back is outside it', () {
      final List<ClosureEvent> events = _closures(DateTime(2026, 3, 16, 12), 4);

      expect(paceOf(events, now), 0);
      expect(activeDaysIn(events, now), 0);
    });

    test('the same boundary holds in a week with no transition', () {
      expect(
        paceOf(
          _closures(DateTime(2026, 7, 16, 12), 4),
          DateTime(2026, 7, 30, 0, 30),
        ),
        0,
      );
      expect(
        paceOf(
          _closures(DateTime(2026, 7, 17, 12), 4),
          DateTime(2026, 7, 30, 0, 30),
        ),
        4,
      );
    });
  });

  group('MomentumSnapshot', () {
    MomentumSnapshot snap({
      required int today,
      required int target,
      double pace = 3,
      double previousPace = 3,
    }) => MomentumSnapshot(
      today: today,
      target: target,
      pace: pace,
      previousPace: previousPace,
      days: const <DayClosures>[],
    );

    test('metTarget is inclusive', () {
      expect(snap(today: 3, target: 3).metTarget, isTrue);
      expect(snap(today: 2, target: 3).metTarget, isFalse);
    });

    test('rising is null when there is nothing to compare', () {
      // So the card can omit the arrow rather than draw a misleading flat one.
      expect(snap(today: 1, target: 1, pace: 0, previousPace: 0).rising, isNull);
      expect(snap(today: 1, target: 1, pace: 3, previousPace: 3).rising, isNull);
    });

    test('rising reports the direction otherwise', () {
      expect(snap(today: 1, target: 1, pace: 3.2, previousPace: 2.8).rising, isTrue);
      expect(snap(today: 1, target: 1, pace: 2.8, previousPace: 3.2).rising, isFalse);
    });
  });
}
