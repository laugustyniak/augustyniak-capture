import 'dart:io';

import 'package:augustyniak_capture/features/momentum/domain/closure_event.dart';
import 'package:augustyniak_capture/features/momentum/domain/momentum_snapshot.dart';
import 'package:augustyniak_capture/features/momentum/presentation/momentum_controller.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/timer/domain/focus_session.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryClosureLog implements ClosureLog {
  _MemoryClosureLog(this.events);

  final List<ClosureEvent> events;

  @override
  Future<List<ClosureEvent>> load() async => events;

  @override
  Future<void> append(ClosureEvent event) async => events.add(event);
}

class _UnreadableClosureLog implements ClosureLog {
  const _UnreadableClosureLog();

  @override
  Future<List<ClosureEvent>> load() async =>
      throw const FileSystemException('permission denied');

  @override
  Future<void> append(ClosureEvent event) async {}
}

ClosureEvent _at(DateTime when, {String? projectId, String? projectName}) =>
    ClosureEvent(
      recordingId: '${when.microsecondsSinceEpoch}',
      at: when,
      kind: ClosureKind.review,
      type: CaptureType.text,
      projectId: projectId,
      projectName: projectName,
    );

List<ClosureEvent> _closures(DateTime day, int count) => <ClosureEvent>[
  for (int i = 0; i < count; i++) _at(day.add(Duration(minutes: i))),
];

void main() {
  final DateTime now = DateTime(2026, 8, 9, 18);
  DateTime clock() => now;

  test('reports three states, not two', () async {
    // "You have closed nothing" is a positive claim about the user's history
    // and must not be made when the file merely failed to read. Same rule as
    // `_indexUnreadable` and `historyUnreadable`.
    final MomentumController failing = MomentumController(
      log: const _UnreadableClosureLog(),
      clock: clock,
    );
    await failing.initialize();

    expect(failing.historyUnreadable, isTrue);
    expect(failing.hasClosures, isFalse);

    final MomentumController empty = MomentumController(
      log: _MemoryClosureLog(<ClosureEvent>[]),
      clock: clock,
    );
    await empty.initialize();

    expect(empty.historyUnreadable, isFalse);
    expect(empty.hasClosures, isFalse);
  });

  test('counts today against a target derived from the pace', () async {
    final MomentumController controller = MomentumController(
      log: _MemoryClosureLog(<ClosureEvent>[
        ..._closures(DateTime(2026, 8, 3, 10), 5),
        ..._closures(DateTime(2026, 8, 6, 10), 1),
        ..._closures(DateTime(2026, 8, 9, 10), 3),
      ]),
      clock: clock,
    );
    await controller.initialize();

    final MomentumSnapshot snapshot = controller.snapshot();

    expect(snapshot.today, 3);
    expect(snapshot.target, 3); // median of [1, 3, 5]
    expect(snapshot.metTarget, isTrue);
  });

  test('noteClosure moves the snapshot without a reload', () async {
    // The shell tells the controller about a closure rather than re-reading the
    // file, so the counter moves in the same frame the row leaves the queue.
    final MomentumController controller = MomentumController(
      log: _MemoryClosureLog(<ClosureEvent>[]),
      clock: clock,
    );
    await controller.initialize();
    expect(controller.snapshot().today, 0);

    controller.noteClosure(_at(DateTime(2026, 8, 9, 11)));

    expect(controller.snapshot().today, 1);
    expect(controller.hasClosures, isTrue);
  });

  test('the window keeps its empty days so a gap stays visible', () async {
    // "Three a day" and "three once a week" are the same tallies and a very
    // different working week.
    final MomentumController controller = MomentumController(
      log: _MemoryClosureLog(<ClosureEvent>[
        ..._closures(DateTime(2026, 8, 9, 10), 2),
        ..._closures(DateTime(2026, 8, 5, 10), 1),
      ]),
      clock: clock,
    );
    await controller.initialize();

    final List<DayClosures> days = controller.snapshot().days;

    expect(days.length, 7);
    expect(days.first.day, DateTime(2026, 8, 9));
    expect(days.first.closures, 2);
    expect(days.last.day, DateTime(2026, 8, 3));
    expect(days.where((DayClosures d) => d.isEmpty).length, 5);
  });

  test('a 30-day window spans thirty days', () async {
    final MomentumController controller = MomentumController(
      log: _MemoryClosureLog(<ClosureEvent>[]),
      clock: clock,
    );
    await controller.initialize();

    expect(controller.snapshot(days: 30).days.length, 30);
  });

  test('groups closures by project, unattributed last', () async {
    final MomentumController controller = MomentumController(
      log: _MemoryClosureLog(<ClosureEvent>[
        _at(DateTime(2026, 8, 9, 10), projectId: 'p1', projectName: 'Acme'),
        _at(DateTime(2026, 8, 9, 11), projectId: 'p1', projectName: 'Acme'),
        _at(DateTime(2026, 8, 9, 12)),
        _at(DateTime(2026, 8, 8, 12)),
        _at(DateTime(2026, 8, 8, 13)),
        _at(DateTime(2026, 8, 8, 14)),
        _at(DateTime(2026, 8, 9, 13), projectId: 'p2', projectName: 'Beta'),
      ]),
      clock: clock,
    );
    await controller.initialize();

    final List<ProjectClosures> projects = controller.projectTallies(7);

    // Unattributed sorts last however much of it there is: it is the residual,
    // not a competitor. Same rule as `tallyByProject` in the timer's domain.
    expect(projects.last.projectId, isNull);
    expect(projects.last.closures, 4);
    expect(projects.first.projectName, 'Acme');
    expect(projects.first.closures, 2);
  });

  test('sessions today come from the reader, and zero without one', () async {
    final MomentumController withReader = MomentumController(
      log: _MemoryClosureLog(<ClosureEvent>[]),
      clock: clock,
      sessions: () => <FocusSession>[
        FocusSession(
          completedAt: DateTime(2026, 8, 9, 9),
          duration: const Duration(minutes: 40),
        ),
        FocusSession(
          completedAt: DateTime(2026, 8, 8, 9),
          duration: const Duration(minutes: 40),
        ),
      ],
    );
    await withReader.initialize();

    expect(withReader.sessionsToday, 1);

    final MomentumController without = MomentumController(
      log: _MemoryClosureLog(<ClosureEvent>[]),
      clock: clock,
    );
    await without.initialize();

    expect(without.sessionsToday, 0);
  });

  test('a reader that throws costs the sessions, never the snapshot', () async {
    // Best-effort under the ClipboardSink contract: the closure history is the
    // thing this panel is about, and a broken session reader must not take it
    // down with it.
    final MomentumController controller = MomentumController(
      log: _MemoryClosureLog(_closures(DateTime(2026, 8, 9, 10), 2)),
      clock: clock,
      sessions: () => throw StateError('timer is gone'),
    );
    await controller.initialize();

    expect(controller.sessionsToday, 0);
    expect(controller.snapshot().today, 2);
  });
}
