import 'dart:io';

import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
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
}
