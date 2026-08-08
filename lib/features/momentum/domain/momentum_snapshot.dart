import '../../timer/domain/focus_session.dart' show focusDayOf;
import 'closure_event.dart';

/// What one day amounts to: how many captures left the desk.
class DayClosures {
  const DayClosures({required this.day, required this.closures});

  /// Local midnight of the day being counted.
  final DateTime day;
  final int closures;

  bool get isEmpty => closures == 0;
}

/// How many calendar days the pace looks back over.
const int paceWindowDays = 14;

/// Below this many active days the target is pinned to 1 — see [targetFrom].
const int paceConfidenceDays = 3;

/// Closures grouped into days, newest first.
///
/// Days with nothing in them are **not** invented here: this reports what
/// happened, and a caller that wants an unbroken calendar strip fills the gaps
/// itself, where it knows how many days it means to show. Same contract as
/// `tallyByDay` in the timer's domain, and the same reason.
List<DayClosures> closuresByDay(List<ClosureEvent> events) {
  final Map<DateTime, int> byDay = <DateTime, int>{};
  for (final ClosureEvent event in events) {
    final DateTime day = focusDayOf(event.at);
    byDay[day] = (byDay[day] ?? 0) + 1;
  }

  final List<DateTime> days = byDay.keys.toList()
    ..sort((DateTime a, DateTime b) => b.compareTo(a));
  return <DayClosures>[
    for (final DateTime day in days)
      DayClosures(day: day, closures: byDay[day]!),
  ];
}

/// What one project amounts to across the closures counted.
class ProjectClosures {
  const ProjectClosures({
    required this.projectId,
    required this.projectName,
    required this.closures,
  });

  /// Null for captures closed with no project, kept as a real row rather than
  /// dropped: unattributed work is a fact about the week worth seeing.
  final String? projectId;

  /// The most recent name seen for this project, so a rename shows the current
  /// one while older rows still group under it.
  final String projectName;

  final int closures;
}

/// Closures grouped by project, busiest first.
///
/// **Unattributed always sorts last**, however much of it there is — it is the
/// residual, not a competitor. Sorting it by count puts `No project` in the
/// middle of the real ones, where it reads as a project you own and pushes work
/// you did below work you did not file. Name breaks the remaining tie so the
/// order cannot flicker between rebuilds. Both rules are lifted from
/// `tallyByProject` in the timer's domain, where they were found by looking at
/// the rendered panel rather than by any assertion about counts.
List<ProjectClosures> closuresByProject(List<ClosureEvent> events) {
  final Map<String?, List<ClosureEvent>> byProject =
      <String?, List<ClosureEvent>>{};
  for (final ClosureEvent event in events) {
    byProject.putIfAbsent(event.projectId, () => <ClosureEvent>[]).add(event);
  }

  final List<ProjectClosures> tallies = <ProjectClosures>[
    for (final MapEntry<String?, List<ClosureEvent>> entry
        in byProject.entries)
      ProjectClosures(
        projectId: entry.key,
        projectName: entry.key == null
            ? 'No project'
            // Last writer wins: the newest row carries the newest name.
            : entry.value
                      .map((ClosureEvent event) => event.projectName)
                      .whereType<String>()
                      .lastOrNull ??
                  'Unnamed project',
        closures: entry.value.length,
      ),
  ];
  tallies.sort((ProjectClosures a, ProjectClosures b) {
    if ((a.projectId == null) != (b.projectId == null)) {
      return a.projectId == null ? 1 : -1;
    }
    final int byCount = b.closures.compareTo(a.closures);
    return byCount != 0 ? byCount : a.projectName.compareTo(b.projectName);
  });
  return tallies;
}

/// Local midnight of the oldest day still inside a [days]-long window ending on
/// the day containing [now].
///
/// `DateTime(y, m, d - n)` and never `subtract(Duration(days: n))`: a day is not
/// always 24 hours, and across a spring-forward transition the `Duration` form
/// lands an hour early — enough to move the boundary onto the previous day and
/// silently drop it from the window. The same arithmetic `columnsFor` in the
/// timer's domain is written to avoid, after that bug removed *today's* column
/// on five Mondays a year.
DateTime _windowStart(DateTime now, int days) {
  final DateTime local = now.toLocal();
  return DateTime(local.year, local.month, local.day - days + 1);
}

/// Counts closures per day inside the pace window.
Map<DateTime, int> _withinWindow(List<ClosureEvent> events, DateTime now) {
  final DateTime start = _windowStart(now, paceWindowDays);
  final Map<DateTime, int> byDay = <DateTime, int>{};
  for (final ClosureEvent event in events) {
    final DateTime day = focusDayOf(event.at);
    if (day.isBefore(start)) continue;
    byDay[day] = (byDay[day] ?? 0) + 1;
  }
  return byDay;
}

/// Distinct days inside the pace window that saw at least one closure.
int activeDaysIn(List<ClosureEvent> events, DateTime now) =>
    _withinWindow(events, now).length;

/// The median number of closures across **active** days in the last
/// [paceWindowDays] calendar days.
///
/// **Active days, not calendar days.** A weekend or a week off must not drag the
/// median to zero, because a target of zero is a target that cannot be missed
/// and therefore says nothing about whether the day went well.
///
/// **A median rather than a mean**, because one exceptional afternoon — a queue
/// cleared before a holiday — would otherwise raise the bar for the fortnight
/// after it, turning a good day into the reason the next ten look like failures.
double paceOf(List<ClosureEvent> events, DateTime now) {
  final Map<DateTime, int> byDay = _withinWindow(events, now);
  if (byDay.isEmpty) return 0;

  final List<int> counts = byDay.values.toList()..sort();
  final int middle = counts.length ~/ 2;
  if (counts.length.isOdd) return counts[middle].toDouble();
  return (counts[middle - 1] + counts[middle]) / 2;
}

/// Today's target: the floor of the pace, never below 1.
///
/// **The floor of 1 is the feature, not a guard.** A fresh install and a return
/// after a fortnight away both meet a target of 1 — a guaranteed win on the
/// first day back, rather than the target of five that was current when the user
/// fell off. That is the endowed-progress effect: a loyalty card with two stamps
/// already on it is completed more often than an empty one.
///
/// The same reasoning pins it to 1 below [paceConfidenceDays]: a median taken
/// from one or two days is not a pace, it is an accident.
int targetFrom(double pace, int activeDays) {
  if (activeDays < paceConfidenceDays) return 1;
  final int floored = pace.floor();
  return floored < 1 ? 1 : floored;
}

/// Everything the panel and the card read, in one value.
///
/// **Derived on read, never stored.** A running app crosses midnight, and a
/// persisted "today's target" would be yesterday's by morning with nothing to
/// trigger a correction. Same rule as `FocusTimerController.today`.
class MomentumSnapshot {
  const MomentumSnapshot({
    required this.today,
    required this.target,
    required this.pace,
    required this.previousPace,
    required this.days,
  });

  /// How many captures closed today.
  final int today;

  /// What today has to reach for the day to count.
  final int target;

  /// The current pace, and the pace as of a week ago. The pair is what lets the
  /// card say `↑ from 2.8` rather than reporting a number against no baseline.
  final double pace;
  final double previousPace;

  /// The window the panel charts, newest first, **with its empty days kept** —
  /// "three a day" and "three once a week" are the same tallies and a very
  /// different working week.
  final List<DayClosures> days;

  bool get metTarget => today >= target;

  /// Null when there is no meaningful comparison, so the UI can omit the arrow
  /// rather than draw a misleading flat one.
  bool? get rising {
    if (pace == previousPace) return null;
    return pace > previousPace;
  }
}
