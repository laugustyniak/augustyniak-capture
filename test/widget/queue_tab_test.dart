import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audivoa_core/features/recordings/domain/capture_category.dart';
import 'package:audivoa_core/features/recordings/domain/capture_type.dart';
import 'package:audivoa_core/features/recordings/domain/recording.dart';
import 'package:audivoa_core/features/recordings/presentation/queue_tab.dart';
import 'package:audivoa_core/features/recordings/presentation/recordings_controller.dart';

import '../support/harness.dart';

/// Guards the queue list: which items a filter shows, what a card renders per
/// capture type, what the search matches on, and — since the design put counts
/// on the chips — that those counts partition the queue instead of
/// double-counting it.
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

    expect(find.text('Nothing captured yet.'), findsOneWidget);
    expect(find.text('0 captures'), findsOneWidget);
  });

  testWidgets('the default All filter lists every item', (
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

    expect(find.textContaining('done'), findsOneWidget);
    expect(find.textContaining('waiting'), findsOneWidget);
    expect(find.text('2 captures'), findsOneWidget);
  });

  testWidgets('the chip counts partition the queue, and All is their sum', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      // Only terminal statuses: `initialize()` resumes anything left
      // non-terminal by a previous session, so a seeded `pendingTranscription`
      // would be drained out of the queue bucket before the first frame.
      seed: <Recording>[
        makeRecording(id: 'done', status: RecordingStatus.completed),
        makeRecording(id: 'raw', status: RecordingStatus.saved),
        makeRecording(id: 'bad', status: RecordingStatus.failed),
      ],
    );
    await pumpQueue(tester, controller);

    expect(find.text('ALL 3'), findsOneWidget);
    // pendingTranscription + transcribing — one bucket, as the pipeline sees it.
    expect(find.text('QUEUE 0'), findsOneWidget);
    expect(find.text('READY 1'), findsOneWidget);
    expect(find.text('FAILED 1'), findsOneWidget);
    // `raw` is "persisted but not queued yet", not "everything".
    expect(find.text('RAW 1'), findsOneWidget);
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

    await tester.tap(find.text('READY 1'));
    await tester.pumpAndSettle();

    expect(find.textContaining('done'), findsOneWidget);
    expect(find.textContaining('waiting'), findsNothing);
  });

  testWidgets('the chip counts ignore the search box', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'a', transcript: 'buy milk and bread'),
        makeRecording(id: 'b', transcript: 'call the dentist'),
      ],
    );
    await pumpQueue(tester, controller);

    await tester.enterText(find.byType(TextField).first, 'dentist');
    await tester.pumpAndSettle();

    expect(find.textContaining('call the dentist'), findsOneWidget);
    expect(find.textContaining('buy milk'), findsNothing);
    // The chip still describes the queue, not the query.
    expect(find.text('ALL 2'), findsOneWidget);
  });

  testWidgets('a failed item offers retry and shows its error', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'bad',
          status: RecordingStatus.failed,
          error: 'endpoint is not responding',
        ),
      ],
    );
    await pumpQueue(tester, controller);

    expect(find.text('RETRY'), findsOneWidget);
    expect(find.text('FAILED'), findsOneWidget);
    expect(find.textContaining('endpoint is not responding'), findsOneWidget);
  });

  testWidgets('a completed item offers no retry', (WidgetTester tester) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[makeRecording(id: 'ok')],
    );
    await pumpQueue(tester, controller);

    expect(find.text('RETRY'), findsNothing);
    expect(find.text('READY'), findsOneWidget);
  });

  testWidgets('every card states the durability guarantee', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'sized', sizeBytes: 2 * 1024 * 1024),
        // A legacy row that never recorded a size omits the segment rather
        // than printing `0 B`.
        makeRecording(id: 'legacy'),
      ],
    );
    await pumpQueue(tester, controller);

    expect(find.text('file verified · 2.0 MB · persisted'), findsOneWidget);
    expect(find.text('file verified · persisted'), findsOneWidget);
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

    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
  });

  testWidgets('the reviewed toggle flips the card state through the controller',
      (WidgetTester tester) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[makeRecording(id: 'x')],
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.byIcon(Icons.radio_button_unchecked_rounded));
    await tester.pumpAndSettle();
    expect(controller.recordings.single.isProcessedByUser, isTrue);

    // The toggle is async, so the notification lands after the settle above;
    // pump again to render the state the controller now holds.
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
  });

  testWidgets('the reviewed strip counts reviewed against the whole queue', (
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

    expect(find.text('REVIEWED'), findsOneWidget);
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('a card shows its category and summary', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'enriched',
          status: RecordingStatus.completed,
          transcript: 'zadzwonić do klienta w piątek',
          category: CaptureCategory.task,
          summary: 'Call the client on Friday.',
          tags: <String>['client', 'call'],
        ),
      ],
    );
    await pumpQueue(tester, controller);

    expect(find.text('TASK'), findsOneWidget);
    expect(find.text('Call the client on Friday.'), findsOneWidget);
    // The pipeline pill is still there beside it.
    expect(find.text('READY'), findsOneWidget);
  });

  testWidgets('an un-enriched card shows no category and no summary', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'plain',
          status: RecordingStatus.completed,
          transcript: 'jakiś tekst',
        ),
      ],
    );
    await pumpQueue(tester, controller);

    // An install with no enrichment profile renders the card it always did.
    for (final CaptureCategory value in CaptureCategory.values) {
      expect(find.text(value.label), findsNothing);
    }
  });

  testWidgets('the edit sheet corrects a wrong category', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'wrong',
          status: RecordingStatus.completed,
          transcript: 'pomysł na nową funkcję',
          category: CaptureCategory.task,
          tags: <String>['idea'],
        ),
      ],
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    // The model's verdict is what the dropdown opens on.
    expect(find.text('Category'), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<CaptureCategory?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('IDEA').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('SAVE'));
    await tester.pumpAndSettle();

    expect(controller.recordings.single.category, CaptureCategory.idea);
  });

  testWidgets('the edit sheet clears a category back to unclassified', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'clearable',
          status: RecordingStatus.completed,
          transcript: 'cokolwiek',
          category: CaptureCategory.note,
        ),
      ],
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<CaptureCategory?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('—').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('SAVE'));
    await tester.pumpAndSettle();

    expect(controller.recordings.single.category, isNull);
  });
}
