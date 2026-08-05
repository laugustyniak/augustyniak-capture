import 'dart:async';

// `ValueListenable` lives in foundation; material re-exports only a subset.
import 'package:flutter/foundation.dart';

import '../../logs/domain/log_event.dart';
import '../domain/alarm_player.dart';
import '../domain/alarm_sound.dart';
import '../domain/focus_session.dart';
import '../domain/timer_defaults.dart';

/// Where a focus session is.
///
/// [finished] is a state of its own rather than a return to [idle] because the
/// screen has something to say there — the session ran out, the alarm is
/// ringing, and the goal that was worked on is still on it. Collapsing the two
/// would make "I have not started" and "I just finished" the same picture.
enum FocusTimerState { idle, running, paused, finished }

/// The Pomodoro countdown behind the Timer tab.
///
/// **Time is read from the clock, never accumulated.** A session stores the
/// wall-clock instant it ends at and every tick answers
/// `deadline.difference(now)`; the periodic timer only decides how often the
/// screen is repainted, and dropping ticks costs nothing. A controller that
/// subtracted 200 ms per tick would drift under load and — the case that
/// actually matters on a laptop — would silently stop counting while macOS
/// suspended the process, so a machine that slept through a 40-minute session
/// would wake up claiming there were 38 minutes left. Here it wakes up
/// finished, which is the truth.
///
/// **No session *state* is persisted, but a finished session is.** A countdown
/// is not a capture: there is no artifact to protect and nothing worth resuming,
/// so the persist-before-process apparatus does not apply to a run in progress.
/// What survives is the *fact that a session completed* — appended to
/// [FocusSessionLog] the moment it reaches zero, because a day's work done is
/// not reconstructible from anything else. Configuration (length, alarm) lives
/// in `AppSettings` and reaches this controller the way the audio config reaches
/// `RecordingsController`: pushed down by the shell on every settings change.
class FocusTimerController extends ChangeNotifier {
  FocusTimerController({
    AlarmPlayer? alarmPlayer,
    FocusSessionLog sessionLog = const NoopFocusSessionLog(),
    FocusProjectResolver? activeProject,
    LogSink logSink = const NoopLogSink(),
    DateTime Function()? clock,
  }) : _alarm = alarmPlayer ?? const NoopAlarmPlayer(),
       _sessionLog = sessionLog,
       _activeProject = activeProject,
       _logs = logSink,
       _clock = clock ?? DateTime.now;

  /// How often the screen is repainted while running. Four times a second is
  /// far more than a seconds readout needs, and is what keeps the ring's sweep
  /// from stepping visibly between whole seconds.
  static const Duration tickInterval = Duration(milliseconds: 250);

  final AlarmPlayer _alarm;
  final FocusSessionLog _sessionLog;

  /// Null when the host does not track projects — the pure-Dart suite, and any
  /// build where the timer stands alone. Sessions are then simply unattributed.
  final FocusProjectResolver? _activeProject;

  final LogSink _logs;
  final DateTime Function() _clock;

  /// Completed sessions, oldest first — the in-memory view of the log file.
  /// Loaded once by [initialize] and kept in step by [_finish].
  List<FocusSession> _sessions = const <FocusSession>[];

  Timer? _ticker;
  bool _disposed = false;

  FocusTimerState _state = FocusTimerState.idle;

  /// The configured length — what the next [start] will run for. Distinct from
  /// [sessionDuration], which is the length of the run currently on screen and
  /// only moves when [extend] is called.
  Duration _configured = TimerDefaults.duration;
  Duration _sessionDuration = TimerDefaults.duration;

  /// Set while running. Null while idle, paused or finished — a paused session
  /// has no end instant, which is precisely what pausing means.
  DateTime? _deadline;

  /// What was left when [pause] froze it, so [resume] can put a new deadline
  /// that far into the future.
  Duration _frozen = TimerDefaults.duration;

  AlarmSound _alarmSound = AlarmSound.fallback;
  String _goal = '';

  /// Ticked at [tickInterval] rather than pushed through [notifyListeners], for
  /// the same reason `RecordingsController.elapsedTicker` is: the shell listens
  /// to this controller, so notifying on every tick would rebuild all six tabs
  /// four times a second to move one arc.
  final ValueNotifier<Duration> _remainingTicker = ValueNotifier<Duration>(
    TimerDefaults.duration,
  );

  ValueListenable<Duration> get remaining => _remainingTicker;

  FocusTimerState get state => _state;
  bool get isRunning => _state == FocusTimerState.running;
  bool get isPaused => _state == FocusTimerState.paused;
  bool get isFinished => _state == FocusTimerState.finished;

  /// True once a session has been started and not yet reset — the window in
  /// which the length chips are frozen and `EXTEND` takes their place.
  bool get isLive => isRunning || isPaused;

  /// The configured length for the next session.
  Duration get duration => _configured;

  /// The length of the session on screen. Equal to [duration] until [extend]
  /// grows it, which is what keeps the ring proportional after a session has
  /// been stretched.
  Duration get sessionDuration => _sessionDuration;

  AlarmSound get alarmSound => _alarmSound;

  /// What this session is for, typed on the Timer tab. Deliberately kept in
  /// memory and deliberately **not** cleared by [reset]: consecutive pomodoros
  /// are usually the same piece of work, and retyping it is the friction that
  /// stops the field being used at all.
  String get goal => _goal;

  set goal(String value) {
    if (value == _goal) return;
    _goal = value;
    notifyListeners();
  }

  /// How much of the session is still ahead, `1` at the start and `0` at the
  /// end. Read by the dial; safe against a zero-length session.
  double get progress {
    final int total = _sessionDuration.inMilliseconds;
    if (total <= 0) return 0;
    final double left = _remainingTicker.value.inMilliseconds / total;
    return left.clamp(0, 1);
  }

  /// The wall-clock instant the session ends at, for the "ends at 17:42" line.
  /// Null unless one is actually running — a paused session has no answer, and
  /// inventing one from `now + remaining` would be a time that moves every
  /// second while nothing counts down.
  DateTime? get endsAt => _deadline;

  /// Read the completed-session history off disk.
  ///
  /// Best-effort and unawaited-safe: a log that will not load costs the history
  /// panel and nothing else, so the timer is usable before this returns and
  /// remains usable if it fails. The shell kicks it once at start-up.
  Future<void> initialize() async {
    try {
      final List<FocusSession> loaded = await _sessionLog.load();
      if (_disposed) return;
      _sessions = List<FocusSession>.unmodifiable(loaded);
      notifyListeners();
    } catch (exception) {
      _logs.log(
        'Focus history could not be read · $exception',
        level: LogLevel.warn,
      );
    }
  }

  /// Every completed session, oldest first.
  List<FocusSession> get sessions => _sessions;

  /// Completed sessions grouped into days, newest day first.
  List<DailyFocusTally> get dailyTallies => tallyByDay(_sessions);

  /// Today's count and focused time — the number the tab leads with.
  ///
  /// Derived on read rather than kept as a counter: a running app crosses
  /// midnight, and a stored "today" would be yesterday's by morning with nothing
  /// to trigger a correction.
  DailyFocusTally get today {
    final DateTime day = focusDayOf(_clock());
    for (final DailyFocusTally tally in dailyTallies) {
      if (tally.day == day) return tally;
    }
    return DailyFocusTally(day: day, sessions: 0, focused: Duration.zero);
  }

  /// The last [days] calendar days, oldest first, **including days with nothing
  /// on them**.
  ///
  /// The gaps are the point: "three sessions a day" and "three sessions once a
  /// week" are the same list of tallies and a very different working week, so a
  /// strip that silently skipped the empty days would misreport the habit it
  /// exists to show.
  List<DailyFocusTally> recentDays(int days) {
    final Map<DateTime, DailyFocusTally> byDay = <DateTime, DailyFocusTally>{
      for (final DailyFocusTally tally in dailyTallies) tally.day: tally,
    };
    final DateTime today = focusDayOf(_clock());
    return <DailyFocusTally>[
      for (int offset = days - 1; offset >= 0; offset--)
        () {
          final DateTime day = DateTime(
            today.year,
            today.month,
            today.day - offset,
          );
          return byDay[day] ??
              DailyFocusTally(day: day, sessions: 0, focused: Duration.zero);
        }(),
    ];
  }

  /// Sessions from the last [days] calendar days, busiest project first.
  ///
  /// Bounded by the same window the strip shows so the two panels answer the
  /// same question — an all-time project split beside a seven-day strip would
  /// invite reading one as the explanation of the other.
  List<ProjectFocusTally> projectTallies(int days) {
    final DateTime from = DateTime(
      focusDayOf(_clock()).year,
      focusDayOf(_clock()).month,
      focusDayOf(_clock()).day - (days - 1),
    );
    return tallyByProject(
      _sessions
          .where(
            (FocusSession session) =>
                !focusDayOf(session.completedAt).isBefore(from),
          )
          .toList(growable: false),
    );
  }

  /// The length the *next* session runs for.
  ///
  /// Pushed down by the shell whenever settings change, so it can arrive at any
  /// moment — including mid-session. It therefore only touches the readout
  /// while nothing is live, exactly as swapping the transcription service only
  /// affects work started afterwards. A running session's length is changed by
  /// [extend] and by nothing else.
  void configure(Duration value) {
    final Duration clamped = TimerDefaults.clamp(value);
    if (clamped == _configured) return;
    _configured = clamped;
    if (!isLive) {
      _sessionDuration = clamped;
      _frozen = clamped;
      _remainingTicker.value = clamped;
      // A finished session whose length is changed is being set up again, so it
      // goes back to idle rather than sitting on a stale DONE.
      //
      // Only a *changed* length reaches this, because of the guard above — and
      // that guard has to stay. This method is a push-down the shell runs on
      // every settings change, so dropping it would clear the DONE screen when
      // the user picked a theme. Re-picking the length that just finished is
      // handled by the chip in `TimerTab`, where the tap is known to be a
      // deliberate one.
      _state = FocusTimerState.idle;
    }
    notifyListeners();
  }

  /// Which clip plays at zero. Same push-down path and the same rule: it is
  /// read when the session ends, so a change reaches even a session already
  /// running.
  void setAlarmSound(AlarmSound value) {
    if (value == _alarmSound) return;
    _alarmSound = value;
    notifyListeners();
  }

  /// Plays the chosen sound now, so picking one does not mean waiting out a
  /// session to hear it. Best-effort under the `ClipboardSink` contract.
  Future<void> previewAlarm() => _play(_alarmSound, preview: true);

  void start() {
    if (isRunning) return;
    _sessionDuration = _configured;
    _beginRunning(_configured);
    _logs.log('Focus timer started · ${_describe(_configured)}');
    notifyListeners();
  }

  void pause() {
    if (!isRunning) return;
    _frozen = _computeRemaining();
    _deadline = null;
    _state = FocusTimerState.paused;
    _stopTicker();
    _remainingTicker.value = _frozen;
    notifyListeners();
  }

  void resume() {
    if (!isPaused) return;
    _beginRunning(_frozen);
    notifyListeners();
  }

  /// One control for the primary action, because the screen only ever offers
  /// one: START while idle or finished, PAUSE while running, RESUME while
  /// paused.
  void toggle() {
    switch (_state) {
      case FocusTimerState.idle:
      case FocusTimerState.finished:
        start();
      case FocusTimerState.running:
        pause();
      case FocusTimerState.paused:
        resume();
    }
  }

  /// Back to a fresh session of the configured length, and silence.
  void reset() {
    _stopTicker();
    _deadline = null;
    _sessionDuration = _configured;
    _frozen = _configured;
    _remainingTicker.value = _configured;
    _state = FocusTimerState.idle;
    unawaited(_silence());
    notifyListeners();
  }

  /// Add [amount] to a live session — "five more minutes" without losing the
  /// thirty-five already spent.
  ///
  /// It grows [sessionDuration] as well as the deadline, so the ring keeps
  /// meaning "this much of *this* session is left" rather than jumping past
  /// full. The configured length is untouched: extending once must not silently
  /// redefine every session after it.
  void extend([Duration amount = TimerDefaults.step]) {
    if (!isLive) return;
    final Duration grown = _sessionDuration + amount;
    if (grown > TimerDefaults.max) return;
    _sessionDuration = grown;
    if (isRunning) {
      _deadline = _deadline!.add(amount);
      _remainingTicker.value = _computeRemaining();
    } else {
      _frozen += amount;
      _remainingTicker.value = _frozen;
    }
    notifyListeners();
  }

  /// Recompute from the clock. Driven by the periodic timer, and called
  /// directly by the tests, which inject their own clock rather than waiting on
  /// a real one — see the `_until` note in CLAUDE.md for why no test in this
  /// repo sleeps a fixed span for a `Timer`.
  @visibleForTesting
  void tick() {
    if (!isRunning) return;
    final Duration left = _computeRemaining();
    _remainingTicker.value = left;
    if (left > Duration.zero) return;
    _finish();
  }

  void _beginRunning(Duration left) {
    _deadline = _clock().add(left);
    _state = FocusTimerState.running;
    _remainingTicker.value = left;
    _startTicker();
  }

  void _finish() {
    _stopTicker();
    _deadline = null;
    _remainingTicker.value = Duration.zero;
    _state = FocusTimerState.finished;
    _logs.log(
      _goal.trim().isEmpty
          ? 'Focus session finished · ${_describe(_sessionDuration)}'
          : 'Focus session finished · ${_describe(_sessionDuration)} · '
                '${_goal.trim()}',
    );
    _record();
    unawaited(_play(_alarmSound));
    notifyListeners();
  }

  /// Count this session. The only place that writes to [_sessionLog], which is
  /// what makes "a pomodoro" mean exactly one thing: a run that reached zero.
  ///
  /// **In memory first, then the file** — the same order the revisions history
  /// uses. A failed append leaves the tally correct for the rest of the session
  /// and merely incomplete on disk, which is strictly better than a number that
  /// is wrong in both places. The write is best-effort under the `ClipboardSink`
  /// contract: it must never throw into a session that has already ended.
  void _record() {
    final String goal = _goal.trim();
    // Resolved here rather than at `start()`: the active project can change
    // during a session, and the honest attribution is the one that was true
    // when the work finished. A resolver that throws must not cost the session,
    // so it is treated like the alarm — the row simply goes down unattributed.
    FocusProject? project;
    try {
      project = _activeProject?.call();
    } catch (exception) {
      _logs.log(
        'Focus session project could not be resolved · $exception',
        level: LogLevel.warn,
      );
    }
    final FocusSession session = FocusSession(
      completedAt: _clock(),
      duration: _sessionDuration,
      goal: goal.isEmpty
          ? null
          : goal.length > FocusSession.maxGoalLength
          ? goal.substring(0, FocusSession.maxGoalLength)
          : goal,
      projectId: project?.id,
      projectName: project?.name,
    );
    _sessions = List<FocusSession>.unmodifiable(<FocusSession>[
      ..._sessions,
      session,
    ]);
    unawaited(_appendSession(session));
  }

  Future<void> _appendSession(FocusSession session) async {
    try {
      await _sessionLog.append(session);
    } catch (exception) {
      _logs.log(
        'Focus session could not be recorded · $exception',
        level: LogLevel.warn,
      );
    }
  }

  Duration _computeRemaining() {
    final DateTime? deadline = _deadline;
    if (deadline == null) return _frozen;
    final Duration left = deadline.difference(_clock());
    return left.isNegative ? Duration.zero : left;
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(tickInterval, (Timer _) => tick());
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  /// Best-effort, under the `ClipboardSink` contract: a missing audio device or
  /// a codec the platform will not open costs the sound, never the session. The
  /// end of a session is a fact the screen already reports.
  Future<void> _play(AlarmSound sound, {bool preview = false}) async {
    if (!sound.isAudible) return;
    try {
      await _alarm.play(sound);
    } catch (exception) {
      _logs.log(
        '${preview ? 'Alarm preview' : 'Alarm'} failed · ${sound.label} · '
        '$exception',
        level: LogLevel.warn,
      );
    }
  }

  Future<void> _silence() async {
    try {
      await _alarm.stop();
    } catch (_) {
      // Silencing something that is not playing is not a failure worth a line.
    }
  }

  static String _describe(Duration value) => '${value.inMinutes} min';

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stopTicker();
    unawaited(_silence());
    _remainingTicker.dispose();
    super.dispose();
  }
}

/// `40:00`, `05:09`, `1:12:30` — the countdown readout.
///
/// Rounded **up** to the second, which is what makes a fresh 40-minute session
/// read `40:00` rather than flicking to `39:59` on the first frame, and makes
/// `00:00` mean the session is genuinely over rather than merely under a second
/// from it. Hours are only printed once there are any, so the common case stays
/// four digits wide and the dial does not resize mid-session.
///
/// Distinct from `formatDuration` in the UI kit, which truncates and takes
/// minutes modulo 60 — correct for a recording's length, wrong for a 90-minute
/// countdown, which it would render as `30:00`.
String formatCountdown(Duration value) {
  final int total = value.isNegative ? 0 : (value.inMilliseconds / 1000).ceil();
  final int hours = total ~/ 3600;
  final String minutes = ((total % 3600) ~/ 60).toString().padLeft(2, '0');
  final String seconds = (total % 60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}
