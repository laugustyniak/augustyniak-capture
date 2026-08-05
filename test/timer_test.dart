import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/settings/data/settings_repository.dart';
import 'package:augustyniak_capture/features/settings/domain/app_settings.dart';
import 'package:augustyniak_capture/features/settings/presentation/settings_controller.dart';
import 'package:augustyniak_capture/features/timer/domain/alarm_player.dart';
import 'package:augustyniak_capture/features/timer/domain/alarm_sound.dart';
import 'package:augustyniak_capture/features/timer/domain/focus_session.dart';
import 'package:augustyniak_capture/features/timer/domain/timer_defaults.dart';
import 'package:augustyniak_capture/features/timer/presentation/focus_timer_controller.dart';

/// Records what the session asked to be played, so the pure-Dart suite can
/// assert on the alarm without an audio device existing.
class _FakeAlarmPlayer implements AlarmPlayer {
  final List<AlarmSound> played = <AlarmSound>[];
  int stops = 0;

  @override
  Future<void> play(AlarmSound sound) async => played.add(sound);

  @override
  Future<void> stop() async => stops++;
}

/// An alarm device that refuses. The session must survive it — the end of a
/// session is a fact the screen already reports, so a silent one is a worse
/// session rather than a broken app.
class _BrokenAlarmPlayer implements AlarmPlayer {
  @override
  Future<void> play(AlarmSound sound) async => throw StateError('no device');

  @override
  Future<void> stop() async {}
}

class _FakeSettingsRepository extends SettingsRepository {
  AppSettings? stored;

  @override
  Future<AppSettings?> load() async => stored;

  @override
  Future<void> save(AppSettings settings) async => stored = settings;
}

/// A clock the test moves by hand.
///
/// No test here sleeps for a real `Timer` — the controller reads time from this
/// function and `tick()` is called directly, so a forty-minute session is
/// asserted in microseconds and a busy machine cannot make the suite flake. See
/// the `_until` note in CLAUDE.md for the failure this avoids.
class _FakeClock {
  DateTime now = DateTime(2026, 8, 5, 9, 0);

  DateTime call() => now;

  void advance(Duration by) => now = now.add(by);
}

/// An in-memory stand-in for `focus-sessions.jsonl`.
class _FakeSessionLog implements FocusSessionLog {
  _FakeSessionLog({List<FocusSession>? stored})
    : rows = <FocusSession>[...?stored];

  final List<FocusSession> rows;
  bool failAppend = false;

  @override
  Future<List<FocusSession>> load() async => List<FocusSession>.of(rows);

  @override
  Future<void> append(FocusSession session) async {
    if (failAppend) throw const FileSystemException('disk is full');
    rows.add(session);
  }
}

void main() {
  late _FakeClock clock;
  late _FakeAlarmPlayer alarm;
  late _FakeSessionLog sessionLog;

  FocusTimerController build({
    AlarmPlayer? player,
    FocusSessionLog? log,
    FocusProjectResolver? activeProject,
  }) {
    final FocusTimerController controller = FocusTimerController(
      alarmPlayer: player ?? alarm,
      sessionLog: log ?? sessionLog,
      activeProject: activeProject,
      clock: clock.call,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  /// Runs a session to zero, the only thing that counts as a pomodoro.
  void runToZero(FocusTimerController timer) {
    timer.start();
    clock.advance(timer.sessionDuration);
    timer.tick();
  }

  setUp(() {
    clock = _FakeClock();
    alarm = _FakeAlarmPlayer();
    sessionLog = _FakeSessionLog();
  });

  group('FocusTimerController', () {
    test('a fresh timer is idle at the shipped forty minutes', () {
      final FocusTimerController timer = build();

      expect(timer.state, FocusTimerState.idle);
      expect(timer.duration, const Duration(minutes: 40));
      expect(timer.remaining.value, const Duration(minutes: 40));
      expect(timer.progress, 1);
      expect(timer.endsAt, isNull);
    });

    test('a running session counts down from the clock', () {
      final FocusTimerController timer = build()..start();

      expect(timer.state, FocusTimerState.running);
      expect(timer.endsAt, DateTime(2026, 8, 5, 9, 40));

      clock.advance(const Duration(minutes: 10));
      timer.tick();

      expect(timer.remaining.value, const Duration(minutes: 30));
      expect(timer.progress, closeTo(0.75, 0.001));
    });

    test(
      'a machine that sleeps through the session wakes up with it finished',
      () {
        // The whole reason the deadline is stored rather than a counter
        // decremented: a controller that subtracted per tick would come back
        // from a suspended process claiming most of the session was still left.
        final FocusTimerController timer = build()..start();

        clock.advance(const Duration(hours: 3));
        timer.tick();

        expect(timer.state, FocusTimerState.finished);
        expect(timer.remaining.value, Duration.zero);
        expect(timer.progress, 0);
        expect(alarm.played, <AlarmSound>[AlarmSound.chime]);
      },
    );

    test('the alarm fires once, and plays the sound that was chosen', () {
      final FocusTimerController timer = build()
        ..setAlarmSound(AlarmSound.bell)
        ..start();

      clock.advance(const Duration(minutes: 41));
      timer.tick();
      // Further ticks land on a finished session and must not ring again.
      timer.tick();
      timer.tick();

      expect(alarm.played, <AlarmSound>[AlarmSound.bell]);
    });

    test('the silent choice reaches zero without playing anything', () {
      final FocusTimerController timer = build()
        ..setAlarmSound(AlarmSound.none)
        ..start();

      clock.advance(const Duration(minutes: 41));
      timer.tick();

      expect(timer.state, FocusTimerState.finished);
      expect(alarm.played, isEmpty);
    });

    test('an audio device that refuses costs the sound, not the session', () {
      final FocusTimerController timer = build(player: _BrokenAlarmPlayer())
        ..start();

      clock.advance(const Duration(minutes: 41));
      timer.tick();

      expect(timer.state, FocusTimerState.finished);
      expect(timer.remaining.value, Duration.zero);
    });

    test('pausing freezes the remaining time; the pause itself is free', () {
      final FocusTimerController timer = build()..start();

      clock.advance(const Duration(minutes: 15));
      timer.tick();
      timer.pause();

      expect(timer.state, FocusTimerState.paused);
      expect(timer.remaining.value, const Duration(minutes: 25));
      // A paused session has no end instant — inventing one from `now +
      // remaining` would print a time that moved while nothing counted down.
      expect(timer.endsAt, isNull);

      clock.advance(const Duration(hours: 2));
      timer.resume();

      expect(timer.state, FocusTimerState.running);
      expect(timer.remaining.value, const Duration(minutes: 25));
      expect(timer.endsAt, DateTime(2026, 8, 5, 11, 40));
    });

    test('reset returns to a fresh session and silences the alarm', () {
      final FocusTimerController timer = build()..start();

      clock.advance(const Duration(minutes: 41));
      timer.tick();
      timer.reset();

      expect(timer.state, FocusTimerState.idle);
      expect(timer.remaining.value, const Duration(minutes: 40));
      expect(alarm.stops, greaterThan(0));
    });

    test('the goal survives a reset', () {
      // Consecutive pomodoros are usually the same piece of work; retyping it
      // is the friction that stops the field being used at all.
      final FocusTimerController timer = build()
        ..goal = 'rewrite the vault section'
        ..start();

      timer.reset();

      expect(timer.goal, 'rewrite the vault section');
    });

    test('a length change never reaches a session already running', () {
      final FocusTimerController timer = build()..start();

      clock.advance(const Duration(minutes: 5));
      timer.tick();
      timer.configure(const Duration(minutes: 90));

      // The run keeps its own length and its own deadline...
      expect(timer.sessionDuration, const Duration(minutes: 40));
      expect(timer.remaining.value, const Duration(minutes: 35));
      expect(timer.endsAt, DateTime(2026, 8, 5, 9, 40));
      // ...and the new length is what the next one starts from.
      expect(timer.duration, const Duration(minutes: 90));

      timer.reset();
      expect(timer.remaining.value, const Duration(minutes: 90));
    });

    test('a length change while idle moves the dial straight away', () {
      final FocusTimerController timer = build()
        ..configure(const Duration(minutes: 25));

      expect(timer.remaining.value, const Duration(minutes: 25));
      expect(timer.sessionDuration, const Duration(minutes: 25));
    });

    test('a length change clears a finished session off DONE', () {
      final FocusTimerController timer = build()..start();
      clock.advance(const Duration(hours: 3));
      timer.tick();
      expect(timer.state, FocusTimerState.finished);

      timer.configure(const Duration(minutes: 25));

      expect(timer.state, FocusTimerState.idle);
      expect(timer.remaining.value, const Duration(minutes: 25));
    });

    test('an unchanged length leaves a finished session on DONE', () {
      // The guard in `configure` is what protects this, and it has to stay:
      // the shell pushes this method down on *every* settings change, so a
      // reset here would clear the DONE screen when the user picked a theme
      // or changed the bitrate. Re-picking the length that just finished is
      // the chip's job in TimerTab, where the tap is known to be deliberate.
      final FocusTimerController timer = build()..start();
      clock.advance(const Duration(hours: 3));
      timer.tick();

      timer.configure(timer.duration);

      expect(timer.state, FocusTimerState.finished);
      expect(timer.remaining.value, Duration.zero);
    });

    test('a length outside the supported range is pulled into it', () {
      final FocusTimerController timer = build()
        ..configure(const Duration(seconds: 5));
      expect(timer.duration, TimerDefaults.min);

      timer.configure(const Duration(days: 1));
      expect(timer.duration, TimerDefaults.max);
    });

    test('extending a live session grows the ring with it', () {
      final FocusTimerController timer = build()..start();

      clock.advance(const Duration(minutes: 38));
      timer.tick();
      timer.extend();

      expect(timer.remaining.value, const Duration(minutes: 7));
      expect(timer.sessionDuration, const Duration(minutes: 45));
      // The ring stays a proportion of *this* session rather than jumping past
      // full, and the configured length is untouched: stretching once must not
      // silently redefine every session after it.
      expect(timer.progress, closeTo(7 / 45, 0.001));
      expect(timer.duration, const Duration(minutes: 40));
    });

    test('nothing extends a session that has not started', () {
      final FocusTimerController timer = build()..extend();

      expect(timer.sessionDuration, const Duration(minutes: 40));
      expect(timer.state, FocusTimerState.idle);
    });

    test('the countdown ticks into its notifier, not into listeners', () {
      // The invariant behind the shell's `Listenable.merge`: the six tabs in
      // the `IndexedStack` must not be rebuilt four times a second to move one
      // arc. Ticks go to `remaining`; only state changes notify.
      final FocusTimerController timer = build();
      int notifications = 0;
      timer.addListener(() => notifications++);

      timer.start();
      final int afterStart = notifications;

      for (int i = 0; i < 5; i++) {
        clock.advance(const Duration(seconds: 1));
        timer.tick();
      }

      expect(notifications, afterStart);
      expect(timer.remaining.value, const Duration(minutes: 39, seconds: 55));
    });

    test('toggle walks start → pause → resume → start again', () {
      final FocusTimerController timer = build()..toggle();
      expect(timer.state, FocusTimerState.running);

      timer.toggle();
      expect(timer.state, FocusTimerState.paused);

      timer.toggle();
      expect(timer.state, FocusTimerState.running);

      clock.advance(const Duration(minutes: 41));
      timer.tick();
      expect(timer.state, FocusTimerState.finished);

      timer.toggle();
      expect(timer.state, FocusTimerState.running);
      expect(timer.remaining.value, const Duration(minutes: 40));
    });
  });

  group('formatCountdown', () {
    test('rounds up, so a fresh session reads its full length', () {
      // Truncating would flick a 40-minute session to 39:59 on the very first
      // frame, and would print 00:00 for the last whole second of work.
      expect(formatCountdown(const Duration(minutes: 40)), '40:00');
      expect(
        formatCountdown(const Duration(minutes: 39, milliseconds: 59700)),
        '40:00',
      );
      expect(formatCountdown(const Duration(milliseconds: 1)), '00:01');
      expect(formatCountdown(Duration.zero), '00:00');
    });

    test('prints hours only once there are any', () {
      expect(formatCountdown(const Duration(minutes: 90)), '1:30:00');
      expect(
        formatCountdown(const Duration(minutes: 59, seconds: 59)),
        '59:59',
      );
    });

    test('a negative remainder is zero, never a minus sign', () {
      expect(formatCountdown(const Duration(seconds: -5)), '00:00');
    });
  });

  group('AlarmSound', () {
    test('an unknown name degrades to the shipped sound, not to silence', () {
      // A name written by a newer build means the user *did* choose a sound;
      // answering with silence would be an alarm that never rings and never
      // says why.
      expect(AlarmSound.fromName('gong'), AlarmSound.fallback);
      expect(AlarmSound.fromName(null), AlarmSound.fallback);
      expect(AlarmSound.fromName('bell'), AlarmSound.bell);
    });

    test('every audible sound names a bundled asset', () {
      for (final AlarmSound sound in AlarmSound.values) {
        expect(sound.isAudible, sound.asset != null);
        if (sound.isAudible) {
          expect(sound.asset, startsWith('sounds/'));
        }
      }
    });
  });

  group('timer settings', () {
    test('legacy JSON with no timer keys defaults to 40 minutes and chime', () {
      final AppSettings settings = AppSettings.fromJson(<String, dynamic>{});

      expect(settings.timerMinutes, 40);
      expect(settings.timerDuration, const Duration(minutes: 40));
      expect(settings.timerAlarm, AlarmSound.chime);
    });

    test('the two keys round-trip', () {
      const AppSettings original = AppSettings(
        timerMinutes: 25,
        timerAlarm: AlarmSound.ping,
      );

      final AppSettings restored = AppSettings.fromJson(original.toJson());

      expect(restored.timerMinutes, 25);
      expect(restored.timerAlarm, AlarmSound.ping);
    });

    test('both keys are always written, unlike shortcuts', () {
      // No three-state dance here: there is no better default for a later build
      // to ship, and silently re-deciding somebody's session length in an
      // update is the opposite of what a timer is for.
      const AppSettings settings = AppSettings();
      final Map<String, dynamic> json = settings.toJson();

      expect(json.containsKey('timerMinutes'), isTrue);
      expect(json.containsKey('timerAlarm'), isTrue);
      expect(json.containsKey('shortcuts'), isFalse);
    });

    test('a nonsense stored length still yields a timer that can run', () {
      expect(
        AppSettings.fromJson(<String, dynamic>{
          'timerMinutes': 0,
        }).timerDuration,
        TimerDefaults.min,
      );
      expect(
        AppSettings.fromJson(<String, dynamic>{
          'timerMinutes': 99999,
        }).timerDuration,
        TimerDefaults.max,
      );
      // A hand-edited file holding the wrong *type* must not take the profiles
      // down with it, like every other field.
      expect(
        AppSettings.fromJson(<String, dynamic>{
          'timerMinutes': 'forty',
        }).timerMinutes,
        40,
      );
    });

    test('the controller persists a chosen length and sound', () async {
      final _FakeSettingsRepository repository = _FakeSettingsRepository();
      final SettingsController controller = SettingsController(
        repository: repository,
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await controller.setTimerDuration(const Duration(minutes: 50));
      await controller.setTimerAlarm(AlarmSound.ping);

      expect(controller.timerDuration, const Duration(minutes: 50));
      expect(controller.timerAlarm, AlarmSound.ping);
      expect(repository.stored?.timerMinutes, 50);
      expect(repository.stored?.timerAlarm, AlarmSound.ping);
    });
  });

  group('completed session history', () {
    test('a session that reaches zero is counted, in memory and on disk', () async {
      final FocusTimerController timer = build();
      timer.goal = 'Ship the handoff sheet';

      runToZero(timer);

      expect(timer.sessions, hasLength(1));
      expect(timer.today.sessions, 1);
      expect(timer.today.focused, const Duration(minutes: 40));

      // The append is fire-and-forget, so let its microtask land.
      await Future<void>.delayed(Duration.zero);
      expect(sessionLog.rows, hasLength(1));
      expect(sessionLog.rows.single.duration, const Duration(minutes: 40));
      expect(sessionLog.rows.single.goal, 'Ship the handoff sheet');
      expect(sessionLog.rows.single.completedAt, DateTime(2026, 8, 5, 9, 40));
    });

    test('pausing, resetting and abandoning a session count for nothing', () async {
      final FocusTimerController timer = build()..start();

      clock.advance(const Duration(minutes: 30));
      timer.tick();
      timer.pause();
      timer.reset();

      // Thirty minutes of work, but the countdown never reached zero — which is
      // the whole definition this feature rests on.
      await Future<void>.delayed(Duration.zero);
      expect(timer.sessions, isEmpty);
      expect(timer.today.sessions, 0);
      expect(sessionLog.rows, isEmpty);
    });

    test('a stretched session records the time it actually ran', () async {
      final FocusTimerController timer = build()..start();

      timer.extend();
      clock.advance(const Duration(minutes: 45));
      timer.tick();

      await Future<void>.delayed(Duration.zero);
      expect(sessionLog.rows.single.duration, const Duration(minutes: 45));
      expect(timer.today.focused, const Duration(minutes: 45));
    });

    test('sessions are tallied by the local day they finished on', () {
      final FocusTimerController timer = build(
        log: _FakeSessionLog(
          stored: <FocusSession>[
            FocusSession(
              completedAt: DateTime(2026, 8, 3, 10),
              duration: const Duration(minutes: 40),
            ),
            FocusSession(
              completedAt: DateTime(2026, 8, 5, 8),
              duration: const Duration(minutes: 25),
            ),
            FocusSession(
              completedAt: DateTime(2026, 8, 5, 11),
              duration: const Duration(minutes: 40),
            ),
          ],
        ),
      );

      return timer.initialize().then((_) {
        final List<DailyFocusTally> tallies = timer.dailyTallies;
        // Newest day first.
        expect(tallies.first.day, DateTime(2026, 8, 5));
        expect(tallies.first.sessions, 2);
        expect(tallies.first.focused, const Duration(minutes: 65));
        expect(tallies.last.day, DateTime(2026, 8, 3));
        expect(tallies.last.sessions, 1);
      });
    });

    test('a session finished after midnight belongs to the day it ended on', () async {
      clock.now = DateTime(2026, 8, 5, 23, 50);
      final FocusTimerController timer = build();

      runToZero(timer);

      // Started on the 5th, finished at 00:30 on the 6th — counted on the 6th,
      // which is the day the work is remembered as being done.
      await Future<void>.delayed(Duration.zero);
      expect(timer.dailyTallies.single.day, DateTime(2026, 8, 6));
      expect(timer.today.sessions, 1);
    });

    test('the recent strip keeps the empty days', () async {
      final FocusTimerController timer = build(
        log: _FakeSessionLog(
          stored: <FocusSession>[
            FocusSession(
              completedAt: DateTime(2026, 8, 5, 10),
              duration: const Duration(minutes: 40),
            ),
            FocusSession(
              completedAt: DateTime(2026, 8, 2, 10),
              duration: const Duration(minutes: 40),
            ),
          ],
        ),
      );
      await timer.initialize();

      final List<DailyFocusTally> week = timer.recentDays(7);

      // Seven consecutive days, oldest first, gaps included — a strip that
      // skipped them would make one busy day look like a steady week.
      expect(week, hasLength(7));
      expect(week.first.day, DateTime(2026, 7, 30));
      expect(week.last.day, DateTime(2026, 8, 5));
      expect(week.last.sessions, 1);
      expect(week.where((DailyFocusTally day) => day.isEmpty), hasLength(5));
    });

    test('a log that cannot be written costs the file, never the session', () async {
      sessionLog.failAppend = true;
      final FocusTimerController timer = build();

      runToZero(timer);
      await Future<void>.delayed(Duration.zero);

      // In memory first: the tally stays right for the rest of the session and
      // is merely incomplete on disk, rather than wrong in both places.
      expect(timer.state, FocusTimerState.finished);
      expect(timer.today.sessions, 1);
      expect(sessionLog.rows, isEmpty);
    });

    test('a goal longer than the cap is stored truncated', () async {
      final FocusTimerController timer = build();
      timer.goal = 'x' * (FocusSession.maxGoalLength + 50);

      runToZero(timer);
      await Future<void>.delayed(Duration.zero);

      expect(sessionLog.rows.single.goal, hasLength(FocusSession.maxGoalLength));
    });

    test('a session survives a JSON round trip', () {
      final FocusSession session = FocusSession(
        completedAt: DateTime(2026, 8, 5, 9, 40),
        duration: const Duration(minutes: 40),
        goal: 'Ship it',
      );

      final FocusSession? back = FocusSession.fromJson(
        jsonDecode(jsonEncode(session.toJson())) as Object?,
      );

      expect(back!.completedAt, session.completedAt);
      expect(back.duration, session.duration);
      expect(back.goal, 'Ship it');
    });

    test('an unreadable row is dropped rather than taking the file down', () {
      expect(FocusSession.fromJson(null), isNull);
      expect(FocusSession.fromJson(<String, dynamic>{'minutes': 40}), isNull);
      expect(
        FocusSession.fromJson(<String, dynamic>{
          'completedAt': 'not a date',
          'minutes': 40,
        }),
        isNull,
      );
      // A goal is optional, so a row without one is still a valid session.
      expect(
        FocusSession.fromJson(<String, dynamic>{
          'completedAt': '2026-08-05T09:40:00.000',
          'minutes': 40,
        }),
        isNotNull,
      );
    });
  });

  group('project attribution', () {
    test('a finished session is attributed to the project active at the time', () async {
      FocusProject? active = const FocusProject(id: 'p1', name: 'Acme');
      final FocusTimerController timer = FocusTimerController(
        alarmPlayer: alarm,
        sessionLog: sessionLog,
        activeProject: () => active,
        clock: clock.call,
      );
      addTearDown(timer.dispose);

      timer.start();
      // Switched mid-session: what counts is which project was active when the
      // work finished, not when it started.
      active = const FocusProject(id: 'p2', name: 'Beta');
      clock.advance(const Duration(minutes: 40));
      timer.tick();

      await Future<void>.delayed(Duration.zero);
      expect(sessionLog.rows.single.projectId, 'p2');
      expect(sessionLog.rows.single.projectName, 'Beta');
    });

    test('with no project active the session is recorded unattributed', () async {
      final FocusTimerController timer = FocusTimerController(
        alarmPlayer: alarm,
        sessionLog: sessionLog,
        activeProject: () => null,
        clock: clock.call,
      );
      addTearDown(timer.dispose);

      runToZero(timer);
      await Future<void>.delayed(Duration.zero);

      expect(sessionLog.rows.single.projectId, isNull);
      expect(timer.projectTallies(7).single.projectName, 'No project');
    });

    test('a resolver that throws costs the attribution, never the session', () async {
      final FocusTimerController timer = FocusTimerController(
        alarmPlayer: alarm,
        sessionLog: sessionLog,
        activeProject: () => throw StateError('projects not loaded'),
        clock: clock.call,
      );
      addTearDown(timer.dispose);

      runToZero(timer);
      await Future<void>.delayed(Duration.zero);

      expect(timer.state, FocusTimerState.finished);
      expect(timer.today.sessions, 1);
      expect(sessionLog.rows.single.projectId, isNull);
    });

    test('projects are tallied busiest first, within the window only', () async {
      final FocusTimerController timer = build(
        log: _FakeSessionLog(
          stored: <FocusSession>[
            // Inside the seven-day window (today is 5 Aug).
            FocusSession(
              completedAt: DateTime(2026, 8, 5, 9),
              duration: const Duration(minutes: 40),
              projectId: 'p1',
              projectName: 'Acme',
            ),
            FocusSession(
              completedAt: DateTime(2026, 8, 4, 9),
              duration: const Duration(minutes: 25),
              projectId: 'p1',
              projectName: 'Acme',
            ),
            FocusSession(
              completedAt: DateTime(2026, 8, 3, 9),
              duration: const Duration(minutes: 40),
              projectId: 'p2',
              projectName: 'Beta',
            ),
            // Outside it — must not reach a seven-day split.
            FocusSession(
              completedAt: DateTime(2026, 7, 1, 9),
              duration: const Duration(minutes: 40),
              projectId: 'p3',
              projectName: 'Old',
            ),
          ],
        ),
      );
      await timer.initialize();

      final List<ProjectFocusTally> week = timer.projectTallies(7);

      expect(week.map((ProjectFocusTally p) => p.projectName), <String>[
        'Acme',
        'Beta',
      ]);
      expect(week.first.sessions, 2);
      expect(week.first.focused, const Duration(minutes: 65));
      // The wider window reaches back far enough to include it.
      expect(timer.projectTallies(60).length, 3);
    });

    test('a renamed project keeps its history under the newest name', () async {
      final FocusTimerController timer = build(
        log: _FakeSessionLog(
          stored: <FocusSession>[
            FocusSession(
              completedAt: DateTime(2026, 8, 3, 9),
              duration: const Duration(minutes: 40),
              projectId: 'p1',
              projectName: 'Old name',
            ),
            FocusSession(
              completedAt: DateTime(2026, 8, 5, 9),
              duration: const Duration(minutes: 40),
              projectId: 'p1',
              projectName: 'New name',
            ),
          ],
        ),
      );
      await timer.initialize();

      // Grouped by id, labelled by the newest name seen — and crucially still
      // two sessions rather than two projects.
      final ProjectFocusTally tally = timer.projectTallies(7).single;
      expect(tally.sessions, 2);
      expect(tally.projectName, 'New name');
    });

    test('legacy rows written before projects existed still count', () {
      final FocusSession? session = FocusSession.fromJson(<String, dynamic>{
        'completedAt': '2026-08-05T09:40:00.000',
        'minutes': 40,
      });

      expect(session, isNotNull);
      expect(session!.projectId, isNull);
      expect(session.projectName, isNull);
    });

    test('the project fields survive a JSON round trip', () {
      final FocusSession session = FocusSession(
        completedAt: DateTime(2026, 8, 5, 9, 40),
        duration: const Duration(minutes: 40),
        projectId: 'p1',
        projectName: 'Acme',
      );

      final FocusSession? back = FocusSession.fromJson(
        jsonDecode(jsonEncode(session.toJson())) as Object?,
      );

      expect(back!.projectId, 'p1');
      expect(back.projectName, 'Acme');
    });
  });

  group('calendar geometry', () {
    test('a week window always needs exactly one column', () {
      for (int weekday = DateTime.monday; weekday <= DateTime.sunday; weekday++) {
        expect(columnsFor(weekday, 7), weekday == DateTime.monday ? 1 : 2);
      }
    });

    test('every cell of a 30-day window has a column to sit in', () {
      // The regression: deriving the column count from
      // `last.difference(start).inDays` loses an hour across spring-forward and
      // floors a whole day away, dropping *today* from the grid. Swept over two
      // years of start weekdays rather than asserted at one date, because the
      // bug only fired on five Mondays a year.
      for (int weekday = DateTime.monday; weekday <= DateTime.sunday; weekday++) {
        final int columns = columnsFor(weekday, 30);
        final int leading = weekday - 1;
        // The last day must land inside the grid the count describes.
        expect(columns * 7, greaterThanOrEqualTo(leading + 30));
        // …and the grid must not carry an entirely empty trailing column.
        expect((columns - 1) * 7, lessThan(leading + 30));
      }
    });

    test('an empty window needs no columns at all', () {
      expect(columnsFor(DateTime.monday, 0), 0);
      expect(columnsFor(DateTime.sunday, 0), 0);
    });

    test('the day keys of a 30-day window are 30 distinct consecutive days', () {
      // Guards the other half of the same DST hazard: the day *addresses* are
      // calendar arithmetic, so they must stay correct across a transition.
      final FocusTimerController timer = build();
      final List<DailyFocusTally> window = timer.recentDays(30);

      expect(window, hasLength(30));
      expect(window.map((DailyFocusTally d) => d.day).toSet(), hasLength(30));
      for (int i = 1; i < window.length; i++) {
        final DateTime previous = window[i - 1].day;
        final DateTime expected = DateTime(
          previous.year,
          previous.month,
          previous.day + 1,
        );
        expect(window[i].day, expected);
      }
    });
  });

  group('history that cannot be read', () {
    test('an unreadable log is reported, not counted as nothing', () async {
      final FocusTimerController timer = build(log: _BrokenSessionLog());

      await timer.initialize();

      // "Nothing done yet" is a claim about the user's history; making it while
      // the file is merely unreadable is the failure `_indexUnreadable` exists
      // to prevent in the queue.
      expect(timer.historyUnreadable, isTrue);
      expect(timer.sessions, isEmpty);
    });

    test('a load that fails after disposal notifies nothing', () async {
      // The shell awaits `initialize()` during bootstrap, so a page torn down
      // while a slow load is still in flight would reach a dead controller.
      // The failing path has to be exactly as quiet as the succeeding one.
      final FocusTimerController timer = FocusTimerController(
        alarmPlayer: alarm,
        sessionLog: _BrokenSessionLog(),
        clock: clock.call,
      );
      final Future<void> loading = timer.initialize();
      timer.dispose();

      await loading;

      expect(timer.historyUnreadable, isFalse);
    });

    test('a readable but empty log is not an error', () async {
      final FocusTimerController timer = build();

      await timer.initialize();

      expect(timer.historyUnreadable, isFalse);
    });
  });

  group('window edges', () {
    FocusTimerController withDays(List<int> daysAgo) {
      final FocusTimerController timer = build(
        log: _FakeSessionLog(
          stored: <FocusSession>[
            for (final int ago in daysAgo)
              FocusSession(
                completedAt: DateTime(2026, 8, 5 - ago, 9),
                duration: const Duration(minutes: 40),
                projectId: 'p$ago',
                projectName: 'Project $ago',
              ),
          ],
        ),
      );
      return timer;
    }

    test('a seven-day window includes day 6 and excludes day 7', () async {
      final FocusTimerController timer = withDays(<int>[0, 6, 7]);
      await timer.initialize();

      final List<ProjectFocusTally> week = timer.projectTallies(7);

      expect(
        week.map((ProjectFocusTally p) => p.projectName),
        containsAll(<String>['Project 0', 'Project 6']),
      );
      expect(
        week.map((ProjectFocusTally p) => p.projectName),
        isNot(contains('Project 7')),
      );
      // The strip above the split must agree — same sessions, same window.
      final int inStrip = timer
          .recentDays(7)
          .fold(0, (int total, DailyFocusTally d) => total + d.sessions);
      expect(inStrip, 2);
    });

    test('a session dated in the future is in neither panel', () async {
      final FocusTimerController timer = build(
        log: _FakeSessionLog(
          stored: <FocusSession>[
            FocusSession(
              completedAt: DateTime(2026, 8, 9, 9),
              duration: const Duration(minutes: 40),
              projectId: 'p1',
              projectName: 'Skewed',
            ),
          ],
        ),
      );
      await timer.initialize();

      // Clock skew or a hand-edited file. It must not show up in the split
      // while being absent from the count printed directly above it.
      expect(timer.projectTallies(7), isEmpty);
      expect(
        timer.recentDays(7).fold(0, (int t, DailyFocusTally d) => t + d.sessions),
        0,
      );
    });
  });

  group('project tally details', () {
    test('an equal-session tie breaks on name, so the order cannot flicker', () async {
      final FocusTimerController timer = build(
        log: _FakeSessionLog(
          stored: <FocusSession>[
            FocusSession(
              completedAt: DateTime(2026, 8, 5, 9),
              duration: const Duration(minutes: 40),
              projectId: 'z',
              projectName: 'Zed',
            ),
            FocusSession(
              completedAt: DateTime(2026, 8, 5, 10),
              duration: const Duration(minutes: 40),
              projectId: 'a',
              projectName: 'Acme',
            ),
          ],
        ),
      );
      await timer.initialize();

      expect(
        timer.projectTallies(7).map((ProjectFocusTally p) => p.projectName),
        <String>['Acme', 'Zed'],
      );
    });

    test('an equal session count is broken by time, not by name', () async {
      // Found by looking at the rendered panel: `Alpha · 25 min` sat above
      // `Zebra · 40 min` purely on the alphabet, which is the opposite of the
      // answer "where did the week go" asks for.
      final FocusTimerController timer = build(
        log: _FakeSessionLog(
          stored: <FocusSession>[
            FocusSession(
              completedAt: DateTime(2026, 8, 5, 9),
              duration: const Duration(minutes: 25),
              projectId: 'a',
              projectName: 'Alpha',
            ),
            FocusSession(
              completedAt: DateTime(2026, 8, 5, 10),
              duration: const Duration(minutes: 40),
              projectId: 'z',
              projectName: 'Zebra',
            ),
          ],
        ),
      );
      await timer.initialize();

      expect(
        timer.projectTallies(7).map((ProjectFocusTally p) => p.projectName),
        <String>['Zebra', 'Alpha'],
      );
    });

    test('unattributed time sorts last however much of it there is', () async {
      // It is the residual, not a competitor. Ordering it by count puts
      // `No project` in the middle of the real rows, where it reads as a
      // project you own and pushes work you filed below work you did not.
      final FocusTimerController timer = build(
        log: _FakeSessionLog(
          stored: <FocusSession>[
            for (int hour = 8; hour < 11; hour++)
              FocusSession(
                completedAt: DateTime(2026, 8, 5, hour),
                duration: const Duration(minutes: 40),
              ),
            FocusSession(
              completedAt: DateTime(2026, 8, 5, 11),
              duration: const Duration(minutes: 40),
              projectId: 'p1',
              projectName: 'Capture',
            ),
            FocusSession(
              completedAt: DateTime(2026, 8, 5, 12),
              duration: const Duration(minutes: 40),
              projectId: 'p2',
              projectName: 'Zebra',
            ),
          ],
        ),
      );
      await timer.initialize();

      final List<ProjectFocusTally> tallies = timer.projectTallies(7);
      expect(
        tallies.map((ProjectFocusTally p) => p.projectName),
        <String>['Capture', 'Zebra', 'No project'],
      );
      // Three of them, and still last.
      expect(tallies.last.sessions, 3);
    });

    test('the round trip carries the project through the file format', () {
      // The two new keys are otherwise never exercised against `fromJson`: every
      // other suite uses an in-memory fake, and `focus-sessions.jsonl` is
      // append-only, so a key typo would drop attribution on rows that can never
      // be rewritten.
      final FocusSession session = FocusSession(
        completedAt: DateTime(2026, 8, 5, 9, 40),
        duration: const Duration(minutes: 40),
        goal: 'Ship it',
        projectId: 'p1',
        projectName: 'Acme',
      );

      final FocusSession? back = FocusSession.fromJson(
        jsonDecode(jsonEncode(session.toJson())) as Object?,
      );

      expect(back!.projectId, 'p1');
      expect(back.projectName, 'Acme');
      expect(back.goal, 'Ship it');
      expect(back.completedAt, session.completedAt);
      expect(back.duration, session.duration);
    });

    test('a project id with no name still groups, under a stated placeholder', () async {
      final FocusTimerController timer = build(
        log: _FakeSessionLog(
          stored: <FocusSession>[
            FocusSession(
              completedAt: DateTime(2026, 8, 5, 9),
              duration: const Duration(minutes: 40),
              projectId: 'p1',
            ),
          ],
        ),
      );
      await timer.initialize();

      expect(timer.projectTallies(7).single.projectName, 'Unnamed project');
    });

    test('a goal of exactly the cap is kept whole', () async {
      final FocusTimerController timer = build();
      timer.goal = 'x' * FocusSession.maxGoalLength;

      runToZero(timer);
      await Future<void>.delayed(Duration.zero);

      expect(sessionLog.rows.single.goal, hasLength(FocusSession.maxGoalLength));
    });
  });
}

/// A log that cannot be read at all — a permissions problem, a truncated mount.
class _BrokenSessionLog implements FocusSessionLog {
  @override
  Future<List<FocusSession>> load() async =>
      throw const FileSystemException('cannot read');

  @override
  Future<void> append(FocusSession session) async {}
}
