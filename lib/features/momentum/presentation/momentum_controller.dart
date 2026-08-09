import 'package:flutter/foundation.dart';

import '../../timer/domain/focus_session.dart';
import '../domain/closure_event.dart';
import '../domain/momentum_snapshot.dart';

/// Reads the timer's already-loaded sessions.
///
/// A callback rather than a second [FocusSessionLog], for the reason
/// `FocusProjectResolver` is one: it avoids a second read of the same file, a
/// session that has just finished is visible immediately, and the dependency is
/// on the [FocusSession] type alone.
///
/// **This feature never writes to `focus-sessions.jsonl`.** `_record()` being
/// called from `_finish()` and nowhere else is the only reason "a pomodoro"
/// means exactly one thing, and a second writer would end that.
typedef FocusSessionsReader = List<FocusSession> Function();

/// How much has been finished lately, and what today has to reach.
///
/// **The counterpart to `GamificationController`, not a replacement for it.**
/// That one answers *how much in total* — lifetime counters and the milestones
/// they unlock. This one answers *how is it going lately*, which needs events
/// with dates on them: a cumulative counter cannot be run backwards into "how
/// many did I close on Tuesday", however it is read. The two live side by side
/// because they are two questions, not two implementations of one.
class MomentumController extends ChangeNotifier {
  MomentumController({
    required ClosureLog log,
    FocusSessionsReader? sessions,
    DateTime Function() clock = DateTime.now,
  }) : _log = log,
       _sessions = sessions,
       _clock = clock;

  final ClosureLog _log;
  final FocusSessionsReader? _sessions;

  /// A seam, like `FocusTimerController`'s: the target reads the last fourteen
  /// days, so a test has to be able to substitute a date rather than wait for
  /// one. No test in this suite may sleep for a real span.
  final DateTime Function() _clock;

  List<ClosureEvent> _events = const <ClosureEvent>[];
  bool _historyUnreadable = false;

  /// True when the log could not be read.
  ///
  /// **Distinct from "nothing closed yet"**, which is a positive claim about
  /// the user's own history and must not be made on the strength of a failed
  /// read. The same three-state rule `_indexUnreadable` enforces for the queue
  /// and `historyUnreadable` for the session log.
  bool get historyUnreadable => _historyUnreadable;

  bool get hasClosures => _events.isNotEmpty;

  Future<void> initialize() async {
    try {
      _events = await _log.load();
      _historyUnreadable = false;
    } catch (_) {
      _events = const <ClosureEvent>[];
      _historyUnreadable = true;
    }
    notifyListeners();
  }

  /// Told about a closure rather than re-reading the file, so the count moves in
  /// the same frame the row leaves the queue.
  void noteClosure(ClosureEvent event) {
    _events = <ClosureEvent>[..._events, event];
    notifyListeners();
  }

  /// Focus sessions finished today, for the panel's second line.
  ///
  /// Zero when no reader is wired — a valid configuration, not an error — and
  /// zero when the reader throws, under the `ClipboardSink` contract: a broken
  /// timer costs this line, never the closure history the panel is about.
  int get sessionsToday {
    final FocusSessionsReader? reader = _sessions;
    if (reader == null) return 0;
    try {
      final DateTime today = focusDayOf(_clock());
      return reader()
          .where(
            (FocusSession session) => focusDayOf(session.completedAt) == today,
          )
          .length;
    } catch (_) {
      return 0;
    }
  }

  /// Closures grouped by project across the last [days] days, busiest first.
  List<ProjectClosures> projectTallies(int days) =>
      closuresByProject(_within(days));

  /// Everything the panel reads, in one derived value.
  ///
  /// **Derived on read, never stored.** A running app crosses midnight, and a
  /// persisted "today's target" would be yesterday's by morning with nothing to
  /// trigger a correction. Same rule as `FocusTimerController.today`.
  MomentumSnapshot snapshot({int days = 7}) {
    final DateTime now = _clock();
    final DateTime today = focusDayOf(now);

    final Map<DateTime, int> byDay = <DateTime, int>{
      for (final DayClosures entry in closuresByDay(_events))
        entry.day: entry.closures,
    };

    // The window **keeps its empty days**, unlike `closuresByDay`: "three a
    // day" and "three once a week" are the same tallies and a very different
    // working week. Same decision as `FocusTimerController.recentDays`.
    final List<DayClosures> window = <DayClosures>[];
    for (int i = 0; i < days; i++) {
      // Calendar arithmetic, never `subtract(Duration(days: i))`: a day is not
      // always 24 hours, and the Duration form drops a column across a
      // spring-forward transition.
      final DateTime day = DateTime(today.year, today.month, today.day - i);
      window.add(DayClosures(day: day, closures: byDay[day] ?? 0));
    }

    // A week earlier, so the panel can report a direction rather than a number
    // against no baseline.
    final DateTime lastWeek = DateTime(today.year, today.month, today.day - 7);

    final double pace = paceOf(_events, now);
    return MomentumSnapshot(
      today: byDay[today] ?? 0,
      target: targetFrom(pace, activeDaysIn(_events, now)),
      pace: pace,
      previousPace: paceOf(_events, lastWeek),
      days: window,
    );
  }

  /// Closures inside a [days]-long window ending today.
  List<ClosureEvent> _within(int days) {
    final DateTime today = focusDayOf(_clock());
    final DateTime start = DateTime(
      today.year,
      today.month,
      today.day - days + 1,
    );
    return _events
        .where((ClosureEvent event) => !focusDayOf(event.at).isBefore(start))
        .toList();
  }
}
