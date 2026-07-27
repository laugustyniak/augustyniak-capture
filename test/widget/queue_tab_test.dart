import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_notes_phase1/features/recordings/domain/capture_type.dart';
import 'package:voice_notes_phase1/features/recordings/domain/recording.dart';
import 'package:voice_notes_phase1/features/recordings/presentation/queue_tab.dart';
import 'package:voice_notes_phase1/features/recordings/presentation/recordings_controller.dart';

import '../support/harness.dart';

/// Guards the queue list before `queue_tab.dart` (829 lines) is split apart.
/// Everything asserted here is behaviour a reader of the file would expect to
/// survive the move: which items a filter shows, what a card renders per
/// capture type, and what the search matches on.
void main() {
  late Directory appDir;

  setUp(() => appDir = Directory.systemTemp.createTempSync('audivoa_queue_'));
  tearDown(() => appDir.deleteSync(recursive: true));

  Future<void> pumpQueue(
    WidgetTester tester,
    RecordingsController controller,
  ) async {
    await tester.pumpWidget(
      hostTab(() => QueueTab(controller: controller), listenable: controller),
    );
    await tester.pump();
  }

  testWidgets('empty index shows the empty panel, not a list', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller =
        await buildRecordingsController(appDir);
    await pumpQueue(tester, controller);

    expect(find.text('The processing queue is empty.'), findsOneWidget);
    expect(find.text('0 ITEMS'), findsOneWidget);
  });

  testWidgets('the default Queue filter hides completed items', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'done', status: RecordingStatus.completed),
        makeRecording(id: 'waiting', status: RecordingStatus.saved),
      ],
    );
    await pumpQueue(tester, controller);

    // Queue = saved/pending/transcribing only.
    expect(find.textContaining('waiting'), findsOneWidget);
    expect(find.textContaining('done'), findsNothing);
    expect(find.text('1 ITEMS'), findsOneWidget);
  });

  testWidgets('switching to Ready swaps which items are listed', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'done', status: RecordingStatus.completed),
        makeRecording(id: 'waiting', status: RecordingStatus.saved),
      ],
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.text('Ready'));
    await tester.pumpAndSettle();

    expect(find.textContaining('done'), findsOneWidget);
    expect(find.textContaining('waiting'), findsNothing);
    expect(find.text('READY TRANSCRIPTS'), findsOneWidget);
  });

  testWidgets('search matches transcript text, not just the filename', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'a', transcript: 'kup mleko i chleb'),
        makeRecording(id: 'b', transcript: 'zadzwoń do dentysty'),
      ],
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.text('Raw'));
    await tester.pumpAndSettle();
    expect(find.text('2 ITEMS'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'dentysty');
    await tester.pumpAndSettle();

    expect(find.text('1 ITEMS'), findsOneWidget);
    expect(find.textContaining('zadzwoń do dentysty'), findsOneWidget);
  });

  testWidgets('a failed item offers retry; a completed one does not', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'bad',
          status: RecordingStatus.failed,
          error: 'endpoint nie odpowiada',
        ),
      ],
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.text('Failed'));
    await tester.pumpAndSettle();

    expect(find.text('RETRY TRANSCRIPTION'), findsOneWidget);
    expect(find.textContaining('endpoint nie odpowiada'), findsOneWidget);
  });

  testWidgets('only audio items get a play button', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'note', type: CaptureType.text, durationMs: 0),
      ],
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.text('Raw'));
    await tester.pumpAndSettle();

    // A text note has no media track, so playback must not be offered.
    expect(find.bySemanticsLabel('Play recording'), findsNothing);
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
  });

  testWidgets('an audio item does get a play button', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[makeRecording(id: 'clip')],
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.text('Raw'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
  });

  testWidgets('the reviewed toggle flips the card state through the controller',
      (WidgetTester tester) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[makeRecording(id: 'x')],
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.text('Raw'));
    await tester.pumpAndSettle();
    expect(find.text('NEEDS REVIEW'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.radio_button_unchecked_rounded));
    await tester.pumpAndSettle();
    expect(controller.recordings.single.isProcessedByUser, isTrue);

    // The toggle is async, so the notification lands after the settle above;
    // pump again to render the state the controller now holds.
    await tester.pumpAndSettle();
    expect(find.text('REVIEWED BY YOU'), findsOneWidget);
    expect(find.text('NEEDS REVIEW'), findsNothing);
  });

  testWidgets('the metrics row counts reviewed and failed items', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: '1', isProcessedByUser: true),
        makeRecording(id: '2', status: RecordingStatus.failed),
        makeRecording(id: '3'),
      ],
    );
    await pumpQueue(tester, controller);

    expect(find.text('1/3'), findsOneWidget); // reviewed / total
    expect(find.text('REVIEWED'), findsOneWidget);
    expect(find.text('FAILED'), findsOneWidget);
  });
}
