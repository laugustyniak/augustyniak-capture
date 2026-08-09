import 'dart:io';

import 'package:augustyniak_capture/features/momentum/domain/closure_event.dart';
import 'package:augustyniak_capture/features/momentum/presentation/momentum_controller.dart';
import 'package:augustyniak_capture/features/momentum/presentation/momentum_panel.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

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

  Future<MomentumController> mount(
    WidgetTester tester,
    ClosureLog log,
  ) async {
    final MomentumController controller = MomentumController(
      log: log,
      clock: clock,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(
      hostTab(
        () => MomentumPanel(controller: controller),
        listenable: controller,
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('an unreadable history is not reported as an empty one', (
    WidgetTester tester,
  ) async {
    await mount(tester, const _UnreadableClosureLog());

    expect(find.textContaining('could not be read'), findsOneWidget);
    expect(find.textContaining('Nothing closed yet'), findsNothing);
  });

  testWidgets('an empty history says so plainly', (WidgetTester tester) async {
    await mount(tester, _MemoryClosureLog(<ClosureEvent>[]));

    expect(find.textContaining('Nothing closed yet'), findsOneWidget);
    expect(find.textContaining('could not be read'), findsNothing);
  });

  testWidgets('shows today against the target', (WidgetTester tester) async {
    await mount(
      tester,
      _MemoryClosureLog(<ClosureEvent>[
        ..._closures(DateTime(2026, 8, 3, 10), 5),
        ..._closures(DateTime(2026, 8, 6, 10), 1),
        ..._closures(DateTime(2026, 8, 8, 10), 3),
        ..._closures(DateTime(2026, 8, 9, 10), 4),
      ]),
    );

    // Median of [1, 3, 4, 5] is 3.5, floored to 3 — and today beat it.
    expect(find.text('4'), findsWidgets);
    expect(find.textContaining('target 3'), findsOneWidget);
  });

  testWidgets('names the project split without colliding with the timer', (
    WidgetTester tester,
  ) async {
    // `WHERE IT WENT` is taken by the session split on the same tab, and two
    // identical headings describing different things on one screen is a real
    // ambiguity — the same one that makes the review filter read `ANY`.
    await mount(
      tester,
      _MemoryClosureLog(<ClosureEvent>[
        _at(DateTime(2026, 8, 9, 10), projectId: 'p1', projectName: 'Acme'),
        _at(DateTime(2026, 8, 9, 11), projectId: 'p2', projectName: 'Beta'),
      ]),
    );

    expect(find.text('CLOSED BY PROJECT'), findsOneWidget);
    expect(find.text('WHERE IT WENT'), findsNothing);
    expect(find.textContaining('Acme'), findsOneWidget);
  });

  testWidgets('a single project draws no split at all', (
    WidgetTester tester,
  ) async {
    // One row restates the total above it in more words. Nothing is a clearer
    // answer, the rule `_FocusHistory` already follows.
    await mount(
      tester,
      _MemoryClosureLog(<ClosureEvent>[
        _at(DateTime(2026, 8, 9, 10), projectId: 'p1', projectName: 'Acme'),
      ]),
    );

    expect(find.text('CLOSED BY PROJECT'), findsNothing);
  });

  testWidgets('switching to the 30-day window keeps the panel alive', (
    WidgetTester tester,
  ) async {
    await mount(tester, _MemoryClosureLog(_closures(DateTime(2026, 8, 9, 10), 2)));

    await tester.tap(find.text('30 DAYS'));
    await tester.pumpAndSettle();

    expect(find.text('30 DAYS'), findsOneWidget);
  });

  testWidgets('settles — nothing here animates forever', (
    WidgetTester tester,
  ) async {
    // PulseDot, ScanLine, a focused TextField and a running CountdownDial all
    // hang pumpAndSettle for the whole suite. Nothing in this panel may join
    // that list.
    await mount(tester, _MemoryClosureLog(_closures(DateTime(2026, 8, 9, 10), 3)));

    await tester.pumpAndSettle();
  });
}
