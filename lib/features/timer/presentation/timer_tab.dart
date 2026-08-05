import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../../settings/presentation/settings_controller.dart';
import '../domain/alarm_sound.dart';
import '../domain/focus_session.dart';
import '../domain/timer_defaults.dart';
import 'countdown_dial.dart';
import 'focus_timer_controller.dart';

/// The Timer tab: one focus session at a time, its length, its goal and what it
/// says when it ends.
///
/// The two halves are owned by different objects on purpose. The **session** —
/// running, paused, how much is left — belongs to [FocusTimerController] and is
/// never written to disk, though the *fact that one finished* is, which is what
/// the COMPLETED SESSIONS panel reads. The **configuration** — length and alarm
/// — belongs to [SettingsController] like every other persisted preference, and
/// reaches the timer through the shell. So the chips here write to settings and
/// the change arrives back down; the tab holds no third copy of either fact.
class TimerTab extends StatefulWidget {
  const TimerTab({super.key, required this.controller, required this.settings});

  final FocusTimerController controller;
  final SettingsController settings;

  @override
  State<TimerTab> createState() => _TimerTabState();
}

class _TimerTabState extends State<TimerTab> {
  final TextEditingController _goal = TextEditingController();
  final FocusNode _goalFocus = FocusNode();

  /// The last value taken *from* the controller, so "dirty" means a difference
  /// from what was synced rather than from what happens to be there now — the
  /// same rule `RecordingEditor` uses to keep a background write from
  /// overwriting something being typed.
  String _synced = '';

  @override
  void initState() {
    super.initState();
    _synced = widget.controller.goal;
    _goal.text = _synced;
    // Written on blur as well as on submit: a goal typed and then left alone
    // while the session runs would otherwise never reach the controller, and so
    // would never reach the log line the session writes when it ends.
    _goalFocus.addListener(() {
      if (!_goalFocus.hasFocus) _commitGoal();
    });
  }

  @override
  void didUpdateWidget(covariant TimerTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final String current = widget.controller.goal;
    if (current != _synced && _goal.text == _synced) {
      _synced = current;
      _goal.text = current;
    }
  }

  void _commitGoal() {
    _synced = _goal.text;
    widget.controller.goal = _goal.text;
  }

  @override
  void dispose() {
    _goal.dispose();
    _goalFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final FocusTimerController timer = widget.controller;
    final DateTime? endsAt = timer.endsAt;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 40),
        children: <Widget>[
          ConsoleHeader(
            title: 'Timer',
            // While a session runs, the useful fact is not how long it is but
            // when it is over — that is the number you compare against the next
            // thing in the day.
            trailing: endsAt == null
                ? '${timer.duration.inMinutes} min'
                : 'ends ${formatTimeOfDay(endsAt)}',
          ),
          const SizedBox(height: 20),
          Center(
            child: CountdownDial(
              remaining: timer.remaining,
              total: timer.sessionDuration,
              state: timer.state,
            ),
          ),
          const SizedBox(height: 22),
          _Controls(controller: timer),
          if (timer.isFinished) ...<Widget>[
            const SizedBox(height: 16),
            _FinishedPanel(controller: timer),
          ],
          const SizedBox(height: 26),
          SectionHeader(
            title: 'SESSIONS DONE',
            trailing: timer.sessions.isEmpty
                ? null
                : '${timer.sessions.length} total',
          ),
          const SizedBox(height: 12),
          // Keyed, and that is load-bearing. This card sits below a
          // conditional `_FinishedPanel`, so finishing a session inserts two
          // children above it in a keyless `ListView`; index-based reconciliation
          // would then discard the state holding the chosen window, collapsing a
          // 30-day view back to 7 at the exact moment the user looks at it.
          _FocusHistory(
            key: const ValueKey<String>('focus-history'),
            controller: timer,
          ),
          const SizedBox(height: 26),
          SectionHeader(
            title: 'SESSION GOAL',
            trailing: timer.isRunning ? 'work until zero' : null,
          ),
          const SizedBox(height: 10),
          ConsoleField(
            controller: _goal,
            focusNode: _goalFocus,
            hintText: 'what are you working on?',
            textInputAction: TextInputAction.done,
            onSubmitted: (String _) => _commitGoal(),
          ),
          const SizedBox(height: 8),
          Text(
            'Kept for the whole run and carried into the log line the session '
            'writes when it ends. It survives RESET, because the next pomodoro '
            'is usually the same piece of work.',
            style: TextStyle(
              color: Console.mutedSoft,
              fontSize: 10,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 26),
          SectionHeader(
            title: 'SESSION LENGTH',
            trailing: timer.isLive ? 'applies to the next session' : null,
          ),
          const SizedBox(height: 12),
          ConsoleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final int minutes in TimerDefaults.presetMinutes)
                      ConsoleChip(
                        label: minutes == TimerDefaults.defaultMinutes
                            ? '$minutes min (Recommended)'
                            : '$minutes min',
                        selected: timer.duration.inMinutes == minutes,
                        // Picking a length after a session ended is setting the
                        // next one up, so the dial leaves DONE here rather than
                        // in `configure`. It cannot be done there: `configure`
                        // is a push-down the shell runs on *every* settings
                        // change, so resetting from inside it would wipe the
                        // DONE screen when the user changed the theme. And it
                        // cannot ride `setTimerDuration` either — that setter
                        // drops a value equal to the stored one, so re-picking
                        // the length just finished would never arrive. Here the
                        // tap is known to be the user's.
                        onSelected: () {
                          if (timer.isFinished) timer.reset();
                          widget.settings.setTimerDuration(
                            Duration(minutes: minutes),
                          );
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  // The rule, stated where it can surprise someone: the chips
                  // are configuration, and configuration never reaches into a
                  // run already under way — the same contract as swapping the
                  // transcription provider mid-capture.
                  timer.isLive
                      ? 'A session already running keeps its length. Use +5 MIN '
                            'to stretch this one.'
                      : 'The countdown reads the clock, not a counter: a '
                            'machine that sleeps through a session wakes up '
                            'with it finished.',
                  style: TextStyle(
                    color: Console.mutedSoft,
                    fontSize: 10,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 26),
          SectionHeader(title: 'ALARM AT ZERO'),
          const SizedBox(height: 12),
          ConsoleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          for (final AlarmSound sound in AlarmSound.values)
                            ConsoleChip(
                              label: sound.label,
                              selected: timer.alarmSound == sound,
                              onSelected: () =>
                                  widget.settings.setTimerAlarm(sound),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Silence has nothing to preview, and a play button that
                    // does nothing is indistinguishable from a broken one.
                    if (timer.alarmSound.isAudible)
                      ConsoleIconButton(
                        icon: Icons.volume_up_rounded,
                        semanticLabel: 'Preview alarm sound',
                        onTap: timer.previewAlarm,
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  timer.alarmSound.blurb,
                  style: ConsoleText.micro.copyWith(height: 1.45),
                ),
                const SizedBox(height: 6),
                Text(
                  'Bundled with the app, like the fonts — nothing is fetched, '
                  'so the alarm rings offline. A device that refuses to play it '
                  'costs the sound, never the session.',
                  style: TextStyle(
                    color: Console.mutedSoft,
                    fontSize: 10,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// START / PAUSE / RESUME, with RESET and +5 MIN beside it.
///
/// One primary control, because the screen only ever has one primary thing to
/// do; what it says is derived from the state rather than from a second flag.
class _Controls extends StatelessWidget {
  _Controls({required this.controller});

  final FocusTimerController controller;

  /// Public-ish strings: the widget tests assert on what is rendered.
  static const String startLabel = 'START';
  static const String pauseLabel = 'PAUSE';
  static const String resumeLabel = 'RESUME';
  static const String restartLabel = 'START AGAIN';

  String get _label => switch (controller.state) {
    FocusTimerState.idle => startLabel,
    FocusTimerState.running => pauseLabel,
    FocusTimerState.paused => resumeLabel,
    FocusTimerState.finished => restartLabel,
  };

  IconData get _icon =>
      controller.isRunning ? Icons.pause_rounded : Icons.play_arrow_rounded;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: _PrimaryButton(
            label: _label,
            icon: _icon,
            onTap: controller.toggle,
          ),
        ),
        if (controller.isLive) ...<Widget>[
          const SizedBox(width: 10),
          _OutlineButton(
            label: '+5 MIN',
            semanticLabel: 'Extend this session by five minutes',
            onTap: controller.extend,
          ),
        ],
        if (controller.state != FocusTimerState.idle) ...<Widget>[
          const SizedBox(width: 10),
          ConsoleIconButton(
            icon: Icons.restart_alt_rounded,
            semanticLabel: 'Reset the timer',
            size: 52,
            iconSize: 21,
            onTap: controller.reset,
          ),
        ],
      ],
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  _PrimaryButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      // Excluded so a screen reader announces the action once rather than
      // announcing the caption and the label as two separate things — the same
      // reason the nav rail's capture buttons exclude theirs.
      excludeSemantics: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Console.accent,
            borderRadius: BorderRadius.circular(14),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Console.accent.withValues(alpha: .35),
                blurRadius: 28,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 20, color: Console.ink),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontFamily: ConsoleFont.display,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2.4,
                  color: Console.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OutlineButton extends StatelessWidget {
  _OutlineButton({
    required this.label,
    required this.semanticLabel,
    required this.onTap,
  });

  final String label;
  final String semanticLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: semanticLabel,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Console.borderStrong),
          ),
          child: Text(
            label,
            style: ConsoleText.pill.copyWith(
              fontSize: 12,
              letterSpacing: 1.2,
              color: Console.textSoft,
            ),
          ),
        ),
      ),
    );
  }
}

/// How many pomodoros have actually been finished — today, over a chosen
/// window, and split by the project they were spent on.
///
/// It counts **completed** sessions only: a run that reached zero. Pauses,
/// resets and abandoned runs are not in the file, so this number cannot flatter
/// the day, which is the only reason it is worth putting on the screen.
class _FocusHistory extends StatefulWidget {
  _FocusHistory({super.key, required this.controller});

  final FocusTimerController controller;

  /// The two windows offered. A week is the span a working rhythm is visible
  /// over; a month is where a habit — or a fortnight of not working — becomes
  /// obvious. Anything longer stops being a thing you read beside a countdown.
  static const List<int> windows = <int>[7, 30];

  @override
  State<_FocusHistory> createState() => _FocusHistoryState();
}

class _FocusHistoryState extends State<_FocusHistory> {
  int _days = _FocusHistory.windows.first;

  @override
  Widget build(BuildContext context) {
    final FocusTimerController timer = widget.controller;
    final DailyFocusTally today = timer.today;
    final List<DailyFocusTally> window = timer.recentDays(_days);
    final List<ProjectFocusTally> projects = timer.projectTallies(_days);

    // Three states, not two. "Nothing done yet" is a claim about the user's
    // history and must not be made when the file simply could not be read.
    if (timer.historyUnreadable) {
      return ConsoleCard(
        accent: Console.amber.withValues(alpha: .45),
        child: Text(
          'The session history could not be read, so this is not a count of '
          'nothing — it is no answer. Finished sessions are still being '
          'appended; the Logs tab has the reason.',
          style: ConsoleText.micro.copyWith(height: 1.45),
        ),
      );
    }
    if (timer.sessions.isEmpty) {
      return ConsoleCard(
        child: Text(
          'No sessions finished yet. A pomodoro is counted when the countdown '
          'reaches zero — pausing or resetting one leaves it out, so this stays '
          'a record of work actually done.',
          style: ConsoleText.micro.copyWith(height: 1.45),
        ),
      );
    }

    final int inWindow = window.fold(
      0,
      (int total, DailyFocusTally day) => total + day.sessions,
    );

    return ConsoleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                '${today.sessions}',
                style: TextStyle(
                  fontFamily: ConsoleFont.display,
                  fontSize: 34,
                  fontWeight: FontWeight.w700,
                  height: 1,
                  color: today.isEmpty ? Console.mutedSoft : Console.accent,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    'today',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ConsoleText.cardMeta,
                  ),
                ),
              ),
              if (!today.isEmpty)
                Text(
                  '${today.focused.inMinutes} min',
                  maxLines: 1,
                  style: ConsoleText.micro,
                ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              for (final int days in _FocusHistory.windows) ...<Widget>[
                ConsoleChip(
                  label: '$days DAYS',
                  selected: days == _days,
                  onSelected: () => setState(() => _days = days),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  '$inWindow in $_days days',
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ConsoleText.micro,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // A week is few enough rows to label each day and give it a bar; a
          // month is not, so it switches to a calendar grid rather than
          // shrinking thirty labelled rows into something unreadable.
          if (_days <= 7)
            _DayBars(days: window)
          else
            _FocusCalendar(days: window),
          // Two conditions, and each rules out a different empty answer. With
          // no project on any session the whole section is one full-width
          // `No project` bar; with only one row it just restates the total
          // above it in more words. Nothing is a clearer answer than either.
          if (projects.length > 1 &&
              projects.any(
                (ProjectFocusTally project) => project.projectId != null,
              )) ...<Widget>[
            const SizedBox(height: 18),
            Container(height: 1, color: Console.border),
            const SizedBox(height: 14),
            Text('WHERE IT WENT', style: ConsoleText.pill),
            const SizedBox(height: 10),
            _ProjectSplit(projects: projects),
          ],
        ],
      ),
    );
  }
}

/// The week view: one labelled row per day, bar proportional to the busiest day
/// shown.
///
/// Days with nothing on them are drawn rather than skipped — an empty row is the
/// fact that no session was finished, and a strip that omitted them would make
/// one busy Monday look like a steady week.
class _DayBars extends StatelessWidget {
  _DayBars({required this.days});

  final List<DailyFocusTally> days;

  static const List<String> _names = <String>[
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];

  @override
  Widget build(BuildContext context) {
    final int busiest = days.fold(
      1,
      (int peak, DailyFocusTally day) =>
          day.sessions > peak ? day.sessions : peak,
    );

    return Column(
      children: <Widget>[
        for (final DailyFocusTally day in days) ...<Widget>[
          Row(
            children: <Widget>[
              SizedBox(
                width: 34,
                child: Text(
                  _names[day.day.weekday - 1],
                  style: ConsoleText.micro.copyWith(
                    color: day.isEmpty ? Console.dimText : Console.textSoft,
                  ),
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    return Stack(
                      children: <Widget>[
                        Container(
                          height: 8,
                          decoration: BoxDecoration(
                            color: Console.track,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        if (!day.isEmpty)
                          Container(
                            height: 8,
                            width:
                                constraints.maxWidth * (day.sessions / busiest),
                            decoration: BoxDecoration(
                              color: Console.accent,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
              SizedBox(
                width: 26,
                child: Text(
                  day.isEmpty ? '\u2013' : '${day.sessions}',
                  textAlign: TextAlign.right,
                  style: ConsoleText.micro.copyWith(
                    color: day.isEmpty ? Console.dimText : Console.text,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
        ],
      ],
    );
  }
}

/// The month view: a calendar grid, weeks running left to right and weekdays
/// down, each cell shaded by how many sessions that day held.
///
/// **One hue, light to dark.** Session count is a magnitude, so it takes a
/// sequential scale rather than a set of distinct colours — a rainbow here would
/// imply the days were different *kinds* of thing rather than more and less of
/// the same one. Empty days keep the track colour, so a gap is visibly a gap and
/// not a missing cell.
class _FocusCalendar extends StatelessWidget {
  _FocusCalendar({required this.days});

  final List<DailyFocusTally> days;

  static const double _cell = 15;
  static const double _gap = 4;

  /// Four steps plus the empty track. More steps than this stop being tellable
  /// apart at 15 px, which is the size the grid has to be to fit a month beside
  /// a countdown.
  static Color _shade(int sessions) {
    if (sessions <= 0) return Console.track;
    if (sessions == 1) return Console.accent.withValues(alpha: .32);
    if (sessions == 2) return Console.accent.withValues(alpha: .55);
    if (sessions == 3) return Console.accent.withValues(alpha: .78);
    return Console.accent;
  }

  static String _label(DailyFocusTally day) {
    final String date = '${day.day.day}/${day.day.month}';
    if (day.isEmpty) return '$date · nothing finished';
    final String count = day.sessions == 1 ? '1 session' : '${day.sessions} sessions';
    return '$date · $count · ${day.focused.inMinutes} min';
  }

  @override
  Widget build(BuildContext context) {
    if (days.isEmpty) return const SizedBox.shrink();

    // Aligned back to the Monday on or before the first day shown, so the rows
    // are weekdays and a column is a real week rather than an arbitrary seven.
    final DateTime first = days.first.day;
    // Calendar arithmetic, never `Duration` — a day is not always 24 hours.
    // `subtract(Duration(days: n))` would drift in a timezone whose transition
    // lands at midnight, and deriving the column count from
    // `difference().inDays` truncates an hour away across spring-forward: in
    // Europe/Warsaw that produced one column too few on five Mondays a year,
    // and the day it dropped was *today*. Both numbers below come from integers
    // the caller already has.
    final DateTime start = DateTime(
      first.year,
      first.month,
      first.day - (first.weekday - 1),
    );
    final DateTime last = days.last.day;
    final Map<DateTime, DailyFocusTally> byDay = <DateTime, DailyFocusTally>{
      for (final DailyFocusTally day in days) day.day: day,
    };
    final int columns = columnsFor(first.weekday, days.length);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int row = 0; row < 7; row++) ...<Widget>[
          Row(
            children: <Widget>[
              SizedBox(
                width: 30,
                child: Text(
                  // Every other weekday, so the labels do not crowd a 15 px row.
                  row.isEven ? _DayBars._names[row] : '',
                  style: ConsoleText.micro.copyWith(color: Console.dimText),
                ),
              ),
              for (int column = 0; column < columns; column++) ...<Widget>[
                Builder(
                  builder: (BuildContext context) {
                    final DateTime day = DateTime(
                      start.year,
                      start.month,
                      start.day + column * 7 + row,
                    );
                    final bool inRange =
                        !day.isBefore(first) && !day.isAfter(last);
                    if (!inRange) {
                      return const SizedBox(
                        width: _cell,
                        height: _cell,
                      );
                    }
                    final DailyFocusTally tally =
                        byDay[day] ??
                        DailyFocusTally(
                          day: day,
                          sessions: 0,
                          focused: Duration.zero,
                        );
                    return Tooltip(
                      // Tap rather than the default long-press: on a phone the
                      // grid is otherwise thirty unlabelled squares whose counts
                      // need a gesture nothing on screen suggests.
                      triggerMode: TooltipTriggerMode.tap,
                      message: _label(tally),
                      child: Container(
                        width: _cell,
                        height: _cell,
                        decoration: BoxDecoration(
                          color: _shade(tally.sessions),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(width: _gap),
              ],
            ],
          ),
          const SizedBox(height: _gap),
        ],
        const SizedBox(height: 4),
        // The scale, named — a shaded grid is unreadable without it, and this is
        // the one legend the panel needs since there is only ever one series.
        Row(
          children: <Widget>[
            const SizedBox(width: 30),
            Text('less', style: ConsoleText.micro.copyWith(color: Console.dimText)),
            const SizedBox(width: 6),
            for (final int step in <int>[0, 1, 2, 3, 4]) ...<Widget>[
              Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: _shade(step),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 3),
            ],
            const SizedBox(width: 3),
            Text('more', style: ConsoleText.micro.copyWith(color: Console.dimText)),
          ],
        ),
      ],
    );
  }
}

/// Which projects the finished sessions went into.
///
/// Sessions run with no project active keep a row of their own rather than
/// being dropped: unattributed focus is a fact about the period worth seeing.
class _ProjectSplit extends StatelessWidget {
  _ProjectSplit({required this.projects});

  final List<ProjectFocusTally> projects;

  /// Enough to see where the time actually goes without the panel turning into
  /// a second screen. The remainder is summed into one honest row rather than
  /// silently dropped.
  static const int maxRows = 4;

  @override
  Widget build(BuildContext context) {
    // Partitioned before the cap. `tallyByProject` pins unattributed time last,
    // so a plain `take(maxRows)` would drop the residual row exactly when there
    // are five or more projects — and the `n more projects` tail would then be
    // counting something that is not a project.
    final List<ProjectFocusTally> named = projects
        .where((ProjectFocusTally project) => project.projectId != null)
        .toList();
    final ProjectFocusTally? residual = projects
        .where((ProjectFocusTally project) => project.projectId == null)
        .firstOrNull;
    final List<ProjectFocusTally> shown = <ProjectFocusTally>[
      ...named.take(maxRows),
      ?residual,
    ];
    final List<ProjectFocusTally> rest = named.skip(maxRows).toList();
    final int busiest = shown.fold(
      1,
      (int peak, ProjectFocusTally project) =>
          project.sessions > peak ? project.sessions : peak,
    );
    final int restSessions = rest.fold(
      0,
      (int total, ProjectFocusTally project) => total + project.sessions,
    );
    final Duration restFocused = rest.fold(
      Duration.zero,
      (Duration total, ProjectFocusTally project) => total + project.focused,
    );

    return Column(
      children: <Widget>[
        for (final ProjectFocusTally project in shown) ...<Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  project.projectName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ConsoleText.micro.copyWith(
                    color: project.projectId == null
                        ? Console.dimText
                        : Console.textSoft,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 74,
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    return Stack(
                      children: <Widget>[
                        Container(
                          height: 6,
                          margin: const EdgeInsets.only(top: 3),
                          decoration: BoxDecoration(
                            color: Console.track,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        Container(
                          height: 6,
                          margin: const EdgeInsets.only(top: 3),
                          width: constraints.maxWidth *
                              (project.sessions / busiest),
                          decoration: BoxDecoration(
                            // The unattributed row is deliberately dimmer: it is
                            // a residue, not a destination competing with the
                            // named projects above it.
                            color: project.projectId == null
                                ? Console.mutedSoft
                                : Console.accent,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 54,
                child: Text(
                  '${project.sessions} · ${project.focused.inMinutes}m',
                  textAlign: TextAlign.right,
                  style: ConsoleText.micro,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
        ],
        // The tail keeps the columns of the rows above it: the right-hand
        // figure is sessions and minutes there, so it must be sessions and
        // minutes here too. Reporting a *project* count in that column made the
        // minute column stop summing to the window total.
        if (rest.isNotEmpty)
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  rest.length == 1 ? '1 more project' : '${rest.length} more projects',
                  style: ConsoleText.micro.copyWith(color: Console.dimText),
                ),
              ),
              const SizedBox(width: 10),
              const SizedBox(width: 74),
              const SizedBox(width: 10),
              SizedBox(
                width: 54,
                child: Text(
                  '$restSessions · ${restFocused.inMinutes}m',
                  textAlign: TextAlign.right,
                  style: ConsoleText.micro.copyWith(color: Console.dimText),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// What the session was, once it is over. Green rather than the accent: it is
/// the one moment on this screen that reports a completed thing.
class _FinishedPanel extends StatelessWidget {
  _FinishedPanel({required this.controller});

  final FocusTimerController controller;

  static String _duration(Duration value) {
    final int minutes = value.inMinutes;
    return '$minutes ${minutes == 1 ? 'minute' : 'minutes'} done';
  }

  @override
  Widget build(BuildContext context) {
    final String goal = controller.goal.trim();
    return ConsoleCard(
      accent: Console.green.withValues(alpha: .45),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ConsoleIconTile(
            icon: Icons.check_rounded,
            color: Console.green,
            size: 34,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  _duration(controller.sessionDuration),
                  style: ConsoleText.cardTitle,
                ),
                const SizedBox(height: 4),
                Text(
                  goal.isEmpty
                      ? 'RESET stops the alarm and sets up the next session.'
                      : goal,
                  style: ConsoleText.micro.copyWith(height: 1.45),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
