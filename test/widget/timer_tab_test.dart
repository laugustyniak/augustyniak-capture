import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/settings/presentation/settings_controller.dart';
import 'package:augustyniak_capture/features/timer/domain/alarm_player.dart';
import 'package:augustyniak_capture/features/timer/domain/alarm_sound.dart';
import 'package:augustyniak_capture/features/timer/domain/focus_session.dart';
import 'package:augustyniak_capture/features/timer/presentation/focus_timer_controller.dart';
import 'package:augustyniak_capture/features/timer/presentation/timer_tab.dart';

import '../support/harness.dart';

/// A clock the test moves by hand.
///
/// `tester.pump(duration)` advances the *fake async* clock, which is what makes
/// the controller's periodic timer fire — but `DateTime.now()` keeps answering
/// the real wall clock, so a session driven by it would still have its full
/// length left after a pumped hour. The countdown reads time from this instead.
class _FakeClock {
  DateTime now = DateTime(2026, 8, 5, 9, 0);

  DateTime call() => now;

  void advance(Duration by) => now = now.add(by);
}


class _FakeAlarmPlayer implements AlarmPlayer {
  final List<AlarmSound> played = <AlarmSound>[];

  @override
  Future<void> play(AlarmSound sound) async => played.add(sound);

  @override
  Future<void> stop() async {}
}

/// **Never `pumpAndSettle` a running session here.** The dial carries a
/// `PulseDot` and a sweep that repeat forever, so "no frames scheduled" is a
/// state a running screen never reaches and the call would hang until the
/// timeout — the same rule the transcribing card and the capture screen live
/// under. Every test below pumps explicit frames.
void main() {
  late _FakeAlarmPlayer alarm;

  /// Hosts the tab with the shell's own wiring in miniature: settings are the
  /// source of truth for length and alarm, and the shell pushes them down on
  /// every change. Without this listener the chips would appear to do nothing,
  /// which is exactly the bug it exists to catch.
  Future<({FocusTimerController timer, SettingsController settings})> pumpTimer(
    WidgetTester tester, {
    _FakeClock? clock,
    FocusSessionLog? sessionLog,
  }) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final SettingsController settings = buildSettingsController();
    await settings.initialize();
    final FocusTimerController timer = FocusTimerController(
      alarmPlayer: alarm,
      sessionLog: sessionLog ?? const NoopFocusSessionLog(),
      clock: clock?.call,
    );
    addTearDown(timer.dispose);
    await timer.initialize();
    void apply() {
      timer.configure(settings.timerDuration);
      timer.setAlarmSound(settings.timerAlarm);
    }

    settings.addListener(apply);
    addTearDown(() => settings.removeListener(apply));
    apply();

    await tester.pumpWidget(
      hostTab(
        () => TimerTab(controller: timer, settings: settings),
        listenable: Listenable.merge(<Listenable>[timer, settings]),
      ),
    );
    await tester.pump();
    return (timer: timer, settings: settings);
  }

  setUp(() => alarm = _FakeAlarmPlayer());

  testWidgets('a fresh tab offers a forty-minute session', (
    WidgetTester tester,
  ) async {
    await pumpTimer(tester);

    expect(find.text('40:00'), findsOneWidget);
    expect(find.text('READY'), findsOneWidget);
    expect(find.text('START'), findsOneWidget);
    // Nothing to reset and nothing to extend before a session exists.
    expect(find.text('+5 MIN'), findsNothing);
  });

  testWidgets('START runs the session and offers PAUSE', (
    WidgetTester tester,
  ) async {
    final ({FocusTimerController timer, SettingsController settings}) host =
        await pumpTimer(tester);

    await tester.tap(find.text('START'));
    await tester.pump();

    expect(host.timer.isRunning, isTrue);
    expect(find.text('FOCUS'), findsOneWidget);
    expect(find.text('PAUSE'), findsOneWidget);
    expect(find.text('+5 MIN'), findsOneWidget);

    // Back to a still screen before the test ends: a live session leaves a
    // repeating animation and a 250 ms periodic timer running.
    host.timer.reset();
    await tester.pump();
  });

  testWidgets('PAUSE stops the countdown and RESUME picks it up', (
    WidgetTester tester,
  ) async {
    final ({FocusTimerController timer, SettingsController settings}) host =
        await pumpTimer(tester);

    await tester.tap(find.text('START'));
    await tester.pump();
    await tester.tap(find.text('PAUSE'));
    await tester.pump();

    expect(host.timer.isPaused, isTrue);
    expect(find.text('PAUSED'), findsOneWidget);
    expect(find.text('RESUME'), findsOneWidget);

    await tester.tap(find.text('RESUME'));
    await tester.pump();
    expect(host.timer.isRunning, isTrue);

    host.timer.reset();
    await tester.pump();
  });

  testWidgets('a length chip persists and moves the dial', (
    WidgetTester tester,
  ) async {
    final ({FocusTimerController timer, SettingsController settings}) host =
        await pumpTimer(tester);

    await tester.tap(find.text('25 min'));
    await tester.pump();

    expect(host.settings.timerDuration, const Duration(minutes: 25));
    expect(host.timer.duration, const Duration(minutes: 25));
    expect(find.text('25:00'), findsOneWidget);
  });

  testWidgets('re-picking the length that just finished sets up the next one', (
    WidgetTester tester,
  ) async {
    // The chip for the length that just ran is the one already selected, so
    // the settings setter drops it as an unchanged value and `configure` never
    // arrives. Without the reset on the tap itself the dial would sit on DONE
    // while the user kept pressing the length they wanted next — and pressing
    // a *different* length would work, which is what makes it baffling.
    final _FakeClock clock = _FakeClock();
    final ({FocusTimerController timer, SettingsController settings}) host =
        await pumpTimer(tester, clock: clock);

    await tester.tap(find.text('START'));
    await tester.pump();
    clock.advance(const Duration(hours: 3));
    host.timer.tick();
    await tester.pump();
    expect(find.text('DONE'), findsOneWidget);

    await tester.tap(find.text('40 min (Recommended)'));
    await tester.pump();

    expect(host.timer.state, FocusTimerState.idle);
    expect(find.text('DONE'), findsNothing);
    expect(find.text('40:00'), findsOneWidget);
  });

  testWidgets('an unrelated settings change leaves DONE alone', (
    WidgetTester tester,
  ) async {
    // The other half of the same decision: `configure` is a push-down the
    // shell runs on every settings change, so the reset must not live there —
    // changing the alarm would otherwise wipe the screen the user is reading.
    final _FakeClock clock = _FakeClock();
    final ({FocusTimerController timer, SettingsController settings}) host =
        await pumpTimer(tester, clock: clock);

    await tester.tap(find.text('START'));
    await tester.pump();
    clock.advance(const Duration(hours: 3));
    host.timer.tick();
    await tester.pump();

    await tester.tap(find.text('Ping'));
    await tester.pump();

    expect(host.timer.state, FocusTimerState.finished);
    expect(find.text('DONE'), findsOneWidget);
  });

  testWidgets('the length chips say when they will take effect', (
    WidgetTester tester,
  ) async {
    final ({FocusTimerController timer, SettingsController settings}) host =
        await pumpTimer(tester);

    await tester.tap(find.text('START'));
    await tester.pump();

    // The rule stated where it can surprise someone: configuration never
    // reaches a run already under way.
    expect(find.text('applies to the next session'), findsOneWidget);

    host.timer.reset();
    await tester.pump();
  });

  testWidgets('the alarm choice persists, and can be previewed', (
    WidgetTester tester,
  ) async {
    final ({FocusTimerController timer, SettingsController settings}) host =
        await pumpTimer(tester);

    await tester.tap(find.text('Ping'));
    await tester.pump();

    expect(host.settings.timerAlarm, AlarmSound.ping);
    expect(host.timer.alarmSound, AlarmSound.ping);

    await tester.tap(find.bySemanticsLabel('Preview alarm sound'));
    await tester.pump();

    expect(alarm.played, <AlarmSound>[AlarmSound.ping]);
  });

  testWidgets('silence has nothing to preview', (WidgetTester tester) async {
    await pumpTimer(tester);

    await tester.tap(find.text('Silent'));
    await tester.pump();

    // A play button that can only do nothing is indistinguishable from a
    // broken one, so it is hidden rather than disabled.
    expect(find.bySemanticsLabel('Preview alarm sound'), findsNothing);
  });

  testWidgets('the goal reaches the controller on submit', (
    WidgetTester tester,
  ) async {
    final ({FocusTimerController timer, SettingsController settings}) host =
        await pumpTimer(tester);

    await tester.enterText(
      find.byType(TextField).first,
      'finish the timer tab',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(host.timer.goal, 'finish the timer tab');
  });

  testWidgets('a finished session reports what it was', (
    WidgetTester tester,
  ) async {
    final _FakeClock clock = _FakeClock();
    final ({FocusTimerController timer, SettingsController settings}) host =
        await pumpTimer(tester, clock: clock);

    host.timer.goal = 'write the dial';
    await host.settings.setTimerDuration(const Duration(minutes: 1));
    await tester.pump();
    host.timer.start();
    await tester.pump();

    // Two things move here and they are not the same clock: the session's own
    // clock jumps past the deadline, and one pumped tick interval is what lets
    // the periodic timer notice.
    clock.advance(const Duration(minutes: 2));
    await tester.pump(FocusTimerController.tickInterval);

    expect(host.timer.isFinished, isTrue);
    expect(find.text('DONE'), findsOneWidget);
    expect(find.text('1 minute done'), findsOneWidget);
    // Twice: the panel reports it, and the goal field still holds it — the
    // next pomodoro is usually the same piece of work.
    expect(find.text('write the dial'), findsNWidgets(2));
    expect(alarm.played, <AlarmSound>[AlarmSound.chime]);
    expect(find.text('START AGAIN'), findsOneWidget);
  });

  group('completed sessions panel', () {
    /// A log holding a fixed history, so the panel is asserted against data the
    /// test chose rather than against sessions it had to run in real time.
    FocusSessionLog logWith(List<FocusSession> rows) => _StubSessionLog(rows);

    testWidgets('an install with no finished sessions says so plainly', (
      WidgetTester tester,
    ) async {
      await pumpTimer(tester);

      expect(find.text('SESSIONS DONE'), findsOneWidget);
      expect(
        find.textContaining('No sessions finished yet'),
        findsOneWidget,
      );
    });

    testWidgets("today's count leads the panel", (WidgetTester tester) async {
      final _FakeClock clock = _FakeClock();
      await pumpTimer(
        tester,
        clock: clock,
        sessionLog: logWith(<FocusSession>[
          FocusSession(
            completedAt: DateTime(2026, 8, 5, 9),
            duration: const Duration(minutes: 40),
          ),
          FocusSession(
            completedAt: DateTime(2026, 8, 5, 11),
            duration: const Duration(minutes: 25),
          ),
          FocusSession(
            completedAt: DateTime(2026, 8, 2, 11),
            duration: const Duration(minutes: 40),
          ),
        ]),
      );

      // Specifically the headline, not any '2' on screen: the 5 Aug day bar
      // renders one too, so a bare `find.text('2')` passed off the bar alone
      // and a headline regressed to 0 or 3 would have gone unnoticed. The
      // 34 px display size is what identifies it.
      expect(
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is Text &&
              widget.data == '2' &&
              widget.style?.fontSize == 34,
        ),
        findsOneWidget,
      );
      expect(find.text('today'), findsWidgets);
      expect(find.text('65 min'), findsOneWidget);
      expect(find.text('3 total'), findsOneWidget);
    });

    testWidgets('the window switches between the week and the month', (
      WidgetTester tester,
    ) async {
      final _FakeClock clock = _FakeClock();
      await pumpTimer(
        tester,
        clock: clock,
        sessionLog: logWith(<FocusSession>[
          FocusSession(
            completedAt: DateTime(2026, 8, 5, 9),
            duration: const Duration(minutes: 40),
          ),
          // Three weeks back: inside the month, outside the week.
          FocusSession(
            completedAt: DateTime(2026, 7, 20, 9),
            duration: const Duration(minutes: 40),
          ),
        ]),
      );

      expect(find.text('1 in 7 days'), findsOneWidget);

      await tester.tap(find.text('30 DAYS'));
      await tester.pump();

      expect(find.text('2 in 30 days'), findsOneWidget);
      // The month view is a shaded grid, which needs its scale named.
      expect(find.text('less'), findsOneWidget);
      expect(find.text('more'), findsOneWidget);
    });

    testWidgets('the project split names where the time went', (
      WidgetTester tester,
    ) async {
      final _FakeClock clock = _FakeClock();
      await pumpTimer(
        tester,
        clock: clock,
        sessionLog: logWith(<FocusSession>[
          FocusSession(
            completedAt: DateTime(2026, 8, 5, 9),
            duration: const Duration(minutes: 40),
            projectId: 'p1',
            projectName: 'Acme',
          ),
          FocusSession(
            completedAt: DateTime(2026, 8, 4, 9),
            duration: const Duration(minutes: 40),
            projectId: 'p1',
            projectName: 'Acme',
          ),
          // Unattributed time keeps a row of its own rather than vanishing.
          FocusSession(
            completedAt: DateTime(2026, 8, 4, 12),
            duration: const Duration(minutes: 25),
          ),
        ]),
      );

      expect(find.text('WHERE IT WENT'), findsOneWidget);
      expect(find.text('Acme'), findsOneWidget);
      expect(find.text('2 · 80m'), findsOneWidget);
      expect(find.text('No project'), findsOneWidget);
    });
  });

  group('completed sessions panel — regressions', () {
    FocusSessionLog logWith(List<FocusSession> rows) => _StubSessionLog(rows);

    testWidgets('the split is ordered busiest first', (
      WidgetTester tester,
    ) async {
      await pumpTimer(
        tester,
        clock: _FakeClock(),
        sessionLog: logWith(<FocusSession>[
          FocusSession(
            completedAt: DateTime(2026, 8, 5, 9),
            duration: const Duration(minutes: 40),
            projectId: 'p1',
            projectName: 'Capture',
          ),
          FocusSession(
            completedAt: DateTime(2026, 8, 5, 11),
            duration: const Duration(minutes: 40),
            projectId: 'p1',
            projectName: 'Capture',
          ),
          FocusSession(
            completedAt: DateTime(2026, 8, 5, 13),
            duration: const Duration(minutes: 40),
            projectId: 'p2',
            projectName: 'Vault',
          ),
        ]),
      );

      expect(find.text('WHERE IT WENT'), findsOneWidget);
      expect(find.text('Capture'), findsOneWidget);
      expect(find.text('2 · 80m'), findsOneWidget);
      expect(find.text('Vault'), findsOneWidget);
      expect(find.text('1 · 40m'), findsOneWidget);
    });

    testWidgets('a single project draws no split at all', (
      WidgetTester tester,
    ) async {
      await pumpTimer(
        tester,
        clock: _FakeClock(),
        sessionLog: logWith(<FocusSession>[
          FocusSession(
            completedAt: DateTime(2026, 8, 5, 10),
            duration: const Duration(minutes: 40),
            projectId: 'p1',
            projectName: 'Capture',
          ),
        ]),
      );

      // One row is either "all of it on your only project" or "all of it
      // unattributed" — both just repeat the total above in more words.
      expect(find.text('WHERE IT WENT'), findsNothing);
    });

    testWidgets('the chosen window survives a session finishing', (
      WidgetTester tester,
    ) async {
      final _FakeClock clock = _FakeClock();
      final ({FocusTimerController timer, SettingsController settings}) host =
          await pumpTimer(
        tester,
        clock: clock,
        sessionLog: logWith(<FocusSession>[
          FocusSession(
            completedAt: DateTime(2026, 8, 5, 9),
            duration: const Duration(minutes: 40),
          ),
        ]),
      );

      await tester.ensureVisible(find.text('30 DAYS'));
      await tester.tap(find.text('30 DAYS'));
      await tester.pump();
      expect(find.text('1 in 30 days'), findsOneWidget);

      // Finishing a session inserts the DONE panel above this card. In a
      // keyless ListView that shifts every later child by two and throws the
      // panel's state away, collapsing the month view back to a week at exactly
      // the moment the user is looking at it.
      host.timer.start();
      clock.advance(const Duration(minutes: 41));
      host.timer.tick();
      await tester.pump();

      expect(host.timer.isFinished, isTrue);
      expect(find.text('1 in 7 days'), findsNothing);
      expect(find.textContaining('in 30 days'), findsOneWidget);
    });

    testWidgets('the month grid draws every day of the window', (
      WidgetTester tester,
    ) async {
      final _FakeClock clock = _FakeClock();
      await pumpTimer(
        tester,
        clock: clock,
        sessionLog: logWith(<FocusSession>[
          FocusSession(
            completedAt: DateTime(2026, 8, 5, 9),
            duration: const Duration(minutes: 40),
          ),
        ]),
      );

      await tester.ensureVisible(find.text('30 DAYS'));
      await tester.tap(find.text('30 DAYS'));
      await tester.pump();

      // Thirty cells, empty days included. This is what a column count derived
      // from `Duration.inDays` got wrong across spring-forward: it dropped one,
      // and the one it dropped was today.
      expect(
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is Tooltip &&
              widget.triggerMode == TooltipTriggerMode.tap,
        ),
        findsNWidgets(30),
      );
      // Today carries the count, and the label is the only place the grid's
      // numbers exist at all.
      expect(
        find.byTooltip('5/8 · 1 session · 40 min'),
        findsOneWidget,
      );
      expect(
        find.byTooltip('4/8 · nothing finished'),
        findsOneWidget,
      );
    });

    testWidgets('projects beyond the fourth are summed, not dropped', (
      WidgetTester tester,
    ) async {
      final _FakeClock clock = _FakeClock();
      await pumpTimer(
        tester,
        clock: clock,
        sessionLog: logWith(<FocusSession>[
          // Six projects, descending so the tail is deterministic.
          for (int index = 0; index < 6; index++)
            for (int repeat = 0; repeat <= (6 - index); repeat++)
              FocusSession(
                completedAt: DateTime(2026, 8, 5, 9),
                // Distinct per project, so the remainder's figure cannot
                // collide with a named row's and pass by accident.
                duration: Duration(minutes: 10 + index),
                projectId: 'p$index',
                projectName: 'Project $index',
              ),
        ]),
      );

      // Four named rows, then one honest remainder — reporting sessions and
      // minutes like the rows above it, so the minute column still sums.
      expect(find.text('Project 0'), findsOneWidget);
      expect(find.text('Project 3'), findsOneWidget);
      expect(find.text('Project 4'), findsNothing);
      expect(find.text('2 more projects'), findsOneWidget);
      // Projects 4 and 5 hold 3 + 2 sessions of ten minutes each.
      expect(find.text('5 · 72m'), findsOneWidget);
    });

    testWidgets('an unreadable history says so instead of claiming zero', (
      WidgetTester tester,
    ) async {
      await pumpTimer(tester, sessionLog: const _BrokenStubLog());

      expect(find.textContaining('could not be read'), findsOneWidget);
      expect(find.textContaining('No sessions finished yet'), findsNothing);
    });

    testWidgets('the panel fits a phone without overflowing', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final _FakeClock clock = _FakeClock();
      final SettingsController settings = buildSettingsController();
      await settings.initialize();
      final FocusTimerController timer = FocusTimerController(
        alarmPlayer: alarm,
        sessionLog: logWith(<FocusSession>[
          FocusSession(
            completedAt: DateTime(2026, 8, 5, 9),
            duration: const Duration(minutes: 40),
            projectId: 'p1',
            projectName: 'A project with a fairly long name',
          ),
        ]),
        clock: clock.call,
      );
      addTearDown(timer.dispose);
      await timer.initialize();

      await tester.pumpWidget(
        hostTab(
          () => TimerTab(controller: timer, settings: settings),
          listenable: Listenable.merge(<Listenable>[timer, settings]),
        ),
      );
      await tester.pump();
      await tester.ensureVisible(find.text('30 DAYS'));
      await tester.tap(find.text('30 DAYS'));
      await tester.pump();

      // A `Spacer` in the chips row throws `RenderFlex overflowed` rather than
      // degrading, and the grid is a fixed-width Row — neither may blow up at
      // the narrowest width this tab is ever drawn at.
      expect(tester.takeException(), isNull);
    });
  });
}

/// Serves a fixed history and refuses nothing — the panel under test only reads.
class _StubSessionLog implements FocusSessionLog {
  const _StubSessionLog(this.rows);

  final List<FocusSession> rows;

  @override
  Future<List<FocusSession>> load() async => rows;

  @override
  Future<void> append(FocusSession session) async {}
}

/// A history that cannot be read, so the panel has to say so.
class _BrokenStubLog implements FocusSessionLog {
  const _BrokenStubLog();

  @override
  Future<List<FocusSession>> load() async => throw StateError('unreadable');

  @override
  Future<void> append(FocusSession session) async {}
}
