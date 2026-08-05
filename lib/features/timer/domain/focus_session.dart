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
    this.projectId,
    this.projectName,
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

  /// Which project was active when the session finished, if any.
  ///
  /// **Both the id and the name are stored**, the same denormalisation
  /// `RouteRecord.target` makes and for the same reason: the id is what groups
  /// sessions together, while the name is what the panel can still show after
  /// the project has been renamed or deleted. Resolving the name at read time
  /// would make a deleted project erase the hours spent on it, which is exactly
  /// the history this file exists to keep.
  final String? projectId;
  final String? projectName;

  static const int maxGoalLength = 200;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'completedAt': completedAt.toIso8601String(),
    'minutes': duration.inMinutes,
    if (goal != null) 'goal': goal,
    if (projectId != null) 'projectId': projectId,
    if (projectName != null) 'projectName': projectName,
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
    final Object? projectId = json['projectId'];
    final Object? projectName = json['projectName'];
    return FocusSession(
      // Stored with an offset, read back in local time: the tally is grouped by
      // the user's own days, so a session must not move to another day because
      // the file was written in a different timezone.
      completedAt: parsed.toLocal(),
      duration: Duration(minutes: minutes),
      goal: goal is String && goal.trim().isNotEmpty ? goal : null,
      // Absent on every row written before sessions carried a project, which is
      // the legacy-defaulting point here: those sessions are real and are still
      // counted, they simply have nothing to attribute.
      projectId: projectId is String && projectId.trim().isNotEmpty
          ? projectId
          : null,
      projectName: projectName is String && projectName.trim().isNotEmpty
          ? projectName
          : null,
    );
  }
}

/// The project a finishing session is attributed to.
///
/// Declared here rather than reusing the projects feature's `Project` so the
/// timer's domain stays independent of it — the same reason `HandoffAgent.id` is
/// an opaque string. The shell owns the mapping.
class FocusProject {
  const FocusProject({required this.id, required this.name});

  final String id;
  final String name;
}

/// Resolves the project to attribute a session to, at the moment it ends.
///
/// A callback rather than a value pushed down on change, for the same reason
/// `ProjectInboxRouter` reads its projects live: the active project can change
/// during a forty-minute session, and what matters is which one was active when
/// the work finished.
typedef FocusProjectResolver = FocusProject? Function();

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

/// What one project amounts to across the sessions counted.
class ProjectFocusTally {
  const ProjectFocusTally({
    required this.projectId,
    required this.projectName,
    required this.sessions,
    required this.focused,
  });

  /// Null for sessions run with no project active — kept as a real row rather
  /// than dropped, because unattributed time is a fact about the week worth
  /// seeing, not an absence of data.
  final String? projectId;

  /// The most recent name seen for this project, so a rename shows the current
  /// one while older rows still group under it.
  final String projectName;

  final int sessions;
  final Duration focused;
}

/// Sessions grouped by project, busiest first.
///
/// Sessions first, because a pomodoro count is what this feature counts — then
/// **focused time**, because two projects on one session each are not equally
/// busy and putting the 25-minute one above the 40-minute one is the opposite
/// of the answer the panel is asked for. Name breaks the remaining tie, so the
/// order cannot flicker between rebuilds — a list that reshuffles when nothing
/// changed reads as a bug.
///
/// **Unattributed time always sorts last**, however much of it there is. It is
/// the residual, not a competitor: sorting it by count puts `No project` in the
/// middle of the real ones, where it reads as a project you own and pushes work
/// you did below work you did not file. Found by looking at the rendered panel
/// — every ordering rule here is satisfied either way, so no assertion about
/// counts could have caught it.
List<ProjectFocusTally> tallyByProject(List<FocusSession> sessions) {
  final Map<String?, List<FocusSession>> byProject =
      <String?, List<FocusSession>>{};
  for (final FocusSession session in sessions) {
    byProject.putIfAbsent(session.projectId, () => <FocusSession>[])
        .add(session);
  }

  final List<ProjectFocusTally> tallies = <ProjectFocusTally>[
    for (final MapEntry<String?, List<FocusSession>> entry
        in byProject.entries)
      ProjectFocusTally(
        projectId: entry.key,
        projectName: entry.key == null
            ? 'No project'
            // Last writer wins: the newest row carries the newest name.
            : entry.value
                      .map((FocusSession session) => session.projectName)
                      .whereType<String>()
                      .lastOrNull ??
                  'Unnamed project',
        sessions: entry.value.length,
        focused: entry.value.fold(
          Duration.zero,
          (Duration total, FocusSession session) => total + session.duration,
        ),
      ),
  ];
  tallies.sort((ProjectFocusTally a, ProjectFocusTally b) {
    if ((a.projectId == null) != (b.projectId == null)) {
      return a.projectId == null ? 1 : -1;
    }
    final int bySessions = b.sessions.compareTo(a.sessions);
    if (bySessions != 0) return bySessions;
    final int byTime = b.focused.compareTo(a.focused);
    return byTime != 0 ? byTime : a.projectName.compareTo(b.projectName);
  });
  return tallies;
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
