/// One focus session that ran all the way to zero.
///
/// **Only a session that reached zero is one of these.** A pause, a reset and a
/// session abandoned halfway are not recorded at all, because the question this
/// answers is "how many pomodoros did I actually complete" — a count that
/// included interrupted runs would flatter the day and stop being worth looking
/// at. That is also why the record is written from `_finish()` and from nowhere
/// else.
class FocusSession {
  const FocusSession({
    required this.completedAt,
    required this.duration,
    this.goal,
  });

  /// When it hit zero, in local time.
  ///
  /// The *end* rather than the start, because that is the instant the session
  /// became a fact, and because it is what a day is counted by: a pomodoro
  /// started at 23:50 and finished at 00:30 belongs to the day it was finished
  /// on, which is the day the user remembers doing the work.
  final DateTime completedAt;

  /// How long it actually ran — the session's own length, so a run stretched
  /// with `+5 MIN` reports the stretched time rather than the configured one.
  final Duration duration;

  /// What the session was for, if anything was typed. Bounded on write: this
  /// file only ever grows, and a pasted paragraph in the goal field must not be
  /// able to make one row larger than the whole day's history.
  final String? goal;

  static const int maxGoalLength = 200;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'completedAt': completedAt.toIso8601String(),
    'minutes': duration.inMinutes,
    if (goal != null) 'goal': goal,
  };

  /// Null when the row cannot be trusted, so the caller can skip exactly that
  /// line. A torn final line after a kill mid-append must cost one session,
  /// never the file — the same contract `RecordingRevision` follows.
  static FocusSession? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final Object? at = json['completedAt'];
    final Object? minutes = json['minutes'];
    if (at is! String || minutes is! int) return null;
    final DateTime? parsed = DateTime.tryParse(at);
    if (parsed == null || minutes < 0) return null;
    final Object? goal = json['goal'];
    return FocusSession(
      // Stored with an offset, read back in local time: the tally is grouped by
      // the user's own days, so a session must not move to another day because
      // the file was written in a different timezone.
      completedAt: parsed.toLocal(),
      duration: Duration(minutes: minutes),
      goal: goal is String && goal.trim().isNotEmpty ? goal : null,
    );
  }
}

/// What one day amounts to: how many sessions, and how much time in them.
class DailyFocusTally {
  const DailyFocusTally({
    required this.day,
    required this.sessions,
    required this.focused,
  });

  /// Local midnight of the day being counted.
  final DateTime day;
  final int sessions;
  final Duration focused;

  bool get isEmpty => sessions == 0;
}

/// Local midnight for [moment] — the key a session is counted under.
DateTime focusDayOf(DateTime moment) {
  final DateTime local = moment.toLocal();
  return DateTime(local.year, local.month, local.day);
}

/// Sessions grouped into days, newest first.
///
/// Days with no sessions are **not** invented here: this reports what happened,
/// and a caller that wants an unbroken calendar strip (the tab does) fills the
/// gaps itself, where it knows how many days it means to show.
List<DailyFocusTally> tallyByDay(List<FocusSession> sessions) {
  final Map<DateTime, List<FocusSession>> byDay =
      <DateTime, List<FocusSession>>{};
  for (final FocusSession session in sessions) {
    byDay.putIfAbsent(focusDayOf(session.completedAt), () => <FocusSession>[])
        .add(session);
  }

  final List<DateTime> days = byDay.keys.toList()
    ..sort((DateTime a, DateTime b) => b.compareTo(a));
  return <DailyFocusTally>[
    for (final DateTime day in days)
      DailyFocusTally(
        day: day,
        sessions: byDay[day]!.length,
        focused: byDay[day]!.fold(
          Duration.zero,
          (Duration total, FocusSession session) => total + session.duration,
        ),
      ),
  ];
}

/// Where completed sessions are written down.
///
/// A seam for the same reason as `AlarmPlayer`: the real implementation touches
/// the user's disk, and the pure-Dart suite must be able to run a session to
/// zero without one. The default records nothing, so a host that never wires it
/// behaves exactly as the timer did before this existed.
abstract interface class FocusSessionLog {
  Future<List<FocusSession>> load();

  /// Throws on failure. The caller swallows it — see `FocusTimerController`.
  Future<void> append(FocusSession session);
}

class NoopFocusSessionLog implements FocusSessionLog {
  const NoopFocusSessionLog();

  @override
  Future<List<FocusSession>> load() async => const <FocusSession>[];

  @override
  Future<void> append(FocusSession session) async {}
}
