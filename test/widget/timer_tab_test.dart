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

/// Seeded history, so the panel can be asserted without running sessions in
/// real time.
class _SeededSessionLog implements FocusSessionLog {
  _SeededSessionLog(this.rows);

  final List<FocusSession> rows;

  @override
  Future<List<FocusSession>> load() async => List<FocusSession>.of(rows);

  @override
  Future<void> append(FocusSession session) async => rows.add(session);
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
    List<FocusSession> history = const <FocusSession>[],
  }) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final SettingsController settings = buildSettingsController();
    await settings.initialize();
    final FocusTimerController timer = FocusTimerController(
      alarmPlayer: alarm,
      sessionLog: _SeededSessionLog(<FocusSession>[...history]),
      clock: clock?.call,
    );
    addTearDown(timer.dispose);
    if (history.isNotEmpty) await timer.initialize();
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

  /// The clock the seeded rows are dated against, so they land inside the
  /// seven-day window the panel shows.
  FocusSession finished({
    required String? projectId,
    String? projectName,
    int hour = 10,
    int minutes = 40,
  }) => FocusSession(
    completedAt: DateTime(2026, 8, 5, hour),
    duration: Duration(minutes: minutes),
    projectId: projectId,
    projectName: projectName,
  );

  testWidgets('the week splits by project, busiest first', (
    WidgetTester tester,
  ) async {
    await pumpTimer(
      tester,
      clock: _FakeClock(),
      history: <FocusSession>[
        finished(projectId: 'p1', projectName: 'Capture', hour: 9),
        finished(projectId: 'p1', projectName: 'Capture', hour: 11),
        finished(projectId: 'p2', projectName: 'Vault', hour: 13),
      ],
    );

    expect(find.text('BY PROJECT'), findsOneWidget);
    expect(find.text('Capture'), findsOneWidget);
    expect(find.text('2 · 80 min'), findsOneWidget);
    expect(find.text('Vault'), findsOneWidget);
    expect(find.text('1 · 40 min'), findsOneWidget);
  });

  testWidgets('time with no project active keeps a row of its own', (
    WidgetTester tester,
  ) async {
    await pumpTimer(
      tester,
      clock: _FakeClock(),
      history: <FocusSession>[
        finished(projectId: 'p1', projectName: 'Capture', hour: 9),
        finished(projectId: null, hour: 11),
      ],
    );

    // Dropping it would make the rows stop adding up to the strip above.
    expect(find.text('No project'), findsOneWidget);
  });

  testWidgets('a single project draws no split at all', (
    WidgetTester tester,
  ) async {
    await pumpTimer(
      tester,
      clock: _FakeClock(),
      history: <FocusSession>[
        finished(projectId: 'p1', projectName: 'Capture'),
      ],
    );

    // One row is either "all of it on your only project" or "all of it
    // unattributed" — both just repeat the total above in more words.
    expect(find.text('BY PROJECT'), findsNothing);
  });
}
