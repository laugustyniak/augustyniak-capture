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
            title: 'COMPLETED SESSIONS',
            trailing: timer.sessions.isEmpty
                ? null
                : '${timer.sessions.length} all time',
          ),
          const SizedBox(height: 12),
          _FocusHistory(controller: timer),
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

/// How many pomodoros have actually been finished, today and over the past week.
///
/// It counts **completed** sessions only — a run that reached zero. Pauses,
/// resets and abandoned runs are not in the file, so this number cannot flatter
/// the day, which is the only reason it is worth putting on the screen.
class _FocusHistory extends StatelessWidget {
  _FocusHistory({required this.controller});

  final FocusTimerController controller;

  /// A week, because that is the span a working rhythm is visible over: a strip
  /// of three days says nothing about a habit, and a month of them would not
  /// fit beside a countdown.
  static const int windowDays = 7;

  static String _dayLabel(DateTime day) {
    const List<String> names = <String>[
      'Mon',
      'Tue',
      'Wed',
      'Thu',
      'Fri',
      'Sat',
      'Sun',
    ];
    return names[day.weekday - 1];
  }

  @override
  Widget build(BuildContext context) {
    final DailyFocusTally today = controller.today;
    final List<DailyFocusTally> week = controller.recentDays(windowDays);
    final int busiest = week.fold(
      1,
      (int peak, DailyFocusTally day) => day.sessions > peak ? day.sessions : peak,
    );

    if (controller.sessions.isEmpty) {
      return ConsoleCard(
        child: Text(
          'No sessions finished yet. A pomodoro is counted when the countdown '
          'reaches zero — pausing or resetting one leaves it out, so this stays '
          'a record of work actually done.',
          style: ConsoleText.micro.copyWith(height: 1.45),
        ),
      );
    }

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
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  today.sessions == 1 ? 'session today' : 'sessions today',
                  style: ConsoleText.cardMeta,
                ),
              ),
              const Spacer(),
              if (!today.isEmpty)
                Text(
                  '${today.focused.inMinutes} min focused',
                  style: ConsoleText.micro,
                ),
            ],
          ),
          const SizedBox(height: 16),
          for (final DailyFocusTally day in week) ...<Widget>[
            _DayRow(day: day, busiest: busiest),
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }
}

/// One day of the strip: label, a bar proportional to the busiest day shown,
/// and the count.
///
/// Days with nothing on them are drawn rather than skipped — an empty row is
/// the fact that no session was finished, and a strip that omitted them would
/// make a week of one-a-day look identical to a single busy Monday.
class _DayRow extends StatelessWidget {
  _DayRow({required this.day, required this.busiest});

  final DailyFocusTally day;
  final int busiest;

  @override
  Widget build(BuildContext context) {
    final bool empty = day.isEmpty;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 34,
          child: Text(
            _FocusHistory._dayLabel(day.day),
            style: ConsoleText.micro.copyWith(
              color: empty ? Console.dimText : Console.textSoft,
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
                  if (!empty)
                    Container(
                      height: 8,
                      width: constraints.maxWidth * (day.sessions / busiest),
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
            empty ? '–' : '${day.sessions}',
            textAlign: TextAlign.right,
            style: ConsoleText.micro.copyWith(
              color: empty ? Console.dimText : Console.text,
            ),
          ),
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
