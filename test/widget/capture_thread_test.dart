import 'dart:io';
import 'dart:ui' as ui;

import 'package:augustyniak_capture/app/ui_kit.dart';
import 'package:augustyniak_capture/features/recordings/data/revisions_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording_revision.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:augustyniak_capture/features/recordings/presentation/capture_focus_view.dart';
import 'package:augustyniak_capture/features/recordings/presentation/capture_thread.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/settings/domain/audio_config.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

CaptureSegment _segment(
  int index,
  DateTime at, {
  String? text = 'words',
  String? error,
  CaptureType type = CaptureType.audioRecording,
}) => CaptureSegment(
  index: index,
  filePath: '/tmp/t-$index.m4a',
  type: type,
  createdAt: at,
  text: text,
  error: error,
);

Recording _row({
  List<CaptureSegment>? segments,
  List<RouteRecord> routes = const <RouteRecord>[],
}) => Recording(
  id: 't',
  filePath: '/tmp/t.m4a',
  createdAt: DateTime.utc(2026, 7, 27, 12),
  durationMs: 1000,
  sizeBytes: 10,
  status: RecordingStatus.completed,
  type: CaptureType.audioRecording,
  transcript: 'words',
  title: 'Original',
  routes: routes,
  segments: segments,
);

RecordingRevision _revision(DateTime at, {String field = 'title'}) =>
    RecordingRevision(
      recordingId: 't',
      at: at,
      field: field,
      from: 'a',
      to: 'b',
      source: RevisionSource.user,
    );

RouteRecord _route(DateTime at, {RouteOutcome? outcome}) => RouteRecord(
  at: at,
  kind: RouteKind.command,
  target: 'Command · launch',
  outcome: outcome,
);

/// Two fragments, one route with an outcome, one revision: the AC's capture.
/// Deliberately handed to the thread out of time order.
Recording _fourEntryRow() => _row(
  segments: <CaptureSegment>[
    _segment(0, DateTime.utc(2026, 7, 27, 12)),
    _segment(1, DateTime.utc(2026, 7, 27, 13), type: CaptureType.image),
  ],
  routes: <RouteRecord>[
    _route(
      DateTime.utc(2026, 7, 27, 14),
      outcome: RouteOutcome(
        briefId: 'b1',
        state: CommandState.inProgress,
        checkedAt: DateTime.utc(2026, 7, 27, 15),
      ),
    ),
  ],
);

class _MemoryRevisions extends RevisionsRepository {
  @override
  Future<Map<String, List<RecordingRevision>>> load() async =>
      <String, List<RecordingRevision>>{};

  @override
  Future<void> append(List<RecordingRevision> revisions) async {}
}

void main() {
  late Directory appDir;
  setUp(() => appDir = Directory.systemTemp.createTempSync('capture_thread_'));
  tearDown(() => appDir.deleteSync(recursive: true));

  Future<void> pumpThread(
    WidgetTester tester,
    Recording recording,
    List<RecordingRevision> revisions,
  ) async {
    await tester.pumpWidget(
      hostTab(() => CaptureThread(recording: recording, revisions: revisions)),
    );
    await tester.pump();
  }

  test('entries are ordered by time, oldest first, across all three kinds', () {
    final List<ThreadEntry> entries = CaptureThread.entriesFor(
      _fourEntryRow(),
      <RecordingRevision>[_revision(DateTime.utc(2026, 7, 27, 12, 30))],
    );
    expect(entries.map((ThreadEntry e) => e.kind), <ThreadEntryKind>[
      ThreadEntryKind.segment,
      ThreadEntryKind.revision,
      ThreadEntryKind.segment,
      ThreadEntryKind.route,
    ]);
    expect(
      entries.map((ThreadEntry e) => e.at).toList(),
      orderedEquals(entries.map((ThreadEntry e) => e.at).toList()..sort()),
    );
  });

  test('equal timestamps keep list position: segments, routes, revisions', () {
    final DateTime same = DateTime.utc(2026, 7, 27, 12);
    final List<ThreadEntry> entries = CaptureThread.entriesFor(
      _row(
        segments: <CaptureSegment>[_segment(0, same), _segment(1, same)],
        routes: <RouteRecord>[_route(same)],
      ),
      <RecordingRevision>[_revision(same)],
    );
    expect(entries.map((ThreadEntry e) => e.kind), <ThreadEntryKind>[
      ThreadEntryKind.segment,
      ThreadEntryKind.segment,
      ThreadEntryKind.route,
      ThreadEntryKind.revision,
    ]);
  });

  testWidgets(
    '2 fragments, a route with an outcome and a revision: 4 entries',
    (WidgetTester tester) async {
      await pumpThread(tester, _fourEntryRow(), <RecordingRevision>[
        _revision(DateTime.utc(2026, 7, 27, 12, 30)),
      ]);

      expect(find.text('THREAD'), findsOneWidget);
      expect(find.byKey(CaptureThread.entryKey), findsNWidgets(4));
      expect(find.textContaining('Capture'), findsWidgets);
      expect(find.textContaining('Fragment 1'), findsOneWidget);
      expect(find.textContaining('Command · launch'), findsOneWidget);
      expect(find.textContaining('IN PROGRESS'), findsOneWidget);
      expect(find.textContaining('title changed'), findsOneWidget);
      // Time order: the revision (12:30) sits between the two fragments.
      final List<String> order = tester
          .widgetList<Text>(find.byKey(CaptureThread.entryTitleKey))
          .map((Text t) => t.data!)
          .toList();
      expect(order, <String>[
        'Capture · voice note',
        'title changed',
        'Fragment 1 · image',
        'Command · launch',
      ]);
      expect(find.textContaining('show all'), findsNothing);
    },
  );

  testWidgets('a failed fragment says FAILED, a pending one says PENDING', (
    WidgetTester tester,
  ) async {
    await pumpThread(
      tester,
      _row(
        segments: <CaptureSegment>[
          _segment(0, DateTime.utc(2026, 7, 27, 12)),
          _segment(1, DateTime.utc(2026, 7, 27, 13), error: 'boom'),
          _segment(2, DateTime.utc(2026, 7, 27, 14), text: null),
        ],
      ),
      const <RecordingRevision>[],
    );
    expect(find.text('DONE'), findsOneWidget);
    expect(find.text('FAILED'), findsOneWidget);
    expect(find.text('PENDING'), findsOneWidget);
  });

  testWidgets('a legacy row has no THREAD section', (
    WidgetTester tester,
  ) async {
    await pumpThread(tester, _row(), const <RecordingRevision>[]);
    expect(find.text('THREAD'), findsNothing);
    expect(find.byKey(CaptureThread.entryKey), findsNothing);
  });

  testWidgets('more than 5 entries collapse to the last 5; show all expands', (
    WidgetTester tester,
  ) async {
    final Recording row = _row(
      segments: <CaptureSegment>[
        for (int i = 0; i < 7; i++)
          _segment(i, DateTime.utc(2026, 7, 27, 12 + i)),
      ],
    );
    await pumpThread(tester, row, const <RecordingRevision>[]);

    expect(find.byKey(CaptureThread.entryKey), findsNWidgets(5));
    // The newest are kept, the oldest folded away.
    expect(find.textContaining('Fragment 6'), findsOneWidget);
    expect(find.textContaining('Fragment 1 '), findsNothing);
    expect(find.text('show all (7)'), findsOneWidget);

    await tester.tap(find.text('show all (7)'));
    await tester.pump();
    expect(find.byKey(CaptureThread.entryKey), findsNWidgets(7));
    expect(find.text('show less'), findsOneWidget);

    await tester.tap(find.text('show less'));
    await tester.pump();
    expect(find.byKey(CaptureThread.entryKey), findsNWidgets(5));
  });

  testWidgets('the detail panel shows a THREAD after a hand edit', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = RecordingsController(
      repository: FakeRecordingsRepository(
        appDir,
        seed: <Recording>[_fourEntryRow()],
      ),
      transcriptionService: const DisabledTranscriptionService(),
      recorder: FakeRecorder(),
      revisionsRepository: _MemoryRevisions(),
      player: FakePlayer(),
      audioConfig: const AudioConfig(sampleRate: 16000, bitRate: 64000),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Future<void> pumpPanel() async {
      await tester.pumpWidget(
        hostTab(
          () => CaptureDetailPanel(
            controller: controller,
            recording: controller.recordings.single,
            projectName: null,
            showMetaColumn: false,
            onEdit: () {},
            onToggleProcessed: () {},
          ),
          listenable: controller,
        ),
      );
      await tester.pump();
      // The panel overflows by a few pixels under the test binding's fallback
      // font even with no thread on the row (verified); that is not what this
      // test is about, so the layout error is drained.
      _drainKnownOverflow(tester);
    }

    await pumpPanel();
    expect(find.byKey(CaptureThread.entryKey), findsNWidgets(3));

    await tester.runAsync(() => controller.setTitle('t', 'Renamed'));
    await tester.pump();
    _drainKnownOverflow(tester);
    expect(controller.revisionsFor('t'), isNotEmpty);
    expect(find.byKey(CaptureThread.entryKey), findsNWidgets(4));
    expect(find.text('title changed'), findsOneWidget);
  });

  final String? out = Platform.environment['CAPTURE_THREAD_PNG'];
  testWidgets('renders the thread to a PNG when asked', skip: out == null, (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      Future<void> load(String family, List<String> paths) async {
        final FontLoader loader = FontLoader(family);
        for (final String path in paths) {
          if (!File(path).existsSync()) continue;
          final Uint8List bytes = File(path).readAsBytesSync();
          loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
        }
        await loader.load();
      }

      const List<String> weights = <String>[
        'Regular',
        'Medium',
        'SemiBold',
        'Bold',
      ];
      await load('SpaceGrotesk', <String>[
        for (final String w in weights) 'assets/fonts/SpaceGrotesk-$w.ttf',
      ]);
      await load('JetBrainsMono', <String>[
        for (final String w in weights) 'assets/fonts/JetBrainsMono-$w.ttf',
      ]);
      final String? root = Platform.environment['FLUTTER_ROOT'];
      if (root != null) {
        await load('MaterialIcons', <String>[
          '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ]);
      }
    });
    tester.view.physicalSize = const Size(640, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      hostTab(
        () => RepaintBoundary(
          key: const Key('thread-png'),
          child: ColoredBox(
            color: Console.background,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: CaptureThread(
                recording: _fourEntryRow(),
                revisions: <RecordingRevision>[
                  _revision(DateTime.utc(2026, 7, 27, 12, 30)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final RenderRepaintBoundary boundary = tester
        .renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('thread-png')),
        );
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 2);
      final ByteData? bytes = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      File(out!).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}

/// Drains only the panel's known overflow (54 px under the test font, present
/// with no thread on the row); any other layout error still fails the test.
void _drainKnownOverflow(WidgetTester tester) {
  Object? error;
  while ((error = tester.takeException()) != null) {
    expect(error.toString(), contains('overflowed by 54'));
  }
}
