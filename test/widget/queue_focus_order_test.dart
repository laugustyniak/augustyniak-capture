import 'dart:io';

import 'package:augustyniak_capture/features/recordings/domain/capture_priority.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/queue_priority.dart';
import 'package:augustyniak_capture/features/recordings/presentation/queue_tab.dart';
import 'package:augustyniak_capture/features/recordings/presentation/queue_toolbar.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// #384: the desk opens in focus order, remembers the sort, and counts what is
/// overdue.
void main() {
  late Directory appDir;
  final DateTime now = DateTime.utc(2026, 7, 29, 12);

  setUp(
    () => appDir = Directory.systemTemp.createTempSync(
      'augustyniak_capture_focus_',
    ),
  );
  tearDown(() => appDir.deleteSync(recursive: true));

  Recording capture(String id, CapturePriority? priority, Duration age) =>
      Recording(
        id: id,
        filePath: '/tmp/$id.m4a',
        createdAt: now.subtract(age),
        durationMs: 1000,
        status: RecordingStatus.completed,
        title: id,
        priority: priority,
      );

  // Controller order, newest first.
  List<Recording> seed() => <Recording>[
    capture('fresh-p0', CapturePriority.p0, const Duration(hours: 2)),
    capture('late-p1', CapturePriority.p1, const Duration(days: 9)),
    capture('old-p0', CapturePriority.p0, const Duration(days: 3)),
    capture('old-p2', CapturePriority.p2, const Duration(days: 30)),
  ];

  Future<void> pumpQueue(
    WidgetTester tester, {
    QueueSort? sort,
    ValueChanged<QueueSort>? onSortChanged,
  }) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: seed(),
    );
    await tester.pumpWidget(
      hostTab(
        () => sort == null
            ? QueueTab(
                controller: controller,
                now: () => now,
                onSortChanged: onSortChanged,
              )
            : QueueTab(
                controller: controller,
                now: () => now,
                sort: sort,
                onSortChanged: onSortChanged,
              ),
        listenable: controller,
      ),
    );
    await tester.pump();
  }

  double top(WidgetTester tester, String title) =>
      tester.getTopLeft(find.text(title)).dy;

  testWidgets('opens in focus order: rank, then oldest first', (
    WidgetTester tester,
  ) async {
    await pumpQueue(tester);

    expect(top(tester, 'old-p0'), lessThan(top(tester, 'fresh-p0')));
    expect(top(tester, 'fresh-p0'), lessThan(top(tester, 'late-p1')));
    expect(top(tester, 'late-p1'), lessThan(top(tester, 'old-p2')));
  });

  testWidgets('a stored newest sort is honoured, and a change is reported', (
    WidgetTester tester,
  ) async {
    final List<QueueSort> changes = <QueueSort>[];
    await pumpQueue(tester, sort: QueueSort.newest, onSortChanged: changes.add);

    expect(top(tester, 'fresh-p0'), lessThan(top(tester, 'late-p1')));
    expect(top(tester, 'late-p1'), lessThan(top(tester, 'old-p0')));

    await tester.tap(find.byType(QueuePriorityMenu));
    await tester.pumpAndSettle();
    await tester.tap(find.text(QueuePriorityMenu.sortLabel));
    await tester.pumpAndSettle();

    expect(changes, <QueueSort>[QueueSort.priority]);
  });

  testWidgets(
    'the overdue pill counts, filters on tap and clears on a second',
    (WidgetTester tester) async {
      await pumpQueue(tester);

      // old-p0 (3 d) and late-p1 (9 d); fresh-p0 and old-p2 are not overdue.
      expect(find.text('OVERDUE 2'), findsOneWidget);

      await tester.tap(find.text('OVERDUE 2'));
      await tester.pumpAndSettle();
      expect(find.text('old-p0'), findsOneWidget);
      expect(find.text('late-p1'), findsOneWidget);
      expect(find.text('fresh-p0'), findsNothing);
      expect(find.text('old-p2'), findsNothing);

      await tester.tap(find.text('OVERDUE 2'));
      await tester.pumpAndSettle();
      expect(find.text('fresh-p0'), findsOneWidget);
      expect(find.text('old-p2'), findsOneWidget);
    },
  );

  testWidgets('the pill is on the phone header too, and hidden at zero', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpQueue(tester);

    expect(find.text('OVERDUE 2'), findsOneWidget);
  });

  testWidgets('no overdue item, no pill', (WidgetTester tester) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        capture('fresh-p0', CapturePriority.p0, const Duration(hours: 2)),
      ],
    );
    await tester.pumpWidget(
      hostTab(
        () => QueueTab(controller: controller, now: () => now),
        listenable: controller,
      ),
    );
    await tester.pump();

    expect(find.textContaining('OVERDUE'), findsNothing);
  });

  testWidgets('a sort that loads after the first build still applies', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: seed(),
    );
    QueueSort sort = QueueSort.priority;
    await tester.pumpWidget(
      hostTab(
        () => QueueTab(controller: controller, now: () => now, sort: sort),
        listenable: controller,
      ),
    );
    await tester.pump();
    expect(top(tester, 'old-p0'), lessThan(top(tester, 'fresh-p0')));

    // Settings finish loading after the tab was built.
    sort = QueueSort.newest;
    controller.notifyListeners();
    await tester.pump();

    expect(top(tester, 'fresh-p0'), lessThan(top(tester, 'late-p1')));
    expect(top(tester, 'late-p1'), lessThan(top(tester, 'old-p0')));
  });

  testWidgets('the overdue pill is DESK-only and its filter ends with it', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        ...seed(),
        capture(
          'handed-p2',
          CapturePriority.p2,
          const Duration(days: 2),
        ).copyWith(isProcessedByUser: true),
      ],
    );
    await tester.pumpWidget(
      hostTab(
        () => QueueTab(controller: controller, now: () => now),
        listenable: controller,
      ),
    );
    await tester.pump();

    await tester.tap(find.text('OVERDUE 2'));
    await tester.pumpAndSettle();
    expect(find.text('fresh-p0'), findsNothing);

    await tester.tap(find.textContaining('OFF DESK'));
    await tester.pumpAndSettle();
    expect(find.textContaining('OVERDUE'), findsNothing);
    expect(find.text('handed-p2'), findsOneWidget);

    await tester.tap(find.textContaining('DESK').first);
    await tester.pumpAndSettle();
    expect(find.text('OVERDUE 2'), findsOneWidget);
    expect(find.text('fresh-p0'), findsOneWidget);
  });
}
