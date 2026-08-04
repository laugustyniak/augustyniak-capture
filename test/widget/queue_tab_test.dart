import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:audivoa_core/app/ui_kit.dart';
import 'package:audivoa_core/features/recordings/domain/capture_category.dart';
import 'package:audivoa_core/features/recordings/domain/capture_type.dart';
import 'package:audivoa_core/features/recordings/domain/recording.dart';
import 'package:audivoa_core/features/recordings/presentation/queue_tab.dart';
import 'package:audivoa_core/features/recordings/presentation/recording_card.dart';
import 'package:audivoa_core/features/recordings/presentation/recordings_controller.dart';

import '../support/harness.dart';

/// Taken from the widget rather than retyped, so renaming the label cannot
/// leave a test asserting a string nothing renders any more.
const String openLabel = RecordingCard.openVideoLabel;

/// A 1×1 PNG. The decoder goes by content, not by the `.thumb.jpg` name, and a
/// real image is what makes the difference between "poster rendered" and
/// "poster fell back" observable.
final Uint8List _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8'
  'BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

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

  /// Lets real filesystem work finish: opening a source stats the file, and
  /// `Image.file` reads and decodes one — neither of which the fake-async zone
  /// a tap runs in will ever advance. `runAsync` hands the isolate back to the
  /// real event loop; the following `pump` renders what completion produced.
  Future<void> settleIo(WidgetTester tester) async {
    for (int i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  testWidgets('empty index shows the empty panel, not a list', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
    );
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

  testWidgets('search matches tags', (WidgetTester tester) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'acme', tags: <String>['project:acme']),
        makeRecording(id: 'other', tags: <String>['project:other']),
      ],
    );
    await pumpQueue(tester, controller);

    await tester.enterText(find.byType(TextField).first, 'project:acme');
    await tester.pumpAndSettle();

    expect(find.textContaining('acme.m4a'), findsOneWidget);
    expect(find.textContaining('other.m4a'), findsNothing);
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

  testWidgets('text and image items get neither play nor open', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'note', type: CaptureType.text, durationMs: 0),
        makeRecording(id: 'scan', type: CaptureType.image, durationMs: 0),
      ],
    );
    await pumpQueue(tester, controller);

    // Neither has a media track: no in-app playback, and nothing the system
    // player would be handed either.
    expect(find.bySemanticsLabel('Play recording'), findsNothing);
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    expect(find.bySemanticsLabel(openLabel), findsNothing);
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
    // Audio plays *in* the app, so it is the stateful control, not the
    // external-launch one.
    expect(find.bySemanticsLabel('Play recording'), findsOneWidget);
    expect(find.bySemanticsLabel(openLabel), findsNothing);
  });

  testWidgets('a video item offers the external open control', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[makeRecording(id: 'clip', type: CaptureType.video)],
    );
    await pumpQueue(tester, controller);

    // Same glyph as audio, different affordance: there is nothing to stop
    // afterwards, so it never becomes the in-app stop button.
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.bySemanticsLabel('Play recording'), findsNothing);
    // Two targets, one action: the leading tile is tappable for a video even
    // before a poster has been extracted for it.
    expect(find.bySemanticsLabel(openLabel), findsNWidgets(2));
  });

  testWidgets('tapping open hands the video source to the platform', (
    WidgetTester tester,
  ) async {
    final File source = File(p.join(appDir.path, 'clip.mp4'))
      ..writeAsBytesSync(<int>[0, 1, 2]);
    final FakeMediaOpener opener = FakeMediaOpener();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      mediaOpener: opener,
      seed: <Recording>[
        makeRecording(
          id: 'clip',
          type: CaptureType.video,
          filePath: source.path,
        ),
      ],
    );
    await pumpQueue(tester, controller);

    // `.last` is the row's play control; `.first` is the leading tile, covered
    // by the poster test below.
    await tester.tap(find.bySemanticsLabel(openLabel).last);
    await settleIo(tester);

    expect(opener.opened, <String>[source.path]);
    // Nothing failed on the way out, so no banner.
    expect(controller.error, isNull);
  });

  testWidgets('a poster replaces the type icon, and is itself a play target', (
    WidgetTester tester,
  ) async {
    final File source = File(p.join(appDir.path, 'clip.mp4'))
      ..writeAsBytesSync(<int>[0, 1, 2]);
    final File poster = File(p.join(appDir.path, 'clip.thumb.jpg'))
      ..writeAsBytesSync(_pixel);
    final FakeMediaOpener opener = FakeMediaOpener();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      mediaOpener: opener,
      seed: <Recording>[
        makeRecording(
          id: 'clip',
          type: CaptureType.video,
          filePath: source.path,
          thumbPath: poster.path,
        ),
      ],
    );
    await pumpQueue(tester, controller);
    await settleIo(tester);

    expect(find.byType(ConsolePosterTile), findsOneWidget);
    // The fallback is only built when the decode fails, so a live poster means
    // no movie glyph anywhere on the card.
    expect(find.byIcon(Icons.movie_outlined), findsNothing);

    // Poster and button are the same action, so both carry the same label.
    expect(find.bySemanticsLabel(openLabel), findsNWidgets(2));
    await tester.tap(find.bySemanticsLabel(openLabel).first);
    await settleIo(tester);

    expect(opener.opened, <String>[source.path]);
  });

  testWidgets('a missing poster file degrades to the type icon', (
    WidgetTester tester,
  ) async {
    // The path is a *claim*: the poster is derived, so it can be cleaned up,
    // truncated or never written while the row still names it.
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'clip',
          type: CaptureType.video,
          thumbPath: p.join(appDir.path, 'gone.thumb.jpg'),
        ),
      ],
    );
    await pumpQueue(tester, controller);
    await settleIo(tester);

    expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
    // A dead poster costs a thumbnail, never the card or the action on it.
    expect(find.bySemanticsLabel(openLabel), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the reviewed toggle flips the card state through the controller',
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
    },
  );

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

    expect(find.text('DONE'), findsOneWidget);
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
    expect(find.text('#client'), findsOneWidget);
    expect(find.text('#call'), findsOneWidget);
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

  /// Renders one card on its own. The enrichment stage has no persisted status
  /// — it is a flag the controller only holds while an HTTP call is open — so
  /// driving the card directly is what makes that window observable without
  /// standing up a gated fake service behind the whole queue.
  Future<void> pumpCard(
    WidgetTester tester, {
    required bool isEnriching,
  }) async {
    await tester.pumpWidget(
      hostTab(
        () => RecordingCard(
          recording: makeRecording(
            id: 'fresh',
            status: RecordingStatus.completed,
            transcript: 'zadzwonić do klienta w piątek',
          ),
          isPlaying: false,
          isEnriching: isEnriching,
          onTogglePlay: () {},
          onOpen: () {},
          onRetry: () {},
          onEdit: () {},
          onToggleProcessed: () {},
        ),
      ),
    );
    // Never `pumpAndSettle` here: both `ScanLine` and the pill's `PulseDot`
    // repeat forever, so "no frames scheduled" is a state this card never
    // reaches.
    await tester.pump();
  }

  testWidgets('a card being enriched says so and runs the scan line', (
    WidgetTester tester,
  ) async {
    await pumpCard(tester, isEnriching: true);

    expect(find.text('ANALYZING'), findsOneWidget);
    expect(find.byType(ScanLine), findsOneWidget);
    expect(find.text(RecordingCard.analyzingLabel), findsOneWidget);
    // The resting label is gone while the model is working, so the two states
    // are never on screen at once.
    expect(find.text('READY'), findsNothing);
    // The item is already durable, and the card still says so.
    expect(find.textContaining('file verified'), findsOneWidget);
    expect(find.text('RETRY'), findsNothing);

    // A few frames of the animation, to prove it drives without throwing.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a card that is not being enriched shows the resting state', (
    WidgetTester tester,
  ) async {
    await pumpCard(tester, isEnriching: false);

    expect(find.text('READY'), findsOneWidget);
    expect(find.byType(ScanLine), findsNothing);
    expect(find.text(RecordingCard.analyzingLabel), findsNothing);
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

  testWidgets('the edit sheet creates and clears tags', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'taggable', tags: <String>['old']),
      ],
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Tags'),
      ' Project:Acme, client, CLIENT,  ',
    );
    await tester.tap(find.text('SAVE'));
    await tester.pumpAndSettle();

    expect(controller.recordings.single.tags, <String>[
      'project:acme',
      'client',
    ]);
    expect(find.text('#project:acme'), findsOneWidget);
    expect(find.text('#client'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Tags'), '');
    await tester.tap(find.text('SAVE'));
    await tester.pumpAndSettle();

    expect(controller.recordings.single.tags, isEmpty);
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
