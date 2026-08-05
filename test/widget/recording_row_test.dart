import 'dart:io';

import 'package:augustyniak_capture/app/ui_kit.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_category.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/card_parts.dart';
import 'package:augustyniak_capture/features/recordings/presentation/queue_metrics.dart';
import 'package:augustyniak_capture/features/recordings/presentation/queue_tab.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_card.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_row.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

void main() {
  late Directory appDir;

  setUp(() => appDir = Directory.systemTemp.createTempSync('capture_row_'));
  tearDown(() => appDir.deleteSync(recursive: true));

  Future<RecordingsController> pumpQueueAtWidth(
    WidgetTester tester,
    double width,
  ) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'adaptive', title: 'Adaptive capture'),
      ],
    );
    await tester.pumpWidget(
      hostTab(() => QueueTab(controller: controller), listenable: controller),
    );
    await tester.pump();
    return controller;
  }

  testWidgets('queue switches from rows to cards exactly at 600 pixels', (
    WidgetTester tester,
  ) async {
    addTearDown(tester.view.reset);
    await pumpQueueAtWidth(tester, 599);

    expect(find.byType(RecordingRow), findsOneWidget);
    expect(find.byType(RecordingCard), findsNothing);

    tester.view.physicalSize = const Size(600, 900);
    await tester.pump();

    expect(find.byType(RecordingRow), findsNothing);
    expect(find.byType(RecordingCard), findsOneWidget);
  });

  testWidgets('expanding a compact row reveals summary and transcript', (
    WidgetTester tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(599, 900);
    tester.view.devicePixelRatio = 1;
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'details',
          title: 'Expandable capture',
          summary: 'A concise summary.',
          transcript: 'The complete transcript.',
        ),
      ],
    );
    await tester.pumpWidget(
      hostTab(() => QueueTab(controller: controller), listenable: controller),
    );
    await tester.pump();

    expect(find.text('A concise summary.'), findsNothing);
    expect(find.text('The complete transcript.'), findsNothing);

    await tester.tap(find.text('Expandable capture'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('A concise summary.'), findsOneWidget);
    expect(find.text('The complete transcript.'), findsOneWidget);
  });

  testWidgets('review target is 44 pixels and does not expand the row', (
    WidgetTester tester,
  ) async {
    bool expanded = false;
    bool reviewed = false;
    int rowTaps = 0;
    int reviewTaps = 0;
    final Recording recording = makeRecording(
      id: 'review',
      title: 'Review capture',
      summary: 'Hidden until expanded.',
    );

    await tester.pumpWidget(
      hostTab(
        () => StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) => RecordingRow(
            recording: recording.copyWith(isProcessedByUser: reviewed),
            expanded: expanded,
            focused: false,
            isPlaying: false,
            isEnriching: false,
            canRoute: false,
            onTap: () => setState(() {
              rowTaps++;
              expanded = !expanded;
            }),
            onTogglePlay: () {},
            onOpen: () {},
            onRetry: () {},
            onEnrich: () {},
            onEdit: () {},
            onRoute: () {},
            onToggleProcessed: () => setState(() {
              reviewTaps++;
              reviewed = !reviewed;
            }),
          ),
        ),
      ),
    );

    final Finder review = find.bySemanticsLabel('Mark as done');
    expect(tester.getSize(review), const Size(44, 44));

    await tester.tap(review);
    await tester.pump(const Duration(milliseconds: 400));

    expect(reviewTaps, 1);
    expect(rowTaps, 0);
    expect(expanded, isFalse);
    expect(find.text('Hidden until expanded.'), findsNothing);
    expect(find.bySemanticsLabel('Mark as not done'), findsOneWidget);
  });

  group('compact header', () {
    Future<RecordingsController> pumpQueue(
      WidgetTester tester, {
      List<Recording>? seed,
    }) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final RecordingsController controller = await buildRecordingsController(
        appDir,
        seed:
            seed ??
            <Recording>[makeRecording(id: 'one', title: 'First capture')],
      );
      await tester.pumpWidget(
        hostTab(() => QueueTab(controller: controller), listenable: controller),
      );
      await tester.pump();
      return controller;
    }

    testWidgets('the review axis is a segmented control with its counts', (
      WidgetTester tester,
    ) async {
      await pumpQueue(
        tester,
        seed: <Recording>[
          makeRecording(id: 'a', title: 'On the desk'),
          makeRecording(id: 'b', title: 'Handed off', isProcessedByUser: true),
        ],
      );

      // The counts live on the segments the user taps, which is why the phone
      // form drops the `n / m` strip entirely.
      expect(find.text('DESK 1'), findsOneWidget);
      expect(find.text('OFF DESK 1'), findsOneWidget);
      expect(find.text('ANY 2'), findsOneWidget);
      expect(find.byType(ReviewedStrip), findsNothing);
    });

    testWidgets('search and the status chips stay folded until asked', (
      WidgetTester tester,
    ) async {
      await pumpQueue(tester);

      expect(find.byType(TextField), findsNothing);
      expect(find.text('ALL 1'), findsNothing);

      await tester.tap(find.bySemanticsLabel('Toggle search'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(TextField), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Toggle filters'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('ALL 1'), findsOneWidget);
    });

    testWidgets('a panel whose control is engaged refuses to close', (
      WidgetTester tester,
    ) async {
      await pumpQueue(tester);

      final Finder filterToggle = find.bySemanticsLabel('Toggle filters');
      await tester.tap(filterToggle);
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.text('FAILED 0'));
      await tester.pump(const Duration(milliseconds: 200));

      // Tapping the toggle again would hide the chips — and with them the only
      // explanation for an empty list. Filters that are *set* pin their panel
      // open; that is the whole reason the strip was pinned before.
      await tester.tap(filterToggle);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('FAILED 0'), findsOneWidget);

      // The close was not lost, only deferred: the toggle already recorded the
      // user's wish, and clearing the filter that pinned the panel open is what
      // finally lets it take effect.
      await tester.tap(find.text('ALL 1'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('ALL 1'), findsNothing);
    });

    testWidgets('a typed query keeps the search box on screen', (
      WidgetTester tester,
    ) async {
      await pumpQueue(tester);

      await tester.tap(find.bySemanticsLabel('Toggle search'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.enterText(find.byType(TextField), 'first');
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.bySemanticsLabel('Toggle search'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('the badge takes the category colour, not a flat accent', (
      WidgetTester tester,
    ) async {
      await pumpQueue(
        tester,
        seed: <Recording>[
          makeRecording(
            id: 'agent',
            title: 'Agent work',
            category: CaptureCategory.agentTask,
          ),
        ],
      );

      final StatusPill pill = tester.widget<StatusPill>(
        find.ancestor(
          of: find.text('AGENT TASK'),
          matching: find.byType(StatusPill),
        ),
      );
      expect(pill.color, categoryColorFor(CaptureCategory.agentTask));
      expect(pill.color, isNot(Console.accent));
    });
  });
}
