import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:augustyniak_capture/app/ui_kit.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_category.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/queue_tab.dart';
import 'package:augustyniak_capture/features/recordings/presentation/queue_toolbar.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_card.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_editor.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/projects/data/projects_repository.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/projects/presentation/projects_controller.dart';

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

  setUp(
    () => appDir = Directory.systemTemp.createTempSync(
      'augustyniak_capture_queue_',
    ),
  );
  tearDown(() => appDir.deleteSync(recursive: true));

  Future<void> pumpQueue(
    WidgetTester tester,
    RecordingsController controller, {
    ProjectsController? projects,
  }) async {
    await tester.pumpWidget(
      hostTab(
        () => QueueTab(controller: controller, projects: projects),
        listenable: projects == null
            ? controller
            : Listenable.merge(<Listenable>[controller, projects]),
      ),
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

  /// The five status buckets moved from a chip row onto one menu button when
  /// the toolbar collapsed to a single line, so selecting one is now two taps.
  /// The button always names the active bucket and its count.
  Future<void> openStatusMenu(WidgetTester tester) async {
    await tester.tap(find.byType(QueueStatusMenu));
    await tester.pumpAndSettle();
  }

  Future<void> selectStatus(WidgetTester tester, String label) async {
    await openStatusMenu(tester);
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
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
        // Titled, because the row is located by name below and an untitled
        // capture no longer prints its uuid filename there.
        makeRecording(
          id: 'done',
          title: 'done',
          status: RecordingStatus.completed,
        ),
        makeRecording(
          id: 'waiting',
          title: 'waiting',
          status: RecordingStatus.saved,
        ),
      ],
    );
    await pumpQueue(tester, controller);

    expect(find.textContaining('done'), findsOneWidget);
    expect(find.textContaining('waiting'), findsOneWidget);
    expect(find.text('2 captures'), findsOneWidget);
  });

  testWidgets('an untitled capture names itself by type and time, not by id', (
    WidgetTester tester,
  ) async {
    // Without an enrichment profile nothing ever writes a title, so this is
    // what the whole queue looks like on an unconfigured install. It used to
    // be a column of uuids: not merely uninformative but mutually
    // indistinguishable, which is what stops a list being scannable at all.
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: '416cd0e0-9930-4b90-8dd9-74155343cd47',
          transcript: 'zobaczmy czy nadal działa ładowanie',
        ),
      ],
    );
    await pumpQueue(tester, controller);

    expect(find.textContaining('416cd0e0'), findsNothing);
    // Not asserting the clock itself: it is rendered in local time, so a fixed
    // string here would pass only in the timezone it was written in.
    expect(find.textContaining('Voice note · '), findsOneWidget);
    // The name does not repeat the excerpt: the transcript is rendered once,
    // in the body, which is why the fallback is not derived from it.
    expect(find.text('zobaczmy czy nadal działa ładowanie'), findsOneWidget);
  });

  testWidgets('arrow keys move a selection and D closes the selected row', (
    WidgetTester tester,
  ) async {
    // The app ships system-wide global hotkeys, and until this existed the
    // window itself had one key binding in it. Reaching the third card meant
    // roughly fifteen presses of Tab.
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'first', title: 'first'),
        makeRecording(id: 'second', title: 'second'),
      ],
    );
    await pumpQueue(tester, controller);

    // Nothing is selected until the user asks: a selection they did not make
    // would put the first keystroke on an arbitrary capture.
    RecordingCard cardFor(String title) => tester.widget<RecordingCard>(
      find.ancestor(of: find.text(title), matching: find.byType(RecordingCard)),
    );
    expect(cardFor('first').focused, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(cardFor('first').focused, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(cardFor('second').focused, isTrue);
    expect(cardFor('first').focused, isFalse);

    // Clamped, not wrapped: arrowing past the end should stop, not jump back
    // to the top of a list the user has just walked down.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(cardFor('second').focused, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await tester.pumpAndSettle();
    expect(
      controller.recordings
          .firstWhere((Recording item) => item.id == 'second')
          .isProcessedByUser,
      isTrue,
    );
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

    // The bar names the active bucket; the other four keep their counts inside
    // the menu, which is what the single-line toolbar traded a chip row for.
    expect(find.text('ALL 3'), findsOneWidget);

    await openStatusMenu(tester);
    expect(find.text('ALL 3'), findsNWidgets(2));
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
        // Titled, because the row is located by name below and an untitled
        // capture no longer prints its uuid filename there.
        makeRecording(
          id: 'done',
          title: 'done',
          status: RecordingStatus.completed,
        ),
        makeRecording(
          id: 'waiting',
          title: 'waiting',
          status: RecordingStatus.saved,
        ),
      ],
    );
    await pumpQueue(tester, controller);

    await selectStatus(tester, 'READY 1');

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
        makeRecording(
          id: 'acme',
          title: 'acme capture',
          tags: <String>['project:acme'],
        ),
        makeRecording(
          id: 'other',
          title: 'other capture',
          tags: <String>['project:other'],
        ),
      ],
    );
    await pumpQueue(tester, controller);

    await tester.enterText(find.byType(TextField).first, 'project:acme');
    await tester.pumpAndSettle();

    // The filename is still searchable — it just no longer poses as the title.
    expect(find.textContaining('acme capture'), findsOneWidget);
    expect(find.textContaining('other capture'), findsNothing);
  });

  testWidgets('every tag is one kind: removable, whoever proposed it', (
    WidgetTester tester,
  ) async {
    // The provenance model is gone, so a tag enrichment suggested and a tag
    // typed by hand are the same object — same colour on the card, and both
    // removable in the editor. Under the old model the suggested one rendered
    // violet and had no remove control at all.
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'tagged', tags: <String>['manual', 'suggested']),
      ],
    );
    await pumpQueue(tester, controller);

    expect(
      tester.widget<Text>(find.text('#manual')).style?.color,
      Console.accent,
    );
    expect(
      tester.widget<Text>(find.text('#suggested')).style?.color,
      Console.accent,
    );

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();
    tester
        .widget<InkResponse>(
          find.descendant(
            of: find.bySemanticsLabel('Remove tag suggested'),
            matching: find.byType(InkResponse),
          ),
        )
        .onTap!();
    await settleIo(tester);

    expect(controller.recordings.single.tags, <String>['manual']);
  });

  testWidgets('filters and assigns captures by project', (
    WidgetTester tester,
  ) async {
    final ProjectsController projects = ProjectsController(
      repository: ProjectsRepository(directoryProvider: () async => appDir),
    );
    addTearDown(projects.dispose);
    final List<Project> projectFixtures = (await tester.runAsync(() async {
      await projects.initialize();
      return <Project>[
        await projects.create(name: 'Acme', repoPath: '/work/acme'),
        await projects.create(name: 'Other', repoPath: '/work/other'),
      ];
    }))!;
    final Project acme = projectFixtures[0];
    final Project other = projectFixtures[1];
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'acme-recording',
          title: 'acme-recording',
          projectId: acme.id,
        ),
        makeRecording(
          id: 'other-recording',
          title: 'other-recording',
          projectId: other.id,
        ),
        makeRecording(id: 'unassigned', title: 'unassigned'),
      ],
    );
    await pumpQueue(tester, controller, projects: projects);

    await tester.tap(find.byType(DropdownButtonFormField<String?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Acme').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('acme-recording'), findsOneWidget);
    expect(find.textContaining('other-recording'), findsNothing);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();
    final Finder otherProjectChip = find.text('Other').last;
    tester
        .widget<InkWell>(
          find.ancestor(of: otherProjectChip, matching: find.byType(InkWell)),
        )
        .onTap!();
    await settleIo(tester);
    expect(controller.recordings.first.projectId, other.id);
  });

  testWidgets('a wide window puts search, project and filters on one line', (
    WidgetTester tester,
  ) async {
    // The stacked layout is what the rest of this suite exercises, since the
    // default 800 px test window is below the strip's single-line threshold.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final ProjectsController projects = ProjectsController(
      repository: ProjectsRepository(directoryProvider: () async => appDir),
    );
    addTearDown(projects.dispose);
    await tester.runAsync(() async {
      await projects.initialize();
      await projects.create(name: 'Acme', repoPath: '/work/acme');
    });
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[makeRecording(id: 'only')],
    );
    await pumpQueue(tester, controller, projects: projects);

    // An overflowing Row reports as a rendering exception rather than a failed
    // assertion, so it has to be claimed explicitly.
    expect(tester.takeException(), isNull);

    final double searchY = tester.getCenter(find.byType(TextField)).dy;
    final double projectY = tester
        .getCenter(find.byType(DropdownButtonFormField<String?>))
        .dy;
    final double chipsY = tester.getCenter(find.text('ALL 1')).dy;
    expect((projectY - searchY).abs(), lessThan(4));
    expect((chipsY - searchY).abs(), lessThan(4));

    // The compact selector drops the floating label for a hint; the value it
    // shows must still be the one the stacked layout shows.
    expect(find.text('All projects'), findsOneWidget);
    expect(find.text('Project'), findsNothing);
  });

  testWidgets('deleting the selected project resets the Queue filter', (
    WidgetTester tester,
  ) async {
    final ProjectsController projects = ProjectsController(
      repository: ProjectsRepository(directoryProvider: () async => appDir),
    );
    addTearDown(projects.dispose);
    final Project project = (await tester.runAsync(() async {
      await projects.initialize();
      return projects.create(name: 'Temporary', repoPath: '/work/temporary');
    }))!;
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'assigned', title: 'assigned', projectId: project.id),
        makeRecording(id: 'unassigned', title: 'unassigned'),
      ],
    );
    await pumpQueue(tester, controller, projects: projects);

    await tester.tap(find.byType(DropdownButtonFormField<String?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Temporary').last);
    await tester.pumpAndSettle();
    expect(find.text('unassigned'), findsNothing);

    await tester.runAsync(() => projects.delete(project.id));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('assigned'), findsOneWidget);
    expect(find.text('unassigned'), findsOneWidget);
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

  testWidgets('a completed item offers LLM enrichment, not processing retry', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'ok', transcript: 'persisted note text'),
      ],
    );
    await pumpQueue(tester, controller);

    expect(find.text('RETRY'), findsNothing);
    expect(find.text('ENRICH'), findsOneWidget);
    // The resting state draws no badge at all: a pill is a claim that something
    // is different, and READY was on almost every row.
    expect(find.text('READY'), findsNothing);
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

  testWidgets('the reviewed toggle closes the row out of the default view', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[makeRecording(id: 'x')],
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.byIcon(Icons.radio_button_unchecked_rounded));
    await tester.pump();
    await settleIo(tester);
    expect(controller.recordings.single.isProcessedByUser, isTrue);
    expect(find.text('MOVED TO DONE'), findsOneWidget);

    // The acknowledgement deliberately outlives the card, then leaves without
    // requiring a dismissal.
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pumpAndSettle();

    // The point of the review axis: closing an item *removes* it from the
    // default view. Before, the queue held every capture ever taken and the
    // toggle only restyled a row, so the list could never shrink.
    expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
    expect(find.text("Desk clear — it's all with someone."), findsOneWidget);

    // And it is not lost — it moved to the other side of the same axis.
    await tester.tap(find.text('OFF DESK 1'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
  });

  testWidgets('Done shows a busy state and ignores a second tap while saving', (
    WidgetTester tester,
  ) async {
    final Completer<void> saveGate = Completer<void>();
    final FakeRecordingsRepository repository = FakeRecordingsRepository(
      appDir,
      seed: <Recording>[makeRecording(id: 'x')],
      saveGate: saveGate.future,
    );
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      repository: repository,
    );
    await pumpQueue(tester, controller);

    final Finder doneControl = find.bySemanticsLabel('Mark as done');
    final Offset doneButton = tester.getCenter(doneControl);
    await tester.tap(doneControl);
    await tester.pump(const Duration(milliseconds: 100));
    expect(repository.saveCalls, 1);
    expect(find.byKey(const ValueKey<String>('marking-done')), findsOneWidget);
    expect(find.text('MOVING TO DONE…'), findsOneWidget);

    await tester.tapAt(doneButton);
    await tester.pump();
    expect(repository.saveCalls, 1);

    saveGate.complete();
    await tester.pump();
    await settleIo(tester);
    expect(find.text('MOVED TO DONE'), findsOneWidget);
  });

  testWidgets('a failed Done write rolls back and offers a retry', (
    WidgetTester tester,
  ) async {
    final FakeRecordingsRepository repository = FakeRecordingsRepository(
      appDir,
      seed: <Recording>[makeRecording(id: 'x')],
      saveError: FileSystemException('disk full'),
    );
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      repository: repository,
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.byIcon(Icons.radio_button_unchecked_rounded));
    await tester.pump();
    await settleIo(tester);

    expect(controller.recordings.single.isProcessedByUser, isFalse);
    expect(find.text('COULD NOT MOVE · TRY AGAIN'), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
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

    // The three review segments split the queue, and the hairline under the bar
    // reads against the whole of it rather than against whatever the segments
    // currently show. There is no `1 / 3` caption: it would be the numerator and
    // the denominator beside it restated as a fraction.
    expect(find.text('DESK 2'), findsOneWidget);
    expect(find.text('OFF DESK 1'), findsOneWidget);
    expect(find.text('ANY 3'), findsOneWidget);
    expect(find.text('1 / 3'), findsNothing);

    await tester.pumpAndSettle();
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.descendant(
              of: find.byType(QueueToolbar),
              matching: find.byType(LinearProgressIndicator),
            ),
          )
          .value,
      closeTo(1 / 3, 0.001),
    );
    // The sentence the caption used to print is still reachable — on the line
    // itself, by pointer and by screen reader.
    expect(find.byTooltip('Handed off 1 of 3'), findsOneWidget);
  });

  testWidgets('empty panel names combined status and review filters', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[makeRecording(id: 'ready')],
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.text('OFF DESK 0'));
    await tester.pumpAndSettle();
    await selectStatus(tester, 'FAILED 0');

    expect(
      find.text('Nothing matches the selected status and review filters.'),
      findsOneWidget,
    );
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
    // …and the resting pipeline state adds no pill beside it, so the category
    // is the only badge on a finished row.
    expect(find.text('READY'), findsNothing);
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
          onEnrich: () {},
          onEdit: () {},
          onToggleProcessed: () {},
          onRoute: () {},
          onHandoff: () {},
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
    expect(find.text('ENRICH'), findsOneWidget);

    // A few frames of the animation, to prove it drives without throwing.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a card that is not being enriched shows the resting state', (
    WidgetTester tester,
  ) async {
    await pumpCard(tester, isEnriching: false);

    // Resting means silent: no ANALYZING, and no READY either.
    expect(find.text('READY'), findsNothing);
    expect(find.byType(ScanLine), findsNothing);
    expect(find.text(RecordingCard.analyzingLabel), findsNothing);
    expect(find.text('ENRICH'), findsOneWidget);
  });

  testWidgets('the inline editor corrects a wrong category', (
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
    await tester.pump();
    expect(find.text('CATEGORY'), findsOneWidget);
    await tester.tap(find.text('IDEA').last);
    await settleIo(tester);

    expect(controller.recordings.single.category, CaptureCategory.idea);
  });

  testWidgets('the inline editor creates and clears tags', (
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
    await tester.pump();
    final Finder oldTag = find.bySemanticsLabel('Remove tag old');
    tester
        .widget<InkResponse>(
          find.descendant(of: oldTag, matching: find.byType(InkResponse)),
        )
        .onTap!();
    await settleIo(tester);
    await tester.enterText(
      find.widgetWithText(TextField, '+ add tag'),
      ' Project:Acme, client, CLIENT,  ',
    );
    await settleIo(tester);

    expect(controller.recordings.single.tags, <String>[
      'project:acme',
      'client',
    ]);
    expect(find.text('#project:acme'), findsOneWidget);
    expect(find.text('#client'), findsOneWidget);

    final Finder projectTag = find.bySemanticsLabel('Remove tag project:acme');
    tester
        .widget<InkResponse>(
          find.descendant(of: projectTag, matching: find.byType(InkResponse)),
        )
        .onTap!();
    await settleIo(tester);
    final Finder clientTag = find.bySemanticsLabel('Remove tag client');
    tester
        .widget<InkResponse>(
          find.descendant(of: clientTag, matching: find.byType(InkResponse)),
        )
        .onTap!();
    await settleIo(tester);

    expect(controller.recordings.single.tags, isEmpty);
  });

  /// The editor holds a dirty field in its own state and does not write on
  /// disposal, so anything that drops its row from the list destroys the edit.
  /// These two cover the ways that can happen without the user asking for it.
  testWidgets('a search that excludes the edited row does not close it', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'keepme',
          status: RecordingStatus.completed,
          transcript: 'zachowaj mnie',
        ),
      ],
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();
    final Finder title = find
        .descendant(
          of: find.byType(RecordingEditor),
          matching: find.byType(TextField),
        )
        .first;
    // Typed, not committed: the value exists only inside the editor.
    await tester.enterText(title, 'Nazwa w trakcie pisania');
    await tester.pump();

    await tester.enterText(
      find.widgetWithText(TextField, 'Search captures'),
      'nic-takiego-nie-ma',
    );
    await tester.pump();

    expect(
      find.byType(RecordingEditor),
      findsOneWidget,
      reason: 'the row being edited is exempt from the search',
    );
    expect(find.text('Nazwa w trakcie pisania'), findsOneWidget);

    // And the edit is still committable — the exemption is worthless if the
    // widget survives without its pending value. Scoped to the editor: the
    // review toggle on a card carries a `DONE` label of its own.
    //
    // The footer sits below the fold on a 600 px viewport and the row grows
    // into the editor over 220 ms, so it has to be waited out and scrolled to
    // before the tap has anything to land on. Without this the tap misses
    // silently and the assertion below passes on a title that was never
    // committed through this button.
    final Finder done = find.descendant(
      of: find.byType(RecordingEditor),
      matching: find.text('DONE'),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(done);
    await tester.pump();
    await tester.tap(done);
    await settleIo(tester);

    expect(controller.recordings.single.title, 'Nazwa w trakcie pisania');
    // The button did what it says: edit mode is gone, not merely un-tapped.
    expect(find.byType(RecordingEditor), findsNothing);
  });

  testWidgets('a status chip that excludes the edited row does not close it', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'ready',
          status: RecordingStatus.completed,
          transcript: 'gotowe',
        ),
        makeRecording(
          id: 'broken',
          status: RecordingStatus.failed,
          transcript: 'padło',
          error: 'boom',
        ),
      ],
    );
    await pumpQueue(tester, controller);

    // The completed row is the first card, so its edit control is the first
    // one in the list.
    await tester.tap(find.byIcon(Icons.edit_outlined).first);
    await tester.pump();
    expect(find.byType(RecordingEditor), findsOneWidget);

    await selectStatus(tester, 'FAILED 1');

    expect(
      find.byType(RecordingEditor),
      findsOneWidget,
      reason: 'a bucket the item no longer belongs to must not end the mode',
    );
  });

  testWidgets('the inline editor clears a category back to unclassified', (
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
    await tester.pump();
    await tester.tap(find.text('—').last);
    await settleIo(tester);

    expect(controller.recordings.single.category, isNull);
  });

  testWidgets('deletion is only reachable from the editor', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[makeRecording(id: 'keep', transcript: 'text')],
    );
    await pumpQueue(tester, controller);

    // The card's action strip is play/edit/done — all cheap, all reversible.
    expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();

    // The editor's footer sits below the fold on a 600 px viewport, so it has
    // to be scrolled into view before the semantics tree describes it — which
    // is also the only state in which a user could reach it.
    // The row grows into the editor over 220 ms; scrolling to the footer before
    // that lands would aim at a box that is still card-sized.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.byIcon(Icons.delete_outline_rounded));
    await tester.pump();
    expect(find.bySemanticsLabel(RecordingEditor.deleteLabel), findsOneWidget);
  });

  testWidgets('DELETE asks first, and cancelling keeps the capture', (
    WidgetTester tester,
  ) async {
    final File source = File(p.join(appDir.path, 'doomed.m4a'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'doomed',
          title: 'A bad take',
          transcript: 'text',
          filePath: source.path,
        ),
      ],
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();
    // The row grows into the editor over 220 ms; scrolling to the footer before
    // that lands would aim at a box that is still card-sized.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.byIcon(Icons.delete_outline_rounded));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel(RecordingEditor.deleteLabel));
    // Long enough for the dialog's entrance to finish. With a single pump its
    // buttons are still being laid out, and a tap aimed at CANCEL lands off
    // screen — which this test cannot see, because "cancelled" and "missed"
    // leave the identical state behind.
    await tester.pump(const Duration(milliseconds: 300));

    // The dialog names the item, because the queue rows all look alike.
    expect(find.text('Delete this capture?'), findsOneWidget);
    // Scoped to the dialog — the editor's title field holds the same words.
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('A bad take'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('CANCEL'));
    await settleIo(tester);

    // Asserted first: it is the only thing that distinguishes a real cancel
    // from a tap that never landed on the button.
    expect(find.text('Delete this capture?'), findsNothing);
    expect(controller.recordings, hasLength(1));
    expect(source.existsSync(), isTrue);
    // Still in edit mode: backing out of the dialog decided nothing.
    expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);
  });

  testWidgets('confirming DELETE removes the row, the file and the mode', (
    WidgetTester tester,
  ) async {
    final File source = File(p.join(appDir.path, 'doomed.m4a'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'doomed', transcript: 'text', filePath: source.path),
        makeRecording(id: 'kept', transcript: 'other'),
      ],
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.byIcon(Icons.edit_outlined).first);
    await tester.pump();
    // The row grows into the editor over 220 ms; scrolling to the footer before
    // that lands would aim at a box that is still card-sized.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.byIcon(Icons.delete_outline_rounded));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel(RecordingEditor.deleteLabel));
    await tester.pump(const Duration(milliseconds: 300));
    // Scoped to the dialog: the editor's own button carries the same word, and
    // tapping that one again would only reopen what is already open.
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('DELETE'),
      ),
    );
    await settleIo(tester);

    expect(controller.recordings.map((Recording item) => item.id), <String>[
      'kept',
    ]);
    expect(source.existsSync(), isFalse);
    // Edit mode left with the row it belonged to, rather than lingering on an
    // id nothing in the queue answers to any more.
    expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
  });
}
